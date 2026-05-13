#!/usr/bin/env bash
# Run INSIDE the asterisk container. Builds asterisk from the
# bind-mounted /asterisk-src. Idempotent: skips configure+menuselect
# if a previous build already succeeded.
set -euo pipefail
cd /asterisk-src

if [[ ! -f .container-built ]]; then
  echo ">>> cleaning stale artifacts and reconfiguring"
  make distclean >/dev/null 2>&1 || true
  rm -f makeopts config.status config.log defaults.h \
        menuselect.makeopts menuselect-tree menuselect/menuselect \
        autoconfig.h 'autoconfig.h.in~'
  git checkout -- Makefile Makefile.rules Makefile.moddir_rules 2>/dev/null || true

  ./bootstrap.sh

  # No ODBC, no PJSIP, no pri — this bug is in the core only.
  ./configure \
    --without-asound --without-pri --without-misdn \
    --without-iodbc --without-unixodbc \
    --disable-xmldoc \
    CFLAGS="-O2"

  make menuselect.makeopts
  # Disable modules we don't need to keep the build fast.
  ./menuselect/menuselect \
    --disable chan_pjsip --disable res_pjsip \
    --disable res_odbc --disable func_odbc \
    --enable func_jitterbuffer \
    --enable res_timing_timerfd \
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
