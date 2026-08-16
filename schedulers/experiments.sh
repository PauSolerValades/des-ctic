#!/usr/bin/env bash
# Run from the repo root (des-ctic-dev). For each dataset config, run the
# full zig build pipeline (simulation → cascades → datasets), 10 runs each,
# from smallest (10K) to biggest (1M). Compiles everything only on the
# first dataset. Deletes the whole steps/ output root first.
# Usage: ./schedulers/experiments.sh [--dry-run]
set -euo pipefail

DRY="${1:-}"

rm -rf steps/traces steps/cascades steps/datasets

first=1
for name in 10K 50K 100K 250K 500K 750K 1M; do
    cfg="job_config/experiments/${name}.json"

    echo "[$name] $(date)"
    if [ "$first" -eq 1 ]; then
        if [ "$DRY" = "--dry-run" ]; then
            echo "  zig build -Dconfig=$cfg -Dcompile=all all"
        else
            zig build -Dconfig="$cfg" -Dcompile=all all
        fi
        first=0
    else
        if [ "$DRY" = "--dry-run" ]; then
            echo "  zig build -Dconfig=$cfg all"
        else
            zig build -Dconfig="$cfg" all
        fi
    fi
done

echo "=== ALL DONE ==="
