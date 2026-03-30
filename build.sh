#!/bin/bash
set -e

# Targets: "bigide" = IDE with anchordocking + extra packages (docked layout)
#          "all"    = plain IDE without anchordocking (undocked layout)
TARGET="${1:-bigide}"
PLATFORM="${2:-gtk2}"

export DIAG=1

# Diagnostic socket inspector: set DIAG=1 to enable ring buffer + TCP server
OPT_FLAGS=""
if [ "${DIAG:-0}" = "1" ]; then
  OPT_FLAGS="-dENABLE_LCL_SOCKET_DIAG"
  echo "[build] Diagnostic mode: LCL socket inspector enabled (port 4747)"
fi

echo "=== Lazarus Build: target=$TARGET platform=$PLATFORM ==="
echo "Started: $(date '+%Y-%m-%d %H:%M:%S')"

if [ -n "$OPT_FLAGS" ]; then
  make clean "$TARGET" LCL_PLATFORM="$PLATFORM" OPT="$OPT_FLAGS" 2>&1 | tail -95
else
  make clean "$TARGET" LCL_PLATFORM="$PLATFORM" 2>&1 | tail -5
fi

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
