#!/usr/bin/env python3
"""
Structural Virality — Exploratory Distribution
==============================================
First look at the SV distribution shape across all non-zero cascades.
No pre-binning of cascade size — just the raw distribution.

Plots:
  1. Histogram (linear scale)
  2. Log-log frequency plot (to check for power-law behavior)
  3. Rank-frequency plot (Zipf-style, sorted descending)
"""

import argparse
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import polars as pl

OUT_DIR = Path("output/sv_distribution")


def load_data(data_dir: str) -> pl.DataFrame:
    path = Path(data_dir).resolve() / "cascades.parquet"
    print(f"Loading {path} ...")
    df = pl.read_parquet(str(path))
    print(f"  {df.height:,} total cascades")
    return df


def plot_density(sv_values: list[float], out_dir: Path) -> None:
    """Histogram + smoothed density via KDE."""
    fig, axes = plt.subplots(1, 2, figsize=(14, 5))

    # Left: histogram with sensible bins
    ax = axes[0]
    ax.hist(sv_values, bins=80, color="#2E86AB", edgecolor="white",
            alpha=0.85, density=True)
    ax.set_xlabel("Structural Virality")
    ax.set_ylabel("Density")
    ax.set_title(f"SV density  (n={len(sv_values):,})")
    ax.axvline(x=1.0, color="crimson", linestyle="--", alpha=0.6, label="SV=1.0 (star)")
    ax.legend()

    # Right: zoom on SV >= 1.0
    sv_high = [v for v in sv_values if v >= 1.0]
    ax = axes[1]
    ax.hist(sv_high, bins=60, color="#A23B72", edgecolor="white",
            alpha=0.85, density=True)
    ax.set_xlabel("Structural Virality")
    ax.set_ylabel("Density")
    ax.set_title(f"SV ≥ 1.0  (n={len(sv_high):,})")

    fig.tight_layout()
    fig.savefig(out_dir / "sv_density.png", dpi=150)
    plt.close(fig)
    print(f"  Saved sv_density.png")


def plot_log_log(sv_values: list[float], out_dir: Path) -> None:
    """Log-log histogram: power-laws show as straight lines."""
    fig, ax = plt.subplots(figsize=(8, 6))

    # Bin in log space, count, then plot log(count) vs log(bin_center)
    counts, bin_edges = np.histogram(sv_values, bins=100)
    bin_centers = (bin_edges[:-1] + bin_edges[1:]) / 2

    # Drop empty bins
    mask = counts > 0
    x = bin_centers[mask]
    y = counts[mask]

    ax.loglog(x, y, "o", color="#2E86AB", markersize=3, alpha=0.6)
    ax.set_xlabel("Structural Virality (log scale)")
    ax.set_ylabel("Frequency (log scale)")
    ax.set_title(f"Log-log SV frequency  (n={len(sv_values):,})")
    ax.grid(True, alpha=0.3, which="both")

    # Fit a power-law slope for reference (linear fit in log-log)
    if len(x) > 2:
        logx = np.log10(x)
        logy = np.log10(y)
        slope, intercept = np.polyfit(logx, logy, 1)
        ax.loglog(x, 10**intercept * x**slope, "--", color="crimson",
                  linewidth=2, label=f"power-law fit (α ≈ {-slope:.2f})")
        ax.legend()

    fig.tight_layout()
    fig.savefig(out_dir / "sv_loglog.png", dpi=150)
    plt.close(fig)
    print(f"  Saved sv_loglog.png")


def plot_rank_frequency(sv_values: list[float], out_dir: Path) -> None:
    """Zipf-style: sort SV descending, plot vs rank.
       A power-law appears as a straight line on log-log."""
    fig, axes = plt.subplots(1, 2, figsize=(14, 5))

    n = len(sv_values)
    sorted_sv = sorted(sv_values, reverse=True)
    ranks = np.arange(1, n + 1)

    # Linear scale
    ax = axes[0]
    ax.plot(ranks, sorted_sv, linewidth=0.5, color="#2E86AB")
    ax.set_xlabel("Rank")
    ax.set_ylabel("Structural Virality")
    ax.set_title("SV rank-frequency (linear)")

    # Log-log scale
    ax = axes[1]
    ax.loglog(ranks, sorted_sv, linewidth=0.5, color="#A23B72")
    ax.set_xlabel("Rank (log scale)")
    ax.set_ylabel("Structural Virality (log scale)")
    ax.set_title("SV rank-frequency (log-log)")
    ax.grid(True, alpha=0.3, which="both")

    fig.tight_layout()
    fig.savefig(out_dir / "sv_rank_frequency.png", dpi=150)
    plt.close(fig)
    print(f"  Saved sv_rank_frequency.png")


def print_summary(sv_values: list[float]) -> None:
    arr = np.array(sv_values)
    print("\n═══ SV summary (non-zero) ═══")
    print(f"  N      : {len(arr):,}")
    print(f"  Mean   : {arr.mean():.4f}")
    print(f"  Median : {np.median(arr):.4f}")
    print(f"  Std    : {arr.std():.4f}")
    print(f"  Min    : {arr.min():.4f}")
    print(f"  Max    : {arr.max():.4f}")
    print(f"  Q1     : {np.percentile(arr, 25):.4f}")
    print(f"  Q3     : {np.percentile(arr, 75):.4f}")
    print(f"\n  Unique values: {len(set(arr)):,}")

    # How many are exactly 1.0?
    n_star = sum(1 for v in sv_values if v == 1.0)
    print(f"  SV = 1.0 (star): {n_star:,}  ({n_star/len(arr)*100:.1f}%)")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--data-dir", type=str, default="../../dataset-creation/data",
        help="Path to directory containing cascades.parquet"
    )
    args = parser.parse_args()

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    df = load_data(args.data_dir)

    total = df.height
    n_zero = df.filter(pl.col("StructuralVirality") == 0).height
    non_zero = df.filter(pl.col("StructuralVirality") > 0)
    n_non_zero = non_zero.height
    print(f"  SV = 0 : {n_zero:,}  ({n_zero/total*100:.1f}%)")
    print(f"  SV > 0 : {n_non_zero:,}  ({n_non_zero/total*100:.1f}%)")

    if n_non_zero == 0:
        print("No non-zero SV values to analyze.")
        return

    sv_values = non_zero["StructuralVirality"].to_list()

    print_summary(sv_values)
    plot_density(sv_values, OUT_DIR)
    plot_log_log(sv_values, OUT_DIR)
    plot_rank_frequency(sv_values, OUT_DIR)

    print(f"\nDone! Output in {OUT_DIR}/")


if __name__ == "__main__":
    main()
