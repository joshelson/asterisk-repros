#!/usr/bin/env bash
# Run INSIDE the container. Rebuilds ONLY res_odbc.so + func_odbc.so
# after a patch change. Much faster than a full make.
set -euo pipefail
cd /asterisk-src

# Force a rebuild. Top-level Makefile drives per-dir builds.
rm -f res/res_odbc.o res/res_odbc.so \
      funcs/func_odbc.o funcs/func_odbc.so
make res
make funcs

# Install just those two.
install -m 0755 res/res_odbc.so   /usr/lib/asterisk/modules/
install -m 0755 funcs/func_odbc.so /usr/lib/asterisk/modules/

echo ">>> modules rebuilt + installed"
