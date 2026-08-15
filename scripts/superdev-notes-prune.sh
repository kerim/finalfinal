#!/bin/bash
#
# superdev-notes-prune.sh — repo-wide sweep for orphaned superdev
# run-notes directories (.claude/superdev/<slug>/) left behind when a
# pipeline dies before it reaches wrap-up.
#
# This is deliberately separate from worktree-cleanup.sh, which is
# slug-required and has its own exit-code contract that sd-wrap-up
# depends on. This script instead walks every directory under
# .claude/superdev/ and reports (or, with --prune, deletes) whichever
# ones look abandoned.
#
# SAFETY RATIONALE — read this before trusting or changing the guards:
# The classification below checks, per directory, whether notes.md has an
# anchored "- status: ... parked|unverified ..." line (the same "^- "
# metadata-line convention as the worktree:/branch: fields parsed below —
# never a free-text scan of prose anywhere in the directory). That check
# is real, but it is extra insurance only — as of this writing, nothing
# in the superdev pipeline actually writes a "parked" marker into a run's
# notes.md; park records live on the bt task note and in the Present
# block, not here. So that grep is not what makes deletion safe, and must
# never be treated as though it were.
#
# The actual safety argument is this: parking a run (and every other
# in-progress or intentionally-retained state) keeps the run's worktree
# and/or branch alive on disk/in git. worktree-cleanup.sh itself only
# ever deletes a slug's run notes in states where the branch is already
# merged or gone — never while a worktree or an unmerged branch still
# exists. So the two guards that actually protect a run in every
# documented pipeline state are guard 1 (live worktree) and guard 2
# (branch exists). Everything else here (the marker grep, the recency
# window) is belt-and-braces on top of that, not a substitute for it.
#
# Usage:
#   scripts/superdev-notes-prune.sh [--repo <path>] [--age-hours N] [--prune] [-h|--help]
#
# NOTE — sandbox caveat (same as worktree-cleanup.sh): this script
# performs destructive filesystem operations (--prune mode) under
# .claude/superdev/<slug>. When invoked from Claude Code, --prune MUST
# be run with the sandbox disabled (dangerouslyDisableSandbox: true) —
# the sandboxed Bash filesystem-write allowlist only covers pre-known
# paths, so a delete under an arbitrary <slug> here can die with
# "Operation not permitted" mid-delete. Do not work around that error
# some other way — just disable the sandbox for this one invocation.
# Report mode (the default, no --prune) performs zero mutations and
# needs no sandbox override.
#
# Exit codes:
#   0  = report clean (no orphans found), or prune completed
#   2  = usage error (missing/bad args)
#   6  = a delete failed mid-prune (re-run to see what remains), or the
#        prune run was aborted before any deletion because a guard could
#        not be evaluated cleanly for at least one directory
#   10 = report mode found one or more orphaned directories (a
#        non-conflicting non-zero code chosen deliberately: 1 collides
#        with the generic "error" convention many `set -e` callers use)

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

print_help() {
    cat <<EOF
superdev-notes-prune.sh — repo-wide sweep for orphaned superdev run-notes
directories (.claude/superdev/<slug>/)

Usage:
  scripts/superdev-notes-prune.sh [--repo <path>] [--age-hours N] [--prune]
  scripts/superdev-notes-prune.sh -h | --help

Options:
  --repo <path>     (optional, default: computed project root) the main
                     repo root whose .claude/superdev/ directory to sweep.
  --age-hours N     (optional, default: 24) a run-notes directory whose
                     contents were modified within the last N hours is
                     always preserved, regardless of the other guards.
  --prune           Actually delete directories classified ORPHANED.
                     Without this flag, the script only reports — zero
                     mutations.
  -h, --help        Show this help and exit 0.

Classification, per directory under <repo>/.claude/superdev/:
  - A name starting with '.' is skipped silently (e.g. the live
    .claude/superdev/.claude/ entry).
  - No notes.md -> SKIPPED (not a run-notes directory). Never a prune
    candidate — this protects .claude/superdev/board/ (has board.html
    and JSON, no notes.md).
  - Otherwise, PRESERVED if any guard trips: a live worktree, an
    existing branch, an anchored "- status: ... parked|unverified ..."
    line in notes.md (belt-and-braces insurance only — see the header
    comment), or a modification within --age-hours. If a guard's
    underlying command could not be evaluated (e.g. git is unavailable),
    the directory is PRESERVED as unevaluable rather than risking a
    false ORPHANED.
  - Otherwise ORPHANED.

Exit codes:
  0  = report clean, or prune completed
  2  = usage error
  6  = a delete failed mid-prune (re-run to see what remains), or the
       prune run was aborted before any deletion because a guard could
       not be evaluated cleanly for at least one directory
  10 = report mode found one or more orphaned directories

See also: scripts/worktree-cleanup.sh, which handles cleanup for one
specific --slug (worktree + branch + run notes together) once a
pipeline finishes. This script is the repo-wide safety net for run
notes left behind by pipelines that never got that far.

IMPORTANT — sandbox note:
  --prune performs destructive filesystem operations under
  .claude/superdev/<slug>. When invoked from Claude Code, --prune MUST
  be run with the sandbox disabled (dangerouslyDisableSandbox: true) —
  the sandboxed Bash filesystem-write allowlist only covers pre-known
  paths, so a delete under an arbitrary <slug> here can die with
  "Operation not permitted" mid-delete. Do not work around that error
  some other way — just disable the sandbox for this one invocation.
  Report mode (the default, no --prune) performs zero mutations and
  needs no sandbox override.
EOF
}

