#!/usr/bin/env bash
# Run the full scenario matrix:
#   variants: buggy, patched
#   contexts: odbc-loop, realtime-loop
#   reload targets: res_odbc.so, func_odbc.so, '' (= module reload all)
#
# 12 runs total. Each run is `DURATION` seconds (default 25), with reloads
# fired every RELOAD_PERIOD (default 1.0s) for the first RELOAD_STOP_AFTER
# (default 18s) seconds, then observation only for the remainder.
set -euo pipefail
HERE="$(cd "$(dirname "$0")"/.. && pwd)"
cd "$HERE/docker"

DURATION="${DURATION:-25}"
RELOAD_STOP_AFTER="${RELOAD_STOP_AFTER:-18}"
CPS="${CPS:-8}"
ITERATIONS="${ITERATIONS:-1500}"
RELOAD_PERIOD="${RELOAD_PERIOD:-1.0}"

# Where the upstream patches live, INSIDE the asterisk source tree
# (which is bind-mounted into the container at /asterisk-src). Override
# if you've placed the patch series elsewhere. Default assumes the
# patches are in a sibling test-configs directory of the asterisk repo;
# set to empty to skip the patched runs entirely.
PATCHES_DIR_IN_CONTAINER="${PATCHES_DIR_IN_CONTAINER:-/asterisk-src/test-configs/odbc-reload-repro/patches}"

ast_exec() { docker compose exec -T asterisk bash -lc "$*"; }
step()     { printf '\n\033[1;36m>>> %s\033[0m\n' "$*"; }

start_asterisk() {
  ast_exec "pkill -9 asterisk 2>/dev/null || true"
  ast_exec "rm -f /var/run/asterisk/asterisk.ctl /var/log/asterisk/full /var/log/asterisk/messages 2>/dev/null || true"
  docker compose exec -d asterisk /scripts/run-asterisk.sh
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

apply_patches() {
  if [[ -z "$PATCHES_DIR_IN_CONTAINER" ]]; then
    echo "PATCHES_DIR_IN_CONTAINER is empty; skipping patched-run setup" >&2
    return 0
  fi
  ast_exec "cd /asterisk-src && \
      git checkout res/res_odbc.c funcs/func_odbc.c configs/samples/res_odbc.conf.sample 2>&1 | head -3 && \
      git apply $PATCHES_DIR_IN_CONTAINER/0001-*.patch \
                $PATCHES_DIR_IN_CONTAINER/0002-*.patch \
                $PATCHES_DIR_IN_CONTAINER/0003-*.patch \
                $PATCHES_DIR_IN_CONTAINER/0004-*.patch \
                $PATCHES_DIR_IN_CONTAINER/0005-*.patch && \
      /scripts/build-modules.sh 2>&1 | tail -3"
}

revert_patches() {
  ast_exec "cd /asterisk-src && \
      git checkout res/res_odbc.c funcs/func_odbc.c configs/samples/res_odbc.conf.sample && \
      /scripts/build-modules.sh 2>&1 | tail -3"
}

run_one() {
  local label="$1" context="$2" target="$3"
  ast_exec "python3 /loadgen/loadgen.py \
      --duration $DURATION --cps $CPS --iterations $ITERATIONS \
      --reload-period $RELOAD_PERIOD --reload-stop-after $RELOAD_STOP_AFTER \
      --reload-target '$target' --context '$context' \
      --pg-host db --pg-user asterisk --pg-pass asterisk --pg-db asterisk \
      --label '$label'" \
    > "$HERE/$label.out" 2>&1
}

# Scenarios: <name>=<reload-target>
declare -a scenarios=(
  "resodbc=res_odbc.so"
  "funcodbc=func_odbc.so"
  "all="
)
declare -a contexts=(odbc-loop realtime-loop)

step "BUGGY: revert patches and rebuild"
revert_patches

for ctx in "${contexts[@]}"; do
  for entry in "${scenarios[@]}"; do
    scenario="${entry%%=*}"
    target="${entry#*=}"
    label="buggy_${ctx//-/_}_${scenario}"
    step "$label  (context=$ctx, reload-target='${target:-EVERYTHING}')"
    start_asterisk
    run_one "$label" "$ctx" "$target"
    grep -E '^(RESULT|POST_TAIL)' "$HERE/$label.out" || true
    stop_asterisk
  done
done

step "PATCHED: apply 5 patches and rebuild"
apply_patches

for ctx in "${contexts[@]}"; do
  for entry in "${scenarios[@]}"; do
    scenario="${entry%%=*}"
    target="${entry#*=}"
    label="patched_${ctx//-/_}_${scenario}"
    step "$label  (context=$ctx, reload-target='${target:-EVERYTHING}')"
    start_asterisk
    run_one "$label" "$ctx" "$target"
    grep -E '^(RESULT|POST_TAIL)' "$HERE/$label.out" || true
    stop_asterisk
  done
done

step "Reverting patches in source tree"
revert_patches >/dev/null

step "SUMMARY"
echo
printf '%-45s | %-7s | %-12s | %-7s | %-7s | %-7s\n' label reloads originates ok fail fail%
printf -- '------------------------------------------------------------------------------------------------------\n'
for f in "$HERE"/buggy_*.out "$HERE"/patched_*.out; do
  [[ -f "$f" ]] || continue
  label=$(basename "$f" .out)
  line=$(grep '^RESULT' "$f" | head -1)
  reloads=$(echo "$line" | sed -nE 's/.*reloads=([0-9]+).*/\1/p')
  originates=$(echo "$line" | sed -nE 's/.*originates=([0-9]+).*/\1/p')
  ok=$(echo "$line" | sed -nE 's/.*\bok=([0-9]+).*/\1/p')
  fail=$(echo "$line" | sed -nE 's/.*fail=([0-9]+).*/\1/p')
  failpct=$(echo "$line" | sed -nE 's/.*fail_pct=([0-9.]+).*/\1/p')
  printf '%-45s | %-7s | %-12s | %-7s | %-7s | %-7s\n' "$label" "$reloads" "$originates" "$ok" "$fail" "${failpct}%"
done
echo
echo "Tail (post-reload-stop) failures:"
for f in "$HERE"/buggy_*.out "$HERE"/patched_*.out; do
  [[ -f "$f" ]] || continue
  label=$(basename "$f" .out)
  line=$(grep '^POST_TAIL' "$f" | head -1)
  ok=$(echo "$line" | sed -nE 's/.*\bok=([0-9]+).*/\1/p')
  fail=$(echo "$line" | sed -nE 's/.*fail=([0-9]+).*/\1/p')
  failpct=$(echo "$line" | sed -nE 's/.*fail_pct=([0-9.]+).*/\1/p')
  printf '  %-43s ok=%-7s fail=%-7s pct=%-7s\n' "$label" "$ok" "$fail" "${failpct}%"
done
