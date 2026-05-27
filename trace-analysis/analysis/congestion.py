"""Section 2: Queued Content Congestion — Session & per-user analysis.

All aggregation uses DuckDB (faster than Polars for 355M-row tables).
Per-user metrics sampled from first run of each size.
"""
import duckdb
import matplotlib.pyplot as plt
import numpy as np
import polars as pl
from pathlib import Path

OUTPUT = Path(__file__).parent / "output"
OUTPUT.mkdir(exist_ok=True)
DATA = Path(__file__).parent.parent / "output"
SIZES = ["100K", "500K", "1M"]
NL = {"100K": "$10^5$", "500K": "$5\\times10^5$", "1M": "$10^6$"}

plt.rcParams.update({"font.size": 11, "figure.dpi": 150})


# ── Helpers ────────────────────────────────────────────────────────────
def _per_run_agg(size):
    """Return DataFrame with one row per run: mean_dur, med_dur, mean_actions, pct_empty."""
    return duckdb.sql(f"""
        SELECT sim_id,
               AVG(duration) as mean_dur, MEDIAN(duration) as med_dur,
               AVG(n_actions) as mean_actions,
               AVG(CAST(empty_timeline_exit AS DOUBLE))*100 as pct_empty,
               AVG(backlog_at_end) as mean_backlog,
               MEDIAN(backlog_at_end) as med_backlog
        FROM '{DATA}/{size}/out_sessions.parquet'
        GROUP BY sim_id
        ORDER BY sim_id
    """).df()

def _per_user_agg(size):
    """Per-user aggregation on first run only (fast, representative)."""
    first_run = duckdb.sql(f"""
        SELECT sim_id FROM '{DATA}/{size}/out_sessions.parquet'
        GROUP BY sim_id ORDER BY sim_id LIMIT 1
    """).df()["sim_id"][0]
    return duckdb.sql(f"""
        SELECT user_id,
               COUNT(*) as n_sessions,
               SUM(duration) as total_online_time,
               AVG(duration) as mean_session_duration,
               MEDIAN(duration) as median_session_duration,
               AVG(CAST(empty_timeline_exit AS DOUBLE))*100 as pct_empty_exit,
               SUM(n_actions) as total_actions,
               SUM(n_reposts) as total_reposts,
               SUM(n_posts_created) as total_posts_created
        FROM '{DATA}/{size}/out_sessions.parquet'
        WHERE sim_id = '{first_run}'
        GROUP BY user_id
    """).df(), first_run


# ── 2.1 Timeline Starvation ────────────────────────────────────────────
def table_starvation():
    print("\n─── 2.1 Timeline Starvation ───")
    print(f"  {'Size':<8} {'%empty_exit':>12} {'%zero_actions':>14} "
          f"{'med_backlog':>14} {'mean_actions':>14} {'med_actions':>12}")
    for s in SIZES:
        r = duckdb.sql(f"""
            SELECT AVG(CAST(empty_timeline_exit AS DOUBLE))*100 as pct_empty,
                   AVG(CASE WHEN n_actions=0 THEN 1.0 ELSE 0.0 END)*100 as pct_zero,
                   MEDIAN(backlog_at_end) as med_bl,
                   AVG(n_actions) as mean_act,
                   MEDIAN(n_actions) as med_act
            FROM '{DATA}/{s}/out_sessions.parquet'
        """).df().iloc[0]
        print(f"  {s:<8} {r['pct_empty']:>11.1f}% {r['pct_zero']:>13.1f}% "
              f"{r['med_bl']:>13.0f} {r['mean_act']:>13.1f} {r['med_act']:>11.0f}")


def plot_backlog_histogram():
    fig, axes = plt.subplots(1, 3, figsize=(15, 4), sharey=True)
    for ax, s in zip(axes, SIZES):
        bl = duckdb.sql(f"""
            SELECT backlog_at_end FROM '{DATA}/{s}/out_sessions.parquet'
            WHERE backlog_at_end > 0
        """).df()["backlog_at_end"].values
        bins = np.logspace(0, np.log10(max(bl.max(), 10)), 60)
        ax.hist(bl, bins=bins, color="darkorange", alpha=0.7, edgecolor="white")
        ax.set_xscale("log"); ax.set_yscale("log")
        ax.set_title(f"{NL[s]} ({len(bl):,} non-zero)")
        ax.set_xlabel("backlog_at_end"); ax.grid(True, alpha=0.3)
    axes[0].set_ylabel("Sessions")
    fig.suptitle("Session-end backlog (log-log, excluding zeros)")
    plt.tight_layout()
    fig.savefig(OUTPUT / "s2_backlog_hist.png", bbox_inches="tight")
    plt.close()


