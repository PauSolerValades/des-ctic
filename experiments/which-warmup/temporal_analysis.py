#!/usr/bin/env python3
"""Temporal analysis: boredom, warmup attention decay, and new post traction.

Usage:
    python temporal_analysis.py --traces ../../traces/10K-warmup \\
                                --cascades ../../cascades/10K-warmup \\
                                --datasets ../../datasets/10K-warmup \\
                                -o output
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor

import matplotlib.pyplot as plt
import numpy as np
import polars as pl
from utils import Config

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main(config: Config) -> None:
    config.output_dir.mkdir(parents=True, exist_ok=True)

    print(f"Found {len(config.warmups)} warmup values: {config.warmups}")
    print(f"Runs per warmup: {config.num_runs}")
    print(f"Traces:   {config.traces_dir}")
    print(f"Cascades: {config.cascades_dir}")
    print(f"Datasets: {config.datasets_dir}")
    print(f"Output:   {config.output_dir}")
    print()

    all_data = load_all_runs(config)

    plot_boredom_timeline(all_data, config)
    plot_warmup_attention_decay(all_data, config)
    plot_new_post_traction(all_data, config)
    plot_combined_summary(all_data, config)
    plot_first_session_backlog(all_data, config)
    plot_sessions_actions(config)
    print("\nDone.")


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------


CREATE_SCHEMA: dict[str, pl.DataType] = {
    "time": pl.Float64,
    "event_id": pl.Int64,
    "gen_id": pl.Int64,
    "user_id": pl.Int64,
    "post_id": pl.Int64,
}

ACTION_SCHEMA: dict[str, pl.DataType] = {
    "time": pl.Float64,
    "event_id": pl.Int64,
    "gen_id": pl.Int64,
    "user_id": pl.Int64,
    "post_id": pl.Int64,
    "parent_id": pl.Int64,
    "type": pl.String,
}

SES_SCHEMA: dict[str, pl.DataType] = {
    "time": pl.Float64,
    "event_id": pl.Int64,
    "gen_id": pl.Int64,
    "user_id": pl.Int64,
    "type": pl.String,
    "backlog": pl.Int64,
}


def _load_run(config: Config, warmup: float, run: int) -> dict[str, pl.DataFrame]:
    """Load all trace files for a single run — parallel I/O."""
    base = str(config.traces_dir / f"{warmup:g}-ticks" / str(run))

    def _read(kind: str, schema: dict) -> pl.DataFrame:
        return pl.read_ndjson(base + kind, schema_overrides=schema)

    with ThreadPoolExecutor(max_workers=3) as ex:
        f_actions = ex.submit(_read, "-action_trace.jsonl", ACTION_SCHEMA)
        f_creates = ex.submit(_read, "-create_trace.jsonl", CREATE_SCHEMA)
        f_sessions = ex.submit(_read, "-session_trace.jsonl", SES_SCHEMA)
        return {
            "actions": f_actions.result(),
            "creates": f_creates.result(),
            "sessions": f_sessions.result(),
        }


def load_all_runs(config: Config) -> dict[int, dict[int, dict[str, pl.DataFrame]]]:
    """Load all trace data for every warmup × run combination.

    Returns ``{warmup: {run: {"actions": df, "creates": df, "sessions": df}}}``.
    """
    all_data: dict[int, dict[int, dict[str, pl.DataFrame]]] = {}
    for warmup in config.warmups:
        all_data[warmup] = {}
        for run in range(config.num_runs):
            all_data[warmup][run] = _load_run(config, warmup, run)
        print(f"  warmup={warmup} loaded")
    return all_data


# ---------------------------------------------------------------------------
# Plotting helpers
# ---------------------------------------------------------------------------


def _post_warmup_actions(
    actions: pl.DataFrame, creates: pl.DataFrame, warmup: float
) -> pl.DataFrame:
    """Return post-warmup actions with ``is_warmup`` column via native join.

    Much faster than the old map_elements / dict-lookup approach.
    """
    obs = actions.filter(pl.col("time") >= warmup)
    return obs.join(
        creates.select(
            pl.col("post_id"),
            (pl.col("time") < warmup).alias("is_warmup"),
        ),
        on="post_id",
        how="left",
    ).with_columns(pl.col("is_warmup").fill_null(False))


def _viridis_colors(n: int) -> list:
    """Return *n* evenly-spaced viridis colours."""
    return plt.cm.viridis(np.linspace(0.15, 0.95, n))


# ---------------------------------------------------------------------------
# Plot: boredom timeline
# ---------------------------------------------------------------------------


def plot_boredom_timeline(all_data: dict, config: Config) -> None:
    """Histogram: when do boredom-ended sessions occur?"""
    warmups = config.warmups
    n_warmups = len(warmups)
    n_cols = 4
    n_rows = (n_warmups + n_cols - 1) // n_cols
    fig, axes = plt.subplots(n_rows, n_cols, figsize=(5 * n_cols, 4 * n_rows))
    axes_flat = axes.flatten() if hasattr(axes, 'flatten') else [axes]
    colors = _viridis_colors(n_warmups)

    for idx, warmup in enumerate(warmups):
        ax = axes_flat[idx]
        # Collect all boredom times via Polars concat instead of Python list
        parts = [
            all_data[warmup][run]["sessions"]
            .filter(pl.col("type") == "end_boredom")
            .select("time")
            for run in range(config.num_runs)
        ]
        all_times_df = pl.concat(parts) if parts else pl.DataFrame(schema={"time": pl.Float64})
        if all_times_df.is_empty():
            continue

        arr = (
            all_times_df.filter(
                (pl.col("time") >= warmup) & (pl.col("time") <= warmup + 5000)
            )
            .select((pl.col("time") - warmup).alias("rel"))
            .to_series()
            .to_numpy()
        )
        if len(arr) == 0:
            continue

        bins = np.logspace(np.log10(1), np.log10(5100), 50)
        counts, _ = np.histogram(arr, bins=bins)
        bin_widths = np.diff(bins)
        rate = counts / bin_widths / config.num_runs
        centers = (bins[:-1] + bins[1:]) / 2

        ax.loglog(centers, rate, ".-", color=colors[idx], linewidth=1, markersize=2)
        ax.axvline(x=1, color="red", linestyle="--", alpha=0.3)
        ax.set_xlabel("Ticks after warmup")
        ax.set_ylabel("Boredom ends / tick / run")
        ax.set_title(f"warmup={warmup}")
        ax.grid(True, alpha=0.2, which="both")

    # Hide unused axes
    for ax in axes_flat[len(warmups) :]:
        ax.set_visible(False)

    fig.suptitle(
        "Boredom-ended sessions over time (log-log, per-tick rate, avg over runs)",
        fontsize=13,
        fontweight="bold",
    )
    fig.tight_layout()
    fig.savefig(config.output_dir / "boredom_timeline.png", dpi=150)
    plt.close(fig)
    print("  Saved boredom_timeline.png")


# ---------------------------------------------------------------------------
# Plot: warmup attention decay
# ---------------------------------------------------------------------------


def plot_warmup_attention_decay(all_data: dict, config: Config) -> None:
    """% of actions on warmup posts, binned over time."""
    warmups = config.warmups
    n_warmups = len(warmups)
    n_cols = 4
    n_rows = (n_warmups + n_cols - 1) // n_cols
    fig, axes = plt.subplots(n_rows, n_cols, figsize=(5 * n_cols, 4 * n_rows))
    axes_flat = axes.flatten() if hasattr(axes, 'flatten') else [axes]
    colors = _viridis_colors(n_warmups)
    bin_size = config.bin_size

    for idx, warmup in enumerate(warmups):
        ax = axes_flat[idx]

        if warmup == 0:
            ax.text(
                0.5,
                0.5,
                "warmup=0\n(no warmup posts)",
                ha="center",
                va="center",
                transform=ax.transAxes,
                fontsize=12,
            )
            ax.set_title("warmup=0")
            continue

        # Native Polars binning — avoids iter_rows()
        parts = []
        for run in range(config.num_runs):
            d = all_data[warmup][run]
            obs = _post_warmup_actions(d["actions"], d["creates"], warmup)
            parts.append(
                obs.select(
                    ((pl.col("time") - warmup) // bin_size).cast(pl.Int64).alias("bin"),
                    pl.col("is_warmup"),
                )
            )
        if not parts:
            continue
        all_binned = pl.concat(parts)
        agg = all_binned.group_by("bin").agg(
            pl.len().alias("total"),
            pl.col("is_warmup").sum().alias("wp"),
        )
        agg_sorted = agg.sort("bin")

        max_bin = agg_sorted["bin"].max()
        xs = np.arange(0, max_bin + 1) * bin_size
        # Build aligned arrays via a join to fill missing bins with 0
        full = pl.DataFrame({"bin": range(max_bin + 1)}).join(
            agg_sorted, on="bin", how="left"
        ).fill_null(0)
        ys = [
            wp / total * 100 if total > 10 else np.nan
            for wp, total in zip(full["wp"].to_list(), full["total"].to_list())
        ]

        ax.plot(xs, ys, "-", color=colors[idx], linewidth=1.5, alpha=0.9)
        ax.axhline(y=0, color="red", linestyle="--", alpha=0.3)
        ax.set_xlabel("Ticks after warmup")
        ax.set_ylabel("% actions on warmup posts")
        ax.set_title(f"warmup={warmup}")
        ax.set_ylim(-5, 105)

    for ax in axes_flat[len(warmups) :]:
        ax.set_visible(False)

    fig.suptitle(
        f"Warmup post attention decay over time (binned every {bin_size} ticks, avg over runs)",
        fontsize=13,
        fontweight="bold",
    )
    fig.tight_layout()
    fig.savefig(config.output_dir / "warmup_attention_decay.png", dpi=150)
    plt.close(fig)
    print("  Saved warmup_attention_decay.png")


# ---------------------------------------------------------------------------
# Plot: new post traction
# ---------------------------------------------------------------------------


def plot_new_post_traction(all_data: dict, config: Config) -> None:
    """Impressions per new post over time — when do new posts get seen?"""
    warmups = config.warmups
    n_warmups = len(warmups)
    n_cols = 4
    n_rows = (n_warmups + n_cols - 1) // n_cols
    fig, axes = plt.subplots(n_rows, n_cols, figsize=(5 * n_cols, 4 * n_rows))
    axes_flat = axes.flatten() if hasattr(axes, 'flatten') else [axes]
    colors = _viridis_colors(n_warmups)
    bin_size = config.bin_size

    for idx, warmup in enumerate(warmups):
        ax = axes_flat[idx]
        # Native Polars binning — avoids iter_rows()
        imp_parts, np_parts = [], []
        for run in range(config.num_runs):
            d = all_data[warmup][run]
            actions, creates = d["actions"], d["creates"]
            obs = _post_warmup_actions(actions, creates, warmup)
            imp_parts.append(
                obs.filter(~pl.col("is_warmup"))
                .select(((pl.col("time") - warmup) // bin_size).cast(pl.Int64).alias("bin"))
            )
            np_parts.append(
                creates.filter(pl.col("time") >= warmup)
                .select(((pl.col("time") - warmup) // bin_size).cast(pl.Int64).alias("bin"))
            )
        if not imp_parts:
            continue

        imp_agg = (
            pl.concat(imp_parts).group_by("bin").len(name="impressions").sort("bin")
        )
        np_agg = (
            pl.concat(np_parts).group_by("bin").len(name="new_posts").sort("bin")
        )

        max_bin = max(
            imp_agg["bin"].max() if not imp_agg.is_empty() else 0,
            np_agg["bin"].max() if not np_agg.is_empty() else 0,
        )
        full_imp = pl.DataFrame({"bin": range(max_bin + 1)}).join(
            imp_agg, on="bin", how="left"
        ).fill_null(0)
        full_np = pl.DataFrame({"bin": range(max_bin + 1)}).join(
            np_agg, on="bin", how="left"
        ).fill_null(0)

        xs = np.arange(0, max_bin + 1) * bin_size
        ys = [
            (imp / config.num_runs) / max(np_count / config.num_runs, 1)
            if np_count > 0
            else np.nan
            for imp, np_count in zip(
                full_imp["impressions"].to_list(),
                full_np["new_posts"].to_list(),
            )
        ]

        ax.plot(xs, ys, "-", color=colors[idx], linewidth=1.5, alpha=0.9)
        ax.set_xlabel("Ticks after warmup")
        ax.set_ylabel("Impressions per new post")
        ax.set_title(f"warmup={warmup}")

    for ax in axes_flat[len(warmups) :]:
        ax.set_visible(False)

    fig.suptitle(
        f"New post traction over time (impressions/post, binned every {bin_size} ticks, avg over runs)",
        fontsize=13,
        fontweight="bold",
    )
    fig.tight_layout()
    fig.savefig(config.output_dir / "new_post_traction.png", dpi=150)
    plt.close(fig)
    print("  Saved new_post_traction.png")


# ---------------------------------------------------------------------------
# Plot: first-session backlog
# ---------------------------------------------------------------------------


def plot_first_session_backlog(all_data: dict, config: Config) -> None:
    """Boxplot: backlog posts deleted when each user's first session ends."""
    fig, ax = plt.subplots(figsize=(12, 6))
    data, labels = [], []

    for warmup in config.warmups:
        all_backlogs: list[int] = []
        for run in range(config.num_runs):
            sessions = all_data[warmup][run]["sessions"]
            ends = sessions.filter(pl.col("type").is_in(["end", "end_boredom"]))
            first_ends = ends.unique(subset=["user_id"], keep="first")
            all_backlogs.extend(first_ends["backlog"].to_list())
        data.append(all_backlogs)
        labels.append(str(warmup))

    bp = ax.boxplot(
        data,
        tick_labels=labels,
        patch_artist=True,
        showfliers=False,
        widths=0.6,
    )
    for patch, color in zip(bp["boxes"], _viridis_colors(len(config.warmups))):
        patch.set_facecolor(color)
        patch.set_alpha(0.7)

    ax.set_xlabel("Warmup time")
    ax.set_ylabel("Backlog posts deleted on session end")
    ax.set_title(
        "Posts lost when first session ends (discarded from active timeline, all users)"
    )
    ax.grid(True, alpha=0.2, axis="y")
    fig.tight_layout()
    fig.savefig(config.output_dir / "first_session_backlog.png", dpi=150)
    plt.close(fig)
    print("  Saved first_session_backlog.png")


