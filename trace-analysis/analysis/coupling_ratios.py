"""Micro-Macro Coupling Ratios — batch means ± CI per size."""
import duckdb, numpy as np
from pathlib import Path

DATA = Path(__file__).parent.parent / "output"
SIZES = ["100K", "500K", "1M"]
INTER_ACTION = 3.0; INTER_CREATION = 20.0

def batch(vals):
    return f"{vals.mean():.2f} ± {1.96*vals.std(ddof=1)/np.sqrt(len(vals)):.3f}"

for s in SIZES:
    post_runs = duckdb.sql(f"""
        SELECT sim_id, AVG(lifetime_raw) as mean_lt, AVG(total_reposts) as mean_rp
        FROM '{DATA}/{s}/out_posts.parquet'
        WHERE total_reposts > 0 GROUP BY sim_id
    """).df()
    sess_runs = duckdb.sql(f"""
        SELECT sim_id, AVG(duration) as mean_dur, AVG(n_actions) as mean_act,
               MEDIAN(n_actions) as med_act,
               AVG(n_reposts) as mean_sess_rep, AVG(backlog_at_end) as mean_bl,
               MEDIAN(backlog_at_end) as med_bl,
               AVG(n_posts_created) as mean_created
        FROM '{DATA}/{s}/out_sessions.parquet' GROUP BY sim_id
    """).df()
    gap_runs = duckdb.sql(f"""
        SELECT sim_id, AVG(next_start - end_time) as mean_offline
        FROM (SELECT sim_id, user_id, end_time,
              LEAD(start_time) OVER (PARTITION BY sim_id, user_id ORDER BY start_time) as next_start
              FROM '{DATA}/{s}/out_sessions.parquet')
        WHERE next_start IS NOT NULL AND (next_start - end_time) > 0
        GROUP BY sim_id
    """).df()
    runs = post_runs.merge(sess_runs, on="sim_id").merge(gap_runs, on="sim_id")

    pi    = runs["mean_lt"] / runs["mean_dur"]
    tau   = runs["mean_lt"] / INTER_CREATION
    eta   = runs["mean_rp"] / runs["mean_act"]
    kappa = runs["mean_created"] / runs["mean_act"]
    psi_m = runs["mean_bl"] / runs["mean_act"]
    psi_d = runs["med_bl"] / runs["med_act"]
    omega = runs["mean_lt"] / runs["mean_offline"]
    lr    = runs["mean_sess_rep"] / runs["mean_dur"]
    delta = INTER_ACTION / runs["mean_lt"]

    print(f"\n=== {s} — Micro-Macro Coupling Ratios ===\n")
    print(f"  {'Ratio':<6} {'Formula':<55} {'Value':>18}")
    print(f"  {'─'*6} {'─'*55} {'─'*18}")
    for name, formula, vals in [
        ("π",   "post_lifetime / session_duration",                     pi),
        ("τ_c", "post_lifetime / inter_creation_time",                  tau),
        ("η",   "reposts_per_post / actions_per_session",               eta),
        ("κ",   "created_per_session / consumed_per_session",           kappa),
        ("ψ",   "median_backlog / median_actions (robust)",             psi_d),
        ("ω",   "post_lifetime / mean_offline_gap",                     omega),
        ("λ_r", "reposts_per_session / session_duration",               lr),
        ("δ",   "inter_action_time / post_lifetime",                    delta),
    ]:
        print(f"  {name:<6} {formula:<55} {batch(vals):>18}")
    
    print(f"\n  Interpretations:")
    print(f"    π   = posts outlive sessions by {pi.mean():.0f}×")
    print(f"    τ_c = {tau.mean():.0f} posts created during one post's lifetime")
    print(f"    η   = reposts are {eta.mean()*100:.1f}% of a session's actions")
    print(f"    κ   = users create {kappa.mean()*100:.1f}% as many posts as they consume")
    print(f"    ψ   = median backlog / median actions = {psi_d.mean():.2f}")
    print(f"          (mean-based: {psi_m.mean()*100:.0f}%, inflated by heavy-tailed backlog)")
    print(f"    ω   = a post survives {omega.mean():.1f} offline cycles")
    print(f"    λ_r = {lr.mean():.4f} reposts/tick (~{1/lr.mean():.0f} ticks/repost per session)")
    print(f"    δ   = {1/delta.mean():.0f} timeline checks fit in one post's lifetime")
