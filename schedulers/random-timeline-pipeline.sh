#!/usr/bin/env bash
# Run from the repo root (des-ctic-dev). Random-timeline pipeline: run the
# cascade + dataset stages via zig on existing traces. dataset-creation now
# converts the .bin traces to parquet itself, so there is no separate
# conversion step and no .jsonl. Simulation is NOT rerun.
# Usage: ./schedulers/random-timeline-pipeline.sh [--dry-run] [size...]
set -euo pipefail

DRY="${1:-}"
if [ "$DRY" = "--dry-run" ]; then shift || true; fi

SIZES=("$@")
[ ${#SIZES[@]} -eq 0 ] && SIZES=(10K 100K 500K)

mkdir -p steps/random-timeline/cascades

for name in "${SIZES[@]}"; do
    cfg="configs/build-configs/random-timeline/pipeline/${name}.json"

    echo "[$name] $(date): cascade + dataset"
    if [ "$DRY" = "--dry-run" ]; then
        echo "  zig build -Dconfig=$cfg pipeline"
    else
        zig build -Dconfig="$cfg" pipeline
    fi
done

echo "=== ALL DONE ==="
