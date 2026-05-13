#!/usr/bin/env bash
# Run the buggy/patched matrix for the jitterbuffer-disable-bridgewait reproducer.
#
# Two JB scenarios are tested: adaptive and fixed.
# Primary metric: peak_cpu / high_cpu_pct (thread CPU during the spin window).
# Secondary metric: fail_pct (calls that don't emit UserEvent in time).
#
# BUGGY  → any thread at 100% CPU, calls time out.
# PATCHED → threads sleep normally, calls complete on schedule.
set -euo pipefail
HERE="$(cd "$(dirname "$0")"/.. && pwd)"
cd "$HERE/docker"

# Tunables
DURATION="${DURATION:-40}"          # total seconds per run
INJECT_STOP="${INJECT_STOP:-10}"    # stop originating after this many seconds
CPS="${CPS:-4}"                     # originates/second (40 total at defaults)

ast_exec() { docker compose exec -T asterisk bash -lc "$*"; }
step()     { printf '\n\033[1;36m>>> %s\033[0m\n' "$*"; }

start_asterisk() {
  ast_exec "pkill -9 asterisk 2>/dev/null || true"
  ast_exec "rm -f /var/run/asterisk/asterisk.ctl \
                  /var/log/asterisk/full \
                  /var/log/asterisk/messages 2>/dev/null || true"
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

# Patches are stored in the reproducer's patches/ dir and mounted at /patches
# inside the container.
apply_patches() {
  ast_exec "cd /asterisk-src && \
      git checkout main/abstract_jb.c 2>&1 | head -2 && \
      git apply /patches/fix-jb-fd-on-disable.patch && \
      /scripts/build-modules.sh 2>&1 | tail -3"
}

revert_patches() {
  ast_exec "cd /asterisk-src && \
      git checkout main/abstract_jb.c && \
      /scripts/build-modules.sh 2>&1 | tail -3"
}

run_one() {
  local label="$1" jb_type="$2" wait_type="$3"
  ast_exec "python3 /loadgen/loadgen.py \
      --duration $DURATION \
      --inject-stop-after $INJECT_STOP \
      --cps $CPS \
      --jb-type '$jb_type' \
      --wait-type '$wait_type' \
      --label '$label'" \
    > "$HERE/$label.out" 2>&1 || true
}

# Scenarios: every combination of (adaptive|fixed) × (wait|bridgewait)
declare -a jb_types=( adaptive fixed )
declare -a wait_types=( wait bridgewait )

run_phase() {
  local phase="$1"
  for jb_type in "${jb_types[@]}"; do
    for wait_type in "${wait_types[@]}"; do
      label="${phase}_${jb_type}_${wait_type}"
      step "$label"
      start_asterisk
      run_one "$label" "$jb_type" "$wait_type"
      grep -E '^(RESULT|POST_TAIL)' "$HERE/$label.out" || true
      stop_asterisk
    done
  done
}

# ── BUGGY ──────────────────────────────────────────────────────────────
step "BUGGY: reverting to unpatched abstract_jb.c"
revert_patches
run_phase buggy

# ── PATCHED ────────────────────────────────────────────────────────────
step "PATCHED: applying fix-jb-fd-on-disable.patch"
apply_patches
run_phase patched

step "Reverting patch in source tree"
revert_patches >/dev/null

# ── SUMMARY ────────────────────────────────────────────────────────────
step "SUMMARY"
echo
printf '%-35s | %-7s | %-7s | %-10s | %-10s\n' \
    label fail% peak_cpu high_cpu% post_hcpu%
printf -- '%-35s-+-%-7s-+-%-7s-+-%-10s-+-%-10s\n' \
    "-----------------------------------" "-------" "-------" "----------" "----------"

for f in "$HERE"/buggy_*.out "$HERE"/patched_*.out; do
  [[ -f "$f" ]] || continue
  label=$(basename "$f" .out)
  line=$(grep '^RESULT' "$f" | head -1)
  failpct=$(echo "$line"   | sed -nE 's/.*fail_pct=([0-9.]+).*/\1/p')
  peak=$(echo "$line"      | sed -nE 's/.*peak_cpu=([0-9.]+).*/\1/p')
  high=$(echo "$line"      | sed -nE 's/.*high_cpu_pct=([0-9.]+).*/\1/p')
  ptail=$(grep '^POST_TAIL' "$f" | head -1 | sed -nE 's/.*post_high_cpu_pct=([0-9.]+).*/\1/p')
  printf '%-35s | %-7s | %-7s | %-10s | %-10s\n' \
      "$label" "${failpct:--}%" "${peak:--}%" "${high:--}%" "${ptail:--}%"
done
echo
echo "Smoking gun: peak_cpu > 100% (buggy) vs single-digit % (patched)."
echo "fail_pct stays low at default tunables on multi-core hosts; raise CPS"
echo "or run on a small VM to also see call-completion failures."
