#!/usr/bin/env python3
"""Mean ± CI95 + Q1–Q3 per network size."""
import numpy as np
import matplotlib.pyplot as plt
from pathlib import Path

HERE = Path(__file__).parent
ROOT = HERE.parent
TRACES = ROOT / "traces"
OUTPUT = HERE / "figures"
OUTPUT.mkdir(exist_ok=True)

SIZES = ["10K", "50K", "100K", "250K", "500K", "750K"]
SIZE_VALS = [10_000, 50_000, 100_000, 250_000, 500_000, 750_000]

plt.rcParams.update({"font.size": 13, "figure.dpi": 150})

fig, ax = plt.subplots(figsize=(9, 5))

means, cis, q1s, q3s = [], [], [], []

for s in SIZES:
    path = TRACES / f"{s}_bskysim_trace" / "execution_times.ssv"
    if not path.exists():
        continue
    ts = np.loadtxt(path, skiprows=1, usecols=2) / 1000
    mu = ts.mean()
    ci = 1.96 * ts.std(ddof=1) / np.sqrt(len(ts))
    q1, q3 = np.percentile(ts, [25, 75])
    print(f"{s}: n={len(ts)}  mean={mu:.1f}s  CI95=±{ci:.2f}s  Q1={q1:.1f}s  Q3={q3:.1f}s")
    means.append(mu); cis.append(ci); q1s.append(q1); q3s.append(q3)

means = np.array(means); cis = np.array(cis)
q1s = np.array(q1s); q3s = np.array(q3s); xs = np.array(SIZE_VALS[:len(means)])

# Q1–Q3 bars
ax.vlines(xs, q1s, q3s, colors="gray", lw=4, alpha=0.4, zorder=2, label="Q1–Q3")

# CI95 error bars (no dot)
ax.errorbar(xs, means, yerr=cis, fmt="none", ecolor="steelblue",
            capsize=5, capthick=2, lw=1.5, zorder=4, label="mean ± CI95")

# X-axis tick labels
ax.set_xticks(xs)
ax.set_xticklabels(SIZES)

ax.set_xlabel("Network size")
ax.set_ylabel("Execution time (s)")
ax.legend(fontsize=10, loc="upper left")
ax.grid(True, alpha=0.3)
ax.set_title("BskySim execution time per run (ReleaseFast, tracing)")
fig.tight_layout()
fig.savefig(OUTPUT / "timing_scatter.png", bbox_inches="tight")
plt.close(fig)
print(f"\nSaved: {OUTPUT / 'timing_scatter.png'}")
