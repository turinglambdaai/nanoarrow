#lang racket/base

;; Column data marshalling between typed Racket data and Arrow buffers.
;;
;; Type mapping (v0.1, primitive types only):
;;   bool      -> (vectorof boolean?)
;;   int8/16/32/64, uint8/16/32/64 -> (vectorof exact-integer?)
;;   float32, float64              -> flvector?
;;   string    -> (vectorof string?)      (UTF-8 encoded)
;;
;; Nulls policy: nullability is representable in the schema (the `nullable`
;; flag of an arrow-field), but a column VALUE that contains a null is not
;; representable in v0.1 and raises exn:fail on both the read and write
;; paths. See README.md.

(require ffi/unsafe
         racket/flonum
         "ffi.rkt"
         (prefix-in schema: "schema.rkt"))

(provide check-column!
         column-byte-buffers
         decode-column-view
         check-no-nulls!
         check-root-no-nulls!)

;; ---------------------------------------------------------------------------
;; Write path: Racket column -> Arrow buffer bytes
;;
;; Returns the column's buffers as a list with one element per Arrow buffer
;; slot; slot 0 (validity) is always #f because a v0.1 column never contains
;; nulls. Buffer bytes use little-endian layout. Slot 1 is the data buffer for
;; fixed-width types and bool; for string it is the int32 offsets buffer and
;; slot 2 the UTF-8 data buffer.

(define (column-length c)
  (if (flvector? c) (flvector-length c) (vector-length c)))

(define (column-ref c i)
  (if (flvector? c) (flvector-ref c i) (vector-ref c i)))

(define (check-column! field-index type column num-rows)
  ;; Validate one column's Racket representation before any bytes are built.
  (define where (format "column ~a (~a)" field-index type))
  (unless (or (vector? column) (flvector? column))
    (raise-nanoarrow-error "nanoarrow: ~a must be a vector or flvector, got ~a"
                           where column))
  (unless (= (column-length column) num-rows)
    (raise-nanoarrow-error
     "nanoarrow: ~a has length ~a but the batch has ~a rows"
     where (column-length column) num-rows))
  (for ([i (in-range (column-length column))])
    (define v (column-ref column i))
    (case type
      [(bool)
       (unless (boolean? v)
         (raise-nanoarrow-error "nanoarrow: ~a row ~a is not a boolean: ~s" where i v))]
      [(int8 int16 int32 int64 uint8 uint16 uint32 uint64)
       (unless (exact-integer? v)
         (raise-nanoarrow-error "nanoarrow: ~a row ~a is not an exact integer: ~s" where i v))
       (check-int-range! where i v (schema:integer-signed? type) (schema:integer-bits type))]
      [(float32 float64)
       (unless (real? v)
         (raise-nanoarrow-error "nanoarrow: ~a row ~a is not a real number: ~s" where i v))]
      [(string)
       (unless (string? v)
         (raise-nanoarrow-error "nanoarrow: ~a row ~a is not a string: ~s" where i v))])))

(define (check-int-range! where i v signed? bits)
  (define ok
    (if signed?
        (and (>= v (- (arithmetic-shift 1 (sub1 bits))))
             (<  v (arithmetic-shift 1 (sub1 bits))))
        (and (>= v 0)
             (<  v (arithmetic-shift 1 bits)))))
  (unless ok
    (raise-nanoarrow-error
     "nanoarrow: ~a row ~a value ~a is out of range for a ~a-bit ~a integer"
     where i v bits (if signed? "signed" "unsigned"))))

