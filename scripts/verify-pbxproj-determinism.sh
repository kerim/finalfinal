#!/bin/bash
#
# verify-pbxproj-determinism.sh — Golden-guard for xcodegen's project.pbxproj output
#
# WHAT THIS GUARDS
# xcodegen regenerates "final final.xcodeproj/project.pbxproj" from project.yml
# on every `xcodegen generate`. On 2026-07-04 two back-to-back commits each
# fired the pre-commit hook's regen: the first regen ADDED 148 lines (individual
# PBXBuildFile/PBXFileReference/Resources entries for files that physically live
# inside folder-referenced bundles), and the very next regen — with ZERO
# intervening source or project.yml changes — DELETED those same 148 lines.
# i.e. `xcodegen generate` was observed to be NON-deterministic for a fixed
# project.yml + filesystem.
#
# WHY A RUNTIME GUARD (not a source fix)
# The reshuffle originates inside XcodeGen 2.45.4 itself: the flat Resources
# build-phase file list (PBXProjGenerator.getBuildFilesForPhase) is written in
# FileManager.contentsOfDirectory enumeration order and is NEVER sorted (unlike
# the navigator group tree, which sortGroups() does sort). We will not
# vendor/patch XcodeGen for this repo. Instead we detect churn at commit time
# and refuse to let a spurious (or real-but-unreviewed) pbxproj diff slip into a
# commit silently. This guard does NOT hide or revert a diff — masking a real
# diff is explicitly forbidden.
#
# HONEST STATE OF THE INVESTIGATION (2026-07-05)
# CONFIRMED: (1) a real structural double-declaration of `final finalTests/Fixtures`
#   across the final finalTests + final finalUITests targets was fixed in
#   project.yml (excludes: ["Fixtures"]); (2) the unsorted-Resources-list
#   mechanism exists in XcodeGen 2.45.4 source.
# UNCONFIRMED: the exact trigger for the original getting-started.ff churn on
#   2026-07-04 was never reproduced on demand (30 consecutive regens were
#   byte-identical). This guard catches the CLASS of bug (regen non-determinism)
#   regardless of the exact trigger, at commit/build time.
# See wiki: projects/final-final/skills/xcodegen-workflow.md
#           (section "A second, distinct oscillation").
#
# Usage: bash scripts/verify-pbxproj-determinism.sh
# Exit 0 + "pbxproj deterministic OK" on success.
# Exit 1 + the churn diff on mismatch.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PBXPROJ="$PROJECT_DIR/final final.xcodeproj/project.pbxproj"

# Mirror the pre-commit hook's defensive check: if xcodegen isn't installed
# there is nothing to verify — skip rather than fail (the hook wraps its own
# `xcodegen generate` in `command -v xcodegen`).
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "verify-pbxproj-determinism: xcodegen not installed — skipping."
  exit 0
fi

if [ ! -f "$PBXPROJ" ]; then
  echo "error: $PBXPROJ not found — run 'xcodegen generate' first." >&2
  exit 1
fi

SNAPSHOT="$(mktemp -t pbxproj-determinism)"
trap 'rm -f "$SNAPSHOT"' EXIT

# Snapshot the first-regen output (already on disk from the caller's generate).
cp "$PBXPROJ" "$SNAPSHOT"

# Second regen — must reproduce the first byte-for-byte.
cd "$PROJECT_DIR"
xcodegen generate >/dev/null 2>&1 || {
  echo "error: 'xcodegen generate' failed inside the determinism guard." >&2
  exit 1
}

if ! diff -q "$SNAPSHOT" "$PBXPROJ" >/dev/null 2>&1; then
  {
    echo ""
    echo "========================================================================="
    echo "  pbxproj NON-DETERMINISM DETECTED — commit aborted."
    echo ""
    echo "  Two consecutive 'xcodegen generate' runs produced different"
    echo "  project.pbxproj output with no intervening changes. This is the"
    echo "  xcodegen Resources-build-phase ordering bug (XcodeGen 2.45.4)."
    echo ""
    echo "  Do NOT just re-commit until it 'settles' — investigate first."
    echo "  Likely cause: a directory reachable two ways across targets in"
    echo "  project.yml. Add an 'excludes:' to the recursive source, mirroring"
    echo "  the 'final final' target's Resources/* excludes."
    echo "  See wiki: projects/final-final/skills/xcodegen-workflow.md"
    echo "            (section 'A second, distinct oscillation')."
    echo ""
    echo "  Churn (first regen [-] vs second regen [+]):"
    echo "-------------------------------------------------------------------------"
    diff -u "$SNAPSHOT" "$PBXPROJ" || true
    echo "========================================================================="
  } >&2
  exit 1
fi

echo "pbxproj deterministic OK — two consecutive regens byte-identical."
