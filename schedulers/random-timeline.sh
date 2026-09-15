#!/usr/bin/env bash
# Run from the repo root (des-ctic-dev). Random-timeline experiment: run the
# simulation for 10K/100K/500K back to back with -Dtimelinerandom, writing to
# steps/random-timeline/. Simulation only (cascade/dataset are null in the
# configs). Compiles bskysim on the first size, reuses it afterwards.
# Usage: ./schedulers/random-timeline.sh [--dry-run]
set -euo pipefail

DRY="${1:-}"

for name in 10K 100K 500K; do
    cfg="configs/build-configs/random-timeline/${name}.json"

    echo "[$name] $(date)"
    if [ "$DRY" = "--dry-run" ]; then
        echo "  zig build -Dconfig=$cfg -Dtimelinerandom all"
    else
        zig build -Dconfig="$cfg" -Dtimelinerandom all
    fi
done

echo "=== ALL DONE ==="
