#lang racket/base

(require racket/flonum)

;; Golden fixture expectations for the nanoarrow test suite.
;;
;; GENERATED DATA — do not edit by hand. The values below are pinned from the
;; output of test/generate-fixtures.py (pyarrow), which also produced the
;; .arrow/.arrows files in this directory. See the comments there and
;; README.md ("Interop testing").

(provide mixed-num-rows
         mixed-fields
         mixed-columns
         single-num-rows
         single-fields
         single-columns
         empty-num-rows
         empty-fields
         empty-columns)

;; --- mixed (golden-file-mixed.arrow / golden-stream-mixed.arrows) ---
(define mixed-num-rows 7)
(define mixed-fields (list
  (list "b" 'bool #t)
  (list "i8" 'int8 #t)
  (list "i16" 'int16 #t)
  (list "i32" 'int32 #t)
  (list "i64" 'int64 #t)
  (list "u8" 'uint8 #t)
  (list "u16" 'uint16 #t)
  (list "u32" 'uint32 #t)
  (list "u64" 'uint64 #t)
  (list "f32" 'float32 #t)
  (list "f64" 'float64 #t)
  (list "s" 'string #t)
  (list "i32nn" 'int32 #f)))
(define mixed-columns (list
  (vector #t #f #t #t #f #f #t)
  (vector -7 100 0 -128 127 5 -1)
  (vector -300 32767 -32768 0 42 7 -1)
  (vector -70000 2147483647 -2147483648 0 1 2 3)
  (vector -5000000000 9223372036854775807 42 0 -1 100 7)
  (vector 0 255 1 2 3 4 5)
  (vector 0 65535 10 20 30 40 50)
  (vector 0 4294967295 1 2 3 4 5)
  (vector 0 18446744073709551615 7 8 9 10 11)
  (flvector 0.5 -1.25 100.0 0.0 2.5 -0.125 1000000000.0)
  (flvector 0.1 -2.718281828 1e+300 0.0 3.141592653589793 -42.5 7.0)
  (vector "hello" "" "wörld ✓" "arrow" "racket" "λx.x" "the end")
  (vector 10 -20 30 -40 50 -60 70)))

;; --- single (golden-file-single.arrow) ---
(define single-num-rows 3)
(define single-fields (list
  (list "u16" 'uint16 #t)))
(define single-columns (list
  (vector 1 65535 0)))

;; --- empty (golden-file-empty.arrow) ---
(define empty-num-rows 0)
(define empty-fields (list
  (list "n" 'int64 #t)
  (list "s" 'string #t)))
(define empty-columns (list
  (vector )
  (vector )))
