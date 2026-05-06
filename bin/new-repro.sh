#!/usr/bin/env bash
# Scaffold a new bug reproducer from _template/.
#
# Usage:  bin/new-repro.sh <repro-name> [short description]
#
# Creates <repro-name>/ with the contents of _template/, substituting
# the placeholder __REPRO_NAME__ with the actual name in all files.
# Optional second argument is a one-line description that gets dropped
# into the new reproducer's README header.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
cd "$REPO_ROOT"

NAME="${1:-}"
DESC="${2:-One-line description of the bug.}"

if [[ -z "$NAME" ]]; then
  echo "usage: $(basename "$0") <repro-name> [\"short description\"]" >&2
  exit 2
fi
if [[ "$NAME" =~ [^a-z0-9_-] ]]; then
  echo "error: repro name must be lowercase letters, digits, _ and - only" >&2
  exit 2
fi
if [[ -e "$NAME" ]]; then
  echo "error: $NAME/ already exists" >&2
  exit 2
fi
if [[ ! -d _template ]]; then
  echo "error: _template/ not found; run from the repo root" >&2
  exit 2
fi

cp -r _template "$NAME"

# Substitute placeholders. Use a portable sed (works on BSD + GNU).
find "$NAME" -type f -print0 | while IFS= read -r -d '' f; do
  # Escape forward slashes in DESC for sed
  desc_esc=$(printf '%s' "$DESC" | sed 's:[\/&]:\\&:g')
  sed -i.bak \
    -e "s/__REPRO_NAME__/$NAME/g" \
    -e "s/__REPRO_DESC__/$desc_esc/g" \
    "$f"
  rm -f "${f}.bak"
done

# Make scripts executable.
chmod +x "$NAME"/scripts/*.sh "$NAME"/build*.sh "$NAME"/run*.sh 2>/dev/null || true

cat <<EOF

Created $NAME/ from _template/.

Next steps:
  1. Edit $NAME/README.md to describe the bug, its trigger, and the
     expected output.
  2. Customize $NAME/asterisk-config/ for whatever modules and config
     this bug needs.
  3. Customize $NAME/sql/init.sql with the schemas + seed data.
  4. Customize $NAME/loadgen/loadgen.py with the load profile and the
     UserEvent fields your dialplan emits.
  5. Customize $NAME/scripts/run-matrix.sh with the scenarios you want.
  6. Add an entry to the top-level README.md under "Reproducers".
  7. Commit.

  cd $NAME && git add . && git commit -m "Add reproducer: $NAME"
EOF
