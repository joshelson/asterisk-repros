#!/usr/bin/env bash
# Run the buggy/patched scenario matrix for this reproducer.
#
# Customize the `scenarios` array, the `apply_patches` / `revert_patches`
# functions, and the loadgen flags below for what your bug needs.
set -euo pipefail
HERE="$(cd "$(dirname "$0")"/.. && pwd)"
cd "$HERE/docker"

DURATION="${DURATION:-25}"
RELOAD_STOP_AFTER="${RELOAD_STOP_AFTER:-18}"
CPS="${CPS:-8}"
ITERATIONS="${ITERATIONS:-1500}"
RELOAD_PERIOD="${RELOAD_PERIOD:-1.0}"

# Where the upstream patches live, INSIDE the asterisk source tree
# (which is bind-mounted at /asterisk-src). Override if you've placed
# them elsewhere; set to empty to skip the patched runs entirely.
PATCHES_DIR_IN_CONTAINER="${PATCHES_DIR_IN_CONTAINER:-/asterisk-src/test-configs/__REPRO_NAME__/patches}"

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
  # Customize the file list to match what your patches touch.
  ast_exec "cd /asterisk-src && \
      git checkout res/ funcs/ configs/ 2>&1 | head -3 && \
      git apply $PATCHES_DIR_IN_CONTAINER/*.patch && \
      /scripts/build-modules.sh 2>&1 | tail -3"
}

revert_patches() {
  ast_exec "cd /asterisk-src && \
      git checkout res/ funcs/ configs/ && \
      /scripts/build-modules.sh 2>&1 | tail -3"
}

run_one() {
  local label="$1" target="$2"
  ast_exec "python3 /loadgen/loadgen.py \
      --duration $DURATION --cps $CPS --iterations $ITERATIONS \
      --reload-period $RELOAD_PERIOD --reload-stop-after $RELOAD_STOP_AFTER \
      --reload-target '$target' --context '__REPRO_NAME__-loop' \
      --pg-host db --pg-user asterisk --pg-pass asterisk --pg-db asterisk \
      --label '$label'" \
    > "$HERE/$label.out" 2>&1 || true
}

# Customize: the scenarios you want to run.  Each entry is <name>=<reload-target>.
declare -a scenarios=(
  "all="               # bare 'module reload' = everything
)

step "BUGGY: revert patches and rebuild"
revert_patches

for entry in "${scenarios[@]}"; do
  scenario="${entry%%=*}"
  target="${entry#*=}"
  label="buggy_${scenario}"
  step "$label  (reload-target='${target:-EVERYTHING}')"
  start_asterisk
  run_one "$label" "$target"
  grep -E '^(RESULT|POST_TAIL)' "$HERE/$label.out" || true
  stop_asterisk
done

step "PATCHED: apply patches and rebuild"
apply_patches

for entry in "${scenarios[@]}"; do
  scenario="${entry%%=*}"
  target="${entry#*=}"
  label="patched_${scenario}"
  step "$label  (reload-target='${target:-EVERYTHING}')"
  start_asterisk
  run_one "$label" "$target"
  grep -E '^(RESULT|POST_TAIL)' "$HERE/$label.out" || true
  stop_asterisk
done

step "Reverting patches in source tree"
revert_patches >/dev/null

step "SUMMARY"
echo
printf '%-45s | %-7s | %-7s | %-7s\n' label reloads fail fail%
printf -- '----------------------------------------------------------------------\n'
for f in "$HERE"/buggy_*.out "$HERE"/patched_*.out; do
  [[ -f "$f" ]] || continue
  label=$(basename "$f" .out)
  line=$(grep '^RESULT' "$f" | head -1)
  reloads=$(echo "$line" | sed -nE 's/.*reloads=([0-9]+).*/\1/p')
  fail=$(echo "$line" | sed -nE 's/.*fail=([0-9]+).*/\1/p')
  failpct=$(echo "$line" | sed -nE 's/.*fail_pct=([0-9.]+).*/\1/p')
  printf '%-45s | %-7s | %-7s | %-7s\n' "$label" "$reloads" "$fail" "${failpct}%"
done
echo
echo "Tail (post-reload-stop) failures:"
for f in "$HERE"/buggy_*.out "$HERE"/patched_*.out; do
  [[ -f "$f" ]] || continue
  label=$(basename "$f" .out)
  line=$(grep '^POST_TAIL' "$f" | head -1)
  fail=$(echo "$line" | sed -nE 's/.*fail=([0-9]+).*/\1/p')
  failpct=$(echo "$line" | sed -nE 's/.*fail_pct=([0-9.]+).*/\1/p')
  printf '  %-43s fail=%-7s pct=%-7s\n' "$label" "$fail" "${failpct}%"
done