def plot_actions_histogram():
    fig, axes = plt.subplots(1, 3, figsize=(15, 4), sharey=True)
    for ax, s in zip(axes, SIZES):
        na = duckdb.sql(f"""
            SELECT n_actions FROM '{DATA}/{s}/out_sessions.parquet'
            WHERE n_actions > 0
        """).df()["n_actions"].values
        bins = np.logspace(0, np.log10(max(na.max(), 10)), 60)
        ax.hist(na, bins=bins, color="mediumseagreen", alpha=0.7, edgecolor="white")
        ax.set_xscale("log"); ax.set_yscale("log")
        ax.set_title(f"{NL[s]}")
        ax.set_xlabel("actions per session"); ax.grid(True, alpha=0.3)
    axes[0].set_ylabel("Sessions")
    fig.suptitle("Posts seen per session (log-log, excluding zeros)")
    plt.tight_layout()
    fig.savefig(OUTPUT / "s2_actions_hist.png", bbox_inches="tight")
    plt.close()


# ── 2.2 Session Duration ───────────────────────────────────────────────
def table_duration_batch():
    print("\n─── 2.2 Session Duration (batch means) ───")
    print(f"  {'Size':<8} {'Metric':<16} {'Mean':>10} {'±CI95':>10}")
    for s in SIZES:
        runs = _per_run_agg(s)
        for col, label in [("mean_dur","mean duration"), ("med_dur","med duration"),
                           ("mean_actions","actions/sess"), ("pct_empty","% empty")]:
            vals = runs[col].values
            mu, ci = vals.mean(), 1.96 * vals.std(ddof=1) / np.sqrt(len(vals))
            print(f"  {s:<8} {label:<16} {mu:>10.1f} {ci:>10.2f}")


def table_duration_percentiles():
    print("\n─── 2.2 Session duration percentiles ───")
    print(f"  {'Size':<8} {'mean':>10} {'p5':>8} {'p25':>8} {'p50':>8} "
          f"{'p75':>8} {'p95':>8} {'p99':>8}")
    for s in SIZES:
        pcts = duckdb.sql(f"""
            SELECT
                AVG(duration) as mean,
                PERCENTILE_CONT(0.05) WITHIN GROUP (ORDER BY duration) as p5,
                PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY duration) as p25,
                MEDIAN(duration) as p50,
                PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY duration) as p75,
                PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duration) as p95,
                PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY duration) as p99
            FROM '{DATA}/{s}/out_sessions.parquet'
        """).df().iloc[0]
        print(f"  {s:<8} {pcts['mean']:>10.0f} {pcts['p5']:>8.0f} "
              f"{pcts['p25']:>8.0f} {pcts['p50']:>8.0f} {pcts['p75']:>8.0f} "
              f"{pcts['p95']:>8.0f} {pcts['p99']:>8.0f}")


def plot_duration_histogram():
    fig, axes = plt.subplots(1, 3, figsize=(15, 4), sharey=True)
    for ax, s in zip(axes, SIZES):
        d = duckdb.sql(f"""
            SELECT duration FROM '{DATA}/{s}/out_sessions.parquet' WHERE duration > 0
        """).df()["duration"].values
        bins = np.logspace(0, np.log10(max(d.max(), 10)), 60)
        ax.hist(d, bins=bins, color="royalblue", alpha=0.7, edgecolor="white")
        ax.set_xscale("log"); ax.set_yscale("log")
        ax.set_title(f"{NL[s]}")
        ax.set_xlabel("session duration (ticks)"); ax.grid(True, alpha=0.3)
    axes[0].set_ylabel("Sessions")
    fig.suptitle("Session duration distribution (log-log)")
    plt.tight_layout()
    fig.savefig(OUTPUT / "s2_duration_hist.png", bbox_inches="tight")
    plt.close()


def plot_duration_vs_empty():
    fig, axes = plt.subplots(1, 3, figsize=(12, 5), sharey=True)
    for ax, s in zip(axes, SIZES):
        df = duckdb.sql(f"""
            SELECT LN(duration+1) as log_dur, empty_timeline_exit
            FROM '{DATA}/{s}/out_sessions.parquet'
            USING SAMPLE 100000
        """).df()
        empty = df[df["empty_timeline_exit"]]["log_dur"].values
        nonempty = df[~df["empty_timeline_exit"]]["log_dur"].values
        ax.boxplot([empty, nonempty], tick_labels=["Empty exit", "Has backlog"],
                   patch_artist=True,
                   boxprops=dict(facecolor="lightcoral"),
                   medianprops=dict(color="black"))
        ax.set_title(f"{NL[s]}")
        ax.set_ylabel("log(duration+1)" if ax == axes[0] else "")
        ax.grid(True, alpha=0.3, axis="y")
    fig.suptitle("Session duration (log scale): empty-exit vs non-empty")
    plt.tight_layout()
    fig.savefig(OUTPUT / "s2_duration_vs_empty.png", bbox_inches="tight")
    plt.close()


