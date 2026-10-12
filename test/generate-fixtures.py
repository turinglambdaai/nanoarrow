#!/usr/bin/env python3
"""Build-time golden fixture generator for the nanoarrow Racket package.

Creates Arrow IPC fixtures in test/data/ using pyarrow and prints the
expected Racket values to stdout. The generated files and the expected
values module (test/data/expected.rkt) are committed so that CI never
needs pyarrow.

Run from the repository root with a pyarrow-enabled interpreter, e.g.:

    python3 test/generate-fixtures.py > /tmp/expected.txt

and paste/inspect the printed table (the committed test/data/expected.rkt
is produced from the same data by hand using this output).

Regeneration policy: fixtures only change when the test data changes.
"""
import pathlib
from decimal import Decimal as _Decimal

import pyarrow as pa

HERE = pathlib.Path(__file__).parent / "data"

NUM_ROWS = 7

MIXED_COLUMNS = [
    ("b", pa.bool_(), True, [True, False, True, True, False, False, True]),
    ("i8", pa.int8(), True, [-7, 100, 0, -128, 127, 5, -1]),
    ("i16", pa.int16(), True, [-300, 32767, -32768, 0, 42, 7, -1]),
    ("i32", pa.int32(), True, [-70000, 2147483647, -2147483648, 0, 1, 2, 3]),
    ("i64", pa.int64(), True, [-5000000000, 9223372036854775807, 42, 0, -1, 100, 7]),
    ("u8", pa.uint8(), True, [0, 255, 1, 2, 3, 4, 5]),
    ("u16", pa.uint16(), True, [0, 65535, 10, 20, 30, 40, 50]),
    ("u32", pa.uint32(), True, [0, 4294967295, 1, 2, 3, 4, 5]),
    ("u64", pa.uint64(), True, [0, 18446744073709551615, 7, 8, 9, 10, 11]),
    ("f32", pa.float32(), True, [0.5, -1.25, 100.0, 0.0, 2.5, -0.125, 1.0e9]),
    ("f64", pa.float64(), True, [0.1, -2.718281828, 1.0e300, 0.0, 3.141592653589793, -42.5, 7.0]),
    ("s", pa.string(), True, ["hello", "", "wörld ✓", "arrow", "racket", "λx.x", "the end"]),
    # One non-nullable column to pin down the nullable flag handling.
    ("i32nn", pa.int32(), False, [10, -20, 30, -40, 50, -60, 70]),
]

SINGLE_COLUMNS = [("u16", pa.uint16(), True, [1, 65535, 0])]

EMPTY_COLUMNS = [("n", pa.int64(), True, []), ("s", pa.string(), True, [])]

UNSUPPORTED_COLUMNS = [
    ("price", pa.decimal128(10, 2), True, [_Decimal("1.50"), _Decimal("2.25")]),
    ("tags", pa.list_(pa.string()), True, [["a", "b"], ["c"]]),
]

# Nullable column that actually contains a null: the reader must reject it.
NULLS_COLUMNS = [("a", pa.int64(), True, [1, None, 3])]

# Two record batches in one file: the reader returns the first batch only.
MULTI_BATCH_COLUMNS = [("a", pa.int64(), False, [10, 20])]
MULTI_BATCH_COLUMNS_2 = [("a", pa.int64(), False, [30, 40])]


def make_schema_and_batch(columns):
    fields = []
    arrays = []
    for name, typ, nullable, values in columns:
        fields.append(pa.field(name, typ, nullable=nullable))
        arrays.append(pa.array(values, type=typ))
    schema = pa.schema(fields)
    batch = pa.RecordBatch.from_arrays(arrays, schema=schema)
    return schema, batch


def write_file(path, schema, batch):
    with pa.OSFile(str(path), "wb") as sink:
        with pa.ipc.new_file(sink, schema) as writer:
            writer.write_batch(batch)


def write_stream(path, schema, batch):
    with pa.OSFile(str(path), "wb") as sink:
        with pa.ipc.new_stream(sink, schema) as writer:
            writer.write_batch(batch)


def racket_literal(value, typ):
    if pa.types.is_boolean(typ):
        return "#t" if value else "#f"
    if pa.types.is_integer(typ):
        return str(value)
    if pa.types.is_floating(typ):
        return repr(float(value))
    if pa.types.is_string(typ):
        escaped = (
            value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")
        )
        return '"%s"' % escaped
    raise ValueError("unexpected type %s" % typ)


