#!/usr/bin/env python3
"""Preprocess ecdfs/parameters/ into per-(session,gap)-pair chunks for the sim.

Reads:
  parameters/pair_params_wide.tsv    per-user fitted session/gap distributions
  parameters/power_tail_canonical.tsv per-user GPD fits (xi, sigma) for power_tail users

Writes:
  parameters/pairs/{dur}__{gap}.tsv  wide rows split per family pair
  parameters/pair_pareto.json        pair probabilities + aggregated Pareto params
                                     for every power_tail side of a pair

GPD(xi>0) == Lomax(shape=1/xi, scale=sigma/xi). We emit the sim's Pareto as
Pareto(shape=1/xi, scale=sigma/xi), dropping Lomax's shift by `scale`
(the sim's Pareto support starts at scale instead of 0 — min sample = scale).
Aggregation = median of xi / sigma over the pair's users with xi > 0
(xi <= 0 is a bounded tail, not a Pareto; ~90% of rows, ignored).
"""
import csv, json, os, statistics, sys

BASE = os.path.join(os.path.dirname(__file__), "..", "ecdfs", "parameters")
PAIRS_DIR = os.path.join(BASE, "pairs")

def main():
    os.makedirs(PAIRS_DIR, exist_ok=True)

    total = 0
    pair_counts = {}          # (dur, gap) -> n
    pt_users = {}             # (dur, gap) -> set of dids with a power_tail side
    pair_files = {}           # (dur, gap) -> open file

    with open(os.path.join(BASE, "pair_params_wide.tsv")) as f:
        r = csv.reader(f, delimiter="\t")
        header = next(r)
        for row in r:
            pair = (row[1], row[2])
            total += 1
            pair_counts[pair] = pair_counts.get(pair, 0) + 1
            if "power_tail" in pair:
                pt_users.setdefault(pair, set()).add(row[0])
            fh = pair_files.get(pair)
            if fh is None:
                fh = open(os.path.join(PAIRS_DIR, f"{pair[0]}__{pair[1]}.tsv"), "w")
                fh.write("\t".join(header) + "\n")
                pair_files[pair] = fh
            fh.write("\t".join(row) + "\n")
    for fh in pair_files.values():
        fh.close()

    # collect xi/sigma per (pair, col) for power_tail users
    fits = {}  # (pair, col) -> [ (xi, sigma) ] with xi > 0
    with open(os.path.join(BASE, "power_tail_canonical.tsv")) as f:
        for r in csv.DictReader(f, delimiter="\t"):
            xi = float(r["xi"])
            if xi <= 0:
                continue
            for pair, dids in pt_users.items():
                if r["did"] in dids:
                    fits.setdefault((pair, r["col"]), []).append((xi, float(r["sigma"])))

    out = {"total_users": total, "pairs": {}}
    for pair, n in sorted(pair_counts.items(), key=lambda kv: -kv[1]):
        entry = {"n": n, "probability": n / total}
        for col, key in (("duration", "duration_pareto"), ("gap", "gap_pareto")):
            pts = fits.get((pair, col))
            if pts:
                xis, sigmas = zip(*pts)
                xi = statistics.median(xis)
                entry[key] = {
                    "shape": 1.0 / xi,
                    "scale": statistics.median(sigmas) / xi,
                    "n": len(pts),
                }
        out["pairs"][f"{pair[0]}__{pair[1]}"] = entry

    with open(os.path.join(BASE, "pair_pareto.json"), "w") as f:
        json.dump(out, f, indent=2)

    print(f"{total} users, {len(pair_counts)} pairs -> {PAIRS_DIR}")
    for k, v in out["pairs"].items():
        extra = {kk: f"a={vv['shape']:.3f} xm={vv['scale']:.1f} (n={vv['n']})"
                 for kk, vv in v.items() if kk.endswith("_pareto")}
        print(f"  {k:35s} p={v['probability']:.4f} {extra}")

if __name__ == "__main__":
    sys.exit(main())
