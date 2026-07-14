#!/usr/bin/env bash
# Run remaining benchmarks: 250K → 500K → 750K → 1M
# 250K & 500K: 4 workers. 750K & 1M: 1 worker.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/zig-out/bin/bskysim"
CONFIG="$ROOT/simconfs/final.json"
DATA="$ROOT/data"
TRACES="$ROOT/traces"

run_one() {
    local size=$1 runs=$2 workers=$3
    local dir="${size}_bskysim_trace"
    local bin="${size}_monotonic.bin"

    if [ -f "$TRACES/$dir/execution_times.ssv" ]; then
        local done=$(($(wc -l < "$TRACES/$dir/execution_times.ssv") - 1))
        if [ "$done" -ge "$runs" ]; then
            echo "[$size] already done ($done runs), skipping"
            return 0
        fi
        echo "[$size] partial ($done/$runs), restarting..."
        rm -rf "$TRACES/$dir"
    fi

    echo "[$size] starting: $runs runs, $workers workers  ($(date))"
    local t0=$SECONDS

    "$BIN" -n "$runs" -o "$TRACES/$dir" -w "$workers" \
        "$DATA/$bin" "$CONFIG"

    local elapsed=$((SECONDS - t0))
    echo "[$size] DONE in ${elapsed}s ($((elapsed/60))m)  ($(date))"
    echo ""
}

echo "=== BskySim queue ==="
echo "Start: $(date)"
echo ""

run_one "250K" 200 4
run_one "500K" 100 4
run_one "750K" 50  1
run_one "1M"   10  1

echo "=== ALL DONE ==="
echo "End: $(date)"
