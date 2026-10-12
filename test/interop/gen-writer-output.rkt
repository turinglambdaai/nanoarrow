#lang racket/base

;; Build-time helper: regenerates test/data/writer-output-file.arrow and
;; test/data/writer-output-stream.arrows using this package's writer for the
;; golden mixed batch (same data as the reader goldens). Run from the
;; repository root:
;;
;;   DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/opt/nanoarrow/lib \
;;     racket test/interop/gen-writer-output.rkt
;;
;; Afterwards validate the output with pyarrow:
;;
;;   python3 test/interop/validate-writer.py

(require racket/file
         racket/flonum
         nanoarrow
         (file "../data/expected.rkt"))

(define batch
  (record-batch
   mixed-num-rows
   (for/list ([spec (in-list mixed-fields)])
     (arrow-field (list-ref spec 0) (list-ref spec 1) (list-ref spec 2)))
   (list->vector mixed-columns)))

(define data-dir (build-path "test" "data"))
(display-to-file (record-batch->ipc-file batch)
                 (build-path data-dir "writer-output-file.arrow")
                 #:exists 'truncate)
(display-to-file (record-batch->ipc-stream batch)
                 (build-path data-dir "writer-output-stream.arrows")
                 #:exists 'truncate)
(printf "wrote ~a file bytes, ~a stream bytes\n"
        (file-size (build-path data-dir "writer-output-file.arrow"))
        (file-size (build-path data-dir "writer-output-stream.arrows")))
