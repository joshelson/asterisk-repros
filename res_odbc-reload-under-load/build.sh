#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

CFLAGS="-O2 -Wall -Wextra -Wno-unused-parameter -pthread"

build_variant() {
  local name="$1" delme="$2" realloc="$3"
  cc $CFLAGS \
     -DBUG_DELME_FILTER=$delme -DBUG_REALLOC_CLASSES=$realloc \
     -o "repro_${name}" repro.c
}

build_variant buggy        1 1   # both bugs
build_variant fix_delme    0 1   # only fix the delme filter
build_variant fix_preserve 1 0   # only fix the realloc/preserve logic
build_variant fix_both     0 0   # both fixes

ls -1 repro_*
