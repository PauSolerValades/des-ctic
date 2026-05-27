"""Per-user empty-exit rate stratified by indegree (follower count).

Joins out_sessions.parquet with network.bin indegree to answer:
Do users with zero followers starve more than well-connected users?
"""
import duckdb
import pandas as pd
import matplotlib.pyplot as plt
import numpy as np
from pathlib import Path

from trace_analysis.network import load_indegree

OUTPUT = Path(__file__).parent / "output"
DATA = Path(__file__).parent.parent / "output"
NETWORK_DATA = Path(__file__).parent.parent.parent / "release-v4" / "data"
SIZES = ["100K", "500K", "1M"]
NL = {"100K": "$10^5$", "500K": "$5\\times10^5$", "1M": "$10^6$"}

plt.rcParams.update({"font.size": 11, "figure.dpi": 150})


def main():
    print("=== Per-user empty-exit rate by indegree (follower count) ===\n")

    fig, axes = plt.subplots(1, 3, figsize=(15, 5))

    for ax, s in zip(axes, SIZES):
        indegree = load_indegree(NETWORK_DATA / s / "network.bin")

        r = duckdb.sql(f"""
            SELECT user_id,
                   AVG(CAST(empty_timeline_exit AS DOUBLE))*100 as pct_empty,
                   AVG(duration) as mean_dur,
                   SUM(n_actions) as total_actions,
                   COUNT(*) as n_sessions
            FROM '{DATA}/{s}/out_sessions.parquet'
            GROUP BY user_id
        """).df()

        r["indegree"] = r["user_id"].map(lambda uid: indegree.get(int(uid), 0))

        def bucket(d):
            if d == 0: return "zero"
            if d < 10: return "1-9"
            if d < 100: return "10-99"
            if d < 1000: return "100-999"
            return "1K+"
        r["deg_bucket"] = r["indegree"].map(bucket)

        order = ["zero", "1-9", "10-99", "100-999", "1K+"]
        agg = (
            r.groupby("deg_bucket")
            .agg(
                n=("user_id", "count"),
                mean_empty=("pct_empty", "mean"),
                std_empty=("pct_empty", "std"),
                med_empty=("pct_empty", "median"),
                mean_dur=("mean_dur", "mean"),
                total_act=("total_actions", "mean"),
            )
            .reindex(order)
            .reset_index()
        )

        print(f"--- {s} ---")
        print(f"  {'Bucket':<10} {'N users':>10} {'mean_empty%':>12} "
              f"{'std_empty%':>12} {'med_empty%':>12} {'mean_dur':>10}")
        for _, row in agg.iterrows():
            print(f"  {row['deg_bucket']:<10} {int(row['n']):>10,} "
                  f"{row['mean_empty']:>11.1f}% {row['std_empty']:>11.1f}% "
                  f"{row['med_empty']:>11.0f}% {row['mean_dur']:>9.0f}")

        zp = (r["indegree"] == 0).mean() * 100
        zm = r.loc[r["indegree"] == 0, "pct_empty"].mean()
        print(f"  Zero-degree users: {zp:.1f}% of all users, "
              f"mean pct_empty={zm:.1f}%")
        print()

        # Boxplot: pct_empty by degree bucket
        box_data = [r.loc[r["deg_bucket"] == b, "pct_empty"].values
                    for b in order]
        bp = ax.boxplot(box_data, tick_labels=order, patch_artist=True,
                        boxprops=dict(facecolor="steelblue", alpha=0.6),
                        medianprops=dict(color="black"),
                        flierprops=dict(markersize=2))
        ax.set_title(f"{NL[s]}")
        ax.set_xlabel("In-degree (followers)")
        ax.grid(True, alpha=0.3, axis="y")
        if ax == axes[0]:
            ax.set_ylabel("% sessions ending empty")

    fig.suptitle("Per-user empty-timeline exit rate by follower count")
    plt.tight_layout()
    fig.savefig(OUTPUT / "s2_empty_by_indegree.png", bbox_inches="tight")
    plt.close()
    print(f"Plot saved → {OUTPUT / 's2_empty_by_indegree.png'}")


if __name__ == "__main__":
    main()
