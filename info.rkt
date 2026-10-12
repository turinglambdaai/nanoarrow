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
;; The catalog build farm runs `raco test --package`, executing every module
;; in the package as a test.  The modules that load the nanoarrow native
;; library at require time cannot run on machines without it (the farm), so
;; they are omitted here; the CI workflow and
;; `raco test nanoarrow/nanoarrow/test/nanoarrow-test.rkt` exercise the full
;; suite through the probe entry point.  test/interop is build-time fixture
;; tooling, not tests.
(define test-omit-paths
  '("nanoarrow/test/nanoarrow-tests.rkt" ; loaded conditionally by the probe
    "nanoarrow/scribblings"              ; documentation, not tests
    "test/interop"
    "nanoarrow/main.rkt"
    "nanoarrow/private/ffi.rkt"
    "nanoarrow/private/schema.rkt"
    "nanoarrow/private/arrays.rkt"
    "nanoarrow/private/ipc.rkt"))
