#!/usr/bin/env bash
# parse-golden.sh — run the comprehensive res_odbc.conf fixture through
# the loaded res_odbc module and surface every observable parser output
# (CLI dumps + parse-time log lines).
#
# Useful as a regression check for the aco-conversion PR: every parser
# branch in the legacy code is exercised by one or more sections in the
# fixture, and the WARNING/ERROR set the new parser produces should be
# equivalent in coverage to what the legacy parser emitted.
#
# This script reuses the docker compose stack from
# ../res_odbc-reload-under-load/docker/. Bring it up once and leave
# it running:
#
#   cd ../res_odbc-reload-under-load/docker && docker compose up -d
#
# Then from this directory:
#
#   ./scripts/parse-golden.sh <label>     # writes expected/<label>.snapshot
#
# Override REPRO_COMPOSE_DIR if your stack lives elsewhere.

set -euo pipefail

LABEL="${1:?usage: parse-golden.sh <label>}"
HERE="$(cd "$(dirname "$0")"/.. && pwd)"
REPRO_COMPOSE_DIR="${REPRO_COMPOSE_DIR:-$HERE/../res_odbc-reload-under-load/docker}"
GOLDEN_CONF_HOST="$HERE/conf/res_odbc.conf"

if [[ ! -d "$REPRO_COMPOSE_DIR" ]]; then
  echo "compose dir not found: $REPRO_COMPOSE_DIR" >&2
  exit 1
fi
if [[ ! -f "$GOLDEN_CONF_HOST" ]]; then
  echo "golden conf not found: $GOLDEN_CONF_HOST" >&2
  exit 1
fi

mkdir -p "$HERE/expected"

cd "$REPRO_COMPOSE_DIR"

ast_exec() { docker compose exec -T asterisk bash -lc "$*"; }

# /etc/asterisk inside the container is bind-mounted to the host's
# res_odbc-reload-under-load/asterisk-config/. Writing to it would
# corrupt the sibling reproducer's checked-in fixture, so save the
# existing conf to a host-side backup, swap in the golden conf, and
# restore on exit.
ORIG_CONF_BACKUP="$(mktemp -t res_odbc.conf.backup.XXXXXX)"
docker compose cp asterisk:/etc/asterisk/res_odbc.conf "$ORIG_CONF_BACKUP"
trap 'docker compose cp "$ORIG_CONF_BACKUP" asterisk:/etc/asterisk/res_odbc.conf >/dev/null 2>&1 || true; rm -f "$ORIG_CONF_BACKUP"; ast_exec "asterisk -rx '\''module reload res_odbc.so'\''" >/dev/null 2>&1 || true' EXIT

echo ">>> copying golden res_odbc.conf into container"
docker compose cp "$GOLDEN_CONF_HOST" asterisk:/etc/asterisk/res_odbc.conf

echo ">>> ensuring odbc.ini has a 'golden-pg' DSN aliased to the live DB"
ast_exec '
  if ! grep -q "^\[golden-pg\]" /etc/odbc.ini 2>/dev/null; then
    cat >> /etc/odbc.ini <<EOF

[golden-pg]
Description = Golden parser-test DSN (aliases asterisk-pg)
Driver      = PostgreSQL
Servername  = db
Server      = db
Port        = 5432
Database    = asterisk
Username    = asterisk
Password    = asterisk
EOF
  fi
'

echo ">>> truncating /var/log/asterisk/messages so we capture only this run"
ast_exec ': > /var/log/asterisk/messages'

echo ">>> reloading res_odbc with the golden config (load #1)"
ast_exec "asterisk -rx 'module reload res_odbc.so'"
sleep 1

echo ">>> capturing post-load #1 odbc-show output"
ast_exec "asterisk -rx 'odbc show all'" > "$HERE/expected/${LABEL}.show-all.load1.raw"

echo ">>> reloading a second time (verifies reload is idempotent)"
ast_exec "asterisk -rx 'module reload res_odbc.so'"
sleep 1

echo ">>> capturing post-load #2 odbc-show output"
ast_exec "asterisk -rx 'odbc show all'" > "$HERE/expected/${LABEL}.show-all.load2.raw"

echo ">>> dumping parse-time log lines (NOTICE/WARNING/ERROR from res_odbc + config_options)"
ast_exec "grep -E 'res_odbc\\.c|func_odbc\\.c|config_options\\.c|Registered ODBC|Adding ENV' /var/log/asterisk/messages" \
  > "$HERE/expected/${LABEL}.log.raw" || true

echo ">>> normalizing snapshot"
SNAPSHOT="$HERE/expected/${LABEL}.snapshot"
{
  echo "=== odbc show all (load #1) ==="
  # Strip volatile lines: connection counts depend on whether SQLConnect
  # succeeded, and the per-class log timestamp varies.
  sed -E \
    -e 's/Number of active connections: [0-9]+ \(out of /Number of active connections: <N> (out of /' \
    -e '/Last fail connection attempt:/d' \
    -e 's/Number of prepares executed: [0-9]+/Number of prepares executed: <N>/' \
    -e 's/Number of queries executed: [0-9]+/Number of queries executed: <N>/' \
    -e '/Longest running SQL query:/d' \
    "$HERE/expected/${LABEL}.show-all.load1.raw"

  echo
  echo "=== odbc show all (load #2) ==="
  sed -E \
    -e 's/Number of active connections: [0-9]+ \(out of /Number of active connections: <N> (out of /' \
    -e '/Last fail connection attempt:/d' \
    -e 's/Number of prepares executed: [0-9]+/Number of prepares executed: <N>/' \
    -e 's/Number of queries executed: [0-9]+/Number of queries executed: <N>/' \
    -e '/Longest running SQL query:/d' \
    "$HERE/expected/${LABEL}.show-all.load2.raw"

  echo
  echo "=== parse-time log lines (sorted, unique, source-stripped) ==="
  # Strip [timestamp] [PID] [levelTAG] thread@source:line: prefix down
  # to the bare message — sorted+uniqued so reload-cycle ordering noise
  # does not surface as snapshot diff.
  sed -E 's/^\[[^]]+\] [A-Z]+\[[0-9]+\][^:]*: //; s/^\[[^]]+\] *//' "$HERE/expected/${LABEL}.log.raw" \
    | sed -E 's/dsn->\[[^]]+\]/dsn->[<DSN>]/' \
    | sort -u
} > "$SNAPSHOT"

echo
echo ">>> snapshot written to $SNAPSHOT"
echo ">>> ($(wc -l < "$SNAPSHOT") lines)"
