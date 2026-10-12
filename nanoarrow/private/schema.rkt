#lang racket/base

;; Arrow schema <-> (listof arrow-field) translation.
;;
;; Supported column types (v0.1) and their Arrow storage enum values:
;;   bool      -> NANOARROW_TYPE_BOOL     vector of booleans
;;   int8..64  -> NANOARROW_TYPE_INT8..   vector of exact integers
;;   uint8..64 -> NANOARROW_TYPE_UINT8..  vector of exact integers
;;   float32   -> NANOARROW_TYPE_FLOAT    flvector
;;   float64   -> NANOARROW_TYPE_DOUBLE   flvector
;;   string    -> NANOARROW_TYPE_STRING   vector of strings (UTF-8)

(require racket/contract
         racket/list
         racket/string
         "ffi.rkt")

(provide supported-type?
         arrow-type->storage-enum
         storage-enum->arrow-type
         storage-enum-name
         integer-type?
         float-type?
         integer-width-bytes
         integer-bits
         integer-signed?
         build-arrow-schema
         arrow-schema-fields!
         schema-child-storage-types)

;; ---------------------------------------------------------------------------
;; Type table

(define supported-type-table
  '((bool      . 2)     ; NANOARROW_TYPE_BOOL
    (uint8     . 3)     ; NANOARROW_TYPE_UINT8
    (int8      . 4)     ; NANOARROW_TYPE_INT8
    (uint16    . 5)     ; NANOARROW_TYPE_UINT16
    (int16     . 6)     ; NANOARROW_TYPE_INT16
    (uint32    . 7)     ; NANOARROW_TYPE_UINT32
    (int32     . 8)     ; NANOARROW_TYPE_INT32
    (uint64    . 9)     ; NANOARROW_TYPE_UINT64
    (int64     . 10)    ; NANOARROW_TYPE_INT64
    (float32   . 12)    ; NANOARROW_TYPE_FLOAT
    (float64   . 13)    ; NANOARROW_TYPE_DOUBLE
    (string    . 14)))  ; NANOARROW_TYPE_STRING

