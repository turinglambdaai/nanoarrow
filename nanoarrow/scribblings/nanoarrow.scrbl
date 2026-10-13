#lang scribble/base

@(require scribble/manual
          (for-label racket/contract
                     racket/flonum
                     nanoarrow))

@(define (tech-arrow . content) (apply tech #:key "Arrow columnar format" content))

@title[#:tag "nanoarrow"]{nanoarrow: Arrow IPC for Racket}
@author{turinglambdaai}

@defmodule[nanoarrow]

This package provides Racket FFI bindings to the Apache
@link["https://arrow.apache.org/nanoarrow/"]{nanoarrow} C library
(0.9.x). It can read and write
@deftech[#:key "Arrow columnar format"]{Arrow columnar format}
@link["https://arrow.apache.org/docs/format/Columnar.html#ipc-encoding"]{@tech-arrow{Arrow
IPC}} payloads---the @tt{.arrow} file format and the stream format---holding
one @bold{record batch} whose columns all have @bold{primitive types}. No
Arrow C++, pyarrow, or JVM is required: only the small, C-only nanoarrow
shared libraries.

@section[#:tag "nanoarrow.install"]{Installation and platform notes}

Install the package from a checkout with:

@commandline{raco pkg install --auto --link /path/to/nanoarrow}

The Racket package itself is pure FFI; you also need the nanoarrow shared
libraries (@tt{libnanoarrow_shared} and @tt{libnanoarrow_ipc_shared},
version 0.9.x):

@itemlist[
 @item{@bold{macOS (Homebrew):} @commandline{brew install nanoarrow}
  The loader automatically probes @tt{/opt/homebrew/opt/nanoarrow/lib} and
  @tt{/usr/local/opt/nanoarrow/lib} when plain dlopen fails, so no
  environment variable is needed in the common case. Setting
  @envvar{DYLD_FALLBACK_LIBRARY_PATH} also works.}
 @item{@bold{Linux:} nanoarrow is generally not in distribution package
  managers; build it from the @tt{apache-arrow-nanoarrow-0.9.0} release:

  @commandline{cmake -S apache-arrow-nanoarrow-apache-arrow-nanoarrow-0.9.0 -B build -DCMAKE_BUILD_TYPE=Release}
  @commandline{cmake --build build && cmake --install build --prefix ~/.nanoarrow}

  Make the libraries findable via @envvar{LD_LIBRARY_PATH}, or point the
  @envvar{NANOARROW_LIBRARY_DIR} environment variable at the install
  prefix's @tt{lib} directory.}
]

The library search order is: @envvar{NANOARROW_LIBRARY_DIR} (if set), the
plain platform loader (which honors @envvar{DYLD_FALLBACK_LIBRARY_PATH} and
@envvar{LD_LIBRARY_PATH}), then the well-known prefixes listed above. The
fallback probing exists because processes spawned by tooling (for example
@tt{raco test} workers on macOS) do not always inherit @envvar{DYLD_*}
variables.

@section[#:tag "nanoarrow.model"]{Data model}

A record batch is described by two transparent structs:

@defstruct*[arrow-field ([name string?]
                         [type arrow-type/c]
                         [nullable boolean?])]{
  One column description. @racket[type] is one of the supported type
  symbols below; @racket[nullable] records the schema-level nullability
  flag (see @secref{nanoarrow.nulls}).
}

@defstruct*[record-batch ([num-rows exact-nonnegative-integer?]
                          [fields (listof arrow-field?)]
                          [columns (vectorof column/c)])]{
  One record batch: @racket[num-rows] rows, with @racket[fields] and
  @racket[columns] parallel. The struct guard validates the column
  representations at construction time.
}

@section[#:tag "nanoarrow.types"]{Type mapping}

@tabular[#:row-properties '(border)
 (list (list @bold{Arrow type} @bold{Type symbol} @bold{Racket representation})
       (list "boolean"          @racket['bool]    @racket[(vectorof boolean?)])
       (list "int8"             @racket['int8]    @racket[(vectorof exact-integer?)])
       (list "int16"            @racket['int16]   @racket[(vectorof exact-integer?)])
       (list "int32"            @racket['int32]   @racket[(vectorof exact-integer?)])
       (list "int64"            @racket['int64]   @racket[(vectorof exact-integer?)])
       (list "uint8"            @racket['uint8]   @racket[(vectorof exact-integer?)])
       (list "uint16"           @racket['uint16]  @racket[(vectorof exact-integer?)])
       (list "uint32"           @racket['uint32]  @racket[(vectorof exact-integer?)])
       (list "uint64"           @racket['uint64]  @racket[(vectorof exact-integer?)])
       (list "float (32-bit)"   @racket['float32] @racket[flvector?])
       (list "double (64-bit)"  @racket['float64] @racket[flvector?])
       (list "string (utf8)"    @racket['string]  @racket[(vectorof string?)]))]

Floating-point columns are @racket[flvector]s of IEEE doubles; a
@racket['float32] column holds values rounded through IEEE single
precision. Integer values must fit their column type (e.g. an
@racket['int8] column rejects @racket[1000]). Everything else---decimals,
lists, structs, timestamps, dictionaries, and so on---is rejected with a
clear "unsupported Arrow type" error when encountered in an input file.

@section[#:tag "nanoarrow.nulls"]{Nulls policy (v0.1)}

Nullability is representable in the @tech-arrow{Arrow schema}: each
@racket[arrow-field] carries a nullable flag that round-trips through the
IPC format. A column @emph{value} that actually contains a null, however,
is not representable in this version: reading or writing one raises
@racket[exn:fail] with a message naming the column. Columns must be fully
populated. (A single sentinel-based representation cannot preserve the
exact-integer typing of integer columns or the @racket[flvector]
representation of float columns; both options were considered and rejecting
nulls was chosen for v0.1.)

@section[#:tag "nanoarrow.api"]{API}

@defthing[arrow-type/c contract?]{
  Flat contract for supported column type symbols:
  @racket['bool], @racket['int8]--@racket['int64], @racket['uint8]--@racket['uint64],
  @racket['float32], @racket['float64], @racket['string].
}

@defthing[column/c contract?]{
  Flat contract for a column value of the representation dictated by its
  field type (see @secref{nanoarrow.types}).
}

@defthing[record-batch/c contract?]{
  Contract covering whole @racket[record-batch] values.
}

@defproc[(nanoarrow-version) string?]{
  Version string of the underlying nanoarrow C library, e.g.
  @racket["0.9.0"].
}

@defproc[(ipc-file->record-batch [input bytes?]) record-batch?]{
  Decode an Arrow IPC @emph{file format} payload (the one beginning and
  ending with the @tt{ARROW1} magic) holding exactly one record batch.
  Raises @racket[exn:fail] on wrong magic, truncation, corrupt framing, or
  unsupported column types. If the payload contains more than one record
  batch, only the first is returned; the remaining tail is ignored in this
  version.
}

@defproc[(record-batch->ipc-file [batch record-batch?]) bytes?]{
  Encode a record batch as an Arrow IPC file format payload. The output is
  byte-for-byte deterministic and is read correctly by pyarrow and other
  Arrow implementations (verified by the package's interop tests).
}

@defproc[(ipc-stream->record-batch [input bytes?]) record-batch?]{
  Like @racket[ipc-file->record-batch] for the Arrow IPC @emph{stream}
  format (no magic, no footer).
}

@defproc[(record-batch->ipc-stream [batch record-batch?]) bytes?]{
  Encode a record batch as an Arrow IPC stream payload.
}

@section[#:tag "nanoarrow.example"]{Worked example}

@racketblock[
(require nanoarrow)

(define batch
  (record-batch
   3
   (list (arrow-field "name" 'string #t)
         (arrow-field "score" 'float64 #f)
         (arrow-field "count" 'int32 #t))
   (vector (vector "ada" "grace" "linus")
           (flvector 9.5 8.0 7.25)
           (vector 1 2 3))))

(define file-bytes (record-batch->ipc-file batch))

(define batch-2 (ipc-file->record-batch file-bytes))
(record-batch-num-rows batch-2)             ; 3
(vector-ref (record-batch-columns batch-2) 1) ; '#(9.5 8.0 7.25) as flvector
]

To write a real @tt{.arrow} file, just write the bytes:

@racketblock[
(with-output-to-file "example.arrow" #:exists 'truncate
  (lambda () (write-bytes file-bytes)))
]

@section[#:tag "nanoarrow.limits"]{Documented limits}

@itemlist[
 @item{Primitive column types only (see @secref{nanoarrow.types}); any
  other type raises a clear error rather than crashing.}
 @item{Exactly one record batch per payload is read; extra record batches
  in the input are ignored.}
 @item{Columns containing null values are rejected
  (see @secref{nanoarrow.nulls}).}
 @item{Little-endian hosts (all common current platforms).}
 @item{nanoarrow 0.9.x shared libraries; the FFI layer checks the
  library version at load time.}
]
