#!/usr/bin/env bash
# Run INSIDE the asterisk container. Rebuilds the modules affected by
# this reproducer's bug (edit the lists below). Much faster than a
# full make.
set -euo pipefail
cd /asterisk-src

# ----------------------------------------------------------------
# Customize: list the source files that have been edited (so we can
# force-rebuild them) and the .so artifacts to install.
# ----------------------------------------------------------------
SRC_FILES=( res/res_odbc.c funcs/func_odbc.c )
MODULE_DIRS=( res funcs )
MODULE_SOS=( res/res_odbc.so funcs/func_odbc.so )
# ----------------------------------------------------------------

# Force a rebuild — source mtimes after `git apply` may not be newer
# than the .so on the host filesystem.
for f in "${SRC_FILES[@]}"; do
  [[ -f "$f" ]] && rm -f "${f%.*}.o"
done
for so in "${MODULE_SOS[@]}"; do
  rm -f "$so"
done

for d in "${MODULE_DIRS[@]}"; do
  make "$d"
done

for so in "${MODULE_SOS[@]}"; do
  install -m 0755 "$so" /usr/lib/asterisk/modules/
done

echo ">>> modules rebuilt + installed"
