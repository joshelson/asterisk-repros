#!/usr/bin/env bash
# Run INSIDE the asterisk container. Builds asterisk from the
# bind-mounted /asterisk-src. Idempotent: skips configure if a
# previous successful build exists.
set -euo pipefail
cd /asterisk-src

if [[ ! -f .container-built ]]; then
  echo ">>> cleaning stale build artifacts and reconfiguring"
  make distclean >/dev/null 2>&1 || true
  rm -f makeopts config.status config.log defaults.h \
        menuselect.makeopts menuselect-tree menuselect/menuselect \
        autoconfig.h 'autoconfig.h.in~'
  git checkout -- Makefile Makefile.rules Makefile.moddir_rules 2>/dev/null || true
  echo ">>> running ./bootstrap.sh"
  ./bootstrap.sh
  echo ">>> running ./configure"
  ./configure --without-asound --without-pri --without-misdn \
    --without-iodbc --with-unixodbc \
    --disable-xmldoc CFLAGS="-O2"
  echo ">>> menuselect: enabling commonly-needed modules"
  make menuselect.makeopts
  ./menuselect/menuselect \
    --enable res_odbc --enable func_odbc \
    --enable res_odbc_transaction --enable chan_pjsip --enable res_pjsip \
    menuselect.makeopts || true
fi

echo ">>> make -j$(nproc) all"
make -j"$(nproc)" all

echo ">>> make install"
make install

if [[ ! -d /var/lib/asterisk/sounds ]]; then
  make samples 2>/dev/null || true
fi

touch .container-built
echo ">>> build done"
