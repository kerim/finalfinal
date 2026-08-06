#!/bin/bash
# final final's in-guest prep, run by the shared vmtest engine's guest
# runner from the copied checkout root, before xcodebuild. Extracted
# verbatim from the pre-relocation guest/run.sh — exit codes preserved
# (66 web bundle, 67 xcodegen, 65 scheme verification).

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
#
# A worktree's build path can shell out to git (version stamping,
# verify-scheme.sh); since the worktree's `.git` file points at an absolute
# HOST path that does not exist in the guest, any such call would fail — but
# only for worktree runs, never for the main checkout. This is a known
# limitation of running a worktree in the VM; verify-scheme.sh's output is
# checked below rather than assumed.
# ---------------------------------------------------------------------------
log "xcodegen"
if ! xcodegen generate; then
  echo "xcodegen generate failed — see output above." >&2
  exit 67
fi
if ! bash scripts/verify-scheme.sh; then
  echo "verify-scheme.sh failed — if this is a worktree run, check for a git" >&2
  echo "invocation against the host-only worktree .git pointer." >&2
  exit 65
fi
