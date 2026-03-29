#!/bin/bash
set -e

# Targets: "bigide" = IDE with anchordocking + extra packages (docked layout)
#          "all"    = plain IDE without anchordocking (undocked layout)
TARGET="${1:-bigide}"
PLATFORM="${2:-gtk2}"

echo "=== Lazarus Build: target=$TARGET platform=$PLATFORM ==="
echo "Started: $(date '+%Y-%m-%d %H:%M:%S')"

make clean "$TARGET" LCL_PLATFORM="$PLATFORM" 2>&1 | tail -5

echo ""
echo "=== Build Complete: $(date '+%Y-%m-%d %H:%M:%S') ==="
for bin in lazarus lazbuild startlazarus; do
  if [ -f "$bin" ]; then
    hash=$(md5sum "$bin" | cut -d' ' -f1)
    size=$(stat --format='%s' "$bin")
    ts=$(stat --format='%y' "$bin" | cut -d. -f1)
    echo "  $bin: ${size} bytes  md5=$hash  built=$ts"
  fi
done
