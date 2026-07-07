#!/usr/bin/env python3
"""Measure the fraction of posts created before/after a time cutoff,
   directly from the creation trace files (ground truth)."""

import argparse
import re
from pathlib import Path

import polars as pl


def parse_run_id(filename: str) -> int:
    m = re.match(r"(\d+)-create_trace", filename)
    if m is None:
        raise ValueError(f"Cannot parse run_id from: {filename}")
    return int(m.group(1))


def main():
    parser = argparse.ArgumentParser(
        description="Ratio of posts created before/after a time cutoff."
    )
    parser.add_argument(
        "--traces-dir", type=str, required=True,
        help="Path to traces directory (e.g., ../../traces/10K_test)"
    )
    parser.add_argument(
        "--cutoff", type=float, default=1000.0,
        help="Time cutoff for warmup (default: 1000)"
    )
    args = parser.parse_args()

    traces_dir = Path(args.traces_dir)
    cutoff = args.cutoff

    files = sorted(traces_dir.glob("*-create_trace.jsonl"))
    if not files:
        print(f"No *-create_trace.jsonl files found in {traces_dir}")
        return

    all_runs: list[pl.DataFrame] = []

    for fpath in files:
        run_id = parse_run_id(fpath.name)
        df = pl.read_ndjson(fpath).select(pl.col("time"))
        df = df.with_columns(pl.lit(run_id).alias("run_id"))
        all_runs.append(df)

    data = pl.concat(all_runs)

    # Per-run ratio
    per_run = (
        data
        .with_columns(
            pl.when(pl.col("time") < cutoff)
              .then(pl.lit(1))
              .otherwise(pl.lit(0))
              .alias("before")
        )
        .group_by("run_id")
        .agg([
            pl.len().alias("total"),
            pl.sum("before").alias("before_cutoff"),
        ])
        .with_columns(
            (pl.col("before_cutoff") / pl.col("total") * 100)
            .round(2)
            .alias("pct_before")
        )
        .sort("run_id")
    )

    # Overall
    total_before = per_run["before_cutoff"].sum()
    total_all = per_run["total"].sum()

    print(f"Traces dir : {traces_dir}")
    print(f"Files      : {len(files)}")
    print(f"Cutoff     : {cutoff}")
    print(f"Total posts: {total_all:,}")
    print(f"Before <{cutoff}: {total_before:,}  ({total_before/total_all*100:.2f}%)")
    print(f"After  >={cutoff}: {total_all - total_before:,}  ({(total_all-total_before)/total_all*100:.2f}%)")
    print()
    print("Per-run (first 10 / last 10):")
    print(per_run.head(10))
    print("...")
    print(per_run.tail(10))

    # After-cutoff time distribution
    after = data.filter(pl.col("time") >= cutoff)
    print(f"\nPosts after cutoff (>= {cutoff}): {after.height:,}")
    if after.height > 0:
        times = after["time"]
        print(f"  Min:  {times.min():.2f}")
        print(f"  Q25:  {times.quantile(0.25):.2f}")
        print(f"  Med:  {times.quantile(0.50):.2f}")
        print(f"  Q75:  {times.quantile(0.75):.2f}")
        print(f"  Max:  {times.max():.2f}")


if __name__ == "__main__":
    main()
