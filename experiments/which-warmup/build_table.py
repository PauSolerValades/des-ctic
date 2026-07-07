#!/usr/bin/env python3
"""Generate a summary table (CSV) for the warmup experiment.

Usage:
    python build_table.py --traces ../../traces/10K-warmup \\
                          --cascades ../../cascades/10K-warmup \\
                          --datasets ../../datasets/10K-warmup \\
                          -o output
"""

from __future__ import annotations

import polars as pl
from utils import Config

SSV_SCHEMA = {
    "run_id": pl.UInt32,
    "post_id": pl.UInt32,
    "user_id": pl.UInt32,
    "parent_id": pl.Int64,
    "type": pl.String,
    "time": pl.Float64,
}


def main(config: Config) -> None:
    config.output_dir.mkdir(parents=True, exist_ok=True)

    header = (
        f"{'wt':>4}  {'boredom%':>8}  {'sesh':>5}  {'posts':>7}  "
        f"{'prolif%':>7}  {'mean_rp':>7}  {'indirect%':>8}  {'multilvl%':>9}"
    )
    print(header)
    print("-" * 80)

    rows: list[list] = []
    for warmup in config.warmups:
        bp, al = session_stats(config, warmup)
        n, pr, mr, pi, pm = cascade_stats(config, warmup)
        print(
            f"{warmup:>4}  {bp:>7.1f}%  {al:>5.0f}  {n:>7,}  "
            f"{pr:>6.1f}%  {mr:>6.2f}  {pi:>7.1f}%  {pm:>8.1f}%"
        )
        rows.append([warmup, bp, al, n, pr, mr, pi, pm])

    result = pl.DataFrame(
        rows,
        schema=[
            "warmup",
            "boredom_pct",
            "avg_session_len",
            "post_wp_posts",
            "pct_prolif",
            "mean_reposts",
            "pct_indirect",
            "pct_multilevel",
        ],
        orient="row",
    )
    out_path = config.output_dir / "summary_table.ssv"
    result.write_csv(out_path, separator=" ")
    print(f"\nSaved {out_path}")


def session_stats(config: Config, warmup: float) -> tuple[float, float]:
    """Return (boredom_pct, avg_session_length) for one warmup value."""
    ticks_dir = config.traces_dir / f"{warmup:g}-ticks"
    total_boredom, total_normal, total_length, n_sessions = 0, 0, 0.0, 0

    for run in range(config.num_runs):
        path = ticks_dir / f"{run}-session_trace.jsonl"
        df = pl.read_ndjson(
            str(path),
            schema_overrides={
                "time": pl.Float64,
                "event_id": pl.Int64,
                "gen_id": pl.Int64,
                "user_id": pl.Int64,
                "type": pl.String,
                "backlog": pl.Int64,
            },
        )
        counts = df["type"].value_counts()
        counts_map = dict(zip(counts["type"].to_list(), counts["count"].to_list()))
        total_boredom += counts_map.get("end_boredom", 0)
        total_normal += counts_map.get("end", 0)

        starts = df.filter(pl.col("type") == "start").sort("time")
        ends = df.filter(pl.col("type").is_in(["end", "end_boredom"])).sort("time")
        for i in range(min(starts.height, ends.height)):
            total_length += ends["time"][i] - starts["time"][i]
            n_sessions += 1

    boredom_pct = (
        round(total_boredom / (total_boredom + total_normal) * 100, 1)
        if (total_boredom + total_normal)
        else 0.0
    )
    avg_length = round(total_length / n_sessions, 1) if n_sessions else 0.0
    return boredom_pct, avg_length


def cascade_stats(
    config: Config, warmup: float
) -> tuple[int, float, float, float, float]:
    """Return (post_warmup_posts, pct_prolif, mean_reposts, pct_indirect, pct_multilevel)."""
    cascade_path = config.cascades_dir / f"warmup-{warmup:g}.ssv"
    df = pl.read_csv(
        str(cascade_path),
        separator=" ",
        schema_overrides=SSV_SCHEMA,
        has_header=True,
    )

    creations = df.filter((pl.col("type") == "creation") & (pl.col("time") >= warmup))
    reposts = df.filter((pl.col("type") == "repost") & (pl.col("time") >= warmup))

    n = creations.height

    # Proliferation: % of posts that get at least one repost
    rc = reposts.group_by(["run_id", "post_id"]).len(name="n")
    pct_prolif = round(rc.height / n * 100, 1) if n else 0.0
    mean_reposts = round(rc["n"].mean(), 2) if rc.height else 0.0

    # Indirect reposts
    authors = creations.select(
        ["run_id", "post_id", pl.col("user_id").alias("author_id")]
    )
    reposts_with_author = reposts.join(authors, on=["run_id", "post_id"]).with_columns(
        pl.col("parent_id").cast(pl.UInt32).alias("p32")
    )
    indirect = reposts_with_author.filter(pl.col("p32") != pl.col("author_id"))

    pct_indirect = (
        round(indirect.height / reposts.height * 100, 1) if reposts.height else 0.0
    )
    pct_multilevel = (
        round(
            indirect.select(["run_id", "post_id"]).unique().height / rc.height * 100, 1
        )
        if rc.height
        else 0.0
    )

    return n, pct_prolif, mean_reposts, pct_indirect, pct_multilevel


if __name__ == "__main__":
    main()
