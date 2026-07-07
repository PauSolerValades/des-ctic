#!/usr/bin/env python3
"""
Quick check: do cascades in the SSV have depth > 1?
Loads the SSV, groups by (run_id, post_id), and counts reposts.
Also checks whether any repost has a parent that is NOT the original author.
"""

import argparse
from pathlib import Path

import polars as pl

SCHEMA = {
    "run_id": pl.UInt32,
    "post_id": pl.UInt32,
    "user_id": pl.UInt32,
    "parent_id": pl.Int64,   # -1 for propagation rows
    "type": pl.String,
    "time": pl.Float64,
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--ssv", type=str, default="../../cascades/10K_test.ssv",
        help="Path to cascades SSV file"
    )
    args = parser.parse_args()

    path = Path(args.ssv).resolve()
    print(f"Loading {path} ...")

    # SSV is space-separated, use scan_csv with separator
    df = pl.read_csv(
        str(path),
        separator=" ",
        schema_overrides=SCHEMA,
        has_header=True,
    )
    print(f"  {df.height:,} total rows")

    # ── 1. Count rows per cascade ───────────────────────────────────────

    creations = df.filter(pl.col("type") == "creation").height
    reposts = df.filter(pl.col("type") == "repost")

    print(f"  {creations:,} creations")
    print(f"  {reposts.height:,} reposts")
    print(f"  {df.height - creations - reposts.height:,} propagation rows")

    # Reposts per (run_id, post_id) — all cascades
    repost_counts = (
        reposts
        .group_by(["run_id", "post_id"])
        .len(name="n_reposts")
        .sort(["run_id", "post_id"])
    )

    print(f"\n═══ Repost distribution ═══")
    print(f"  Cascades with reposts: {repost_counts.height:,}")

    # Distribution of repost counts
    dist = (
        repost_counts
        .group_by("n_reposts")
        .len(name="cascade_count")
        .sort("n_reposts")
    )
    print("\nRepost count distribution (top 20 + tail):")
    print(dist.head(20))
    if dist.height > 20:
        print("  ...")
        print(dist.tail(10))

    print(f"\n  Max reposts in any cascade: {repost_counts['n_reposts'].max()}")

    # ── 2. Check for multi-level: reposts where parent ≠ author ─────────

    # Get the author (creator) for each cascade
    authors = (
        df.filter(pl.col("type") == "creation")
        .select(["run_id", "post_id", pl.col("user_id").alias("author_id")])
    )

    # Join reposts with their cascade author
    reposts_with_author = reposts.join(
        authors, on=["run_id", "post_id"], how="inner"
    )

    # Cast parent_id to same type for comparison
    reposts_with_author = reposts_with_author.with_columns(
        pl.col("parent_id").cast(pl.UInt32).alias("parent_id_u32")
    )

    # How many reposts are from someone OTHER than the author?
    indirect = reposts_with_author.filter(
        pl.col("parent_id_u32") != pl.col("author_id")
    )

    total_reposts = reposts_with_author.height
    n_indirect = indirect.height

    print(f"\n═══ Multi-level check ═══")
    print(f"  Total reposts:          {total_reposts:,}")
    print(f"  Reposts from root:      {total_reposts - n_indirect:,}  ({(total_reposts-n_indirect)/total_reposts*100:.1f}%)")
    print(f"  Reposts NOT from root:  {n_indirect:,}  ({n_indirect/total_reposts*100:.1f}%)")

    if n_indirect > 0:
        print(f"\n  First 20 indirect reposts:")
        print(indirect.select(["run_id", "post_id", "user_id", "author_id", "parent_id", "time"]).head(20))

        # Which post_ids have indirect reposts?
        indirect_posts = indirect.select(["run_id", "post_id"]).unique()
        print(f"\n  Cascades with at least one indirect repost: {indirect_posts.height:,}")

    # ── 3. Also check: who are the repost parents?
    #    (moot since we already confirmed 0 indirect reposts)

    repost_parents = reposts.select(pl.col("parent_id").cast(pl.UInt32)).unique()
    n_rep_parents = repost_parents.filter(pl.col("parent_id") != 0).height
    print(f"\n═══ Parent check ═══")
    print(f"  Unique repost parent_ids:  {n_rep_parents}")


if __name__ == "__main__":
    main()
