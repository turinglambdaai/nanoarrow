#lang racket/base

;; Arrow IPC message framing: decode FILE/STREAM bytes into a record batch's
;; schema + struct ArrowArray, and encode them back via ArrowIpcWriter.
;;
;; Reader: walks encapsulated IPC messages (PeekHeader -> VerifyHeader ->
;; DecodeHeader), binds the first Schema message with ArrowIpcDecoderSetSchema
;; and decodes the first RecordBatch message body into an ArrowArray with
;; ArrowIpcDecoderDecodeArray (field index -1 = whole struct). Parsing stops
;; as soon as the record batch is in hand: pyarrow-style files continue with
;; an EOS marker + footer, while nanoarrow's own writer appends the footer
;; directly without an EOS marker, so neither tail is interpreted as a
;; message. Decoding FULL-validates buffers, so corrupt input cannot make us
;; read out of bounds; the decoder copies buffer bytes out of the input, so
;; the returned array is self-contained.
;;
;; Writer: builds the output through ArrowIpcWriter (StartFile /
;; WriteSchema / WriteArrayView / FinalizeFile for the FILE format;
;; WriteSchema / WriteArrayView for the STREAM format) into an ArrowBuffer
;; output sink. The ArrowIpcEncoder reads only length/offset/buffer_views
;; from the view, never view->array.

(require ffi/unsafe
         "ffi.rkt"
         "arrays.rkt")

(provide parse-ipc-messages
         write-ipc-bytes
         arrow-buffer->bytes!)

;; ---------------------------------------------------------------------------
;; Shared plumbing

(define (ipc-buffer-view bs)
  ;; An ArrowBufferView over a Racket byte string.
  (make-ArrowBufferView bs (bytes-length bs)))

(define (slice-buffer-view bv from)
  ;; View starting `from` bytes into the same memory as bv.
  (make-ArrowBufferView
   (ptr-add (ArrowBufferView-data bv) from)
   (- (ArrowBufferView-size_bytes bv) from)))

(define (arrow-buffer->bytes! buffer)
  ;; Copy the contents of an ArrowBuffer into a Racket byte string. The
  ;; caller keeps ownership of the ArrowBuffer.
  (define size (ArrowBuffer-size_bytes buffer))
  (define out (make-bytes size))
  (when (> size 0)
    (memcpy out (ArrowBuffer-data buffer) size))
  out)

;; ---------------------------------------------------------------------------
;; Reading

