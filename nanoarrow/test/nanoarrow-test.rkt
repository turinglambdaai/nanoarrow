#lang racket/base

;; Test entry point.  The real suite lives in "nanoarrow-tests.rkt" and is
;; loaded only when the nanoarrow native library is available: machines
;; without it (e.g. the package catalog's build farm) skip cleanly instead
;; of reporting failures.

(define lib-available?
  (with-handlers ([exn:fail? (λ (_) #f)])
    (dynamic-require 'nanoarrow/main #f)
    #t))

(unless lib-available?
  (printf "nanoarrow: nanoarrow native library not available; skipping tests\n"))

(when lib-available?
  (dynamic-require "nanoarrow-tests.rkt" #f))
