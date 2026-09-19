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

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

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

# sweep_other_worktrees — heal collateral scheme damage in every OTHER
# worktree after this script has force-quit Xcode.
#
# `killall Xcode` quits the whole app, not one document. If Xcode had
# more than this worktree's project open — a concurrently-running
# agent's worktree, the main checkout, an unrelated worktree — the kill
# just flushed every one of those open documents' stale in-memory scheme
# state back to disk too, not just the project the caller here cares
# about. That's the confirmed root cause of this guard's own repeated
# collateral-corruption recurrences (wiki: "xcodegen Workflow",
# 2026-07-06/07/09/10 entries).
#
# DISCLOSED BEHAVIOR CHANGE: this reaches into and can modify files in
# OTHER worktrees — including a concurrently-running agent's worktree —
# without asking first. Scope is deliberately narrow: only `.xcscheme`
# files, only replaced with that worktree's own last-committed content
# (`git -C <worktree> checkout -- <path>`, never anything from this
# worktree), and only when scripts/verify-scheme.sh confirms one of its
# existing 4 corruption signatures — never a broader "clean up anything
# that looks different" pass. The restore is from that worktree's own git
# INDEX, which is equivalent to its HEAD unless the scheme file happens to
# have a staged-but-uncommitted change at the exact moment of the sweep —
# in that rare case, the staged content is preserved rather than
# clobbered, which is strictly safer than a hard `checkout HEAD --` would
# be. `.xcscheme` is already documented as a disposable
# generated artifact in this repo ("don't hand-edit .xcodeproj, it'll be
# overwritten") — a verify-scheme.sh failure here is unambiguous
# corruption, never a legitimate hand-edit worth preserving. This
# automates a recovery step that was previously done manually
# ("restored from HEAD via git checkout" — wiki history, a simplification
# of the index-restore semantics described above); it does not
# expand what gets fixed or how "corrupted" is decided.
#
# Scope: every worktree except $1 (this one). This worktree's own
# .xcscheme, even if it too got flushed by the kill above, is about to
# be freshly overwritten by the caller's own imminent `xcodegen
# generate` call regardless (both callers of this script always run
# `xcodegen generate` immediately after this script returns 0), so
# healing it here would be moot.
#
# Never fails the caller: any problem inside this sweep is logged to
# stderr and skipped. It must never become a new reason to block a
# legitimate xcodegen run.
sweep_other_worktrees() {
  local self_dir="$1"
  local verify_script="$self_dir/scripts/verify-scheme.sh"
  if [ ! -f "$verify_script" ]; then
    echo "check-xcode-not-holding-project: $verify_script not found; skipping multi-worktree scheme sweep." >&2
    return
  fi

  # Resolve via git itself, not just cd/pwd — a raw string compare against
  # $self_dir can silently mismatch whenever it differs from git's own
  # worktree-list output only by symlink resolution (e.g. macOS's
  # /tmp -> /private/tmp), which would wrongly re-sweep this worktree's
  # own (about-to-be-regenerated-anyway) scheme files as if they were
  # "another" worktree. Verified live in this exact scenario.
  local self_toplevel
  self_toplevel="$(git -C "$self_dir" rev-parse --show-toplevel 2>/dev/null)"
  [ -z "$self_toplevel" ] && self_toplevel="$self_dir"

  local worktrees
  worktrees="$(git -C "$self_dir" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')"
  if [ -z "$worktrees" ]; then
    echo "check-xcode-not-holding-project: 'git worktree list' returned nothing; skipping multi-worktree scheme sweep." >&2
    return
  fi

  local checked=0 healed=0 wt f rel verify_err verify_rc
  while IFS= read -r wt; do
    [ -z "$wt" ] && continue
    [ "$wt" = "$self_toplevel" ] && continue   # about to be regenerated by the caller regardless

    local schemes_dir="$wt/final final.xcodeproj/xcshareddata/xcschemes"
    [ -d "$schemes_dir" ] || continue

    while IFS= read -r -d '' f; do
      checked=$((checked + 1))
      verify_err="$(bash "$verify_script" "$f" 2>&1 >/dev/null)"
      verify_rc=$?
      [ "$verify_rc" -eq 0 ] && continue

      echo "check-xcode-not-holding-project: collateral damage — '$f' (worktree: $wt) failed scheme verification after the Xcode quit above; restoring from that worktree's own git index." >&2
      rel="${f#"$wt"/}"
      if ! git -C "$wt" checkout -- "$rel"; then
        echo "check-xcode-not-holding-project: WARNING — 'git -C \"$wt\" checkout -- \"$rel\"' failed; could not auto-heal. Inspect $wt manually." >&2
        continue
      fi
      if bash "$verify_script" "$f" >/dev/null 2>&1; then
        echo "check-xcode-not-holding-project: healed — '$f' restored clean from $wt's own git index." >&2
        healed=$((healed + 1))
        record_heal "$self_dir" "$wt" "$rel" "$verify_err"
      else
        echo "check-xcode-not-holding-project: WARNING — restored '$f' from $wt's git index but it STILL fails verification (the committed copy may itself be bad). Inspect $wt manually." >&2
      fi
    done < <(find "$schemes_dir" -name "*.xcscheme" -print0 2>/dev/null)
  done <<< "$worktrees"

  echo "check-xcode-not-holding-project: multi-worktree scheme sweep complete — $checked other-worktree scheme file(s) checked, $healed healed." >&2
}

# record_heal — persistent, discoverable record of a heal, separate from
# the stderr logging above. Two reasons stderr alone isn't enough: (1)
# this hook's own header comment documents that Claude Code silently
# discards stderr from a PreToolUse hook that exits 0; (2) even when
# stderr IS visible, it's scoped to this session's process — a different,
# concurrently-running agent whose worktree just got healed has no way to
# see this session's hook output at all, by construction. Written into
# the HEALED worktree itself (not this one) so its own owning agent can
# discover it locally on its own next turn, with no dependency on this
# session's transcript. .claude/autodev/ is already gitignored repo-wide,
# so this never risks being committed or cluttering that worktree's
# `git status`.
record_heal() {
  local healer_dir="$1" wt="$2" rel="$3" reason="$4"
  local log_dir="$wt/.claude/autodev"
  if ! mkdir -p "$log_dir" 2>/dev/null; then
    echo "check-xcode-not-holding-project: WARNING — could not create $log_dir to record this heal persistently; the heal itself still succeeded, only the durable record is missing." >&2
    return
  fi
  printf '%s healed=%s worktree=%s healed_by=%s reason=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rel" "$wt" "$healer_dir" "$(printf '%s' "$reason" | tr '\n' ' ')" \
    >> "$log_dir/scheme-guard-heals.log"
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then

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

sweep_other_worktrees "$PROJECT_DIR"

exit 0

fi
