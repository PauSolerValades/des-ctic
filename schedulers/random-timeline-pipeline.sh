#!/usr/bin/env bash
# Run from the repo root (des-ctic-dev). Random-timeline pipeline: for each
# dataset size, convert the .bin traces to parquet (only the kinds the dataset
# queries read: action/session/swap/propagate), delete the now-redundant .jsonl
# (parquet replaces it; the .bin stays so it is regenerable), then run the
# cascade + dataset stages via zig. Simulation is NOT rerun.
# Usage: ./schedulers/random-timeline-pipeline.sh [--dry-run] [size...]
set -euo pipefail

DRY="${1:-}"
if [ "$DRY" = "--dry-run" ]; then shift || true; fi

SIZES=("$@")
[ ${#SIZES[@]} -eq 0 ] && SIZES=(10K 100K 500K)

BINPARQUET="${BINPARQUET:-bin-to-parquet/bin-to-parquet}"

mkdir -p steps/random-timeline/cascades

for name in "${SIZES[@]}"; do
    traces="steps/random-timeline/traces/${name}"
    cfg="configs/build-configs/random-timeline/pipeline/${name}.json"

    echo "[$name] $(date): convert bins -> parquet"
    # action is the biggest, so it frees the most disk first.
    for pair in action:action_trace propagate:propagate_trace session:session_trace swap:swap_trace; do
        t="${pair%%:*}"; suffix="${pair##*:}"
        if [ "$DRY" = "--dry-run" ]; then
            echo "  $BINPARQUET -type $t -dir $traces && rm -f $traces/*-$suffix.jsonl"
        else
            "$BINPARQUET" -type "$t" -dir "$traces"
            rm -f "$traces"/*-"$suffix".jsonl
        fi
    done
    if [ "$DRY" = "--dry-run" ]; then
        echo "  rm -f $traces/*-create_trace.jsonl   # create parquet unused by dataset"
    else
        rm -f "$traces"/*-create_trace.jsonl
    fi

    echo "[$name] $(date): cascade + dataset"
    if [ "$DRY" = "--dry-run" ]; then
        echo "  zig build -Dconfig=$cfg pipeline"
    else
        zig build -Dconfig="$cfg" pipeline
    fi
done

echo "=== ALL DONE ==="