# ─────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────

repo="$PROJECT_DIR"
age_hours=24
prune=0

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)
            repo="${2:-}"
            [ -n "$repo" ] || { echo "superdev-notes-prune: usage error -- --repo requires a value" >&2; exit 2; }
            shift 2
            ;;
        --age-hours)
            age_hours="${2:-}"
            [ -n "$age_hours" ] || { echo "superdev-notes-prune: usage error -- --age-hours requires a value" >&2; exit 2; }
            shift 2
            ;;
        --prune)
            prune=1
            shift
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            echo "superdev-notes-prune: usage error -- unrecognized argument '$1'" >&2
            exit 2
            ;;
    esac
done

if [ ! -d "$repo" ]; then
    echo "superdev-notes-prune: usage error -- --repo path '$repo' does not exist" >&2
    exit 2
fi

case "$age_hours" in
    ''|*[!0-9]*)
        echo "superdev-notes-prune: usage error -- --age-hours must be a non-negative integer, got '$age_hours'" >&2
        exit 2
        ;;
esac

SUPERDEV_DIR="$repo/.claude/superdev"

# Absolute cutoff timestamp for the recency guard. Deliberately NOT
# `find -newermt "-N hours"` (relative form) -- on at least one machine
# this repo runs on, `find` is a `bfs` shim that rejects the relative
# form with a parse error. Because the guard below is written as
# "output non-empty -> preserve", a failing `find` would otherwise send
# its error to stderr, the command substitution would come back empty,
# and the age guard would silently read as "clear" -- pushing a
# mid-flight notes dir toward deletion instead of protecting it.
# Verified on this machine: the relative form fails, the absolute form
# below works.
cutoff="$(date -v-"${age_hours}"H '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "-${age_hours} hours" '+%Y-%m-%d %H:%M:%S')"

# ─────────────────────────────────────────────
# Guards
#
# Each guard function sets GUARD_RESULT to one of:
#   TRIP  -- the guard's condition holds; the directory must be PRESERVED
#   CLEAR -- the guard ran cleanly and found nothing
#   ERROR -- the guard's underlying command failed; the directory must
#            be PRESERVED as unevaluable, never allowed to read as CLEAR
# and GUARD_DETAIL to a short human-readable reason.
#
# Every guard is written so a command failure is distinguished from "ran
# fine, found nothing" -- never `if [ -n "$(cmd)" ]` on its own, which
# would let a failing command's empty/error output silently read as
# "guard clear". See the `|| rc=$?` pattern throughout: under `set -e`,
# a bare `var="$(cmd)"` with a failing cmd aborts the whole script
# immediately (verified on this machine), so every guard command is run
# with an explicit `|| rc=$?` to capture failure without exiting.
# ─────────────────────────────────────────────

GUARD_RESULT=""
GUARD_DETAIL=""

guard_live_worktree() {
    local wt="$1"
    local out rc=0
    out="$(git -C "$repo" worktree list --porcelain 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        GUARD_RESULT="ERROR"
        GUARD_DETAIL="live-worktree guard: 'git worktree list --porcelain' failed: $out"
        return
    fi
    if grep -qxF "worktree $wt" <<<"$out"; then
        GUARD_RESULT="TRIP"
        GUARD_DETAIL="live worktree -- registered at '$wt'"
        return
    fi
    if [ -e "$wt" ]; then
        GUARD_RESULT="TRIP"
        GUARD_DETAIL="live worktree -- directory exists at '$wt'"
        return
    fi
    GUARD_RESULT="CLEAR"
    GUARD_DETAIL=""
}

guard_branch_exists() {
    local candidate out rc tripped=0 trip_name=""
    for candidate in "$@"; do
        rc=0
        out="$(git -C "$repo" branch --list "$candidate" 2>&1)" || rc=$?
        if [ "$rc" -ne 0 ]; then
            GUARD_RESULT="ERROR"
            GUARD_DETAIL="branch-exists guard: 'git branch --list $candidate' failed: $out"
            return
        fi
        if [ -n "$out" ]; then
            tripped=1
            trip_name="$candidate"
        fi
    done
    if [ "$tripped" -eq 1 ]; then
        GUARD_RESULT="TRIP"
        GUARD_DETAIL="branch exists -- '$trip_name'"
        return
    fi
    GUARD_RESULT="CLEAR"
    GUARD_DETAIL=""
}

