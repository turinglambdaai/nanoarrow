# nanoarrow

[![CI](https://github.com/turinglambdaai/nanoarrow/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/nanoarrow/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Racket FFI bindings to [Apache Arrow
nanoarrow](https://arrow.apache.org/nanoarrow/): read and write **Arrow IPC
files and streams** (`.arrow`) containing record batches of primitive-typed
columns — from pure Racket, with no Arrow C++, pyarrow, or JVM installed.

- Apache Arrow IPC **file** format (`ARROW1` magic + footer) and **stream**
  format, both directions.
- Primitive column types: `bool`, `int8`–`int64`, `uint8`–`uint64`,
  `float32`/`float64` (Racket `flvector`s), `string` (UTF-8).
- Writer output is byte-for-byte deterministic and verified against
  **pyarrow**; the reader is verified against pyarrow-generated goldens.
- Everything else (decimals, nested types, timestamps, …) fails with a
  clear "unsupported Arrow type" error instead of crashing.

## Status

v0.1.0 — documented limits: primitive types only, one record batch per
payload, columns containing nulls are rejected (nullability itself
round-trips through the schema), little-endian hosts, nanoarrow 0.9.x.

## Install

```sh
raco pkg install --auto --link /path/to/nanoarrow
```

You also need the nanoarrow **0.9.x** shared libraries
(`libnanoarrow_shared` and `libnanoarrow_ipc_shared`):

- **macOS**: `brew install nanoarrow`. The loader probes
  `/opt/homebrew/opt/nanoarrow/lib` automatically; setting
  `DYLD_FALLBACK_LIBRARY_PATH` also works.
- **Linux**: build from the `apache-arrow-nanoarrow-0.9.0` release
  (small, fast CMake build):

  ```sh
  cmake -S apache-arrow-nanoarrow-apache-arrow-nanoarrow-0.9.0 -B build \
        -DCMAKE_BUILD_TYPE=Release -DNANOARROW_BUILD_TESTS=OFF
  cmake --build build && cmake --install build --prefix ~/.nanoarrow
  ```

  then expose it with `LD_LIBRARY_PATH=~/.nanoarrow/lib` or
  `NANOARROW_LIBRARY_DIR=~/.nanoarrow/lib`.

`NANOARROW_LIBRARY_DIR` (if set) is searched before the platform loader;
the automatic prefix probing exists because `raco test` workers on macOS do
not reliably inherit `DYLD_*` variables.

## Usage

```racket
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

; encode to an Arrow IPC file payload (bytes)
(define file-bytes (record-batch->ipc-file batch))

; decode it back
(define batch-2 (ipc-file->record-batch file-bytes))
(vector-ref (record-batch-columns batch-2) 1) ; '#(9.5 8.0 7.25)

; write a real .arrow file
(with-output-to-file "example.arrow" #:exists 'truncate
  (lambda () (write-bytes file-bytes)))
```

Stream format equivalents: `record-batch->ipc-stream` /
`ipc-stream->record-batch`.

### Type mapping

| Arrow type | Symbol | Racket |
|---|---|---|
| boolean | `'bool` | `(vectorof boolean?)` |
| int8/int16/int32/int64 | `'int8` … | `(vectorof exact-integer?)` |
| uint8/uint16/uint32/uint64 | `'uint8` … | `(vectorof exact-integer?)` |
| float (32-bit) | `'float32` | `flvector?` |
| double (64-bit) | `'float64` | `flvector?` |
| string (utf8) | `'string` | `(vectorof string?)` |

Full documentation: `raco docs nanoarrow` (or
`nanoarrow/scribblings/nanoarrow.scrbl`).

## Interop testing

The committed test suite runs without pyarrow:

```sh
DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/opt/nanoarrow/lib raco test -p nanoarrow
```

It covers:

1. **Reader goldens** — pyarrow-written `.arrow` files
   (`test/data/golden-*.arrow`) decoded to pinned Racket values
   (`test/data/expected.rkt`), including negative integers, unicode
   strings, an empty 0-row batch, and a single-column batch.
2. **Writer validation** — our writer's bytes for the mixed batch are
   committed (`test/data/writer-output-*`) and were decoded and
   value-checked by pyarrow 20.0.0 (`test/interop/validate-writer.py`);
   the suite asserts byte-identity so regressions fail loudly. CI does not
   need pyarrow.
3. **Round trips** — our reader on our writer output, per type, plus
   empty and single-column edge cases.
4. **Errors** — wrong magic, truncated files/streams, unsupported column
   types (decimal/list golden), nulls, out-of-range integers, column
   length mismatches: all clear `exn:fail` messages.

To regenerate fixtures or re-run the pyarrow validation, see
`test/interop/README.md` (build-time only).

## Design notes

- The FFI layer (`nanoarrow/private/ffi.rkt`) declares every C struct from
  the 0.9.0 headers explicitly and pins their sizes in the test suite; the
  loader falls back through well-known prefixes.
- The reader uses nanoarrow's IPC decoder
  (`ArrowIpcDecoder*`) with full flatbuffer validation, so corrupt input
  cannot cause out-of-bounds reads; decoded arrays own their buffers
  (the decoder copies out of the input).
- The writer builds the schema through nanoarrow (`ArrowSchema*`) and
  feeds the IPC encoder (`ArrowIpcWriter`) a hand-populated
  `ArrowArrayView` whose buffer views point directly into Racket byte
  strings — zero copies, no C-side buffer management on the write path.
- All C resources are released via `dynamic-wind` on every path.

## License

MIT — see [LICENSE](LICENSE).
