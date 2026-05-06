#!/usr/bin/env bash
# Start asterisk in the foreground inside the container.
set -euo pipefail
exec /usr/sbin/asterisk -fvvg -C /etc/asterisk/asterisk.conf
