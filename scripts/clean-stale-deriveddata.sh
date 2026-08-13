#!/bin/bash
#
# clean-stale-deriveddata.sh — Remove old DerivedData directories that cause
# duplicate QuickLook extension registrations.
#
# Runs as a buildScript on the GitStamp aggregate target in project.yml
# (moved off the app target's preBuildScripts when
# ENABLE_USER_SCRIPT_SANDBOXING went on — this script's `rm -rf` and
# directory scanning outside SRCROOT/DERIVED_DATA can't be expressed as
# declared build-script inputs/outputs, but GitStamp is deliberately exempt
# from sandboxing already and runs on every build, so it's a natural home).
#
# Each `xcodegen generate` run produces a new project file hash, so Xcode
# gives it a new `final_final-<hash>` DerivedData directory. Left alone,
# these accumulate and each one's copy of the QuickLook .appex gets
# registered, causing duplicate QL extensions. This script runs on every
# build, deleting every `final_final-*` directory except the one the
# current build is using.
#
# Concurrency hazard this guards against: every git worktree of this repo
# generates its own Xcode project (different project file path -> different
# DerivedData hash), so two worktrees building at the same time each run
# this cleanup independently. Without care, worktree A's cleanup pass can
# `rm -rf` worktree B's DerivedData dir while B's xcodebuild is actively
# reading/writing into it (module cache, intermediates, index store),
# corrupting or crashing B's build. Two independent checks prevent that:
#
#   1. Freshness: skip any directory (including the directory itself) that
#      has anything touched in the last $STALE_MINUTES minutes. An active
#      build writes intermediates/log/index files continuously, so a live
#      directory always looks fresh; only a directory truly abandoned by an
#      old xcodegen hash stays untouched that long. This project's builds
#      run a few minutes at most (see docs/guides/running-tests.md), so 15
#      minutes is a generous safety margin, not a tight one.
#   2. Lock: atomically claim a directory with `mkdir` (POSIX-atomic on
#      APFS) before deleting it, so two worktrees' cleanup passes racing on
#      the same stale directory at the same instant don't both `rm -rf` it
#      at once. A lock older than $STALE_MINUTES is treated as abandoned
#      (left behind by a cleanup pass that didn't finish, e.g. a file busy
#      elsewhere) and is reclaimed rather than blocking cleanup forever.
#
# This never touches the current build's own DerivedData directory, and
# never fails the build -- any error here is swallowed so a cleanup problem
# can't break compilation.

DERIVED_DATA_DIR="$HOME/Library/Developer/Xcode/DerivedData"
CURRENT_DD="${BUILD_DIR%Build/*}"
CURRENT_DD="${CURRENT_DD%/}"
STALE_MINUTES=15

for dd in "$DERIVED_DATA_DIR"/final_final-*/; do
  dd="${dd%/}"
  [ -d "$dd" ] || continue
  [ "$dd" = "$CURRENT_DD" ] && continue

  # Something in this directory (including the directory itself) was
  # touched recently -- treat it as an active build and leave it alone.
  if [ -n "$(/usr/bin/find "$dd" -mmin -"$STALE_MINUTES" -print -quit 2>/dev/null)" ]; then
    continue
  fi

  lock="$dd/.claude-cleanup-lock"
  if [ -d "$lock" ]; then
    # Reclaim a lock abandoned by a cleanup pass that didn't finish.
    if [ -z "$(/usr/bin/find "$lock" -mmin -"$STALE_MINUTES" -print -quit 2>/dev/null)" ]; then
      rmdir "$lock" 2>/dev/null || true
    fi
  fi

  if mkdir "$lock" 2>/dev/null; then
    rm -rf "$dd" 2>/dev/null || true
  fi
  # If mkdir failed, another build's cleanup pass already claimed this
  # directory (or it disappeared underneath us) -- skip it, don't retry.
done

exit 0
