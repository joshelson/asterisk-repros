#!/usr/bin/env bash
# Run INSIDE the asterisk container. Builds asterisk + the two ODBC
# modules from the mounted /asterisk-src.
#
# Note: this discards any host-side ./configure artifacts because the
# host (macOS) cannot build asterisk; the artifacts in the source tree
# from a prior linux configure may also be stale. We mark a successful
# build with .container-built so subsequent runs skip configure.
set -euo pipefail
cd /asterisk-src

if [[ ! -f .container-built ]]; then
  echo ">>> cleaning stale build artifacts and reconfiguring"
  # Best-effort distclean (may fail if Makefile is unusable; that's OK).
  make distclean >/dev/null 2>&1 || true
  # Only remove genuinely-generated files. Makefile, Makefile.rules,
  # etc. are checked into git and must NOT be deleted.
  rm -f makeopts config.status config.log defaults.h \
        menuselect.makeopts menuselect-tree menuselect/menuselect \
        autoconfig.h 'autoconfig.h.in~'
  # Restore Makefile if a previous bad build deleted it.
  git checkout -- Makefile Makefile.rules Makefile.moddir_rules 2>/dev/null || true
  echo ">>> running ./bootstrap.sh"
  ./bootstrap.sh
  echo ">>> running ./configure"
  ./configure --without-asound --without-pri --without-misdn \
    --without-iodbc --with-unixodbc \
    --enable-dev-mode \
    CFLAGS="-O2"
  echo ">>> menuselect: enabling res_odbc + func_odbc + chan_pjsip + TEST_FRAMEWORK"
  make menuselect.makeopts
  ./menuselect/menuselect \
    --enable res_odbc --enable func_odbc \
    --enable res_odbc_transaction --enable chan_pjsip --enable res_pjsip \
    --enable TEST_FRAMEWORK \
    --enable test_res_odbc \
    menuselect.makeopts || true
fi

echo ">>> make -j$(nproc) all"
make -j"$(nproc)" all

echo ">>> make install"
make install

# Don't replace our test configs (they're bind-mounted at /etc/asterisk)
# but DO populate /var/lib/asterisk and similar.
if [[ ! -d /var/lib/asterisk/sounds ]]; then
  make samples 2>/dev/null || true
fi

touch .container-built
echo ">>> build done"
