#!/usr/bin/env bash
# Run from the repo root (des-ctic-dev). Super warmup sweep: sizes
# 10K/100K/500K/1M × warmups 0/1/10/25/50/100, 5 runs each. Each combo runs
# the full `all` pipeline (simulation → cascades → datasets) so the output
# feeds which-warmup (bskysim-data-analysis/experiments/which-warmup):
#   --traces   steps/warmup-super/traces/<size>-warmup
#   --cascades steps/warmup-super/cascades/<size>-warmup
#   --datasets steps/warmup-super/datasets/<size>-warmup
# Old results are left untouched; this run lives under steps/warmup-super.
# Missing warmup params (w0/w1/w25/w50) are generated from the w10 template.
# New build system: no -Dcompile; `zig build -Dconfig=<cfg> all` runs the
# full chain. Deletes steps/warmup-super first.
# Usage: ./schedulers/warmup-super.sh [--dry-run]
set -euo pipefail

DRY="${1:-}"
RUNS=5
OUT="steps/warmup-super"

rm -rf "$OUT"
mkdir -p "$OUT/tmp"

for name in 10K 100K 500K 1M; do
    case "$name" in
        10K)  workers=8 ;;
        100K) workers=4 ;;
        500K) workers=2 ;;
        1M)   workers=1 ;;
    esac

    for w in 0 1 10 25 50 100; do
        # all warmup params are identical except warmup_time; reuse the w10 template
        params="$OUT/tmp/w${w}.json"
        sed "s/\"warmup_time\": 10/\"warmup_time\": $w/" \
            configs/simconfs/warmup/params/w10.json > "$params"

        traces="$OUT/traces/${name}-warmup/${w}-ticks"
        cfg="$OUT/tmp/${name}-w${w}.json"

        cat > "$cfg" <<EOF
{
  "simulation": {
    "workers": $workers,
    "runs": $RUNS,
    "output_dir": "$traces",
    "data_file": "data/monotonic/${name}_monotonic.bin",
    "config_file": "$params"
  },
  "cascade": {
    "buckets": null,
    "bucket_file": null,
    "output_file": "$OUT/cascades/${name}-warmup/warmup-${w}.tsv",
    "traces_dir": "$traces"
  },
  "dataset": {
    "output_dir": "$OUT/datasets/${name}-warmup/warmup-${w}",
    "cascades_ssv": "$OUT/cascades/${name}-warmup/warmup-${w}.tsv",
    "likes_ssv": "$OUT/cascades/${name}-warmup/warmup-${w}_likes.tsv",
    "traces_dir": "$traces",
    "dataset": "all"
  }
}
EOF

        echo "[$name w$w] $(date)"
        if [ "$DRY" = "--dry-run" ]; then
            echo "  zig build -Dconfig=$cfg all"
        else
            zig build -Dconfig="$cfg" all
        fi
    done
done

echo "=== ALL DONE ==="
