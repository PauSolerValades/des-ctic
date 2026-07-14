#!/usr/bin/env bash
# Run benchmarks: loops over datasets and worker counts.
# Logs go to validate-trace/progress/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/zig-out/bin/bskysim"
CONFIG="$ROOT/simconfs/final.json"
DATA="$ROOT/data/monotonic"
TRACES="$ROOT/traces"
LOG_DIR="$ROOT/validate-trace/progress"

RUNS=500

SIZES=("250K" "500K" "750K" "1M")
WORKERS=(4 2 1 1)

mkdir -p "$LOG_DIR"

echo "=== BskySim queue ===" | tee "$LOG_DIR/master.log"
echo "Start: $(date)" | tee -a "$LOG_DIR/master.log"
echo "Sizes: ${SIZES[*]}" | tee -a "$LOG_DIR/master.log"
echo "Workers: ${WORKERS[*]}" | tee -a "$LOG_DIR/master.log"
echo "" | tee -a "$LOG_DIR/master.log"

for i in "${!SIZES[@]}"; do
    SIZE="${SIZES[$i]}"
    W="${WORKERS[$i]}"
    DIR="${SIZE}_bskysim_trace"
    LOG="$LOG_DIR/${SIZE}.log"

    rm -rf "$TRACES/$DIR"

    echo "[$SIZE] $RUNS runs, $W workers  ($(date))" | tee -a "$LOG"
    t0=$SECONDS

    "$BIN" -n "$RUNS" -o "$TRACES/$DIR" -w "$W" \
        "$DATA/${SIZE}_monotonic.bin" "$CONFIG" >> "$LOG" 2>&1

    rc=$?
    elapsed=$((SECONDS - t0))

    if [ $rc -eq 0 ]; then
        echo "[$SIZE] OK  in ${elapsed}s ($((elapsed/60))m)  ($(date))" | tee -a "$LOG"
    else
        echo "[$SIZE] FAIL (rc=$rc) in ${elapsed}s  ($(date))" | tee -a "$LOG"
    fi
    echo "" | tee -a "$LOG"
done

echo "=== ALL DONE ===" | tee -a "$LOG_DIR/master.log"
echo "End: $(date)" | tee -a "$LOG_DIR/master.log"