(define (supported-type? t) (and (assq t supported-type-table) #t))

(define (arrow-type->storage-enum t)
  (cond [(assq t supported-type-table) => cdr]
        [else
         (raise-nanoarrow-error
          "nanoarrow: unsupported column type ~s; supported types are: ~a"
          t
          (string-join (map symbol->string (map car supported-type-table)) ", "))]))

(define enum-name-table
  (hasheq 0 'UNINITIALIZED 1 'NA 2 'BOOL 3 'UINT8 4 'INT8 5 'UINT16 6 'INT16
          7 'UINT32 8 'INT32 9 'UINT64 10 'INT64 11 'HALF_FLOAT 12 'FLOAT
          13 'DOUBLE 14 'STRING 15 'BINARY 16 'FIXED_SIZE_BINARY 17 'DATE32
          18 'DATE64 19 'TIMESTAMP 20 'TIME32 21 'TIME64 22 'INTERVAL_MONTHS
          23 'INTERVAL_DAY_TIME 24 'DECIMAL128 25 'DECIMAL256 26 'LIST
          27 'STRUCT 28 'SPARSE_UNION 29 'DENSE_UNION 30 'DICTIONARY 31 'MAP
          32 'EXTENSION 33 'FIXED_SIZE_LIST 34 'DURATION 35 'LARGE_STRING
          36 'LARGE_BINARY 37 'LARGE_LIST 38 'INTERVAL_MONTH_DAY_NANO
          39 'RUN_END_ENCODED 40 'BINARY_VIEW 41 'STRING_VIEW 42 'DECIMAL32
          43 'DECIMAL64 44 'LIST_VIEW 45 'LARGE_LIST_VIEW))

(define (storage-enum-name enum)
  (hash-ref enum-name-table enum (lambda () (format "type #~a" enum))))

(define (storage-enum->arrow-type enum)
  (for/first ([pair (in-list supported-type-table)]
              #:when (= (cdr pair) enum))
    (car pair)))

(define (integer-type? t)
  (memq t '(int8 int16 int32 int64 uint8 uint16 uint32 uint64)))

(define (float-type? t) (memq t '(float32 float64)))

;; Byte width of the fixed-size data buffer for an integer column.
(define (integer-width-bytes t)
  (case t
    [(int8 uint8) 1]
    [(int16 uint16) 2]
    [(int32 uint32) 4]
    [(int64 uint64) 8]
    [else (raise-nanoarrow-error "nanoarrow: not an integer type: ~s" t)]))

(define (integer-bits t) (* 8 (integer-width-bytes t)))

(define (integer-signed? t)
  (case t
    [(int8 int16 int32 int64) #t]
    [(uint8 uint16 uint32 uint64) #f]
    [else (raise-nanoarrow-error "nanoarrow: not an integer type: ~s" t)]))

;; ---------------------------------------------------------------------------
;; Building an ArrowSchema for the IPC writer

;; (build-arrow-schema! fields) -> _ArrowSchema-pointer
;; The caller owns the returned schema and must (release-arrow-schema! it).
;; `fields` is a list of (list name type nullable) triples with supported
;; types; violations raise exn:fail.
(define (build-arrow-schema fields)
  (define schema (new-ArrowSchema))
  (ArrowSchemaInit schema)
  (with-handlers ([exn:fail? (lambda (e) (release-arrow-schema! schema) (raise e))])
    (define n (length fields))
    (check-rc "ArrowSchemaSetTypeStruct"
                  (ArrowSchemaSetTypeStruct schema n)
                  (make-arrow-error))
    (for ([field (in-list fields)]
          [i (in-naturals)])
      (unless (and (list? field) (= (length field) 3)
                   (string? (list-ref field 0))
                   (supported-type? (list-ref field 1))
                   (boolean? (list-ref field 2)))
        (raise-nanoarrow-error
         "nanoarrow: invalid field spec ~s; expected (list name supported-type nullable)"
         field))
      (define child (arrow-schema-child schema i))
      (check-rc "ArrowSchemaSetType"
                    (ArrowSchemaSetType
                     child (arrow-type->storage-enum (list-ref field 1)))
                    (make-arrow-error))
      (check-rc "ArrowSchemaSetName"
                    (ArrowSchemaSetName child (list-ref field 0))
                    (make-arrow-error))
      ;; ArrowSchemaSetType leaves ARROW_FLAG_NULLABLE set on children;
      ;; normalize the flag to exactly what the field spec says so that
      ;; non-nullable columns are encoded as non-nullable.
      (set-ArrowSchema-flags!
       child
       (if (list-ref field 2) FLAG-NULLABLE 0)))
    schema))

;; ---------------------------------------------------------------------------
;; Reading a decoded ArrowSchema

;; (schema-child-storage-types schema) -> (listof storage-enum)
(define (schema-child-storage-types schema)
  (for/list ([i (in-range (ArrowSchema-n_children schema))])
    (define view (new-ArrowSchemaView))
    (check-rc "ArrowSchemaViewInit"
                  (ArrowSchemaViewInit view (arrow-schema-child schema i)
                                           (make-arrow-error))
                  (make-arrow-error))
    (ArrowSchemaView-storage_type view)))

;; (arrow-schema-fields! schema) -> (listof (list name type nullable))
;; Raises a clear error for any unsupported column type. Consumes the schema:
;; releases it before returning (callers that need it alive should not use
;; this helper).
(define (arrow-schema-fields! schema)
  (define n (ArrowSchema-n_children schema))
  (with-handlers ([exn:fail? (lambda (e) (release-arrow-schema! schema) (raise e))])
    (define result
      (for/list ([i (in-range n)])
        (define child (arrow-schema-child schema i))
        (define name (c-string-field (ArrowSchema-name child)))
        (define view (new-ArrowSchemaView))
        (check-rc "ArrowSchemaViewInit"
                      (ArrowSchemaViewInit view child (make-arrow-error))
                      (make-arrow-error))
        (define storage (ArrowSchemaView-storage_type view))
        (define type (storage-enum->arrow-type storage))
        (unless type
          ;; Human-readable description of what we cannot handle.
          (define child-desc
            (let ([s (ArrowSchemaToString child)])
              (bytes->string/utf-8 (subbytes s 0 (min (bytes-length s)
                                                      (or (bytes-index-of* s 0) (bytes-length s)))))))
          (raise-nanoarrow-error
           "nanoarrow: column ~a (~a) has unsupported Arrow type ~a; \
this package supports primitive types only (bool, int8-int64, uint8-uint64, \
float32, float64, string)"
           (or name (format "#~a" i))
           child-desc
           (storage-enum-name storage)))
        (list (or name (format "field~a" i))
              type
              (not (zero? (bitwise-and (ArrowSchema-flags child) FLAG-NULLABLE))))))
    (release-arrow-schema! schema)
    result))

;; Index of the first occurrence of byte b in bs, or #f.
(define (bytes-index-of* bs b)
  (for/first ([x (in-bytes bs)]
              [i (in-naturals)]
              #:when (= x b))
    i))
