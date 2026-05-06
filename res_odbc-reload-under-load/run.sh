#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

DURATION="${DURATION:-5}"

variants=(buggy fix_delme fix_preserve fix_both)

printf '\n%-15s %-7s %-12s %-15s %-13s %-15s %-15s\n' \
  variant reloads lookup_ok lookup_fail "lookup_fail%" pool_misses "pool_miss%"
printf '%s\n' '-------------------------------------------------------------------------------------------------------'

for v in "${variants[@]}"; do
  if [[ ! -x "./repro_$v" ]]; then
    echo "missing binary: ./repro_$v — run ./build.sh first" >&2
    exit 2
  fi
  out=$("./repro_$v" "$DURATION" 2>/dev/null)
  reloads=$(awk '{for (i=1;i<=NF;i++) if ($i ~ /^reloads=/) {sub(/.*=/,"",$i); print $i; exit}}' <<< "$out")
  lookup_ok=$(awk '{for (i=1;i<=NF;i++) if ($i ~ /^lookup_ok=/) {sub(/.*=/,"",$i); print $i; exit}}' <<< "$out")
  lookup_fail=$(awk '{for (i=1;i<=NF;i++) if ($i ~ /^lookup_fail=/) {sub(/.*=/,"",$i); print $i; exit}}' <<< "$out")
  lookup_fail_pct=$(awk '{for (i=1;i<=NF;i++) if ($i ~ /^lookup_fail_pct=/) {sub(/.*=/,"",$i); print $i; exit}}' <<< "$out")
  pool_misses=$(awk '{for (i=1;i<=NF;i++) if ($i ~ /^pool_misses=/) {sub(/.*=/,"",$i); print $i; exit}}' <<< "$out")
  pool_miss_pct=$(awk '{for (i=1;i<=NF;i++) if ($i ~ /^pool_miss_pct=/) {sub(/.*=/,"",$i); print $i; exit}}' <<< "$out")
  printf '%-15s %-7s %-12s %-15s %-13s %-15s %-15s\n' \
    "$v" "$reloads" "$lookup_ok" "$lookup_fail" "${lookup_fail_pct}%" \
    "$pool_misses" "${pool_miss_pct}%"
done

echo
echo "Legend:"
echo "  lookup_fail   = ast_odbc_request_obj() returned NULL ('Class not found')."
echo "                  Bug 2 = aoro2_class_cb skips delme=1 classes during reload."
echo "  pool_misses   = a request had to do a fresh fake-connect()."
echo "                  Bug 1 = reload always reallocates classes, dropping the pool."
