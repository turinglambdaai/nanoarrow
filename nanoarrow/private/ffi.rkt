#lang racket/base

;; Low-level FFI bindings to libnanoarrow_shared / libnanoarrow_ipc (v0.9.x).
;;
;; Every C struct declared here was transcribed from the nanoarrow 0.9.0
;; headers (nanoarrow.h, nanoarrow/common/inline_types.h, nanoarrow_ipc.h)
;; and its size is asserted against the C layout by
;; nanoarrow/test/nanoarrow-test.rkt. Do not reorder struct fields.
;;
;; Library discovery: plain dlopen search first (respects
;; DYLD_FALLBACK_LIBRARY_PATH / LD_LIBRARY_PATH), then well-known install
;; prefixes and the NANOARROW_LIBRARY_DIR environment variable. The fallback
;; probing exists because `raco test` worker processes do not inherit
;; DYLD_* variables on macOS.

(require racket/string
         ffi/unsafe
         ffi/unsafe/define)

(provide (all-defined-out))

;; ---------------------------------------------------------------------------
;; Library loading

(define runtime-lib-extension
  (case (system-type 'os)
    [(macosx) "dylib"]
    [(unix) "so"]
    [else "dll"]))

(define candidate-directories
  (append
   (let ([env (getenv "NANOARROW_LIBRARY_DIR")])
     (if env (list env) '()))
   '("/opt/homebrew/opt/nanoarrow/lib"      ; Homebrew (Apple silicon)
     "/usr/local/opt/nanoarrow/lib"          ; Homebrew (Intel mac)
     "/usr/local/lib"
     "~/.nanoarrow/lib")))                   ; CI source-build prefix

(define (candidate-paths base-names)
  ;; The plain name lets the platform loader search DYLD_FALLBACK_LIBRARY_PATH
  ;; / LD_LIBRARY_PATH / default paths; explicit prefixes cover the case where
  ;; the environment variable did not survive into this process. Versioned
  ;; names are probed too, for installations that ship them.  macOS Homebrew
  ;; and Linux CMake disagree on the file names: libnanoarrow_ipc_shared vs
  ;; libnanoarrow_ipc — try every known base name.
  (define version-suffixes
    (if (equal? runtime-lib-extension "dylib")
        '("9.dylib" "0.dylib")
        '("so.9" "so.0")))
  (define file-names
    (append
     (for*/list ([base (in-list base-names)])
       (format "lib~a.~a" base runtime-lib-extension))
     (for*/list ([base (in-list base-names)]
                 [suffix (in-list version-suffixes)])
       (format "lib~a.~a" base suffix))))
  (append
   base-names
   (for*/list ([dir (in-list candidate-directories)]
               [file (in-list file-names)])
     (path->string (expand-user-path (build-path dir file))))))

(define (try-ffi-lib spec)
  (with-handlers ([exn:fail:filesystem? (lambda (_) #f)])
    (ffi-lib spec)))

(define (load-nanoarrow-library base-names)
  (define candidates (candidate-paths base-names))
  (or (ormap try-ffi-lib candidates)
      (raise (exn:fail:filesystem
              (format "nanoarrow: could not load lib~a; searched: ~a. Install \
nanoarrow 0.9.x (e.g. `brew install nanoarrow`) or point NANOARROW_LIBRARY_DIR \
at the directory holding the shared libraries."
                      (car base-names)
                      (string-join (map (lambda (c) (if (path? c) (path->string c) c)) candidates)
                                   ", "))
              (current-continuation-marks)))))

(define nanoarrow-lib (load-nanoarrow-library '("nanoarrow_shared" "nanoarrow")))
(define nanoarrow-ipc-lib (load-nanoarrow-library '("nanoarrow_ipc_shared" "nanoarrow_ipc")))

(define-ffi-definer define-nanoarrow nanoarrow-lib)
(define-ffi-definer define-nanoarrow-ipc nanoarrow-ipc-lib)

;; ---------------------------------------------------------------------------
;; Enum constants (from nanoarrow 0.9.0 headers)

;; enum ArrowType (nanoarrow/common/inline_types.h)
(define TYPE-UNINITIALIZED 0)
(define TYPE-BOOL 2)
(define TYPE-UINT8 3)
(define TYPE-INT8 4)
(define TYPE-UINT16 5)
(define TYPE-INT16 6)
(define TYPE-UINT32 7)
(define TYPE-INT32 8)
(define TYPE-UINT64 9)
(define TYPE-INT64 10)
(define TYPE-FLOAT 12)
(define TYPE-DOUBLE 13)
(define TYPE-STRING 14)
(define TYPE-STRUCT 27)
(define TYPE-LARGE-STRING 35)

;; ARROW_FLAG_NULLABLE (Arrow C data interface)
(define FLAG-NULLABLE 2)

;; enum ArrowValidationLevel
(define VALIDATION-FULL 3)

;; enum ArrowIpcMessageType
(define IPC-MESSAGE-TYPE-SCHEMA 1)
(define IPC-MESSAGE-TYPE-RECORD-BATCH 3)

;; struct ArrowError is a 1024-byte char buffer.
(define ARROW-ERROR-SIZE 1024)

;; Arrow IPC end-of-stream marker: continuation 0xFFFFFFFF + length 0.
(define ipc-eos-marker (bytes #xFF #xFF #xFF #xFF #x00 #x00 #x00 #x00))

;; Arrow IPC file magic (6 bytes, padded to 8 at the start of a file).
(define ipc-file-magic #"ARROW1")

;; ---------------------------------------------------------------------------
;; C struct definitions (field order matches the 0.9.0 headers exactly)

(define-cstruct _ArrowBufferAllocator
  ([reallocate _fpointer]
   [free _fpointer]
   [private_data _pointer]))

(define-cstruct _ArrowSchema
  ([format _pointer]
   [name _pointer]
   [metadata _pointer]
   [flags _int64]
   [n_children _int64]
   [children _pointer]
   [dictionary _pointer]
   [release _fpointer]
   [private_data _pointer]))

(define-cstruct _ArrowArray
  ([length _int64]
   [null_count _int64]
   [offset _int64]
   [n_buffers _int64]
   [n_children _int64]
   [buffers _pointer]
   [children _pointer]
   [dictionary _pointer]
   [release _fpointer]
   [private_data _pointer]))

;; struct ArrowLayout: enum[3] + enum[3] + int64[3] + int64, flattened.
(define-cstruct _ArrowLayout
  ([buffer_type_0 _int] [buffer_type_1 _int] [buffer_type_2 _int]
   [buffer_data_type_0 _int] [buffer_data_type_1 _int] [buffer_data_type_2 _int]
   [element_size_bits_0 _int64] [element_size_bits_1 _int64] [element_size_bits_2 _int64]
   [child_size_elements _int64]))

(define-cstruct _ArrowBufferView
  ([data _pointer]
   [size_bytes _int64]))

(define-cstruct _ArrowBuffer
  ([data _pointer]
   [size_bytes _int64]
   [capacity_bytes _int64]
   [allocator _ArrowBufferAllocator]))

(define-cstruct _ArrowSchemaView
  ([schema _pointer]
   [type _int]
   [storage_type _int]
   [layout _ArrowLayout]
   [extension_name _ArrowBufferView]
   [extension_metadata _ArrowBufferView]
   [fixed_size _int32]
   [decimal_bitwidth _int32]
   [decimal_precision _int32]
   [decimal_scale _int32]
   [time_unit _int]
   [timezone _pointer]
   [union_type_ids _pointer]))

;; struct ArrowArrayView with buffer_views[3] flattened into six scalars.
(define-cstruct _ArrowArrayView
  ([array _pointer]
   [offset _int64]
   [length _int64]
   [null_count _int64]
   [storage_type _int]
   [layout _ArrowLayout]
   [buffer_view_0_data _pointer] [buffer_view_0_size _int64]
   [buffer_view_1_data _pointer] [buffer_view_1_size _int64]
   [buffer_view_2_data _pointer] [buffer_view_2_size _int64]
   [n_children _int64]
   [children _pointer]
   [dictionary _pointer]
   [union_type_id_map _pointer]
   [n_variadic_buffers _int32]
   [variadic_buffers _pointer]
   [variadic_buffer_sizes _pointer]))

(define-cstruct _ArrowIpcDecoder
  ([message_type _int]
   [metadata_version _int]
   [endianness _int]
   [feature_flags _int32]
   [codec _int]
   [header_size_bytes _int32]
   [body_size_bytes _int64]
   [dictionary _pointer]
   [footer _pointer]
   [private_data _pointer]))

(define-cstruct _ArrowIpcEncoder
  ([private_data _pointer]))

(define-cstruct _ArrowIpcWriter
  ([private_data _pointer]))

(define-cstruct _ArrowIpcOutputStream
  ([write _fpointer]
   [release _fpointer]
   [private_data _pointer]))

;; ---------------------------------------------------------------------------
;; Small helpers

;; define-cstruct constructors take a value for every field; these build the
;; zero-initialized structs the nanoarrow Init* functions expect.
(define (new-ArrowSchema)
  (make-ArrowSchema #f #f #f 0 0 #f #f #f #f))

(define (new-ArrowArray)
  (make-ArrowArray 0 0 0 0 0 #f #f #f #f #f))

(define (zero-ArrowLayout) (make-ArrowLayout 0 0 0 0 0 0 0 0 0 0))

(define (new-ArrowArrayView)
  (make-ArrowArrayView
   #f 0 0 0 0
   (zero-ArrowLayout)
   #f 0 #f 0 #f 0
   0 #f #f #f 0 #f #f))

(define (new-ArrowSchemaView)
  (make-ArrowSchemaView
   #f 0 0
   (zero-ArrowLayout)
   (make-ArrowBufferView #f 0)
   (make-ArrowBufferView #f 0)
   0 0 0 0 0 #f #f))

(define (new-ArrowIpcDecoder)
  (make-ArrowIpcDecoder 0 0 0 0 0 0 0 #f #f #f))

(define (new-ArrowBuffer)
  (make-ArrowBuffer #f 0 0 (make-ArrowBufferAllocator #f #f #f)))

(define (new-ArrowIpcWriter) (make-ArrowIpcWriter #f))

(define (new-ArrowIpcOutputStream) (make-ArrowIpcOutputStream #f #f #f))

(define (make-arrow-error)
  ;; A zeroed 1024-byte block usable as `struct ArrowError*`.
  (make-bytes ARROW-ERROR-SIZE 0))

(define (arrow-error-message err)
  ;; Extract the NUL-terminated message from an ArrowError buffer.
  (define len
    (let loop ([i 0])
      (cond [(>= i ARROW-ERROR-SIZE) ARROW-ERROR-SIZE]
            [(zero? (bytes-ref err i)) i]
            [else (loop (add1 i))])))
  (bytes->string/utf-8 (subbytes err 0 len)))

;; NULL C pointers surface as #f in _pointer-typed struct fields.
(define (release-arrow-schema! schema)
  ;; Invoke schema->release exactly once (the callback NULLs itself).
  (define release (ArrowSchema-release schema))
  (when release
    ((cast release _fpointer (_fun _pointer -> _void)) schema)))

(define (release-arrow-array! array)
  ;; Invoke array->release exactly once.
  (define release (ArrowArray-release array))
  (when release
    ((cast release _fpointer (_fun _pointer -> _void)) array)))

;; Child accessors for the `children` (struct **) fields.
(define (arrow-schema-child schema i)
  (cast (ptr-ref (ArrowSchema-children schema) _pointer i)
        _pointer _ArrowSchema-pointer))

(define (arrow-array-child array i)
  (cast (ptr-ref (ArrowArray-children array) _pointer i)
        _pointer _ArrowArray-pointer))

(define (arrow-array-view-child view i)
  (cast (ptr-ref (ArrowArrayView-children view) _pointer i)
        _pointer _ArrowArrayView-pointer))

;; Read a NUL-terminated C string field of a struct as a Racket string
;; (or #f for NULL).
(define (c-string-field ptr)
  (and ptr (let ([s (cast ptr _pointer _string/utf-8)]) (and s (string-copy s)))))

;; ---------------------------------------------------------------------------
;; Function bindings: nanoarrow core

(define-nanoarrow ArrowNanoarrowVersion (_fun -> _string))

(define-nanoarrow ArrowSchemaInit (_fun _ArrowSchema-pointer -> _void))
(define-nanoarrow ArrowSchemaInitFromType (_fun _ArrowSchema-pointer _int -> _int))
(define-nanoarrow ArrowSchemaSetTypeStruct (_fun _ArrowSchema-pointer _int64 -> _int))
(define-nanoarrow ArrowSchemaSetType (_fun _ArrowSchema-pointer _int -> _int))
(define-nanoarrow ArrowSchemaSetName (_fun _ArrowSchema-pointer _string/utf-8 -> _int))
(define-nanoarrow ArrowSchemaToString
  (_fun _ArrowSchema-pointer (out : (_bytes o 512)) (_int64 = 512) (_byte = 1)
        -> _int64
        -> (values out)))

(define-nanoarrow ArrowSchemaViewInit
  (_fun _ArrowSchemaView-pointer _ArrowSchema-pointer _pointer -> _int))

(define-nanoarrow ArrowBufferAllocatorDefault (_fun -> _ArrowBufferAllocator))
(define-nanoarrow ArrowFree (_fun _pointer -> _void))

;; Release the data owned by an ArrowBuffer allocated with the default
;; allocator. (ArrowBufferReset itself is a static inline in the headers and
;; is not exported by the shared library.)
(define (free-arrow-buffer-data! buffer)
  (define data (ArrowBuffer-data buffer))
  (when data
    (ArrowFree data))
  (set-ArrowBuffer-data! buffer #f)
  (set-ArrowBuffer-size_bytes! buffer 0)
  (set-ArrowBuffer-capacity_bytes! buffer 0))

(define-nanoarrow ArrowArrayViewInitFromSchema
  (_fun _ArrowArrayView-pointer _ArrowSchema-pointer _pointer -> _int))
(define-nanoarrow ArrowArrayViewSetArray
  (_fun _ArrowArrayView-pointer _ArrowArray-pointer _pointer -> _int))
(define-nanoarrow ArrowArrayViewReset (_fun _ArrowArrayView-pointer -> _void))

;; ---------------------------------------------------------------------------
;; Function bindings: nanoarrow IPC

(define-nanoarrow-ipc ArrowIpcCheckRuntime (_fun _pointer -> _int))

(define-nanoarrow-ipc ArrowIpcDecoderInit (_fun _ArrowIpcDecoder-pointer -> _int))
(define-nanoarrow-ipc ArrowIpcDecoderReset (_fun _ArrowIpcDecoder-pointer -> _void))
(define-nanoarrow-ipc ArrowIpcDecoderPeekHeader
  (_fun _ArrowIpcDecoder-pointer _ArrowBufferView
        (prefix-size : (_ptr o _int32)) _pointer
        -> _int
        -> prefix-size))
(define-nanoarrow-ipc ArrowIpcDecoderVerifyHeader
  (_fun _ArrowIpcDecoder-pointer _ArrowBufferView _pointer -> _int))
(define-nanoarrow-ipc ArrowIpcDecoderDecodeHeader
  (_fun _ArrowIpcDecoder-pointer _ArrowBufferView _pointer -> _int))
(define-nanoarrow-ipc ArrowIpcDecoderDecodeSchema
  (_fun _ArrowIpcDecoder-pointer _ArrowSchema-pointer _pointer -> _int))
(define-nanoarrow-ipc ArrowIpcDecoderSetSchema
  (_fun _ArrowIpcDecoder-pointer _ArrowSchema-pointer _pointer -> _int))
(define-nanoarrow-ipc ArrowIpcDecoderDecodeArray
  (_fun _ArrowIpcDecoder-pointer _ArrowBufferView _int64
        _ArrowArray-pointer _int _pointer
        -> _int))

(define-nanoarrow-ipc ArrowIpcOutputStreamInitBuffer
  (_fun _ArrowIpcOutputStream-pointer _ArrowBuffer-pointer -> _int))

(define-nanoarrow-ipc ArrowIpcWriterInit
  (_fun _ArrowIpcWriter-pointer _ArrowIpcOutputStream-pointer -> _int))
(define-nanoarrow-ipc ArrowIpcWriterReset (_fun _ArrowIpcWriter-pointer -> _void))
(define-nanoarrow-ipc ArrowIpcWriterStartFile (_fun _ArrowIpcWriter-pointer _pointer -> _int))
(define-nanoarrow-ipc ArrowIpcWriterFinalizeFile (_fun _ArrowIpcWriter-pointer _pointer -> _int))
(define-nanoarrow-ipc ArrowIpcWriterWriteSchema
  (_fun _ArrowIpcWriter-pointer _ArrowSchema-pointer _pointer -> _int))
(define-nanoarrow-ipc ArrowIpcWriterWriteArrayView
  (_fun _ArrowIpcWriter-pointer _ArrowArrayView-pointer _pointer -> _int))

;; ---------------------------------------------------------------------------
;; Guarded call helpers

;; Raise a clear exn:fail when a nanoarrow function returns a non-zero code.
(define (check-rc who rc err)
  (unless (zero? rc)
    (raise (exn:fail
            (format "nanoarrow: ~a failed (code ~a)~a"
                    who
                    rc
                    (let ([msg (arrow-error-message err)])
                      (if (string=? msg "") "" (format ": ~a" msg))))
            (current-continuation-marks)))))

(define (raise-nanoarrow-error message-format . args)
  (raise (exn:fail (apply format message-format args) (current-continuation-marks))))
