#!/usr/bin/env bash
# Skeleton matrix runner. Replace with the actual scenarios for this repro.
set -euo pipefail
HERE="$(cd "$(dirname "$0")"/.. && pwd)"
cd "$HERE/docker"

echo "TODO: implement this repro's scenario matrix"
echo "  - bring up the stack: docker compose up -d"
echo "  - run buggy + patched variants"
echo "  - emit RESULT and POST_TAIL lines for each"
