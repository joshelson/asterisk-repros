#!/usr/bin/env bash
# Path B test runner. Drives the full reproducer end-to-end against
# multiple reload scenarios.
#
#   1. docker compose up -d (postgres + asterisk container)
#   2. Build asterisk in the asterisk container (one-time, slow ~5-15 min)
#   3. For each scenario: run BASELINE (no patches), apply patches +
#      rebuild only ODBC modules, run FIXED, revert patches.
#   4. Print before/after summary with per-scenario tail-failure rate
#      (the "stuck disconnected" indicator: failures persisting AFTER
#      reloads have stopped).

set -euo pipefail

HERE="$(cd "$(dirname "$0")"/.. && pwd)"
cd "$HERE/docker"

DURATION="${DURATION:-30}"
RELOAD_STOP_AFTER="${RELOAD_STOP_AFTER:-22}"
CPS="${CPS:-8}"
ITERATIONS="${ITERATIONS:-3000}"
RELOAD_PERIOD="${RELOAD_PERIOD:-1.0}"

ast_exec() { docker compose exec -T asterisk bash -lc "$*"; }

step() { printf '\n\033[1;36m>>> %s\033[0m\n' "$*"; }

start_asterisk() {
  ast_exec "pkill -9 asterisk 2>/dev/null || true"
  ast_exec "rm -f /var/run/asterisk/asterisk.ctl 2>/dev/null || true"
  docker compose exec -d asterisk /scripts/run-asterisk.sh
  # Wait for AMI socket to come up (asterisk startup ~5-8s).
  for _ in $(seq 1 30); do
    if ast_exec "asterisk -rx 'core show version' 2>/dev/null | grep -q Asterisk"; then
      return 0
    fi
    sleep 1
  done
  echo "asterisk failed to start" >&2
  return 1
}

stop_asterisk() {
  ast_exec "pkill -9 asterisk 2>/dev/null || true"
  sleep 1
}

run_loadgen() {
  local label="$1" target="$2"
  ast_exec "python3 /loadgen/loadgen.py \
      --duration $DURATION --cps $CPS --iterations $ITERATIONS \
      --reload-period $RELOAD_PERIOD \
      --reload-stop-after $RELOAD_STOP_AFTER \
      --reload-target '$target' \
      --pg-host db --pg-user asterisk --pg-pass asterisk --pg-db asterisk \
      --label '$label'" \
    | tee "$HERE/$label.out"
}

apply_patches() {
  ast_exec "cd /asterisk-src && \
      git apply test-configs/odbc-reload-repro/patches/0001-*.patch \
                test-configs/odbc-reload-repro/patches/0002-*.patch \
                test-configs/odbc-reload-repro/patches/0003-*.patch \
                test-configs/odbc-reload-repro/patches/0004-*.patch && \
      /scripts/build-modules.sh"
}

revert_patches() {
  # All patches in this series modify res/res_odbc.c and/or
  # funcs/func_odbc.c. Revert both.
  ast_exec "cd /asterisk-src && \
      git checkout res/res_odbc.c funcs/func_odbc.c && \
      /scripts/build-modules.sh >/dev/null 2>&1 || true"
}

# Each scenario: <label>=<reload-target>
declare -a scenarios=(
  "all=          "        # bare 'module reload' = everything
  "res_odbc=res_odbc.so"
  "func_odbc=func_odbc.so"
)

step "bringing the stack up"
docker compose up -d

step "(re)building asterisk if needed"
ast_exec "/scripts/build-asterisk.sh"

# Make sure we start from a clean source tree.
revert_patches >/dev/null 2>&1 || true

for entry in "${scenarios[@]}"; do
  scenario="${entry%%=*}"
  target="${entry#*=}"
  target="${target##* }"  # trim leading spaces (for the empty case)
  target="${target%% *}"

  step "==== scenario: $scenario  (reload target: '${target:-EVERYTHING}') ===="

  step "BASELINE: $scenario"
  start_asterisk
  run_loadgen "baseline_${scenario}" "$target"
  stop_asterisk

  step "applying patches and rebuilding ODBC modules"
  apply_patches

  step "FIXED: $scenario"
  start_asterisk
  run_loadgen "fixed_${scenario}" "$target"
  stop_asterisk

  step "reverting patches"
  revert_patches
done

step "summary"
echo
echo "================================================================"
for entry in "${scenarios[@]}"; do
  scenario="${entry%%=*}"
  echo "--- scenario: $scenario ---"
  for variant in baseline fixed; do
    f="$HERE/${variant}_${scenario}.out"
    if [[ -f "$f" ]]; then
      grep -E '^(RESULT|POST_TAIL)' "$f" || true
    fi
  done
done
echo "================================================================"
echo
echo "raw output: $HERE/{baseline,fixed}_*.out"
