# Interop tooling (build-time only)

This directory contains the pyarrow-based tooling that generates and
validates the committed fixtures under `test/data/`. **The committed test
suite never needs pyarrow** — it only reads the generated files and the
pinned expectations in `test/data/expected.rkt`.

## What is here

- `generate-fixtures.py` — builds the pyarrow golden fixtures
  (`golden-file-*.arrow`, `golden-stream-*.arrows`) with pyarrow, verifies
  them by reading them back, and prints the expected values that
  `test/data/expected.rkt` pins.
- `gen-writer-output.rkt` — writes `writer-output-file.arrow` and
  `writer-output-stream.arrows` using this package's writer for the same
  logical batch. Run from the repository root:

      DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/opt/nanoarrow/lib \
        racket test/interop/gen-writer-output.rkt

- `validate-writer.py` — reads the writer output fixtures with pyarrow and
  asserts every field name, type, nullability flag and value. This is the
  proof that other Arrow implementations can consume our writer's bytes:

      python3 test/interop/validate-writer.py

## Regeneration policy

Fixtures only change when the test data changes. To regenerate everything:

1. `python3 -m venv <venv> && <venv>/bin/pip install "pyarrow<21"` (py3.9+)
2. `<venv>/bin/python test/generate-fixtures.py` — regenerates the golden
   files and prints the expected values; update `test/data/expected.rkt`
   from that output if the data changed.
3. `DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/opt/nanoarrow/lib \
    racket test/interop/gen-writer-output.rkt` — regenerates the writer
   output fixtures.
4. `<venv>/bin/python test/interop/validate-writer.py` — must pass.
