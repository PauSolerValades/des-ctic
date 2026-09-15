#!/usr/bin/env python3
"""Read a self-describing .bin trace written by bskysim.

Layout: one text header line terminated by '\\n', then fixed-size records.
The header records the compiler's actual field offsets, so the reader never
assumes declaration order:

    type:<name>,record_size:<n>,endian:little,
    name:<field>,offset:<byte>,kind:<tag>[,variants:<v0>|<v1>|...],...

Usage:
    uv run bin_reader.py <trace.bin> [--limit N]
    uv run bin_reader.py --selftest
"""

import argparse
import json
import struct
import sys

# kind tag -> struct format char; endianness is prefixed on use.
KINDS = {
    "f64": "d", "f32": "f", "f16": "e",
    "u64": "Q", "u32": "I", "u16": "H", "u8": "B",
    "i64": "q", "i32": "i", "i16": "h", "i8": "b",
    "bool": "?",
}


def parse_header(line):
    header = {"fields": []}
    for token in line.rstrip("\n").split(","):
        key, _, value = token.partition(":")
        if key == "name":
            header["fields"].append({"name": value})
        elif key == "offset":
            header["fields"][-1]["offset"] = int(value)
        elif key == "kind":
            header["fields"][-1]["kind"] = value
        elif key == "variants":
            header["fields"][-1]["variants"] = value.split("|")
        elif key == "record_size":
            header["record_size"] = int(value)
        else:
            header[key] = value
    return header


def read_header(f):
    return parse_header(f.readline().decode("ascii"))


def iter_records(f, header, limit=None):
    endian = "<" if header.get("endian", "little") == "little" else ">"
    size = header["record_size"]
    fields = []
    for fd in header["fields"]:
        if fd["kind"] not in KINDS:
            raise ValueError(f"unknown kind {fd['kind']!r} for field {fd['name']!r}")
        fields.append((fd["name"], fd["offset"], struct.Struct(endian + KINDS[fd["kind"]]), fd.get("variants")))

    remaining = limit
    while remaining is None or remaining > 0:
        chunk = f.read(size)
        if len(chunk) != size:
            if chunk:
                raise ValueError(f"truncated record: {len(chunk)}/{size} bytes")
            return
        record = {}
        for name, offset, unpack, variants in fields:
            (value,) = unpack.unpack_from(chunk, offset)
            if variants is not None:
                value = variants[value] if value < len(variants) else value
            record[name] = value
        yield record
        if remaining is not None:
            remaining -= 1


def _selftest():
    import io

    header = (
        "type:Rec,record_size:16,endian:little,"
        "name:a,offset:0,kind:f64,"
        "name:n,offset:8,kind:u32,"
        "name:k,offset:12,kind:u8,variants:alpha|beta\n"
    )
    # note: field order in memory (a, n, k) need not match declaration order.
    body = struct.pack("<dIB3x", 1.5, 7, 1)
    f = io.BytesIO(header.encode() + body)

    parsed = read_header(f)
    assert parsed["type"] == "Rec"
    assert parsed["record_size"] == 16
    assert [fd["name"] for fd in parsed["fields"]] == ["a", "n", "k"]
    assert list(iter_records(f, parsed)) == [{"a": 1.5, "n": 7, "k": "beta"}]
    print("selftest ok")


def main():
    ap = argparse.ArgumentParser(description="Read a bskysim .bin trace")
    ap.add_argument("path", nargs="?", help="path to a *-trace.bin file")
    ap.add_argument("--limit", type=int, default=None, help="max records to read")
    ap.add_argument("--selftest", action="store_true", help="run the built-in check")
    args = ap.parse_args()

    if args.selftest:
        _selftest()
        return
    if not args.path:
        ap.error("path is required unless --selftest is used")

    with open(args.path, "rb") as f:
        header = read_header(f)
        print(json.dumps({k: v for k, v in header.items() if k != "fields"}))
        for record in iter_records(f, header, args.limit):
            print(json.dumps(record))


if __name__ == "__main__":
    sys.exit(main())