guard_marker() {
    # Anchored to an actual status declaration line in notes.md, the same
    # "^- " metadata-line shape the worktree:/branch: extraction above
    # already relies on -- never a recursive, free-text scan of prose,
    # which would also match unrelated sentences (e.g. an e2e-notes.md
    # describing a test result as "unverified") anywhere in the
    # directory.
    local notes_file="$1"
    local out rc=0
    out="$(grep -m1 -i -E '^- status: .*\b(parked|unverified)\b' "$notes_file" 2>&1)" || rc=$?
    # grep exit codes: 0 = match found, 1 = no match (not an error),
    # >1 = a real error (unreadable path, bad regex, etc).
    if [ "$rc" -gt 1 ]; then
        GUARD_RESULT="ERROR"
        GUARD_DETAIL="marker guard: grep failed: $out"
        return
    fi
    if [ "$rc" -eq 0 ] && [ -n "$out" ]; then
        GUARD_RESULT="TRIP"
        GUARD_DETAIL="parked/unverified status marker found in notes.md (belt-and-braces insurance only -- see header comment)"
        return
    fi
    GUARD_RESULT="CLEAR"
    GUARD_DETAIL=""
}

guard_recent() {
    local dir="$1"
    local out rc=0
    out="$(find "$dir" -newermt "$cutoff" -print -quit 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        GUARD_RESULT="ERROR"
        GUARD_DETAIL="recency guard: find failed: $out"
        return
    fi
    if [ -n "$out" ]; then
        GUARD_RESULT="TRIP"
        GUARD_DETAIL="modified within ${age_hours}h (cutoff '$cutoff')"
        return
    fi
    GUARD_RESULT="CLEAR"
    GUARD_DETAIL=""
}

# Combines all four guards for one directory. Sets CLASS to one of
# PRESERVED / ORPHANED, and CLASS_REASON to a short human reason.
# Any guard ERROR wins over any guard TRIP: if even one guard could not
# be evaluated, the directory is reported as unevaluable regardless of
# what the other guards found, per must-fix 2 -- a failure anywhere
# must never be allowed to blend into a "safe to delete" read.
classify_directory() {
    local wt="$1" notes_dir="$2"
    shift 2
    local -a br_list=("$@")

    local -a results=() details=()

    guard_live_worktree "$wt"
    results+=("$GUARD_RESULT"); details+=("$GUARD_DETAIL")

    guard_branch_exists "${br_list[@]}"
    results+=("$GUARD_RESULT"); details+=("$GUARD_DETAIL")

    guard_marker "$notes_dir/notes.md"
    results+=("$GUARD_RESULT"); details+=("$GUARD_DETAIL")

    guard_recent "$notes_dir"
    results+=("$GUARD_RESULT"); details+=("$GUARD_DETAIL")

    local i
    for i in "${!results[@]}"; do
        if [ "${results[$i]}" = "ERROR" ]; then
            CLASS="PRESERVED"
            CLASS_REASON="unevaluable guard -- inspect manually (${details[$i]})"
            return
        fi
    done
    for i in "${!results[@]}"; do
        if [ "${results[$i]}" = "TRIP" ]; then
            CLASS="PRESERVED"
            CLASS_REASON="${details[$i]}"
            return
        fi
    done
    CLASS="ORPHANED"
    CLASS_REASON=""
}

# ─────────────────────────────────────────────
# Delete-path validation (must-fix 3)
#
# The delete target is a directory name read off disk, not something
# the caller can fully control -- validate it before every `rm -rf`.
# ─────────────────────────────────────────────

validate_delete_target() {
    local target="$1" base_dir="$2"
    [ -n "$target" ] || return 1
    case "$target" in
        *..*) return 1 ;;
    esac
    local parent base_name
    parent="$(dirname -- "$target")"
    [ "$parent" = "$base_dir" ] || return 1
    base_name="$(basename -- "$target")"
    case "$base_name" in
        ''|.*) return 1 ;;
    esac
    [ -d "$target" ] || return 1
    return 0
}

# ─────────────────────────────────────────────
# Sweep
# ─────────────────────────────────────────────

if [ ! -d "$SUPERDEV_DIR" ]; then
    echo "superdev-notes-prune: report clean -- '$SUPERDEV_DIR' does not exist, nothing to sweep."
    exit 0
fi

