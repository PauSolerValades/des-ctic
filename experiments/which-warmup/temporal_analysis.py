#!/usr/bin/env python3
"""Temporal analysis: boredom, warmup attention decay, and new post traction.

Usage:
    python temporal_analysis.py --traces ../../traces/10K-warmup \\
                                --cascades ../../cascades/10K-warmup \\
                                --datasets ../../datasets/10K-warmup \\
                                -o output
"""

from __future__ import annotations

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
    plot_micro_comparison(all_data, config)

    print("\nDone.")


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------


def _load_run(config: Config, warmup: int, run: int) -> dict[str, pl.DataFrame]:
    """Load all trace files for a single run."""
    base = config.traces_dir / f"{warmup:g}-ticks" / str(run)
    SES_SCHEMA = {
        "time": pl.Float64,
        "event_id": pl.Int64,
        "gen_id": pl.Int64,
        "user_id": pl.Int64,
        "type": pl.String,
        "backlog": pl.Int64,
    }
    return {
        "actions": pl.read_ndjson(str(base) + "-action_trace.jsonl"),
        "creates": pl.read_ndjson(str(base) + "-create_trace.jsonl"),
        "sessions": pl.read_ndjson(
            str(base) + "-session_trace.jsonl", schema_overrides=SES_SCHEMA
        ),
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


def _make_post_time_map(creates: pl.DataFrame) -> dict:
    """Build a ``{post_id: creation_time}`` lookup from a creates dataframe."""
    return dict(zip(creates["post_id"].to_list(), creates["time"].to_list()))


def _add_is_warmup_col(
    actions: pl.DataFrame, creates: pl.DataFrame, warmup: int
) -> pl.DataFrame:
    """Filter actions to post-warmup and add an ``is_warmup`` boolean column."""
    post_times = _make_post_time_map(creates)
    obs = actions.filter(pl.col("time") >= warmup)
    return obs.with_columns(
        pl.col("post_id")
        .map_elements(
            lambda pid: post_times.get(pid, 99999) < warmup,
            return_dtype=pl.Boolean,
        )
        .alias("is_warmup")
    )


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
    axes_flat = axes.flatten() if n_warmups > 1 else [axes]
    colors = _viridis_colors(n_warmups)

    for idx, warmup in enumerate(warmups):
        ax = axes_flat[idx]
        all_times: list[float] = []

        for run in range(config.num_runs):
            sessions = all_data[warmup][run]["sessions"]
            bored = sessions.filter(pl.col("type") == "end_boredom")
            all_times.extend(bored["time"].to_list())

        if not all_times:
            continue

        arr = np.array(all_times)
        obs_end = warmup + 5000
        arr = arr[(arr >= warmup) & (arr <= obs_end)]
        rel_time = arr - warmup

        bins = np.logspace(np.log10(1), np.log10(5100), 50)
        counts, _ = np.histogram(rel_time, bins=bins)
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
    axes_flat = axes.flatten() if n_warmups > 1 else [axes]
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

        bin_wp: dict[int, int] = {}
        bin_total: dict[int, int] = {}

        for run in range(config.num_runs):
            d = all_data[warmup][run]
            obs = _add_is_warmup_col(d["actions"], d["creates"], warmup)
            for row in obs.iter_rows():
                t = row[0]  # time
                is_wp = row[-1]  # is_warmup
                bin_idx = int((t - warmup) // bin_size)
                bin_total[bin_idx] = bin_total.get(bin_idx, 0) + 1
                if is_wp:
                    bin_wp[bin_idx] = bin_wp.get(bin_idx, 0) + 1

        max_bin = max(bin_total.keys()) if bin_total else 0
        xs = np.arange(0, max_bin + 1) * bin_size
        ys = [
            bin_wp.get(b, 0) / bin_total.get(b, 1) * 100
            if bin_total.get(b, 0) > 10
            else np.nan
            for b in range(max_bin + 1)
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
    axes_flat = axes.flatten() if n_warmups > 1 else [axes]
    colors = _viridis_colors(n_warmups)
    bin_size = config.bin_size

    for idx, warmup in enumerate(warmups):
        ax = axes_flat[idx]
        bin_impressions: dict[int, int] = {}
        bin_new_posts: dict[int, int] = {}

        for run in range(config.num_runs):
            d = all_data[warmup][run]
            actions, creates = d["actions"], d["creates"]
            obs = _add_is_warmup_col(actions, creates, warmup)
            new_actions = obs.filter(~pl.col("is_warmup"))

            for row in new_actions.iter_rows():
                t = row[0]
                bin_idx = int((t - warmup) // bin_size)
                bin_impressions[bin_idx] = bin_impressions.get(bin_idx, 0) + 1

            new_creates = creates.filter(pl.col("time") >= warmup)
            for row in new_creates.iter_rows():
                t = row[0]
                bin_idx = int((t - warmup) // bin_size)
                bin_new_posts[bin_idx] = bin_new_posts.get(bin_idx, 0) + 1

        max_bin = max(
            list(bin_impressions.keys()) + list(bin_new_posts.keys()), default=0
        )
        xs = np.arange(0, max_bin + 1) * bin_size
        ys = [
            (bin_impressions.get(b, 0) / config.num_runs)
            / max(bin_new_posts.get(b, 0) / config.num_runs, 1)
            if bin_new_posts.get(b, 0) > 0
            else np.nan
            for b in range(max_bin + 1)
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
# Plot: micro comparison (warmup 1–5)
# ---------------------------------------------------------------------------


def plot_micro_comparison(all_data: dict, config: Config) -> None:
    """Focused comparison: warmup values 1–5 only."""
    selected = [w for w in config.warmups if 1 <= w <= 5]
    if not selected:
        print("  [skip] micro_comparison — no warmup values in 1..5 range")
        return

    colors = {1: "#2E86AB", 2: "#A23B72", 3: "#F18F01", 4: "#C73E1D", 5: "#3CAEA3"}
    fig, axes = plt.subplots(1, 3, figsize=(22, 6))

    # 1. Boredom rate (log-log)
    ax = axes[0]
    for warmup in selected:
        all_times: list[float] = []
        for run in range(config.num_runs):
            sessions = all_data[warmup][run]["sessions"]
            bored = sessions.filter(pl.col("type") == "end_boredom")
            all_times.extend(bored["time"].to_list())
        arr = np.array(all_times)
        arr = arr[(arr >= warmup) & (arr <= warmup + 5000)]
        rel_time = arr - warmup
        bins = np.logspace(np.log10(1), np.log10(5000), 60)
        counts, _ = np.histogram(rel_time, bins=bins)
        rate = counts / np.diff(bins) / config.num_runs
        centers = (bins[:-1] + bins[1:]) / 2
        ax.loglog(
            centers,
            rate,
            ".-",
            color=colors[warmup],
            label=f"w={warmup}",
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
    for warmup in selected:
        bin_wp: dict[int, int] = {}
        bin_total: dict[int, int] = {}
        for run in range(config.num_runs):
            d = all_data[warmup][run]
            obs = _add_is_warmup_col(d["actions"], d["creates"], warmup)
            for row in obs.iter_rows():
                t, is_wp = row[0], row[-1]
                b = int((t - warmup) // 100)
                bin_total[b] = bin_total.get(b, 0) + 1
                if is_wp:
                    bin_wp[b] = bin_wp.get(b, 0) + 1
        max_bin = max(bin_total.keys())
        xs = np.arange(0, max_bin + 1) * 100
        ys = [
            bin_wp.get(b, 0) / bin_total.get(b, 1) * 100
            if bin_total.get(b, 0) > 50
            else np.nan
            for b in range(max_bin + 1)
        ]
        ax.plot(xs, ys, "-", color=colors[warmup], label=f"w={warmup}", linewidth=1.5)
    ax.set_xlabel("Ticks after warmup")
    ax.set_ylabel("% actions on warmup posts")
    ax.set_title("Warmup attention decay")
    ax.legend()
    ax.grid(True, alpha=0.2)

    # 3. New post traction
    ax = axes[2]
    for warmup in selected:
        bin_imp: dict[int, int] = {}
        bin_np: dict[int, int] = {}
        for run in range(config.num_runs):
            d = all_data[warmup][run]
            actions, creates = d["actions"], d["creates"]
            obs = _add_is_warmup_col(actions, creates, warmup)
            for row in obs.filter(~pl.col("is_warmup")).iter_rows():
                b = int((row[0] - warmup) // 100)
                bin_imp[b] = bin_imp.get(b, 0) + 1
            for row in creates.filter(pl.col("time") >= warmup).iter_rows():
                b = int((row[0] - warmup) // 100)
                bin_np[b] = bin_np.get(b, 0) + 1
        max_bin = max(list(bin_imp.keys()) + list(bin_np.keys()))
        xs = np.arange(0, max_bin + 1) * 100
        ys = [bin_imp.get(b, 0) / max(bin_np.get(b, 0), 1) for b in range(max_bin + 1)]
        ax.plot(xs, ys, "-", color=colors[warmup], label=f"w={warmup}", linewidth=1.5)
    ax.set_xlabel("Ticks after warmup")
    ax.set_ylabel("Impressions per new post")
    ax.set_title("New post traction")
    ax.legend()
    ax.grid(True, alpha=0.2)

    fig.suptitle("Micro-comparison: warmup 1–5", fontsize=14, fontweight="bold")
    fig.tight_layout()
    fig.savefig(config.output_dir / "micro_comparison.png", dpi=150)
    plt.close(fig)
    print("  Saved micro_comparison.png")


# ---------------------------------------------------------------------------
# Plot: combined summary
# ---------------------------------------------------------------------------


def plot_combined_summary(all_data: dict, config: Config) -> None:
    """One summary plot: boredom + warmup attention + new post traction."""
    selected = [w for w in config.warmups if w in (5, 25, 100, 1000)]
    if not selected:
        print("  [skip] combined_summary — no matching warmup values")
        return

    colors = {5: "#2E86AB", 25: "#A23B72", 100: "#F18F01", 1000: "#C73E1D"}
    fig, axes = plt.subplots(1, 3, figsize=(22, 6))

    # 1. Boredom rate
    ax = axes[0]
    for warmup in selected:
        all_times: list[float] = []
        for run in range(config.num_runs):
            sessions = all_data[warmup][run]["sessions"]
            bored = sessions.filter(pl.col("type") == "end_boredom")
            all_times.extend(bored["time"].to_list())
        arr = np.array(all_times)
        arr = arr[(arr >= warmup) & (arr <= warmup + 5000)]
        rel_time = arr - warmup
        bins = np.logspace(np.log10(1), np.log10(5000), 60)
        counts, _ = np.histogram(rel_time, bins=bins)
        rate = counts / np.diff(bins) / config.num_runs
        centers = (bins[:-1] + bins[1:]) / 2
        ax.loglog(
            centers,
            rate,
            ".-",
            color=colors[warmup],
            label=f"w={warmup}",
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
    for warmup in selected:
        bin_wp: dict[int, int] = {}
        bin_total: dict[int, int] = {}
        for run in range(config.num_runs):
            d = all_data[warmup][run]
            obs = _add_is_warmup_col(d["actions"], d["creates"], warmup)
            for row in obs.iter_rows():
                t, is_wp = row[0], row[-1]
                b = int((t - warmup) // 100)
                bin_total[b] = bin_total.get(b, 0) + 1
                if is_wp:
                    bin_wp[b] = bin_wp.get(b, 0) + 1
        max_bin = max(bin_total.keys())
        xs = np.arange(0, max_bin + 1) * 100
        ys = [
            bin_wp.get(b, 0) / bin_total.get(b, 1) * 100
            if bin_total.get(b, 0) > 50
            else np.nan
            for b in range(max_bin + 1)
        ]
        ax.plot(xs, ys, "-", color=colors[warmup], label=f"w={warmup}", linewidth=1.5)
    ax.set_xlabel("Ticks after warmup")
    ax.set_ylabel("% actions on warmup posts")
    ax.set_title("Warmup attention decay")
    ax.legend()
    ax.grid(True, alpha=0.2)

    # 3. New post traction
    ax = axes[2]
    for warmup in selected:
        bin_imp: dict[int, int] = {}
        bin_np: dict[int, int] = {}
        for run in range(config.num_runs):
            d = all_data[warmup][run]
            actions, creates = d["actions"], d["creates"]
            obs = _add_is_warmup_col(actions, creates, warmup)
            for row in obs.filter(~pl.col("is_warmup")).iter_rows():
                b = int((row[0] - warmup) // 100)
                bin_imp[b] = bin_imp.get(b, 0) + 1
            for row in creates.filter(pl.col("time") >= warmup).iter_rows():
                b = int((row[0] - warmup) // 100)
                bin_np[b] = bin_np.get(b, 0) + 1
        max_bin = max(list(bin_imp.keys()) + list(bin_np.keys()))
        xs = np.arange(0, max_bin + 1) * 100
        ys = [bin_imp.get(b, 0) / max(bin_np.get(b, 0), 1) for b in range(max_bin + 1)]
        ax.plot(xs, ys, "-", color=colors[warmup], label=f"w={warmup}", linewidth=1.5)
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
