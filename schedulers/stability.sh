#!/usr/bin/env bash
# Run from the repo root (des-ctic-dev). Stability sweep: for each dataset ×
# each sim-params file in configs/build-configs/stability/params/ (warmup=100,
# varying duration), run the simulation (10 runs) into
# steps/stability/traces/<size>/d<N>/ — the dir-of-dirs layout the
# stable-regime analysis expects (used_config.json is auto-copied by the
# sim). No cascades/datasets: the analysis only reads session traces.
# Deletes steps/stability first.
# Usage: ./schedulers/stability.sh [--dry-run]
set -euo pipefail

DRY="${1:-}"
RUNS=10

rm -rf steps/stability
mkdir -p steps/stability/tmp

for name in 10K 100K 500K 1M; do
    case "$name" in
        10K|50K) workers=8 ;;
        100K)    workers=4 ;;
        250K)    workers=3 ;;
        500K)    workers=2 ;;
        *)       workers=1 ;;
    esac

    for params in configs/build-configs/stability/params/d*.json; do
        d="$(basename "$params" .json)"
        traces="steps/stability/traces/${name}/${d}"
        cfg="steps/stability/tmp/${name}-${d}.json"

        cat > "$cfg" <<EOF
{
  "simulation": {
    "workers": $workers,
    "runs": $RUNS,
    "output_dir": "$traces",
    "data_file": "data/monotonic/${name}_monotonic.bin",
    "config_file": "$params"
  },
  "cascade": null,
  "dataset": null
}
EOF

        echo "[$name $d] $(date)"
        if [ "$DRY" = "--dry-run" ]; then
            echo "  zig build -Dconfig=$cfg all"
        else
            zig build -Dconfig="$cfg" all
        fi
    done
done

echo "=== ALL DONE ==="