;; mode is 'file or 'stream.
(define (parse-ipc-messages input what mode)
  (when (eq? mode 'file)
    (check-file-magic! input what))
  (define body
    (if (eq? mode 'file)
        (subbytes input 8)   ; skip leading "ARROW1" + 2 pad bytes
        input))

  (define decoder (new-ArrowIpcDecoder))
  (define schema (new-ArrowSchema))
  (define array (new-ArrowArray))
  (define err (make-arrow-error))
  ;; The schema/array structs are only handed to the caller on success; on
  ;; any failure the post thunk below releases them. Release calls are no-ops
  ;; while the structs are still untouched (release callback is NULL).
  (define succeeded? #f)
  (dynamic-wind
    (lambda ()
      (check-rc "ArrowIpcDecoderInit" (ArrowIpcDecoderInit decoder) err))
    (lambda ()
      (let loop ([bv (ipc-buffer-view body)])
        (define remaining (ArrowBufferView-size_bytes bv))
        (cond
          ;; Out of bytes without ever seeing a record batch.
          [(<= remaining 0)
           (raise-nanoarrow-error
            "nanoarrow: cannot read ~a: no record batch message found before end of input"
            what)]
          ;; End-of-stream marker (0xFFFFFFFF 00000000).
          [(eos-marker? bv)
           (raise-nanoarrow-error
            "nanoarrow: cannot read ~a: no record batch message found before end of stream"
            what)]
          [else
           (define prefix-size (ArrowIpcDecoderPeekHeader decoder bv err))
           (unless (and (member prefix-size '(4 8)) (exact-integer? prefix-size))
             (framing-error what err))
           (check-rc "ArrowIpcDecoderVerifyHeader"
                         (ArrowIpcDecoderVerifyHeader decoder bv err) err)
           (define header-size (ArrowIpcDecoder-header_size_bytes decoder))
           (define body-size (ArrowIpcDecoder-body_size_bytes decoder))
           (define total (+ header-size body-size))
           (when (> total remaining)
             (raise-nanoarrow-error
              "nanoarrow: cannot read ~a: message needs ~a bytes but only ~a remain \
(input may be truncated)"
              what total remaining))
           (check-rc "ArrowIpcDecoderDecodeHeader"
                         (ArrowIpcDecoderDecodeHeader decoder bv err) err)
           (define message-type (ArrowIpcDecoder-message_type decoder))
           (cond
             [(= message-type IPC-MESSAGE-TYPE-SCHEMA)
              (check-rc "ArrowIpcDecoderDecodeSchema"
                            (ArrowIpcDecoderDecodeSchema decoder schema err) err)
              (check-rc "ArrowIpcDecoderSetSchema"
                            (ArrowIpcDecoderSetSchema decoder schema err) err)
              (loop (slice-buffer-view bv total))]
             [(= message-type IPC-MESSAGE-TYPE-RECORD-BATCH)
              (check-rc "ArrowIpcDecoderDecodeArray"
                            (ArrowIpcDecoderDecodeArray
                             decoder (slice-buffer-view bv header-size) -1
                             array VALIDATION-FULL err)
                            err)
              ;; Done: v0.1 reads exactly one record batch and ignores any
              ;; remaining tail (EOS marker, file footer, further batches).
              (set! succeeded? #t)
              (values schema array (ArrowArray-length array))]
             [else
              ;; Dictionary batches, tensors, etc. get a clear error.
              (raise-nanoarrow-error
               "nanoarrow: cannot read ~a: unsupported IPC message type ~a"
               what message-type)])])))
    (lambda ()
      ;; Failure path: the body above raised, so the structs are ours to
      ;; release (no-ops if untouched). The decoder is always reset.
      (unless succeeded?
        (release-arrow-array! array)
        (release-arrow-schema! schema))
      (ArrowIpcDecoderReset decoder))))

(define (check-file-magic! input what)
  (unless (and (>= (bytes-length input) 16)
               (equal? ipc-file-magic (subbytes input 0 6)))
    (raise-nanoarrow-error
     "nanoarrow: cannot read ~a: wrong magic (an Arrow IPC file must start with \
the 6-byte ARROW1 magic)" what))
  (unless (equal? ipc-file-magic (subbytes input (- (bytes-length input) 6)))
    (raise-nanoarrow-error
     "nanoarrow: cannot read ~a: file does not end with the ARROW1 magic \
(the file may be truncated or corrupt)" what)))

(define (eos-marker? bv)
  (and (>= (ArrowBufferView-size_bytes bv) 8)
       (let ([p (ArrowBufferView-data bv)])
         (and (= (ptr-ref p _uint8 0) #xFF)
              (= (ptr-ref p _uint8 1) #xFF)
              (= (ptr-ref p _uint8 2) #xFF)
              (= (ptr-ref p _uint8 3) #xFF)
              (zero? (ptr-ref p _uint32 4))))))

(define (framing-error what err)
  (define msg (arrow-error-message err))
  (if (string=? msg "")
      (raise-nanoarrow-error
       "nanoarrow: cannot read ~a: invalid IPC message framing (wrong magic or \
corrupt input)" what)
      (raise-nanoarrow-error
       "nanoarrow: cannot read ~a: invalid IPC message framing: ~a" what msg)))

;; ---------------------------------------------------------------------------
;; Writing

;; (write-ipc-bytes schema view file-format?) -> bytes?
;; Writes the schema + one record batch through ArrowIpcWriter into an
;; ArrowBuffer output sink and returns the bytes. file-format? adds the
;; ARROW1 magic and the footer.
(define (write-ipc-bytes schema view file-format?)
  (define output-buffer (new-ArrowBuffer))
  (set-ArrowBuffer-allocator! output-buffer (ArrowBufferAllocatorDefault))
  (define output-stream (new-ArrowIpcOutputStream))
  (define writer (new-ArrowIpcWriter))
  (define err (make-arrow-error))
  (define writer-initialized? #f)

  (dynamic-wind
    (lambda ()
      (check-rc "ArrowIpcOutputStreamInitBuffer"
                    (ArrowIpcOutputStreamInitBuffer output-stream output-buffer)
                    err)
      ;; ArrowIpcWriterInit takes ownership of output-stream.
      (check-rc "ArrowIpcWriterInit"
                    (ArrowIpcWriterInit writer output-stream)
                    err)
      (set! writer-initialized? #t))
    (lambda ()
      (when file-format?
        (check-rc "ArrowIpcWriterStartFile"
                      (ArrowIpcWriterStartFile writer err) err))
      (check-rc "ArrowIpcWriterWriteSchema"
                    (ArrowIpcWriterWriteSchema writer schema err) err)
      (check-rc "ArrowIpcWriterWriteArrayView"
                    (ArrowIpcWriterWriteArrayView writer view err) err)
      (when file-format?
        (check-rc "ArrowIpcWriterFinalizeFile"
                      (ArrowIpcWriterFinalizeFile writer err) err))
      (arrow-buffer->bytes! output-buffer))
    (lambda ()
      (when writer-initialized?
        (ArrowIpcWriterReset writer))   ; releases the output stream too
      (free-arrow-buffer-data! output-buffer))))
