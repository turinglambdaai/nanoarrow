#lang info

(define collection 'multi)
(define version "0.1")
;; rackunit-lib is a run-time dependency: the package ships its test suite
;; and the catalog's dependency check scans shipped modules in run mode.
(define deps '("base" "rackunit-lib"))
(define build-deps '("scribble-lib" "racket-doc" "rackunit-lib"))
(define pkg-desc
  "Racket FFI bindings to Apache Arrow nanoarrow: read and write Arrow IPC files containing record batches of primitive column types, without installing Arrow C++ or pyarrow.")
(define pkg-authors '("turinglambdaai"))
(define license 'MIT)
(define scribblings '(("nanoarrow/scribblings/nanoarrow.scrbl" ())))
;; "nanoarrow-tests.rkt" is loaded conditionally by "nanoarrow-test.rkt"
;; (native library probe); the scribblings module is not a test;
;; test/interop contains build-time fixture tooling, not tests.
(define test-omit-paths '("nanoarrow/test/nanoarrow-tests.rkt"
                          "nanoarrow/scribblings"
                          "test/interop"))
