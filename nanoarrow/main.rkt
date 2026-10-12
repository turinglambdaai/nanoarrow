#lang racket/base

;; nanoarrow: read and write Arrow IPC files and streams of primitive-typed
;; record batches from Racket, backed by the Apache Arrow nanoarrow C library
;; (no Arrow C++ or pyarrow required).
;;
;; See nanoarrow/scribblings/nanoarrow.scrbl for the full documentation,
;; including the type mapping table and platform notes.

(require racket/contract
         racket/flonum
         (except-in ffi/unsafe ->)
         "private/ffi.rkt"
         (prefix-in schema: "private/schema.rkt")
         (prefix-in arrays: "private/arrays.rkt")
         (prefix-in ipc: "private/ipc.rkt"))

(provide
 (contract-out
  ;; Version string of the underlying nanoarrow C library, e.g. "0.9.0".
  [nanoarrow-version (-> string?)]
  ;; Predicates and contracts for the public data types.
  [arrow-type? predicate/c]
  [arrow-type/c contract?]
  [column/c contract?]
  [record-batch/c contract?]
  ;; One column description: name, supported type symbol, nullability.
  ;; Nullable fields must still not CONTAIN nulls in this version.
  [struct arrow-field ([name string?] [type arrow-type/c] [nullable boolean?])]
  ;; One record batch: row count plus parallel fields/columns.
  [struct record-batch
    ([num-rows exact-nonnegative-integer?]
     [fields (listof arrow-field?)]
     [columns (vectorof column/c)])]
  ;; Arrow IPC FILE format (ARROW1 magic + footer), one record batch.
  [ipc-file->record-batch (-> bytes? record-batch?)]
  [record-batch->ipc-file (-> record-batch? bytes?)]
  ;; Arrow IPC STREAM format (no magic, no footer), one record batch.
  [ipc-stream->record-batch (-> bytes? record-batch?)]
  [record-batch->ipc-stream (-> record-batch? bytes?)]))

;; ---------------------------------------------------------------------------
;; Public data structures

;; A single column: name, supported type symbol, nullability flag. A nullable
;; field still must not CONTAIN nulls in this version.
(struct arrow-field (name type nullable)
  #:transparent
  #:guard (lambda (name type nullable own-name)
            (unless (string? name)
              (raise-argument-error own-name "string?" name))
            (unless (arrow-type? type)
              (raise-argument-error own-name "arrow-type?" type))
            (unless (boolean? nullable)
              (raise-argument-error own-name "boolean?" nullable))
            (values name type nullable)))

;; One record batch: row count plus parallel lists of fields and columns.
;; A column's Racket representation depends on its field type:
;;   bool -> (vectorof boolean?), int8..uint64 -> (vectorof exact-integer?),
;;   float32/float64 -> flvector?, string -> (vectorof string?).
(struct record-batch (num-rows fields columns)
  #:transparent
  #:guard (lambda (num-rows fields columns own-name)
            (unless (exact-nonnegative-integer? num-rows)
              (raise-argument-error own-name "exact-nonnegative-integer?" num-rows))
            (unless (and (list? fields) (andmap arrow-field? fields))
              (raise-argument-error own-name "(listof arrow-field?)" fields))
            (unless (and (vector? columns)
                         (= (vector-length columns) (length fields)))
              (raise-argument-error
               own-name
               "a vector of columns, parallel to the list of fields"
               columns))
            (for ([field (in-list fields)]
                  [column (in-vector columns)]
                  [i (in-naturals)])
              (arrays:check-column! i (arrow-field-type field) column num-rows))
            (values num-rows fields columns)))

;; ---------------------------------------------------------------------------
;; Contracts

