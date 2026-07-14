#!/usr/bin/env python3
"""Compute O(n) time complexity from all available benchmark runs.

Reads execution_times.ssv from traces/{size}_bskysim_trace/ for all sizes
that have data, computes per-size mean ± CI95, and plots with linear fit.

Usage:
    uv run --with matplotlib,numpy compute_complexity.py
"""

import numpy as np
import matplotlib.pyplot as plt
from pathlib import Path

HERE = Path(__file__).parent
ROOT = HERE.parent
TRACES = ROOT / "traces"
OUTPUT = HERE / "figures"
OUTPUT.mkdir(exist_ok=True)

SIZES = ["10K", "50K", "100K", "250K", "500K", "750K", "1M"]
SIZE_VALUES = {
    "10K": 10_000, "50K": 50_000, "100K": 100_000,
    "250K": 250_000, "500K": 500_000, "750K": 750_000, "1M": 1_000_000,
}
LABELS = {
    "10K": "$10^4$", "50K": "$5\\times10^4$", "100K": "$10^5$",
    "250K": "$2.5\\times10^5$", "500K": "$5\\times10^5$",
    "750K": "$7.5\\times10^5$", "1M": "$10^6$",
}

plt.rcParams.update({"font.size": 12, "figure.dpi": 150})


def load_times(path: Path) -> np.ndarray:
    """Load time_ms column from an .ssv file, skipping header."""
    times = []
    with open(path) as f:
        next(f)
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split()
            times.append(float(parts[2]))
    return np.array(times)


def main():
    means = {}
    cis = {}
    counts = {}

    print(f"{'Size':<8} {'N runs':>7} {'Mean (ms)':>12} {'±CI95':>10} "
          f"{'Per-user':>10} {'Min':>10} {'Max':>10}")
    print("-" * 75)

    for s in SIZES:
        path = TRACES / f"{s}_bskysim_trace" / "execution_times.ssv"
        if not path.exists():
            print(f"{s:<8} {'—':>7} {'(no data)':>12}")
            continue

        ts = load_times(path)
        if len(ts) == 0:
            print(f"{s:<8} {'0':>7} {'(empty)':>12}")
            continue

        mu = ts.mean()
        n = len(ts)
        ci = 1.96 * ts.std(ddof=1) / np.sqrt(n) if n > 1 else 0
        means[s] = mu
        cis[s] = ci
        counts[s] = n

        per_user = mu / SIZE_VALUES[s] * 1000  # μs/user
        print(f"{s:<8} {n:>7} {mu:>12.0f} {ci:>10.0f} "
              f"{per_user:>9.1f}μs {ts.min():>10.0f} {ts.max():>10.0f}")

    if len(means) < 2:
        print("\nNeed at least 2 sizes for a fit.")
        return

    print()
    sizes_present = [s for s in SIZES if s in means]
    xs = np.array([SIZE_VALUES[s] for s in sizes_present])
    ys = np.array([means[s] for s in sizes_present])

    # O(n) fit: time = a * n
    a = np.sum(xs * ys) / np.sum(xs ** 2)
    y_pred = a * xs
    ss_res = np.sum((ys - y_pred) ** 2)
    ss_tot = np.sum((ys - ys.mean()) ** 2)
    r2 = 1 - ss_res / ss_tot

    print(f"O(n) fit:  time = {a:.2f} ms/user · n  = {a*1000:.1f} μs/user")
    print(f"R² = {r2:.4f}")
    print()

    for s in sizes_present:
        ratio = means[s] / SIZE_VALUES[s] * 1000
        print(f"  {s:<8} {ratio:8.1f} μs/user  (n={counts[s]})")

    # ---- Plot ----
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13, 5))

    # Left: absolute times with O(n) fit
    fit_x = np.linspace(0, xs[-1] * 1.1, 100)
    fit_y = a * fit_x

    yerr = [cis[s] for s in sizes_present]
    ax1.errorbar(xs, ys, yerr=yerr, fmt="o", capsize=6, capthick=1.5, ms=10,
                 color="steelblue", zorder=5)
    ax1.plot(fit_x, fit_y, "--", color="crimson", lw=1.5,
             label=f"O(n): {a*1000:.0f} μs/user\n$R^2$ = {r2:.3f}")
    for s in sizes_present:
        ax1.annotate(s, (SIZE_VALUES[s], means[s]),
                     textcoords="offset points", xytext=(0, 14),
                     ha="center", fontsize=10, fontweight="bold")
    ax1.set_xlabel("Network size (n)")
    ax1.set_ylabel("Mean execution time (ms)")
    ax1.legend(fontsize=10)
    ax1.grid(True, alpha=0.3)
    ax1.set_title("Execution time vs network size")

    # Right: per-user time (μs/user) — should be constant if O(n)
    per_user = ys / xs * 1000
    per_user_ci = np.array([cis[s] / SIZE_VALUES[s] * 1000 for s in sizes_present])

    ax2.errorbar(xs, per_user, yerr=per_user_ci, fmt="s", capsize=6,
                 capthick=1.5, ms=10, color="darkorange", zorder=5)
    ax2.axhline(np.mean(per_user), color="crimson", ls="--", lw=1.5,
                label=f"mean = {np.mean(per_user):.1f} μs/user")
    for i, s in enumerate(sizes_present):
        ax2.annotate(s, (SIZE_VALUES[s], per_user[i]),
                     textcoords="offset points", xytext=(0, 14),
                     ha="center", fontsize=10, fontweight="bold")
    ax2.set_xlabel("Network size (n)")
    ax2.set_ylabel("Time per user (μs/user)")
    ax2.legend(fontsize=10)
    ax2.grid(True, alpha=0.3)
    ax2.set_title("Per-user cost (constant ≈ O(n))")

    fig.suptitle("O(n) time complexity — BskySim (ReleaseFast, tracing)",
                 fontsize=13, fontweight="bold")
    fig.tight_layout()
    out_path = OUTPUT / "complexity_on.png"
    fig.savefig(out_path, bbox_inches="tight")
    plt.close(fig)
    print(f"\nPlot saved: {out_path}")


if __name__ == "__main__":
    main()
