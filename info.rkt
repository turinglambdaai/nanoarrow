#lang info

(define collection 'multi)

(define version "0.1.0")

(define deps '("base"))

(define build-deps '("scribble-lib" "racket-doc" "rackunit-lib"))

(define pkg-desc
  "Racket FFI bindings to Apache Arrow nanoarrow: read and write Arrow IPC files containing record batches of primitive column types, without installing Arrow C++ or pyarrow.")

(define pkg-authors '(turinglambdaai))

(define license 'MIT)

;; test/interop contains build-time fixture tooling (it writes files), not
;; tests; exclude it from `raco test`.
(define test-omit-paths '("test/interop"))