(define arrow-type/c
  (or/c 'bool 'int8 'int16 'int32 'int64
        'uint8 'uint16 'uint32 'uint64
        'float32 'float64 'string))

;; A flat contract instead of an or/c of vectorof contracts: an empty vector
;; would otherwise match two alternatives at once and raise a contract error.
(define (column-value? v)
  (or (flvector? v)
      (and (vector? v)
           (let ([elems (vector->list v)])
             (or (andmap boolean? elems)
                 (andmap exact-integer? elems)
                 (andmap string? elems))))))
(define column/c (flat-named-contract 'arrow-column column-value?))

(define record-batch/c
  (struct/c record-batch
            exact-nonnegative-integer?
            (listof (struct/c arrow-field string? arrow-type/c boolean?))
            (vectorof column/c)))

;; ---------------------------------------------------------------------------
;; Public API

;; Version of the underlying nanoarrow C library.
(define (nanoarrow-version) (ArrowNanoarrowVersion))

;; Supported column type symbols.
(define (arrow-type? t) (schema:supported-type? t))

;; (ipc-file->record-batch bytes) -> record-batch?
;; Decodes an Arrow IPC FILE format payload (ARROW1 magic + footer) holding
;; exactly one record batch. Additional record batches, if present, are
;; ignored in this version.
(define (ipc-file->record-batch input)
  (convert-input->record-batch input 'file "IPC file"))

;; (ipc-stream->record-batch bytes) -> record-batch?
;; Same as ipc-file->record-batch for the Arrow IPC STREAM format (no magic,
;; no footer).
(define (ipc-stream->record-batch input)
  (convert-input->record-batch input 'stream "IPC stream"))

;; (record-batch->ipc-file batch) -> bytes?
;; Encodes a record batch as an Arrow IPC FILE format payload.
(define (record-batch->ipc-file batch) (convert-record-batch->bytes batch #t))

;; (record-batch->ipc-stream batch) -> bytes?
;; Encodes a record batch as an Arrow IPC STREAM format payload.
(define (record-batch->ipc-stream batch) (convert-record-batch->bytes batch #f))

;; ---------------------------------------------------------------------------
;; Internals

(define (convert-input->record-batch input mode what)
  (unless (bytes? input)
    (raise-argument-error what "bytes?" input))
  (define-values (schema array num-rows)
    (ipc:parse-ipc-messages input what mode))
  ;; From here on we own schema and array; the post thunk releases both on
  ;; every exit path (schema may already be consumed by
  ;; arrow-schema-fields!, tracked below).
  (define view (new-ArrowArrayView))
  (define schema-released? #f)
  (dynamic-wind
    (lambda () #f)
    (lambda ()
      (define err (make-arrow-error))
      (check-rc "ArrowArrayViewInitFromSchema"
                    (ArrowArrayViewInitFromSchema view schema err)
                    err)
      (check-rc "ArrowArrayViewSetArray"
                    (ArrowArrayViewSetArray view array err)
                    err)
      (arrays:check-root-no-nulls! view)
      ;; Extract field metadata first; it validates that every column type is
      ;; supported and consumes (releases) the schema.
      (define fields
        (for/list ([spec (in-list (schema:arrow-schema-fields! schema))])
          (arrow-field (list-ref spec 0) (list-ref spec 1) (list-ref spec 2))))
      (set! schema-released? #t)
      (define n-children (ArrowArrayView-n_children view))
      (unless (= n-children (length fields))
        (raise-nanoarrow-error
         "nanoarrow: record batch has ~a columns but its schema declares ~a fields"
         n-children (length fields)))
      (define columns
        (for/vector ([field (in-list fields)]
                     [i (in-naturals)])
          (define child-view (arrow-array-view-child view i))
          (arrays:check-no-nulls! (arrow-field-name field) child-view)
          (arrays:decode-column-view (arrow-field-name field)
                                     (arrow-field-type field)
                                     child-view
                                     num-rows)))
      (record-batch num-rows fields columns))
    (lambda ()
      ;; Reset the view before releasing the array it points at.
      (ArrowArrayViewReset view)
      (release-arrow-array! array)
      (unless schema-released?
        (release-arrow-schema! schema)))))

(define (convert-record-batch->bytes batch file-format?)
  (define num-rows (record-batch-num-rows batch))
  (define fields (record-batch-fields batch))
  (define columns (record-batch-columns batch))
  ;; The Racket byte strings backing the buffers must stay reachable for the
  ;; whole write, hence this outer scope.
  (define buffer-list
    (for/list ([field (in-list fields)]
               [column (in-vector columns)]
               [i (in-naturals)])
      (arrays:column-byte-buffers (arrow-field-type field) column num-rows)))
  (define schema
    (schema:build-arrow-schema
     (for/list ([field (in-list fields)])
       (list (arrow-field-name field)
             (arrow-field-type field)
             (arrow-field-nullable field)))))
  ;; From here on we own the schema.
  (dynamic-wind
    (lambda () #f)
    (lambda ()
      (define view (new-ArrowArrayView))
      (dynamic-wind
        (lambda () #f)
        (lambda ()
          (define err (make-arrow-error))
          (check-rc "ArrowArrayViewInitFromSchema"
                        (ArrowArrayViewInitFromSchema view schema err)
                        err)
          (define shells (populate-view! view fields buffer-list num-rows))
          ;; Keep the shells and the backing bytes alive until the write is
          ;; done (everything is returned/enclosed here anyway).
          (begin0
            (ipc:write-ipc-bytes schema view file-format?)
            (void shells buffer-list)))
        (lambda ()
          (ArrowArrayViewReset view))))
    (lambda ()
      (release-arrow-schema! schema))))

;; A minimal ArrowArray shell for the IPC encoder: the encoder reads
;; length/null_count/n_buffers/n_children (and recurses over children) from
;; the array each view points at, but only ever reads view buffer_views for
;; content, so the shells carry no buffers and no release callback. They stay
;; reachable from this module's lexical scope for as long as the encoder can
;; touch them.
(define (array-shell length n-buffers)
  (define shell (make-ArrowArray length 0 0 n-buffers 0 #f #f #f #f #f))
  (when (> n-buffers 0)
    (define table (malloc _pointer n-buffers 'raw))
    (for ([i (in-range n-buffers)])
      (ptr-set! table _pointer i #f))
    (set-ArrowArray-buffers! shell table))
  shell)

;; Fill a freshly initialized ArrowArrayView (root struct + child views) with
;; array shells, lengths, and buffer views pointing into the Racket-owned
;; buffer bytes. Returns the list of shells so the caller keeps them alive
;; until the write completes.
(define (populate-view! view fields buffer-list num-rows)
  (define root-shell (array-shell num-rows 0))
  (set-ArrowArrayView-array! view root-shell)
  (set-ArrowArrayView-offset! view 0)
  (set-ArrowArrayView-length! view num-rows)
  (set-ArrowArrayView-null_count! view 0)
  (set-ArrowArrayView-buffer_view_0_data! view #f)
  (set-ArrowArrayView-buffer_view_0_size! view 0)
  (define shells
    (for/list ([field (in-list fields)]
               [buffers (in-list buffer-list)]
               [i (in-naturals)])
      (define child (arrow-array-view-child view i))
      (set-ArrowArrayView-array! child (array-shell num-rows 0))
      (set-ArrowArrayView-offset! child 0)
      (set-ArrowArrayView-length! child num-rows)
      (set-ArrowArrayView-null_count! child 0)
      (set-ArrowArrayView-buffer_view_0_data! child #f)
      (set-ArrowArrayView-buffer_view_0_size! child 0)
      ;; buffers is (list validity offsets/data ...); slot 0 stays empty.
      (case (arrow-field-type field)
        [(string)
         (set-ArrowArrayView-buffer_view_1_data! child (list-ref buffers 1))
         (set-ArrowArrayView-buffer_view_1_size! child (bytes-length (list-ref buffers 1)))
         (set-ArrowArrayView-buffer_view_2_data! child (list-ref buffers 2))
         (set-ArrowArrayView-buffer_view_2_size! child (bytes-length (list-ref buffers 2)))
         (array-shell num-rows 3)]
        [else
         (set-ArrowArrayView-buffer_view_1_data! child (list-ref buffers 1))
         (set-ArrowArrayView-buffer_view_1_size! child (bytes-length (list-ref buffers 1)))
         (array-shell num-rows 2)])))
  (for ([field (in-list fields)]
        [shell (in-list shells)]
        [i (in-naturals)])
    (set-ArrowArrayView-array! (arrow-array-view-child view i) shell))
  (cons root-shell shells))

;; ---------------------------------------------------------------------------

(module+ main
  (require racket/cmdline
           racket/file)
  (define file
    (command-line
     #:program "nanoarrow"
     #:usage-help
     "Convert between an Arrow IPC file and a printed record batch summary."
     "With --info, print the nanoarrow library version."
     #:once-each
     [("--info") "Print nanoarrow version and exit."
      (printf "nanoarrow (Racket bindings) on libnanoarrow ~a\n" (nanoarrow-version))
      (exit 0)]
     #:args (file)
     file))
  (define batch (ipc-file->record-batch (file->bytes file)))
  (printf "rows: ~a\n" (record-batch-num-rows batch))
  (for ([field (in-list (record-batch-fields batch))]
        [column (in-vector (record-batch-columns batch))])
    (printf "  ~a ~a~a: ~a row(s)\n"
            (arrow-field-name field)
            (arrow-field-type field)
            (if (arrow-field-nullable field) "" " not-null")
            (if (flvector? column)
                (flvector-length column)
                (vector-length column)))))
