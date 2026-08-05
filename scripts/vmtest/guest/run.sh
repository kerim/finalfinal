#!/bin/bash
# Runs INSIDE a disposable Tart guest clone, invoked by `vmtest run`'s
# `tart exec`. Copies the read-only checkout to guest APFS (never build on
# virtiofs), builds the web bundle, regenerates the Xcode project, and runs
# xcodebuild test with the given scope.
#
# Shares expected: "src" (checkout, read-only), "out" (results, writable).
#
# Usage: run.sh [-only-testing SPEC]...   (zero or more — empty means full
#                                           suite, exactly like xcodebuild)

set -uo pipefail

SRC="/Volumes/My Shared Files/src"
OUT="/Volumes/My Shared Files/out"
WORK="$HOME/work/final final"
export PATH="/opt/homebrew/bin:$PATH"

log() { printf '\n=== %s (%s) ===\n' "$1" "$(date +%H:%M:%S)"; }

# ---------------------------------------------------------------------------
# 1. Copy to guest APFS.
#
#    The exclude is `.git` with NO trailing slash. A superdev worktree's
#    `.git` is a FILE (containing `gitdir: <absolute host path>`), not a
#    directory — `.git/` would only match a directory and silently let the
#    worktree's `.git` file through, which then points at a path that does
#    not exist inside the guest.
# ---------------------------------------------------------------------------
log "copy checkout to guest APFS"
mkdir -p "$HOME/work"
rsync -a --delete \
  --exclude 'build/' --exclude 'releases/' --exclude '.worktrees/' \
  --exclude 'node_modules/' --exclude '.git' \
  "$SRC/" "$WORK/"
du -sh "$WORK"

cd "$WORK"

# ---------------------------------------------------------------------------
# 2. Web editor bundle.
#
#    `pnpm approve-builds --all` runs once at golden-image provision time
#    (see provision.sh) so esbuild's postinstall script — which downloads its
#    real platform binary — isn't skipped by pnpm's newer "ignored build
#    scripts" gate. It's re-run here too, defensively: this script has no
#    `-e`, so a silent web-bundle failure previously went unnoticed for
#    every run whose SOURCE checkout already had a stale-but-present
#    Resources/editor/ from earlier host-side work (main checkout) — a fresh
#    worktree has no such fallback, and Verification 4 caught it live: pnpm
#    build failed outright with no visible error, xcodegen only warned about
#    the missing directory instead of stopping, and the failure didn't
#    surface until xcodebuild's own build-phase script died minutes later.
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
# 3. Regenerate the Xcode project.
#
#    A worktree's build path can shell out to git (version stamping,
#    verify-scheme.sh); since the worktree's `.git` file points at an
#    absolute HOST path that does not exist in the guest, any such call would
#    fail — but only for worktree runs, never for the main checkout. This is
#    a known limitation of running a worktree in the VM; verify-scheme.sh's
#    output is checked below rather than assumed.
# ---------------------------------------------------------------------------
log "xcodegen"
if ! xcodegen generate; then
  echo "xcodegen generate failed — see output above." >&2
  exit 67
fi
if ! bash scripts/verify-scheme.sh; then
  echo "verify-scheme.sh failed — if this is a worktree run, check for a git"
  echo "invocation against the host-only worktree .git pointer." >&2
  exit 65
fi

# ---------------------------------------------------------------------------
# 4. xcodebuild test.
#
#    TEST_RUNNER_FF_E2E_SHOT_DIR, not FF_E2E_SHOT_DIR: screenshots are
#    written by test code in the XCUITest RUNNER process, and a variable
#    exported around xcodebuild does not propagate there. xcodebuild forwards
#    only TEST_RUNNER_-prefixed variables, stripping the prefix on arrival.
#    There is no .xctestplan, so there is no environmentVariableEntries
#    alternative either.
#
#    The value "e2e-shots" is deliberately RELATIVE, not an absolute /tmp
#    path — the runner is sandboxed and the POC found /tmp itself is not
#    writable from inside it (NSCocoaErrorDomain 513). E2EShotDir.path (in
#    UITestHelpers.swift) resolves a relative value against the runner's own
#    NSHomeDirectory() at runtime, landing in the one location the POC proved
#    writable: the xctrunner container's Data/e2e-shots.
# ---------------------------------------------------------------------------
log "xcodebuild test"
rm -rf "$OUT/TestRun.xcresult" 2>/dev/null

xcodebuild test \
  -scheme "final final" \
  -destination 'platform=macOS' \
  "$@" \
  -resultBundlePath "$OUT/TestRun.xcresult" \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
  TEST_RUNNER_FF_E2E_SHOT_DIR=e2e-shots \
  > "$OUT/xcodebuild.log" 2>&1
STATUS=$?

log "exit status: $STATUS"
tail -60 "$OUT/xcodebuild.log"
exit "$STATUS"
