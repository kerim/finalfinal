#!/bin/bash
# final final's in-guest prep, run by the shared vmtest engine's guest
# runner from the copied checkout root, before xcodebuild. Extracted
# verbatim from the pre-relocation guest/run.sh — exit codes preserved
# (66 web bundle, 67 xcodegen).

set -uo pipefail

WORK="$(pwd)"
export PATH="/opt/homebrew/bin:$PATH"

log() { printf '\n=== %s (%s) ===\n' "$1" "$(date +%H:%M:%S)"; }

# ---------------------------------------------------------------------------
# Web editor bundle.
#
# `pnpm approve-builds --all` runs once at golden-image provision time (see
# provision-warm.sh) so esbuild's postinstall script — which downloads its
# real platform binary — isn't skipped by pnpm's newer "ignored build
# scripts" gate. It's re-run here too, defensively: a silent web-bundle
# failure previously went unnoticed for every run whose SOURCE checkout
# already had a stale-but-present Resources/editor/ from earlier host-side
# work — a fresh worktree has no such fallback, and Verification 4 caught it
# live: pnpm build failed with no visible error, xcodegen only warned about
# the missing directory, and the failure didn't surface until xcodebuild's
# own build-phase script died minutes later.
# ---------------------------------------------------------------------------
log "web bundle"
cd web
pnpm install --frozen-lockfile
pnpm approve-builds --all >/dev/null 2>&1 || true
if ! pnpm build; then
  echo "pnpm build failed — see output above. Not continuing to xcodegen/xcodebuild" >&2
  echo "with a missing or stale web bundle." >&2
  exit 66
fi
cd "$WORK"

# ---------------------------------------------------------------------------
# Regenerate the Xcode project.
# ---------------------------------------------------------------------------
log "xcodegen"
if ! xcodegen generate; then
  echo "xcodegen generate failed — see output above." >&2
  exit 67
fi