# ---------------------------------------------------------------------------
# Plot: sessions → actions (uses datasets, not traces)
# ---------------------------------------------------------------------------


def plot_sessions_actions(config: Config) -> None:
    """Boxplot: total actions per session from the sessions dataset."""
    fig, ax = plt.subplots(figsize=(12, 6))
    data, labels = [], []

    for warmup in config.warmups:
        path = config.datasets_dir / f"warmup-{warmup:g}" / "sessions.parquet"
        if not path.exists():
            print(
                f"  [skip] {path} not found — skipping sessions_actions for warmup={warmup}"
            )
            data.append([])
            labels.append(str(warmup))
            continue

        df = pl.read_parquet(str(path))
        data.append(df["total_actions"].to_list())
        labels.append(str(warmup))

    bp = ax.boxplot(
        data,
        tick_labels=labels,
        patch_artist=True,
        showfliers=False,
        widths=0.6,
    )
    for patch, color in zip(bp["boxes"], _viridis_colors(len(config.warmups))):
        patch.set_facecolor(color)
        patch.set_alpha(0.7)

    ax.set_xlabel("Warmup time")
    ax.set_ylabel("Actions per session")
    ax.set_title("Total actions per session (all users, all runs)")
    ax.grid(True, alpha=0.2, axis="y")
    fig.tight_layout()
    fig.savefig(config.output_dir / "sessions_actions.png", dpi=150)
    plt.close(fig)
    print("  Saved sessions_actions.png")


