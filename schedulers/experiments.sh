#!/usr/bin/env bash
# For each dataset in data/monotonic/: run the zig build once (10 runs),
# writing traces to steps/traces/<name>_run. Workers: 10K/50K=8, 100K=4,
# 250K=3, 500K=2, 750K/1M=1. Compiles everything only on the first
# dataset. Deletes the whole steps/ output root before starting.
# Usage: ./python-utils/steps_benchmarks.sh [--dry-run]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DATA="$ROOT/data/monotonic"
STEPS="$ROOT/steps"
RUNS=10
DRY="${1:-}"

rm -rf "$STEPS"

first=1
for bin in "$DATA"/*_monotonic.bin; do
    name="$(basename "$bin" _monotonic.bin)"
    case "$name" in
        10K|50K) workers=8 ;;
        100K)    workers=4 ;;
        250K)    workers=3 ;;
        500K)    workers=2 ;;
        750K|1M) workers=1 ;;
        *)       workers=1 ;;
    esac
    cfg="steps/job_config/${name}.json"
    mkdir -p "$(dirname "$cfg")"

    cat > "$cfg" <<EOF
{
  "simulation": {
    "workers": $workers,
    "runs": $RUNS,
    "output_dir": "steps/traces/${name}_run",
    "data_file": "data/monotonic/${name}_monotonic.bin",
    "config_file": "job_config/prod.json"
  },
  "cascade": {
    "buckets": null,
    "bucket_file": null,
    "output_file": "steps/cascades/${name}_run.tsv",
    "traces_dir": "steps/traces/${name}_run"
  },
  "dataset": {
    "output_dir": "steps/datasets/${name}_run",
    "cascades_ssv": "steps/cascades/${name}_run.tsv",
    "likes_ssv": "steps/cascades/${name}_run_likes.tsv",
    "traces_dir": "steps/traces/${name}_run",
    "dataset": "all"
  }
}
EOF

    echo "[$name] $(date)"
    if [ "$first" -eq 1 ]; then
        if [ "$DRY" = "--dry-run" ]; then
            echo "  zig build -Dconfig=$cfg -Dcompile=all"
        else
            zig build -Dconfig="$cfg" -Dcompile=all
        fi
        first=0
    else
        if [ "$DRY" = "--dry-run" ]; then
            echo "  zig build -Dconfig=$cfg"
        else
            zig build -Dconfig="$cfg"
        fi
    fi
done

echo "=== ALL DONE ==="
