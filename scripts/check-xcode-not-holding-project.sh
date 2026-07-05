#!/bin/bash
# check-xcode-not-holding-project.sh — reusable Xcode-eviction guard.
#
# Extracted so it can be called from anywhere xcodegen might run (not just
# at `git commit` time, where an equivalent inline check already lives in
# .git/hooks/pre-commit): scripts/build.sh and the Claude Code
# xcodegen-eviction-guard.sh PreToolUse hook both shell out to this one
# script — no duplicated logic between them.
#
# If Xcode.app is running at all, running xcodegen (or `git checkout`)
# against a project it holds open is unsafe: within seconds to minutes,
# Xcode re-imposes its own stale in-memory copy of the .xcscheme back onto
# disk, silently reverting the regen. This script does not regenerate or
# verify anything itself — callers should not proceed with xcodegen if
# this exits non-zero.
#
# Design (2026-07-06, revised): an earlier version asked Xcode itself which
# project(s) it had open (via osascript / Apple Events), so only a
# genuinely-affected quit would happen. That mechanism needs Apple Events
# permission (`allowAppleEvents`), which Claude Code's sandbox denies by
# default and which can only be granted globally (any app, not just
# Xcode) — so detection silently couldn't confirm anything during a
# Claude-Code-driven session, the exact scenario that caused the repeated
# corruption this guard exists to prevent. Replaced with a plain process
# check (no Apple Events, no special permission needed beyond the standing
# `Bash(killall Xcode)` allow rule): if Xcode is running at all, and
# nothing is actively building/testing right now, just quit it outright.
# Less precise (can no longer tell whether Xcode has THIS project or some
# unrelated one open) but it actually works inside the sandbox, which the
# precise version didn't.
#
# Usage: bash scripts/check-xcode-not-holding-project.sh
# Exit 0 — safe to proceed (Xcode wasn't running, or was running with
#          nothing building and has now been quit).
# Exit 1 — Xcode is running AND a build/test is in flight (xcodebuild or
#          XCBBuildService process found) — message on stderr. Do not
#          proceed; another agent or the user may be relying on Xcode
#          right now. Retry once the in-flight build/test finishes.

# pgrep's exit codes: 0 = matched, 1 = no match, >=2 = it couldn't even get
# the process list (observed: exit 3, "sysmon request failed" / "pgrep:
# Cannot get process list" — happens inside Claude Code's own Bash sandbox,
# which blocks the process-list API pgrep needs). That failure must never
# be silently treated as "no match" — it means "unknown," and the two
# checks below fail toward opposite defaults on "unknown" because the risk
# is asymmetric: guessing wrong on "is Xcode running" just misses a
# corruption-prevention opportunity, but guessing wrong on "is a build in
# flight" could quit Xcode out from under someone's in-progress work.

# Returns: 0 = confirmed running, 1 = confirmed not running, 2 = unknown.
xcode_is_running() {
  pgrep -xq Xcode
  local rc=$?
  [ "$rc" -le 1 ] && return "$rc"
  return 2
}

# Returns: 0 = confirmed something's in flight, 1 = confirmed nothing is,
# 2 = unknown.
build_in_flight() {
  local rc
  pgrep -xq xcodebuild; rc=$?
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -gt 1 ] && return 2
  pgrep -xq XCBBuildService; rc=$?
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -gt 1 ] && return 2
  return 1
}

xcode_is_running
rc=$?
if [ "$rc" -eq 2 ]; then
  echo "check-xcode-not-holding-project: could not verify whether Xcode is running (pgrep couldn't get the process list — likely running inside a sandbox that blocks it); proceeding WITHOUT this safety check." >&2
  exit 0
fi
if [ "$rc" -eq 1 ]; then
  exit 0   # confirmed not running — nothing to do
fi

# Xcode confirmed running from here on.
build_in_flight
rc=$?
if [ "$rc" -eq 2 ]; then
  echo "check-xcode-not-holding-project: Xcode is running, but could not verify whether a build/test is in flight (pgrep couldn't get the process list) — NOT quitting it, to stay on the safe side. If scheme corruption occurs, close Xcode manually and retry." >&2
  exit 1
fi
if [ "$rc" -eq 0 ]; then
  echo "check-xcode-not-holding-project: Xcode is running and a build/test appears to be in flight (xcodebuild or XCBBuildService process found) — NOT quitting it, since that could be another agent's or the user's in-progress work. Wait for it to finish, then retry." >&2
  exit 1
fi

echo "check-xcode-not-holding-project: Xcode is running with no build/test in flight — quitting it (killall Xcode) before regenerating." >&2
killall Xcode

# Give it a moment to actually exit before the caller proceeds — killall
# returns as soon as the signal is sent, not once the app has quit. If we
# can no longer tell (pgrep starts failing, e.g. because Xcode's exit
# tears down something pgrep depends on), stop waiting rather than loop
# blindly — either way, proceed; there's no further action this script can
# take.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  xcode_is_running
  [ "$?" -eq 1 ] && break
  sleep 0.3
done

exit 0