def table_duration_vs_actions():
    print("\n─── 2.2.4 Duration vs actions ───")
    for s in SIZES:
        print(f"\n  {s}:")
        r = duckdb.sql(f"""
            SELECT
                CASE WHEN duration < 10 THEN '<10'
                     WHEN duration < 60 THEN '10-60'
                     WHEN duration < 300 THEN '60-300'
                     ELSE '300+' END as bucket,
                COUNT(*) as n,
                AVG(n_actions) as mean_actions,
                AVG(n_reposts) as mean_reposts,
                AVG(CAST(empty_timeline_exit AS DOUBLE))*100 as pct_empty
            FROM '{DATA}/{s}/out_sessions.parquet'
            GROUP BY bucket
        """).df()
        print(f"  {'Bucket':<10} {'N':>10} {'mean_actions':>14} "
              f"{'mean_reposts':>14} {'%empty':>8}")
        for _, row in r.iterrows():
            print(f"  {row['bucket']:<10} {int(row['n']):>10,} {row['mean_actions']:>14.1f} "
                  f"{row['mean_reposts']:>14.2f} {row['pct_empty']:>7.1f}%")


# ── 2.3 Per-user aggregation ──────────────────────────────────────────
def table_user_agg():
    print("\n─── 2.3 Per-user aggregation (1 run per size) ───")
    print(f"  {'Size':<8} {'users':>10} {'sess/user':>11} {'mean_dur':>10} "
          f"{'med_dur':>9} {'%empty':>8} {'act/user':>10} {'rep/user':>9}")
    for s in SIZES:
        df, run_name = _per_user_agg(s)
        n = len(df)
        print(f"  {s:<8} {n:>10,} {df['n_sessions'].mean():>10.1f} "
              f"{df['mean_session_duration'].mean():>9.0f} "
              f"{df['median_session_duration'].median():>8.0f} "
              f"{df['pct_empty_exit'].mean():>7.1f}% "
              f"{df['total_actions'].mean():>9.0f} {df['total_reposts'].mean():>8.1f}")


def plot_user_empty_hist():
    fig, axes = plt.subplots(1, 3, figsize=(15, 4), sharey=True)
    for ax, s in zip(axes, SIZES):
        df, _ = _per_user_agg(s)
        pe = df["pct_empty_exit"].values
        ax.hist(pe, bins=50, color="indianred", alpha=0.7, edgecolor="white")
        ax.axvline(pe.mean(), color="black", ls="--", lw=1.5,
                   label=f"μ = {pe.mean():.1f}%")
        ax.set_title(f"{NL[s]}")
        ax.set_xlabel("% sessions ending empty")
        ax.legend(fontsize=9); ax.grid(True, alpha=0.3)
    axes[0].set_ylabel("Users")
    fig.suptitle("Per-user boredom ratio")
    plt.tight_layout()
    fig.savefig(OUTPUT / "s2_user_empty_hist.png", bbox_inches="tight")
    plt.close()


def plot_reposters_vs_non():
    fig, axes = plt.subplots(1, 3, figsize=(12, 5), sharey=True)
    for ax, s in zip(axes, SIZES):
        df, _ = _per_user_agg(s)
        rep = np.log(df[df["total_reposts"] > 0]["mean_session_duration"].values + 1)
        non = np.log(df[df["total_reposts"] == 0]["mean_session_duration"].values + 1)
        ax.boxplot([non, rep], tick_labels=["Never reposts", "Reposts"],
                   patch_artist=True,
                   boxprops=dict(facecolor="mediumseagreen"),
                   medianprops=dict(color="black"))
        ax.set_title(f"{NL[s]}")
        if ax == axes[0]: ax.set_ylabel("log(mean_dur+1)")
        ax.grid(True, alpha=0.3, axis="y")
    fig.suptitle("Per-user mean session duration (log): reposters vs non-reposters")
    plt.tight_layout()
    fig.savefig(OUTPUT / "s2_reposters_vs_non.png", bbox_inches="tight")
    plt.close()


# ── 2.4 Content creation ───────────────────────────────────────────────
def table_creation():
    print("\n─── 2.4 Content creation per session ───")
    for s in SIZES:
        r = duckdb.sql(f"""
            SELECT AVG(n_posts_created) as mean_created,
                   SUM(CASE WHEN n_posts_created>0 THEN 1 ELSE 0 END)*100.0/COUNT(*) as pct_with
            FROM '{DATA}/{s}/out_sessions.parquet'
        """).df().iloc[0]
        print(f"  {s}: {r['pct_with']:.1f}% of sessions have posts created "
              f"(mean={r['mean_created']:.2f}/session)")


# ── MAIN ───────────────────────────────────────────────────────────────
def main():
    print("=== 2.1 Timeline Starvation ===")
    table_starvation()
    plot_backlog_histogram()
    plot_actions_histogram()

    print("\n=== 2.2 Session Duration ===")
    table_duration_batch()
    table_duration_percentiles()
    plot_duration_histogram()
    plot_duration_vs_empty()
    table_duration_vs_actions()

    print("\n=== 2.3 Per-user aggregation ===")
    table_user_agg()
    plot_user_empty_hist()
    plot_reposters_vs_non()

    print("\n=== 2.4 Content creation ===")
    table_creation()

    print(f"\nAll plots saved to {OUTPUT}/")


if __name__ == "__main__":
    main()
