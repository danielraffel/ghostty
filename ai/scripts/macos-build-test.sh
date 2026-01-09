#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ai/scripts/macos-build-test.sh [options]

Build and test Ghostty on macOS using the repo's supported Zig workflow.

Options:
  --run                 Run the macOS app after build/test (zig build run).
  --no-test             Skip tests.
  --test-filter <name>  Run only tests matching <name>.
  --lib-vt              Build/test libghostty-vt only (no full app build).
  -h, --help            Show this help.
EOF
}

run_app=false
skip_tests=false
test_filter=""
lib_vt=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      run_app=true
      shift
      ;;
    --no-test)
      skip_tests=true
      shift
      ;;
    --test-filter)
      test_filter="${2:-}"
      if [[ -z "$test_filter" ]]; then
        echo "error: --test-filter requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --lib-vt)
      lib_vt=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
cd "$REPO_ROOT"

LOG_DIR="${REPO_ROOT}/ai/output"
mkdir -p "$LOG_DIR"
LOG_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/macos-build-test-${LOG_TIMESTAMP}.log"

log() {
  printf '%s\n' "$*" | tee -a "$LOG_FILE"
}

run_and_log() {
  log "+ $*"
  "$@" 2>&1 | tee -a "$LOG_FILE"
}

log "log file: ${LOG_FILE}"

if $lib_vt; then
  run_and_log zig build lib-vt

  if ! $skip_tests; then
    if [[ -n "$test_filter" ]]; then
      run_and_log zig build test-lib-vt -Dtest-filter="${test_filter}"
    else
      run_and_log zig build test-lib-vt
    fi
  fi

  if $run_app; then
    log "note: --run ignored for --lib-vt (no app to run)"
  fi
  log "open app: (not available for --lib-vt)"
  exit 0
fi

run_and_log zig build

if ! $skip_tests; then
  if [[ -n "$test_filter" ]]; then
    run_and_log zig build test -Dtest-filter="${test_filter}"
  else
    run_and_log zig build test
  fi
fi

if $run_app; then
  run_and_log zig build run
fi

app_path="$(ls -td macos/build/*/Ghostty.app 2>/dev/null | head -n 1 || true)"
if [[ -n "$app_path" ]]; then
  log "open app: open \"${app_path}\""
else
  log "open app: (Ghostty.app not found under macos/build)"
fi