shopt -s nullglob
entries=("$SUPERDEV_DIR"/*)
shopt -u nullglob

declare -a all_names=() all_classes=() all_reasons=()
declare -a orphan_dirs=()
found_unevaluable=0

echo "superdev-notes-prune: scanning '$SUPERDEV_DIR' (age threshold: ${age_hours}h, cutoff: $cutoff)"
echo ""

if [ "${#entries[@]}" -gt 0 ]; then
for entry in "${entries[@]}"; do
    [ -d "$entry" ] || continue
    name="$(basename -- "$entry")"
    case "$name" in
        .*) continue ;;
    esac

    notes_file="$entry/notes.md"
    if [ ! -f "$notes_file" ]; then
        all_names+=("$name")
        all_classes+=("SKIPPED")
        all_reasons+=("not a run-notes directory")
        continue
    fi

    # A recorded value is only trusted if the line is present AND its
    # value is non-empty -- a truncated write can leave a bare
    # "- worktree: " (or "- branch: ") with nothing after the label,
    # which must fall back to the computed default exactly like a
    # missing line would, never silently use the empty string.
    wt_line=""
    wt_line="$(grep -m1 '^- worktree: ' "$notes_file" 2>/dev/null)" || true
    WT="${wt_line#- worktree: }"
    if [ -z "$WT" ]; then
        WT="$repo/.claude/worktrees/$name"
    fi

    # The branch guard always checks the UNION of the recorded name (if
    # any, and non-empty) plus all three conventional fallback names --
    # never just the recorded name alone. Extra candidates can only make
    # this guard trip MORE often (fail toward PRESERVED), never less.
    br_line=""
    br_line="$(grep -m1 '^- branch: ' "$notes_file" 2>/dev/null)" || true
    recorded_branch="${br_line#- branch: }"
    br_list=("worktree-$name" "superdev/$name" "autodev/$name")
    if [ -n "$recorded_branch" ]; then
        br_list+=("$recorded_branch")
    fi

    classify_directory "$WT" "$entry" "${br_list[@]}"

    all_names+=("$name")
    all_classes+=("$CLASS")
    all_reasons+=("$CLASS_REASON")

    if [ "$CLASS" = "PRESERVED" ]; then
        case "$CLASS_REASON" in
            unevaluable*) found_unevaluable=1 ;;
        esac
    fi
    if [ "$CLASS" = "ORPHANED" ]; then
        orphan_dirs+=("$entry")
    fi
done
fi

for i in "${!all_names[@]}"; do
    if [ -n "${all_reasons[$i]}" ]; then
        printf '  %s: %s (%s)\n' "${all_names[$i]}" "${all_classes[$i]}" "${all_reasons[$i]}"
    else
        printf '  %s: %s\n' "${all_names[$i]}" "${all_classes[$i]}"
    fi
done

echo ""

# ─────────────────────────────────────────────
# Report mode
# ─────────────────────────────────────────────

if [ "$prune" -eq 0 ]; then
    if [ "${#orphan_dirs[@]}" -gt 0 ]; then
        echo "superdev-notes-prune: report mode -- ${#orphan_dirs[@]} orphaned run-notes directory/directories found. Re-run with --prune to delete them."
        exit 10
    fi
    echo "superdev-notes-prune: report clean -- no orphaned run-notes directories found."
    exit 0
fi

# ─────────────────────────────────────────────
# Prune mode (must-fix 2: refuse the whole run if any guard was
# unevaluable for any directory -- never proceed with a partial/
# uncertain classification.)
# ─────────────────────────────────────────────

if [ "$found_unevaluable" -eq 1 ]; then
    echo "superdev-notes-prune: ABORTING prune -- at least one directory's guards could not be evaluated cleanly (see 'unevaluable guard' above). No deletions were performed. Investigate the failure and re-run." >&2
    exit 6
fi

if [ "${#orphan_dirs[@]}" -eq 0 ]; then
    echo "superdev-notes-prune: prune completed -- nothing to delete."
    exit 0
fi

delete_failed=0
deleted_count=0
for dir in "${orphan_dirs[@]}"; do
    if ! validate_delete_target "$dir" "$SUPERDEV_DIR"; then
        echo "superdev-notes-prune: REFUSING to delete '$dir' -- failed path-safety validation (must be a direct child of '$SUPERDEV_DIR', non-empty, and free of '..' components)." >&2
        delete_failed=1
        continue
    fi
    echo "superdev-notes-prune: deleting $dir"
    if rm -rf -- "$dir"; then
        deleted_count=$((deleted_count + 1))
    else
        echo "superdev-notes-prune: FAILED to delete '$dir'" >&2
        delete_failed=1
    fi
done

if [ "$delete_failed" -eq 1 ]; then
    echo "superdev-notes-prune: prune finished with at least one delete failure ($deleted_count succeeded) -- re-run to see what remains." >&2
    exit 6
fi

echo "superdev-notes-prune: prune completed -- deleted $deleted_count orphaned run-notes directory/directories."
exit 0
