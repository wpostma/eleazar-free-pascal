#!/bin/bash
set -e

# test-lcl.sh — Build and run LCL unit tests
#
# Usage:
#   ./test-lcl.sh              # build LCL + tests, run all tests
#   ./test-lcl.sh build        # build only (LCL + test runner)
#   ./test-lcl.sh run          # run only (skip build)
#   ./test-lcl.sh quick        # build LCL-only (no clean), run tests
#   ./test-lcl.sh smoke        # build + run IDE smoke test via socket inspector
#
# Environment:
#   LCL_PLATFORM   gtk2 (default), qt5, etc.
#   DIAG=1         build with ENABLE_LCL_SOCKET_DIAG (ring buffer + inspector)
#   VERBOSE=1      show full build output instead of tail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PLATFORM="${LCL_PLATFORM:-gtk2}"
LAZBUILD="./lazbuild"
TEST_RUNNER="./test/runtests"
TEST_DIR="./test"
RESULTS_DIR="./test/results"
MODE="${1:-all}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[test-lcl]${NC} $*"; }
ok()   { echo -e "${GREEN}[  OK  ]${NC} $*"; }
fail() { echo -e "${RED}[ FAIL ]${NC} $*"; }
warn() { echo -e "${YELLOW}[ WARN ]${NC} $*"; }

OPT_FLAGS=""
if [ "${DIAG:-0}" = "1" ]; then
  OPT_FLAGS="-dENABLE_LCL_SOCKET_DIAG"
  log "Diagnostic mode: ring buffer + socket inspector enabled"
fi

mkdir -p "$RESULTS_DIR"

# ─── Phase 1: Build LCL ─────────────────────────────────────────────────────

build_lcl() {
  log "Building LCL (platform=$PLATFORM)..."
  local start=$(date +%s)

  local make_cmd="make lcl LCL_PLATFORM=$PLATFORM"
  if [ -n "$OPT_FLAGS" ]; then
    make_cmd="$make_cmd OPT=\"$OPT_FLAGS\""
  fi

  if [ "${VERBOSE:-0}" = "1" ]; then
    eval "$make_cmd" 2>&1
  else
    eval "$make_cmd" 2>&1 | tail -3
  fi

  local elapsed=$(( $(date +%s) - start ))
  ok "LCL built in ${elapsed}s"
}

# ─── Phase 2: Build lazbuild (needed to compile test runner) ─────────────────

build_lazbuild() {
  if [ -x "$LAZBUILD" ]; then
    log "lazbuild exists, skipping rebuild"
    return 0
  fi
  log "Building lazbuild..."
  local start=$(date +%s)

  if [ "${VERBOSE:-0}" = "1" ]; then
    make lazbuild LCL_PLATFORM=$PLATFORM 2>&1
  else
    make lazbuild LCL_PLATFORM=$PLATFORM 2>&1 | tail -3
  fi

  local elapsed=$(( $(date +%s) - start ))
  ok "lazbuild built in ${elapsed}s"
}

# ─── Phase 3: Build test runner ──────────────────────────────────────────────

build_tests() {
  log "Building test runner..."
  local start=$(date +%s)

  $LAZBUILD --build-mode=Default "$TEST_DIR/runtests.lpi" 2>&1 | tail -5
  if [ ! -x "$TEST_RUNNER" ]; then
    fail "Test runner not found at $TEST_RUNNER"
    fail "Trying alternate location..."
    # lazbuild may place it elsewhere depending on config
    local alt=$(find "$TEST_DIR" -name "runtests" -type f -executable 2>/dev/null | head -1)
    if [ -n "$alt" ]; then
      TEST_RUNNER="$alt"
      log "Found test runner at $TEST_RUNNER"
    else
      fail "Cannot find test runner binary"
      exit 1
    fi
  fi

  local elapsed=$(( $(date +%s) - start ))
  ok "Test runner built in ${elapsed}s"
}

