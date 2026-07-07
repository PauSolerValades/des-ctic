#!/bin/bash
set -euo pipefail

TRACE_NAME="${1:?Usage: $0 <trace_folder_name>}"

echo "==> Building cascades from traces/$TRACE_NAME …"
./construct-cascades/zig-out/bin/construct-cascade -o "cascades/${TRACE_NAME}.ssv" "traces/$TRACE_NAME"

echo "==> Creating datasets from cascades/${TRACE_NAME} …"
./dataset-creation/dataset-creation -output "datasets/$TRACE_NAME" "cascades/${TRACE_NAME}.ssv" "cascades/${TRACE_NAME}_likes.ssv" "traces/$TRACE_NAME/" all

echo "==> Done. Results in cascades/ and datasets/"