(define (column-byte-buffers type column num-rows)
  (case type
    [(bool)
     (list #f (bool-vector->bitmap-bytes column))]
    [(int8 int16 int32 int64 uint8 uint16 uint32 uint64)
     (define w (schema:integer-width-bytes type))
     (define signed? (schema:integer-signed? type))
     (define buf (make-bytes (* w num-rows)))
     (for ([i (in-range num-rows)])
       (write-integer! buf i (column-ref column i) w signed?))
     (list #f buf)]
    [(float32 float64)
     (define width (if (eq? type 'float32) 4 8))
     (define buf (make-bytes (* width num-rows)))
     (for ([i (in-range num-rows)])
       (ptr-set! buf (if (eq? type 'float32) _float _double) i (column-ref column i)))
     (list #f buf)]
    [(string)
     (define encoded
       (for/list ([i (in-range num-rows)])
         (string->bytes/utf-8 (column-ref column i))))
     (define data (apply bytes-append (if (null? encoded) (list #"") encoded)))
     (unless (< (bytes-length data) 2147483648) ; int32 offset space
       (raise-nanoarrow-error
        "nanoarrow: string column data (~a bytes) exceeds the 2 GiB Arrow string offset limit"
        (bytes-length data)))
     (define offsets (make-bytes (* 4 (add1 num-rows))))
     ;; Arrow string offsets have n+1 entries, ending with the total length.
     (let loop ([i 0] [offset 0])
       (write-integer! offsets i offset 4 #f)
       (when (< i num-rows)
         (loop (add1 i) (+ offset (bytes-length (list-ref encoded i))))))
     (list #f offsets data)]
    [else
     (raise-nanoarrow-error "nanoarrow: unsupported column type ~s" type)]))

;; Write an integer at element index i with the given byte width, little-endian.
(define (write-integer! buf i v w signed?)
  (define le (integer->integer-bytes v w signed? #f))
  (bytes-copy! buf (* w i) le))

(define (bool-vector->bitmap-bytes column)
  (define n (column-length column))
  (define buf (make-bytes (quotient (+ n 7) 8) 0))
  (for ([i (in-range n)]
        #:when (column-ref column i))
    (define byte-i (quotient i 8))
    (bytes-set! buf byte-i
                (bitwise-ior (bytes-ref buf byte-i)
                             (arithmetic-shift 1 (modulo i 8)))))
  buf)

;; ---------------------------------------------------------------------------
;; Read path: ArrowArrayView child -> Racket column
;;
;; `view` is a pointer to the child's ArrowArrayView (buffer views already
;; populated by ArrowArrayViewSetArray). Reading mirrors nanoarrow's inline
;; getters: element i lives at physical index (+ offset i).

(define (check-no-nulls! field view)
  ;; Reject a positive null_count and, when a validity bitmap is present,
  ;; scan it for cleared bits (covers null_count == -1 "unknown" too).
  (define null-count (ArrowArrayView-null_count view))
  (when (> null-count 0)
    (nulls-error field null-count))
  (define validity (ArrowArrayView-buffer_view_0_data view))
  (when validity
    (define n (ArrowArrayView-length view))
    (define view-offset (ArrowArrayView-offset view))
    (for ([i (in-range n)])
      (unless (validity-bit? validity (+ view-offset i))
        (nulls-error field i)))))

(define (check-root-no-nulls! view)
  (define null-count (ArrowArrayView-null_count view))
  (when (> null-count 0)
    (raise-nanoarrow-error
     "nanoarrow: the record batch contains ~a struct-level null value(s), which \
is not supported in this version"
     null-count)))

(define (nulls-error field where)
  (raise-nanoarrow-error
   "nanoarrow: column ~a contains a null value (~a); nulls are not supported in \
this version, columns must be fully populated"
   field where))

(define (validity-bit? validity-ptr i)
  (zero? (bitwise-and (ptr-ref validity-ptr _uint8 (quotient i 8))
                      (arithmetic-shift 1 (modulo i 8)))))

(define (decode-column-view name type view num-rows)
  (define view-offset (ArrowArrayView-offset view))
  (case type
    [(bool)
     (define data (ArrowArrayView-buffer_view_1_data view))
     (for/vector #:length num-rows ([i (in-range num-rows)])
       (define bit-i (+ view-offset i))
       (not (zero? (bitwise-and (ptr-ref data _uint8 (quotient bit-i 8))
                                (arithmetic-shift 1 (modulo bit-i 8))))))]
    [(int8 uint8 int16 uint16 int32 uint32 int64 uint64)
     (define data (ArrowArrayView-buffer_view_1_data view))
     (define ctype (integer-ctype type))
     (for/vector #:length num-rows ([i (in-range num-rows)])
       (ptr-ref data ctype (+ view-offset i)))]
    [(float32 float64)
     (define data (ArrowArrayView-buffer_view_1_data view))
     (define ctype (if (eq? type 'float32) _float _double))
     (for/flvector #:length num-rows ([i (in-range num-rows)])
       (ptr-ref data ctype (+ view-offset i)))]
    [(string)
     (define offsets (ArrowArrayView-buffer_view_1_data view))
     (define data (ArrowArrayView-buffer_view_2_data view))
     (for/vector #:length num-rows ([i (in-range num-rows)])
       (define start (ptr-ref offsets _int32 (+ view-offset i)))
       (define end (ptr-ref offsets _int32 (+ view-offset i 1)))
       (unless (and (<= 0 start) (<= start end))
         (raise-nanoarrow-error
          "nanoarrow: column ~a has invalid string offsets at row ~a" name i))
       (define len (- end start))
       (define bs (make-bytes len))
       (when (> len 0)
         (memcpy bs (ptr-add data start) len))
       (with-handlers ([exn:fail? (lambda (e)
                                    (raise-nanoarrow-error
                                     "nanoarrow: column ~a row ~a is not valid UTF-8" name i))])
         (bytes->string/utf-8 bs)))]
    [else
     (raise-nanoarrow-error "nanoarrow: unsupported column type ~s" type)]))

(define (integer-ctype type)
  (case type
    [(int8) _int8] [(uint8) _uint8]
    [(int16) _int16] [(uint16) _uint16]
    [(int32) _int32] [(uint32) _uint32]
    [(int64) _int64] [(uint64) _uint64]))