# ─── Phase 4: Run tests ─────────────────────────────────────────────────────

run_tests() {
  local timestamp=$(date '+%Y%m%d_%H%M%S')
  local xml_file="$RESULTS_DIR/results_${timestamp}.xml"
  local log_file="$RESULTS_DIR/results_${timestamp}.log"

  log "Running tests..."
  log "  XML: $xml_file"
  log "  Log: $log_file"

  local start=$(date +%s)
  local exit_code=0

  # Run under Xvfb if available and no display set, or if DISPLAY is set use it
  local run_cmd="$TEST_RUNNER --all --format=xml --file=$xml_file"

  if [ -z "$DISPLAY" ]; then
    if command -v xvfb-run &>/dev/null; then
      log "No DISPLAY set, using xvfb-run"
      run_cmd="xvfb-run -a $run_cmd"
    else
      warn "No DISPLAY and xvfb-run not found — tests needing GUI may fail"
    fi
  fi

  $run_cmd 2>&1 | tee "$log_file" || exit_code=$?

  local elapsed=$(( $(date +%s) - start ))

  echo ""
  if [ $exit_code -eq 0 ]; then
    ok "All tests passed in ${elapsed}s"
  else
    fail "Tests finished with exit code $exit_code in ${elapsed}s"
    # Parse the log for a summary line
    if [ -f "$log_file" ]; then
      echo ""
      log "Test summary:"
      grep -iE "^(Tests|Failures|Errors|Run|OK)" "$log_file" 2>/dev/null || true
    fi
  fi

  # Keep only the 10 most recent result files
  ls -t "$RESULTS_DIR"/results_*.xml 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null || true
  ls -t "$RESULTS_DIR"/results_*.log 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null || true

  return $exit_code
}

# ─── Phase 5: IDE smoke test (requires DIAG build) ──────────────────────────

smoke_test() {
  if [ "${DIAG:-0}" != "1" ]; then
    warn "Smoke test requires DIAG=1. Rebuilding with diagnostics..."
    DIAG=1 OPT_FLAGS="-dENABLE_LCL_SOCKET_DIAG"
    build_lcl
  fi

  log "IDE smoke test (placeholder — needs socket inspector implementation)"
  log "  Future: launch IDE under Xvfb, connect to localhost:4747,"
  log "  verify tree, check bounds, assert no exceptions, exit."
  warn "Not yet implemented — see LCL_SOCKET_INSPECTOR.md"
  return 0
}

# ─── Main ────────────────────────────────────────────────────────────────────

total_start=$(date +%s)

case "$MODE" in
  build)
    build_lcl
    build_lazbuild
    build_tests
    ;;
  run)
    run_tests
    ;;
  quick)
    # Skip clean, just rebuild LCL and tests
    log "Quick mode: incremental build"
    build_lcl
    build_lazbuild
    build_tests
    run_tests
    ;;
  smoke)
    build_lcl
    build_lazbuild
    smoke_test
    ;;
  all|"")
    build_lcl
    build_lazbuild
    build_tests
    run_tests
    ;;
  *)
    echo "Usage: $0 [build|run|quick|smoke|all]"
    echo ""
    echo "Modes:"
    echo "  all     Build LCL + tests, run all tests (default)"
    echo "  build   Build LCL + test runner only"
    echo "  run     Run tests only (skip build)"
    echo "  quick   Incremental build (no clean) + run tests"
    echo "  smoke   Build + IDE smoke test via socket inspector"
    echo ""
    echo "Environment:"
    echo "  LCL_PLATFORM=gtk2   Widget set (default: gtk2)"
    echo "  DIAG=1              Enable socket inspector + ring buffer"
    echo "  VERBOSE=1           Show full build output"
    exit 1
    ;;
esac

total_elapsed=$(( $(date +%s) - total_start ))
echo ""
log "Total time: ${total_elapsed}s"
