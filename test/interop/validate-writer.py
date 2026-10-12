#!/usr/bin/env python3
"""Build-time pyarrow validation of the Racket writer's output.

Decodes test/data/writer-output-file.arrow and
test/data/writer-output-stream.arrows (both produced by
nanoarrow's `record-batch->ipc-file` / `->ipc-stream` for the
golden mixed batch) and asserts the logical content matches
test/data/expected.rkt exactly.

Run from the repository root with a pyarrow-enabled interpreter:

    python3 test/interop/validate-writer.py

This script is only needed when regenerating the writer output
fixtures; the committed test suite never needs pyarrow.
"""
import pathlib
import sys

import pyarrow as pa

ROOT = pathlib.Path(__file__).parent.parent.parent
DATA = ROOT / "test" / "data"

sys.path.insert(0, str(DATA / ".."))  # noqa: E402 (not used; expected data is static)

EXPECTED_COLUMNS = [
    ("b", [True, False, True, True, False, False, True]),
    ("i8", [-7, 100, 0, -128, 127, 5, -1]),
    ("i16", [-300, 32767, -32768, 0, 42, 7, -1]),
    ("i32", [-70000, 2147483647, -2147483648, 0, 1, 2, 3]),
    ("i64", [-5000000000, 9223372036854775807, 42, 0, -1, 100, 7]),
    ("u8", [0, 255, 1, 2, 3, 4, 5]),
    ("u16", [0, 65535, 10, 20, 30, 40, 50]),
    ("u32", [0, 4294967295, 1, 2, 3, 4, 5]),
    ("u64", [0, 18446744073709551615, 7, 8, 9, 10, 11]),
    ("f32", [0.5, -1.25, 100.0, 0.0, 2.5, -0.125, 1.0e9]),
    ("f64", [0.1, -2.718281828, 1.0e300, 0.0, 3.141592653589793, -42.5, 7.0]),
    ("s", ["hello", "", "wörld ✓", "arrow", "racket", "λx.x", "the end"]),
    ("i32nn", [10, -20, 30, -40, 50, -60, 70]),
]

EXPECTED_FIELDS = [
    ("b", pa.bool_(), True),
    ("i8", pa.int8(), True),
    ("i16", pa.int16(), True),
    ("i32", pa.int32(), True),
    ("i64", pa.int64(), True),
    ("u8", pa.uint8(), True),
    ("u16", pa.uint16(), True),
    ("u32", pa.uint32(), True),
    ("u64", pa.uint64(), True),
    ("f32", pa.float32(), True),
    ("f64", pa.float64(), True),
    ("s", pa.string(), True),
    ("i32nn", pa.int32(), False),
]


def check_batch(path, opener, label):
    with pa.memory_map(str(path), "rb") as source:
        reader = opener(source)
        if hasattr(reader, "num_record_batches"):
            batch = reader.get_batch(0)
            print("  %s: num_record_batches=%d" % (label, reader.num_record_batches))
        else:
            batch = reader.read_next_batch()
            print("  %s: stream batch read" % label)
    assert batch.num_rows == 7, (label, batch.num_rows)
    for i, (name, typ, nullable) in enumerate(EXPECTED_FIELDS):
        field = batch.schema.field(i)
        assert field.name == name, (label, i, field.name, name)
        assert field.type == typ, (label, name, field.type, typ)
        assert field.nullable == nullable, (label, name, field.nullable, nullable)
    for i, (name, values) in enumerate(EXPECTED_COLUMNS):
        got = batch.column(i).to_pylist()
        assert got == values, (label, name, got, values)
    print("  %s: %d rows x %d columns verified" % (label, batch.num_rows, batch.num_columns))


def main():
    print("pyarrow %s" % pa.__version__)
    check_batch(DATA / "writer-output-file.arrow", pa.ipc.open_file, "file")
    check_batch(DATA / "writer-output-stream.arrows", pa.ipc.open_stream, "stream")
    print("OK: pyarrow decoded the Racket writer output for both formats")


if __name__ == "__main__":
    main()