# ---------------------------------------------------------------------------
# Plot: combined summary
# ---------------------------------------------------------------------------


def plot_combined_summary(all_data: dict, config: Config) -> None:
    """One summary plot: boredom + warmup attention + new post traction."""
    warmups = config.warmups
    colors = _viridis_colors(len(warmups))
    fig, axes = plt.subplots(1, 3, figsize=(22, 6))

    # 1. Boredom rate
    ax = axes[0]
    for idx, warmup in enumerate(warmups):
        parts = [
            all_data[warmup][run]["sessions"]
            .filter(pl.col("type") == "end_boredom")
            .select("time")
            for run in range(config.num_runs)
        ]
        all_times_df = pl.concat(parts) if parts else pl.DataFrame(schema={"time": pl.Float64})
        if all_times_df.is_empty():
            continue
        arr = (
            all_times_df.filter(
                (pl.col("time") >= warmup) & (pl.col("time") <= warmup + 5000)
            )
            .select((pl.col("time") - warmup).alias("rel"))
            .to_series()
            .to_numpy()
        )
        if len(arr) == 0:
            continue
        bins = np.logspace(np.log10(1), np.log10(5000), 60)
        counts, _ = np.histogram(arr, bins=bins)
        rate = counts / np.diff(bins) / config.num_runs
        centers = (bins[:-1] + bins[1:]) / 2
        ax.loglog(
            centers,
            rate,
            ".-",
            color=colors[idx],
            label=f"w={warmup:g}",
            linewidth=1.5,
            markersize=2,
        )
    ax.set_xlabel("Ticks after warmup")
    ax.set_ylabel("Boredom ends / tick / run")
    ax.set_title("Boredom rate (log-log)")
    ax.legend()
    ax.grid(True, alpha=0.2, which="both")

    # 2. Warmup attention decay
    ax = axes[1]
    for idx, warmup in enumerate(warmups):
        parts = []
        for run in range(config.num_runs):
            d = all_data[warmup][run]
            obs = _post_warmup_actions(d["actions"], d["creates"], warmup)
            parts.append(
                obs.select(
                    ((pl.col("time") - warmup) // 100).cast(pl.Int64).alias("bin"),
                    pl.col("is_warmup"),
                )
            )
        if not parts:
            continue
        all_binned = pl.concat(parts)
        agg = all_binned.group_by("bin").agg(
            pl.len().alias("total"),
            pl.col("is_warmup").sum().alias("wp"),
        ).sort("bin")

        max_bin = agg["bin"].max()
        full = pl.DataFrame({"bin": range(max_bin + 1)}).join(
            agg, on="bin", how="left"
        ).fill_null(0)
        xs = np.arange(0, max_bin + 1) * 100
        ys = [
            wp / total * 100 if total > 50 else np.nan
            for wp, total in zip(full["wp"].to_list(), full["total"].to_list())
        ]
        ax.plot(xs, ys, "-", color=colors[idx], label=f"w={warmup:g}", linewidth=1.5)
    ax.set_xlabel("Ticks after warmup")
    ax.set_ylabel("% actions on warmup posts")
    ax.set_title("Warmup attention decay")
    ax.legend()
    ax.grid(True, alpha=0.2)

    # 3. New post traction
    ax = axes[2]
    for idx, warmup in enumerate(warmups):
        imp_parts, np_parts = [], []
        for run in range(config.num_runs):
            d = all_data[warmup][run]
            actions, creates = d["actions"], d["creates"]
            obs = _post_warmup_actions(actions, creates, warmup)
            imp_parts.append(
                obs.filter(~pl.col("is_warmup"))
                .select(((pl.col("time") - warmup) // 100).cast(pl.Int64).alias("bin"))
            )
            np_parts.append(
                creates.filter(pl.col("time") >= warmup)
                .select(((pl.col("time") - warmup) // 100).cast(pl.Int64).alias("bin"))
            )
        if not imp_parts:
            continue

        imp_agg = (
            pl.concat(imp_parts).group_by("bin").len(name="impressions").sort("bin")
        )
        np_agg = (
            pl.concat(np_parts).group_by("bin").len(name="new_posts").sort("bin")
        )

        max_bin = max(
            imp_agg["bin"].max() if not imp_agg.is_empty() else 0,
            np_agg["bin"].max() if not np_agg.is_empty() else 0,
        )
        full_imp = pl.DataFrame({"bin": range(max_bin + 1)}).join(
            imp_agg, on="bin", how="left"
        ).fill_null(0)
        full_np = pl.DataFrame({"bin": range(max_bin + 1)}).join(
            np_agg, on="bin", how="left"
        ).fill_null(0)

        xs = np.arange(0, max_bin + 1) * 100
        ys = [
            imp / max(np_count, 1)
            for imp, np_count in zip(
                full_imp["impressions"].to_list(),
                full_np["new_posts"].to_list(),
            )
        ]
        ax.plot(xs, ys, "-", color=colors[idx], label=f"w={warmup:g}", linewidth=1.5)
    ax.set_xlabel("Ticks after warmup")
    ax.set_ylabel("Impressions per new post")
    ax.set_title("New post traction")
    ax.legend()
    ax.grid(True, alpha=0.2)

    fig.suptitle(
        "Warmup dynamics: boredom → warmup drain → new content takeoff",
        fontsize=14,
        fontweight="bold",
    )
    fig.tight_layout()
    fig.savefig(config.output_dir / "combined_summary.png", dpi=150)
    plt.close(fig)
    print("  Saved combined_summary.png")


if __name__ == "__main__":
    main()
