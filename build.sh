#!/bin/bash
set -e

# Usage:
#   bash build.sh                  # default: bigide gtk2
#   bash build.sh qt5              # bigide qt5
#   bash build.sh gtk2             # bigide gtk2
#   bash build.sh bigide qt5       # explicit target + platform
#   bash build.sh all gtk2         # undocked IDE
#   DIAG=0 bash build.sh           # disable socket inspector

# Parse arguments — detect platform shortcuts
TARGET="bigide"
PLATFORM="gtk2"

for ARG in "$@"; do
  case "$ARG" in
    gtk2|gtk3|qt5|qt6)  PLATFORM="$ARG" ;;
    bigide|all)         TARGET="$ARG" ;;
    *)                  echo "Unknown argument: $ARG"; echo "Usage: build.sh [bigide|all] [gtk2|gtk3|qt5|qt6]"; exit 1 ;;
  esac
done

# Diagnostic socket inspector: DIAG=1 (default) enables ring buffer + TCP server
export DIAG="${DIAG:-1}"

OPT_FLAGS=""
if [ "${DIAG}" = "1" ]; then
  OPT_FLAGS="-dENABLE_LCL_SOCKET_DIAG"
  echo "[build] Diagnostic mode: LCL socket inspector enabled (port 4747)"
fi

echo "=== Eleazar Build: target=$TARGET platform=$PLATFORM ==="
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
echo "  platform: $PLATFORM"
