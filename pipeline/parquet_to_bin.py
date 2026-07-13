#!/usr/bin/env python3
"""Convert BlueSky network parquet files to a flat binary file.

Expected parquet files in the input folder:
    nodes.parquet         – columns: did (string), int_id (i32 → written as u32)
    induced_edges.parquet – columns: actor_id (i32 → written as u32), subject_id (i32 → u32)

Binary layout (little-endian, no header):
    u32  num_users
    u32  user_ids[num_users]
    u32  num_induced
    u32  induced_edges[num_induced * 2]   (actor_id, subject_id interleaved)

Usage:
    uv run --with pyarrow parquet_to_bin.py 10K
    uv run --with pyarrow parquet_to_bin.py 10K -o ./my_output
"""

import os
import struct
import sys

EXPECTED = ("nodes.parquet", "induced_edges.parquet")


def die(msg: str) -> None:
    print(f"Error: {msg}", file=sys.stderr)
    sys.exit(1)


def read_u32_col(folder: str, filename: str, col: str) -> "list[int]":
    import pyarrow.parquet as pq
    t = pq.read_table(os.path.join(folder, filename))
    # parquet stores i32 but values are non-negative u32 IDs
    return [v & 0xFFFFFFFF for v in t.column(col).to_pylist()]


def main() -> None:
    args = sys.argv[1:]
    if not args:
        print(f"Usage: {sys.argv[0]} <input_folder> [-o <output_dir>]", file=sys.stderr)
        sys.exit(1)

    inp = args[0]
    out = None

    i = 1
    while i < len(args):
        if args[i] == "-o" and i + 1 < len(args):
            out = args[i + 1]
            i += 2
        else:
            die(f"unknown option: {args[i]}")

    if not os.path.isdir(inp):
        die(f"'{inp}' is not a directory")

    missing = [f for f in EXPECTED if not os.path.isfile(os.path.join(inp, f))]
    if missing:
        die(f"missing files in '{inp}': {missing}")

    if out is None:
        parent = os.path.dirname(os.path.abspath(inp))
        name = os.path.basename(os.path.abspath(inp))
        out = os.path.join(parent, f"{name}_binary")

    os.makedirs(out, exist_ok=True)

    print(f"Reading: {inp}  ->  {out}")

    users = read_u32_col(inp, "nodes.parquet", "int_id")
    induced_a = read_u32_col(inp, "induced_edges.parquet", "actor_id")
    induced_s = read_u32_col(inp, "induced_edges.parquet", "subject_id")

    # Deduplicate edges
    seen = set()
    deduped_a, deduped_s = [], []
    for a, s in zip(induced_a, induced_s):
        if (a, s) not in seen:
            seen.add((a, s))
            deduped_a.append(a)
            deduped_s.append(s)

    dupes = len(induced_a) - len(deduped_a)
    if dupes > 0:
        print(f"  removed {dupes:,} duplicate edges ({len(deduped_a):,} unique)")

    print(f"  users: {len(users)}  induced: {len(deduped_a)}")

    buf = bytearray()

    buf.extend(struct.pack("<I", len(users)))
    buf.extend(struct.pack(f"<{len(users)}I", *users))

    buf.extend(struct.pack("<I", len(deduped_a)))
    for a, s in zip(deduped_a, deduped_s):
        buf.extend(struct.pack("<II", a, s))


    out_path = os.path.join(out, "network.bin")
    with open(out_path, "wb") as f:
        f.write(buf)

    print(f"  wrote: {out_path}  ({len(buf):,} bytes)")


if __name__ == "__main__":
    main()
