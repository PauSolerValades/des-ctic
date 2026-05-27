"""Log-log CCDF of struct_virality — straight line = exponential/power-law tail."""
import duckdb
import matplotlib.pyplot as plt
import numpy as np
from pathlib import Path

OUTPUT = Path(__file__).parent / "output"
DATA = Path(__file__).parent.parent / "output"
SIZES = ["100K", "500K", "1M"]
NL = {"100K": "$10^5$", "500K": "$5\\times10^5$", "1M": "$10^6$"}

plt.rcParams.update({"font.size": 11, "figure.dpi": 150})

def ccdf(vals):
    s = np.sort(vals)
    return s, 1.0 - np.arange(len(s)) / len(s)

fig, axes = plt.subplots(1, 3, figsize=(15, 5))
for ax, s in zip(axes, SIZES):
    v = duckdb.sql(f"""
        SELECT struct_virality FROM '{DATA}/{s}/out_cascades.parquet'
        WHERE struct_virality > 1.34
    """).df()["struct_virality"].values
    
    x, y = ccdf(v)
    ax.loglog(x, y, ".", markersize=1.5, alpha=0.5, color="darkviolet")
    
    # Fit power-law tail (top 20%)
    tail = x >= np.percentile(x, 80)
    if tail.sum() > 5:
        a, b = np.polyfit(np.log10(x[tail]), np.log10(y[tail]), 1)
        ax.loglog(x[tail], 10**(a * np.log10(x[tail]) + b), "r--", lw=1.5)
        ax.text(0.95, 0.15, f"α≈{-a:.1f}", transform=ax.transAxes,
                ha="right", fontsize=9, color="red")
    
    ax.set_title(f"{NL[s]} (n={len(v):,})")
    ax.set_xlabel("struct_virality ν")
    ax.grid(True, alpha=0.3, which="both")
axes[0].set_ylabel("P(ν ≥ x)")
fig.suptitle("CCDF of structural virality (log-log, excluding minimal ν ≤ 1.34)")
plt.tight_layout()
fig.savefig(OUTPUT / "s4_virality_ccdf.png", bbox_inches="tight")
plt.close()
print(f"Done → s4_virality_ccdf.png")
