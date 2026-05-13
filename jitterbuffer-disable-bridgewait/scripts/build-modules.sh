#!/usr/bin/env bash
# Run INSIDE the asterisk container. Rebuilds just main/abstract_jb.c
# (which compiles into the asterisk binary, not a loadable module).
# Much faster than a full make for patch/revert cycles.
set -euo pipefail
cd /asterisk-src

# Force the object file to be considered stale regardless of mtime.
rm -f main/abstract_jb.o

echo ">>> rebuilding main/ and relinking asterisk binary"
make -j"$(nproc)" main
make install

echo ">>> abstract_jb rebuilt + installed"
