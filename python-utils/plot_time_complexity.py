#!/usr/bin/env python3
"""Time scalability (big-O) of BskySim across dataset sizes.

Reads execution_times.ssv from steps/final/traces/{size}/ for every available
size, fits candidate complexity models, and saves a single log-log plot.

Usage:
    uv run --with matplotlib,numpy,seaborn plot_time_complexity.py
"""

import shutil
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import seaborn as sns

HERE = Path(__file__).parent
ROOT = HERE.parent
TRACES = ROOT / "steps" / "final" / "traces"
OUTPUT = HERE / "figures"
OUTPUT.mkdir(exist_ok=True)

SIZES = ["10K", "100K", "500K", "1M"]
N = {"10K": 1e4, "100K": 1e5, "500K": 5e5, "1M": 1e6}

# Thesis styling (firehose-analysis/AGENTS.md): whitegrid, LaTeX, 11pt base.
sns.set_theme(style="whitegrid")
plt.rcParams.update({
    # LaTeX only when available; falls back to mathtext on machines without it.
    "text.usetex": shutil.which("latex") is not None,
    "axes.labelsize": 11,
    "font.size": 11,
    "legend.fontsize": 11,
    "xtick.labelsize": 10,
    "ytick.labelsize": 10,
})


def load_times(path: Path) -> np.ndarray:
    """Load the time_ms column from an .ssv file (header: batch run time_ms)."""
    with open(path) as f:
        next(f)
        return np.array([float(line.split()[2]) for line in f if line.strip()])


def basis(name: str, x: np.ndarray) -> np.ndarray:
    return {"O(n)": x, "O(n log n)": x * np.log(x), "O(n^2)": x ** 2}[name]


def main() -> None:
    data = {
        s: load_times(TRACES / s / "execution_times.ssv")
        for s in SIZES
        if (TRACES / s / "execution_times.ssv").exists()
    }
    sizes = [s for s in SIZES if s in data]
    if len(sizes) < 2:
        raise SystemExit(f"Need at least 2 sizes; found only {sizes}")

    n = np.array([N[s] for s in sizes])
    mean = np.array([data[s].mean() for s in sizes])

    # Through-origin candidate models t = a * f(n); pick the best by R².
    ss_tot = np.sum((mean - mean.mean()) ** 2)
    best = None
    for name in ("O(n)", "O(n log n)", "O(n^2)"):
        base = basis(name, n)
        a = np.sum(mean * base) / np.sum(base ** 2)
        r2 = 1 - np.sum((mean - a * base) ** 2) / ss_tot
        print(f"{name:<11} a={a:.4g}  R2={r2:.4f}")
        if best is None or r2 > best[1]:
            best = (name, a, r2)

    name, a, r2 = best
    p, logc = np.polyfit(np.log(n), np.log(mean), 1)
    print(f"\nBest model: {name} (R2={r2:.4f})  ->  time = {a:.4g} * {name.lstrip('O(').rstrip(')')} ms")
    print(f"Free power-law exponent: p = {p:.3f}")

    print(f"\n{'Size':<6} {'n runs':>7} {'Mean (ms)':>12} {'Median (ms)':>12}")
    print("-" * 42)
    for s in sizes:
        ts = data[s]
        print(f"{s:<6} {len(ts):>7} {ts.mean():>12.0f} {np.median(ts):>12.0f}")

    # ---- Plot (one figure, one png) ----
    palette = sns.color_palette("colorblind", len(sizes))
    fig, ax = plt.subplots(figsize=(7, 5))

    for s, color in zip(sizes, palette):
        ts = data[s]
        ci = 1.96 * ts.std(ddof=1) / np.sqrt(len(ts))
        ax.scatter([N[s]] * len(ts), ts, s=16, alpha=0.3,
                   color=color, linewidths=0)
        ax.errorbar([N[s]], [ts.mean()], yerr=[ci], fmt="o", ms=7,
                    color=color, capsize=4, capthick=1.2, zorder=5)
        ax.annotate(s, (N[s], ts.mean()), textcoords="offset points",
                    xytext=(0, 9), ha="center", fontsize=10,
                    fontweight="bold", color=color)

    n_fit = np.geomspace(n.min(), n.max(), 100)
    ax.plot(n_fit, a * basis(name, n_fit), "--", color="0.2", lw=1.5,
            label=f"{name}  ($R^2={r2:.3f}$)")

    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel("Network size $n$")
    ax.set_ylabel("Execution time (ms)")
    ax.set_title("BskySim time scalability per dataset")
    ax.legend()

    fig.tight_layout()
    out_path = OUTPUT / "time_scalability.png"
    fig.savefig(out_path, bbox_inches="tight", dpi=150)
    plt.close(fig)
    print(f"\nPlot saved: {out_path}")


if __name__ == "__main__":
    main()
