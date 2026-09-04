#!/bin/bash
#
# e2e-hygiene.sh — merge-gate hygiene check for the UI test suite.
#
# Two checks, both against $BASE (default: main):
#   1. The sleep ratchet (scripts/e2e-lint.py --ratchet) — no permanent
#      test file may gain a fixed-wait hit above its baseline.
#   2. A new-file cap — this branch may add at most one new permanent
#      *.swift file directly under final finalUITests/, unless a commit in
#      the range carries the trailer `e2e-cap: allow` in its body.
#
# The cap exists because one task should mean one new e2e file at most
# (the "scratch test is evidence, one new permanent file per task" rule —
# see superdev-skill/PIPELINE.md and .claude/skills/e2e-verify/SKILL.md).
# More than that from a single branch is usually a sign the task should
# have been split, or that scratch content is being committed permanently
# instead of being torn back down.
#
# Usage: scripts/e2e-hygiene.sh [--base REF]
# Exit: 0 = clean, 2 = a check failed (name printed).
#

set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASE="main"

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    *) echo "e2e-hygiene.sh: unknown option: $1" >&2; exit 2 ;;
  esac
done

cd "$PROJECT_DIR"

status=0

echo "e2e-hygiene: checking sleep ratchet..."
if ! python3 scripts/e2e-lint.py --ratchet; then
  status=2
fi

echo ""
echo "e2e-hygiene: checking new-file cap vs $BASE..."
# Only *.swift files directly under the UI test dir, added (not modified)
# relative to $BASE. `--diff-filter=A` — added only, so a rename or an edit
# to an existing file never counts against the cap.
NEW_FILES="$(git diff --name-only --diff-filter=A "$BASE"...HEAD -- 'final finalUITests/*.swift' 2>/dev/null)"
NEW_COUNT=0
if [ -n "$NEW_FILES" ]; then
  NEW_COUNT="$(printf '%s\n' "$NEW_FILES" | grep -c .)"
fi

if [ "$NEW_COUNT" -gt 1 ]; then
  if git log "$BASE"..HEAD --format=%B 2>/dev/null | grep -qF "e2e-cap: allow"; then
    echo "e2e-hygiene: $NEW_COUNT new UI test files vs $BASE, but a commit carries 'e2e-cap: allow' — admitted."
  else
    echo "e2e-hygiene: $NEW_COUNT new UI test files vs $BASE (cap is 1):"
    printf '%s\n' "$NEW_FILES" | sed 's/^/  /'
    echo "e2e-hygiene: one task should add at most one new permanent e2e file. If this is deliberate, add a trailer 'e2e-cap: allow' to a commit in this range."
    status=2
  fi
else
  echo "e2e-hygiene: $NEW_COUNT new UI test file(s) vs $BASE — within cap."
fi

exit "$status"