def racket_vector(values, typ):
    if pa.types.is_floating(typ):
        return "(flvector %s)" % " ".join(racket_literal(v, typ) for v in values)
    return "(vector %s)" % " ".join(racket_literal(v, typ) for v in values)


def emit_expected(label, columns):
    print(";; --- %s ---" % label)
    print("(define %s-num-rows %d)" % (label, len(columns[0][3]) if columns else 0))
    lines = []
    for name, typ, nullable, values in columns:
        type_name = {
            pa.bool_(): "bool",
            pa.int8(): "int8",
            pa.int16(): "int16",
            pa.int32(): "int32",
            pa.int64(): "int64",
            pa.uint8(): "uint8",
            pa.uint16(): "uint16",
            pa.uint32(): "uint32",
            pa.uint64(): "uint64",
            pa.float32(): "float32",
            pa.float64(): "float64",
            pa.string(): "string",
        }[typ]
        lines.append('  (list "%s" \'%s %s)' % (name, type_name, "#t" if nullable else "#f"))
    print("(define %s-fields (list%s))" % (label, "\n" + "\n".join(lines) if lines else ""))
    col_lines = [ "  " + racket_vector(values, typ) for _, typ, _, values in columns ]
    print("(define %s-columns (list%s))" % (label, "\n" + "\n".join(col_lines) if col_lines else ""))
    print()


def main():
    HERE.mkdir(parents=True, exist_ok=True)

    schema, batch = make_schema_and_batch(MIXED_COLUMNS)
    write_file(HERE / "golden-file-mixed.arrow", schema, batch)
    write_stream(HERE / "golden-stream-mixed.arrows", schema, batch)

    schema_s, batch_s = make_schema_and_batch(SINGLE_COLUMNS)
    write_file(HERE / "golden-file-single.arrow", schema_s, batch_s)

    schema_e, batch_e = make_schema_and_batch(EMPTY_COLUMNS)
    write_file(HERE / "golden-file-empty.arrow", schema_e, batch_e)

    schema_u, batch_u = make_schema_and_batch(UNSUPPORTED_COLUMNS)
    write_file(HERE / "golden-file-unsupported.arrow", schema_u, batch_u)

    schema_n, batch_n = make_schema_and_batch(NULLS_COLUMNS)
    write_file(HERE / "golden-file-nulls.arrow", schema_n, batch_n)

    schema_m, batch_m = make_schema_and_batch(MULTI_BATCH_COLUMNS)
    _, batch_m2 = make_schema_and_batch(MULTI_BATCH_COLUMNS_2)
    with pa.OSFile(str(HERE / "golden-file-multi-batch.arrow"), "wb") as sink:
        with pa.ipc.new_file(sink, schema_m) as writer:
            writer.write_batch(batch_m)
            writer.write_batch(batch_m2)

    emit_expected("mixed", MIXED_COLUMNS)
    emit_expected("single", SINGLE_COLUMNS)
    emit_expected("empty", EMPTY_COLUMNS)

    # Sanity: read everything back with pyarrow and verify round-trip.
    for path, columns in [
        ("golden-file-mixed.arrow", MIXED_COLUMNS),
        ("golden-file-single.arrow", SINGLE_COLUMNS),
        ("golden-file-empty.arrow", EMPTY_COLUMNS),
        ("golden-stream-mixed.arrows", MIXED_COLUMNS),
        ("golden-file-multi-batch.arrow", MULTI_BATCH_COLUMNS),
    ]:
        p = HERE / path
        if "stream" in path:
            with pa.memory_map(str(p), "rb") as source:
                reader = pa.ipc.open_stream(source)
                table = reader.read_all()
        else:
            with pa.memory_map(str(p), "rb") as source:
                reader = pa.ipc.open_file(source)
                if "multi-batch" in path:
                    assert reader.num_record_batches == 2, path
                    table = reader.get_batch(0)
                else:
                    assert reader.num_record_batches == 1, path
                    table = reader.get_batch(0)
        for i, (name, typ, _, values) in enumerate(columns):
            got = table.column(i).to_pylist()
            assert got == values, (path, name, got, values)
        print(";; verified round-trip: %s (%d rows, %d cols)" % (path, table.num_rows, table.num_columns))

    # Sanity: the nulls fixture really contains a null.
    with pa.memory_map(str(HERE / "golden-file-nulls.arrow"), "rb") as source:
        reader = pa.ipc.open_file(source)
        batch = reader.get_batch(0)
        assert batch.column(0).null_count == 1
        print(";; verified nulls fixture has null_count=1")


if __name__ == "__main__":
    main()
