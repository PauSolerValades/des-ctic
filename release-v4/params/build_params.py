#!/usr/bin/env python3
"""Ephemeral script: sample 10k Pareto (shape, scale) pairs from the CSVs
and write one file per quantity: session duration, inter-session, inter-post.
Format: one pair per line as  shape  scale  (space-separated floats)."""

import csv
import random
import os

random.seed(42)
N = 10_000
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# ── 1. Sessions params ──────────────────────────────────────────────
rows_duration = []
rows_gap = []

with open(os.path.join(SCRIPT_DIR, "pareto_sessions_params.csv"), newline="") as f:
    reader = csv.DictReader(f)
    for r in reader:
        if r["table"] != "sessions_all":
            continue
        alpha = float(r["alpha"])
        xmin = float(r["xmin"])
        pair = (alpha, xmin)
        if r["quantity"] == "duration":
            rows_duration.append(pair)
        elif r["quantity"] == "gap":
            rows_gap.append(pair)

print(f"duration rows: {len(rows_duration)}")
print(f"gap rows:      {len(rows_gap)}")

sample_duration = random.sample(rows_duration, min(N, len(rows_duration)))
sample_gap = random.sample(rows_gap, min(N, len(rows_gap)))

with open(os.path.join(SCRIPT_DIR, "session_duration_params.txt"), "w") as f:
    for shape, scale in sample_duration:
        f.write(f"{shape} {scale}\n")

with open(os.path.join(SCRIPT_DIR, "inter_session_params.txt"), "w") as f:
    for shape, scale in sample_gap:
        f.write(f"{shape} {scale}\n")

# ── 2. Inter-post params ────────────────────────────────────────────
rows_post = []
with open(os.path.join(SCRIPT_DIR, "pareto_inter_post_params.csv"), newline="") as f:
    reader = csv.DictReader(f)
    for r in reader:
        if r["gap_type"] != "global":
            continue
        alpha = float(r["alpha"])
        xmin_s = float(r["xmin_s"])  # seconds
        rows_post.append((alpha, xmin_s))

print(f"inter-post rows: {len(rows_post)}")

sample_post = random.sample(rows_post, min(N, len(rows_post)))

with open(os.path.join(SCRIPT_DIR, "inter_creation_params.txt"), "w") as f:
    for shape, scale in sample_post:
        f.write(f"{shape} {scale}\n")

print("\nDone →")
print(f"  {SCRIPT_DIR}/session_duration_params.txt  ({len(sample_duration)} pairs)")
print(f"  {SCRIPT_DIR}/inter_session_params.txt     ({len(sample_gap)} pairs)")
print(f"  {SCRIPT_DIR}/inter_creation_params.txt    ({len(sample_post)} pairs)")
