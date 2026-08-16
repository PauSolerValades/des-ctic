#!/usr/bin/env bash
# Run from the repo root (des-ctic-dev). Warmup sweep: for each dataset ×
# each sim-params file in configs/simconfs/warmup/params/, run the
# simulation only (5 runs) into steps/warmup/traces/<size>-warmup/<w>-ticks/
# — the layout the which-warmup analysis expects. No cascades/datasets.
# Compiles bskysim only on the first combo. Deletes steps/warmup first.
# Usage: ./schedulers/warmup.sh [--dry-run]
set -euo pipefail

DRY="${1:-}"
RUNS=5

rm -rf steps/warmup
mkdir -p steps/warmup/tmp

first=1
for name in 10K 50K 100K 250K 500K 750K 1M; do
    case "$name" in
        10K|50K) workers=8 ;;
        100K)    workers=4 ;;
        250K)    workers=3 ;;
        500K)    workers=2 ;;
        *)       workers=1 ;;
    esac

    for params in configs/simconfs/warmup/params/w*.json; do
        w="$(basename "$params" .json)"; w="${w#w}"
        traces="steps/warmup/traces/${name}-warmup/${w}-ticks"
        cfg="steps/warmup/tmp/${name}-w${w}.json"

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

        echo "[$name w$w] $(date)"
        if [ "$first" -eq 1 ]; then
            if [ "$DRY" = "--dry-run" ]; then
                echo "  zig build -Dconfig=$cfg -Dcompile=simulation all"
            else
                zig build -Dconfig="$cfg" -Dcompile=simulation all
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
done

echo "=== ALL DONE ==="
