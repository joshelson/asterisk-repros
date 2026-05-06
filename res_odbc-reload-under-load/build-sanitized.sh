#!/usr/bin/env bash
# Builds the reproducer under TSan + ASan separately. If the proof of
# patch 1's safety is correct, both should run for the full duration
# without reporting any data races, use-after-free, or leaks.
set -euo pipefail
cd "$(dirname "$0")"

build_one() {
  local sanflag="$1" out="$2" delme="$3" realloc="$4"
  cc -O1 -g -Wall -Wextra -Wno-unused-parameter -pthread \
     $sanflag \
     -DBUG_DELME_FILTER=$delme -DBUG_REALLOC_CLASSES=$realloc \
     -o "$out" repro.c
}

build_one "-fsanitize=thread"             repro_tsan_buggy    1 1
build_one "-fsanitize=thread"             repro_tsan_fixed    0 0
build_one "-fsanitize=address,leak"       repro_asan_fixed    0 0 || \
  build_one "-fsanitize=address"          repro_asan_fixed    0 0  # macOS may not have lsan

ls -1 repro_tsan_* repro_asan_*
