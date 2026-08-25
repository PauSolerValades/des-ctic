#!/usr/bin/env bash
# Builds jemalloc for bskysim. Zig passes the destination path for the archive
# as "$1" (see build.zig); the build happens in the jemalloc source tree, then
# the archive is copied there so the build system can track it.
#
# Idempotent: configure runs only when the Makefile is missing, then `make` is
# incremental. The flags below are the single source of truth for how jemalloc
# is compiled.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JEMALLOC="$ROOT/../../jemalloc"
OUT="${1:?usage: build-jemalloc.sh <output-archive-path>}"

# --with-jemalloc-prefix=          -> export plain malloc/free/realloc/... so
#                                     linking this archive overrides glibc.
# --enable-static --disable-shared -> one .a we can link into the binary.
# --disable-cxx                    -> no C++ integration needed.
CONFIGURE_FLAGS=(
    --enable-static
    --disable-shared
    --with-jemalloc-prefix=
    --disable-cxx
)

if [ ! -d "$JEMALLOC" ]; then
    echo "error: jemalloc not found at $JEMALLOC" >&2
    exit 1
fi

(
    cd "$JEMALLOC"
    if [ ! -f Makefile ]; then
        ./autogen.sh "${CONFIGURE_FLAGS[@]}"
    fi
    make -j"$(nproc)"
)

cp -f "$JEMALLOC/lib/libjemalloc.a" "$OUT"
