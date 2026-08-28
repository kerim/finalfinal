#!/bin/bash
#
# worktree-cleanup.sh — Safe, idempotent autodev worktree/branch/notes cleanup
#
# Classifies the current state of a `.claude/worktrees/<slug>` worktree (plus
# its `autodev/<slug>` branch and `.claude/superdev/<slug>` run notes) and takes
# the one action that state allows — or refuses and explains why.
#
# NOTE: this script performs destructive filesystem operations under
# .claude/worktrees/<slug> and .claude/superdev/<slug>. When invoked from
# Claude Code, it MUST be run with the sandbox disabled
# (dangerouslyDisableSandbox: true) — the sandboxed Bash filesystem-write
# allowlist only covers pre-known paths, so a delete under an arbitrary
# <slug> here can die with "Operation not permitted" mid-delete, which is
# the exact failure mode this script exists to make recoverable from. Do
# not try to work around that error some other way — just disable the
# sandbox for this one invocation. Read-only/--dry-run invocations do not
# need the sandbox disabled.
#
# Usage: scripts/worktree-cleanup.sh --slug <slug> --base <branch> [--repo <path>] [--dry-run] [-h|--help]
#
# Exit codes:
#   0 = success (no-op, plain removal, or auto-recovered)
#   2 = usage error (missing/bad args)
#   3 = refuse: genuine uncommitted changes present
#   4 = refuse: branch not merged into base
#   5 = ambiguous leftover artifact, needs a human decision
#   6 = unexpected failure during a mutating command (e.g. git worktree
#       remove/prune or rm -rf itself failed) — state may have changed;
#       re-run this script with the same --slug/--base to detect and
#       recover/report whatever resulted
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

print_help() {
    cat <<EOF
worktree-cleanup.sh — Safe, idempotent autodev worktree/branch/notes cleanup

Usage:
  scripts/worktree-cleanup.sh --slug <slug> --base <branch> [--repo <path>] [--dry-run]
  scripts/worktree-cleanup.sh -h | --help

Options:
  --slug <slug>   (required) the worktree/branch slug.
  --base <branch> (optional, default: main) the branch to check "merged" against.
  --repo <path>   (optional, default: computed project root) the main repo
                  root — NOT the worktree itself. This script is meant to be
                  run from the main checkout, operating on
                  <repo>/.claude/worktrees/<slug>.
  --dry-run       Run all read-only classification, print the state detected
                  and exactly what action would be taken and what message
                  would be shown, but perform zero filesystem/git mutations.
                  Exit code matches what the real run would produce.
  -h, --help      Show this help and exit 0.

Exit codes:
  0 = success (no-op, plain removal, or auto-recovered)
  2 = usage error (missing/bad args)
  3 = refuse: genuine uncommitted changes present
  4 = refuse: branch not merged into base
  5 = ambiguous leftover artifact, needs a human decision
  6 = unexpected failure during a mutating command — state may have changed;
      re-run with the same --slug/--base to detect and recover/report it

See also: scripts/superdev-notes-prune.sh, a repo-wide sweep for
orphaned .claude/superdev/<slug> run-notes directories left behind by a
pipeline that died before wrap-up ever called this script for its slug.
That script has its own shape (report-by-default, --prune to delete,
its own exit codes) — it does not replace this one.

IMPORTANT — sandbox note:
  This script performs destructive filesystem operations under
  .claude/worktrees/<slug> and .claude/superdev/<slug>. When invoked from
  Claude Code, it MUST be run with the sandbox disabled
  (dangerouslyDisableSandbox: true) — the sandboxed Bash filesystem-write
  allowlist only covers pre-known paths, so a delete under an arbitrary
  <slug> here can die with "Operation not permitted" mid-delete, which is
  the exact failure mode this script exists to make recoverable from. Do
  not try to work around that error some other way — just disable the
  sandbox for this one invocation. Read-only/--dry-run invocations do not
  need the sandbox disabled.
EOF
}

# ─────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────
slug=""
base="main"
repo="$PROJECT_DIR"
dry_run=0

while [ $# -gt 0 ]; do
    case "$1" in
        --slug)
            slug="${2:-}"
            [ -n "$slug" ] || { echo -e "${RED}worktree-cleanup: usage error — --slug requires a value${NC}" >&2; exit 2; }
            shift 2
            ;;
        --base)
            base="${2:-}"
            [ -n "$base" ] || { echo -e "${RED}worktree-cleanup: usage error — --base requires a value${NC}" >&2; exit 2; }
            shift 2
            ;;
        --repo)
            repo="${2:-}"
            [ -n "$repo" ] || { echo -e "${RED}worktree-cleanup: usage error — --repo requires a value${NC}" >&2; exit 2; }
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            echo -e "${RED}worktree-cleanup: usage error — unrecognized argument '$1'${NC}" >&2
            exit 2
            ;;
    esac
done

if [ -z "$slug" ]; then
    echo -e "${RED}worktree-cleanup: usage error — --slug is required${NC}" >&2
    print_help >&2
    exit 2
fi

if [ ! -d "$repo" ]; then
    echo -e "${RED}worktree-cleanup: usage error — --repo path '$repo' does not exist${NC}" >&2
    exit 2
fi

WT="$repo/.claude/worktrees/$slug"
NOTES="$repo/.claude/superdev/$slug"

# ─────────────────────────────────────────────
# Read-only classification (no sandbox needed for any of this)
# ─────────────────────────────────────────────

registered=0
prunable=0
registered_branch=""
if worktree_list_porcelain="$(git -C "$repo" worktree list --porcelain 2>/dev/null)"; then
    # Parse porcelain output: entries are separated by blank lines, each
    # starting with "worktree <path>", possibly followed by "HEAD"/"branch"/
    # "prunable" lines.
    current_path=""
    while IFS= read -r line; do
        case "$line" in
            "worktree "*)
                current_path="${line#worktree }"
                if [ "$current_path" = "$WT" ]; then
                    registered=1
                fi
                ;;
            "branch "*)
                if [ "$current_path" = "$WT" ]; then
                    registered_branch="${line#branch refs/heads/}"
                fi
                ;;
            "prunable"*)
                if [ "$current_path" = "$WT" ]; then
                    prunable=1
                fi
                ;;
            "")
                current_path=""
                ;;
        esac
    done <<< "$worktree_list_porcelain"
fi

# Determine the branch for this slug. Prefer the branch git itself reports
# for a currently-registered worktree (authoritative, and correct regardless
# of naming convention) over guessing. Only guess when there's no live
# registration to consult (branch/dir already removed by an earlier attempt,
# or a detached worktree). Two conventions exist in practice: the manual
# fallback this script's usage docs assume (`autodev/<slug>`), and the native
# EnterWorktree tool, which prefixes the branch with `worktree-` and flattens
# any `/` in the requested name to `+` (an EnterWorktree name of
# "autodev/foo" ends up as branch "worktree-autodev+foo", worktree dir
# ".claude/worktrees/autodev+foo" — so here `slug` is already "autodev+foo",
# and "worktree-$slug" is the correct guess). Guessing wrong here previously
# caused this script to refuse a fully-merged worktree with "branch not
# merged" because it was checking a branch name that didn't exist at all.
if [ "$registered" -eq 1 ] && [ -n "$registered_branch" ]; then
    BR="$registered_branch"
elif [ -n "$(git -C "$repo" branch --list "autodev/$slug" 2>/dev/null)" ]; then
    BR="autodev/$slug"
elif [ -n "$(git -C "$repo" branch --list "worktree-$slug" 2>/dev/null)" ]; then
    BR="worktree-$slug"
else
    BR="autodev/$slug"
fi

dir_exists=0
[ -e "$WT" ] && dir_exists=1

branch_exists=0
if [ -n "$(git -C "$repo" branch --list "$BR" 2>/dev/null)" ]; then
    branch_exists=1
fi

branch_merged=0
if [ "$branch_exists" -eq 1 ]; then
    if [ -n "$(git -C "$repo" branch --merged "$base" --list "$BR" 2>/dev/null)" ]; then
        branch_merged=1
    fi
fi

clean=0
all_pure_deletion=0
status_lines=""
if [ "$registered" -eq 1 ] && [ "$dir_exists" -eq 1 ] && [ "$prunable" -eq 0 ]; then
    status_lines="$(git -C "$WT" status --porcelain 2>/dev/null || true)"
    if [ -z "$status_lines" ]; then
        clean=1
    else
        all_pure_deletion=1
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            prefix="${line:0:2}"
            if [ "$prefix" != " D" ]; then
                all_pure_deletion=0
                break
            fi
        done <<< "$status_lines"
    fi
fi

# ─────────────────────────────────────────────
# Classification (exhaustive, in the exact required order)
# ─────────────────────────────────────────────

state=""
if [ "$registered" -eq 1 ]; then
    if [ "$prunable" -eq 1 ] || [ "$dir_exists" -eq 0 ]; then
        state="S3"
    else
        if [ "$clean" -eq 1 ]; then
            if [ "$branch_merged" -eq 1 ]; then
                state="S1"
            else
                state="S2b"
            fi
        else
            if [ "$all_pure_deletion" -eq 1 ]; then
                if [ "$branch_exists" -eq 1 ] && [ "$branch_merged" -eq 0 ]; then
                    state="S2c-unmerged"
                else
                    state="S2c-merged"
                fi
            else
                state="S2a"
            fi
        fi
    fi
elif [ "$dir_exists" -eq 1 ]; then
    state="S4"
elif [ "$branch_exists" -eq 1 ]; then
    if [ "$branch_merged" -eq 1 ]; then
        state="S5-merged"
    else
        state="S5-unmerged"
    fi
else
    state="S0"
fi

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────

run() {
    # Execute a mutating command unless --dry-run is set. --dry-run must
    # produce the exact same stdout/stderr messages and exit code as the
    # real run would, so this stays silent — the final per-state summary
    # message already states what action was/would be taken.
    #
    # On failure (real run only): never let an unguarded `set -e` abort with
    # a raw, undiagnosed error and an undocumented exit code — that is
    # exactly the confusing failure mode this script exists to replace.
    # Print a clear diagnostic and exit 6. This does not change what
    # happened — a subsequent run of this script (same --slug/--base) will
    # correctly detect and recover/report whatever state resulted.
    if [ "$dry_run" -eq 1 ]; then
        return 0
    fi
    local out
    if out="$("$@" 2>&1)"; then
        return 0
    fi
    echo -e "${RED}worktree-cleanup: UNEXPECTED FAILURE — command failed: $*${NC}" >&2
    echo "$out" >&2
    echo -e "${RED}'$slug' may now be in a partially-changed state. Re-run this script with the same --slug/--base to detect and safely recover or report whatever state resulted — do not assume anything beyond what a re-run shows.${NC}" >&2
    exit 6
}

count_pure_deletions() {
    local n=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        n=$((n + 1))
    done <<< "$status_lines"
    echo "$n"
}

delete_branch_or_report() {
    # Attempts `git branch -d "$BR"`, which independently re-checks merge
    # status against $repo's actual checked-out HEAD/upstream — NOT against
    # "$base" the way our own `branch --merged "$base"` check above does.
    # Normally these agree (the caller merges into $base while it's checked
    # out in $repo, then runs this script right after), but nothing enforces
    # that, so git can refuse here even though our own check said "merged".
    # On success: returns 0, branch_del_err is empty.
    # On failure: returns 1, branch_del_err holds git's one-line message.
    #   Callers MUST treat this as non-fatal — do not let it crash the
    #   script and do not delete the run notes; branch + notes are retained
    #   together for a human to reconcile.
    # Honors --dry-run like run(): performs no git call, reports success,
    # since --dry-run must not mutate anything and cannot know what a real
    # call would do.
    branch_del_err=""
    if [ "$dry_run" -eq 1 ]; then
        return 0
    fi
    if branch_del_err="$(git -C "$repo" branch -d "$BR" 2>&1 >/dev/null)"; then
        return 0
    fi
    return 1
}

# ─────────────────────────────────────────────
# Actions per state
# ─────────────────────────────────────────────

case "$state" in
    S0)
        echo "worktree-cleanup: NOTHING TO DO — no worktree, branch, or run notes found for '$slug'."
        exit 0
        ;;

    S1)
        run git -C "$repo" worktree remove "$WT"
        branch_del_failed=0
        if [ "$branch_exists" -eq 1 ]; then
            if ! delete_branch_or_report; then
                branch_del_failed=1
            fi
        fi
        if [ "$branch_del_failed" -eq 1 ]; then
            echo -e "${RED}worktree-cleanup: REMOVED — worktree '$slug' removed, but branch '$BR' could NOT be auto-deleted (git says it isn't fully merged into the currently checked-out branch, which may differ from '$base'): $branch_del_err. Run notes retained alongside it. If you're confident the branch's work is safe, finish manually: git -C '$repo' branch -D '$BR' && rm -rf '$NOTES'${NC}" >&2
        else
            run rm -rf "$NOTES"
            echo "worktree-cleanup: REMOVED — '$slug' worktree removed, branch '$BR' deleted (was merged into '$base'), run notes deleted."
        fi
        exit 0
        ;;

    S2a)
        echo -e "${RED}worktree-cleanup: REFUSING — worktree '$slug' has uncommitted changes:${NC}" >&2
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            echo "    $line" >&2
        done <<< "$status_lines"
        echo "Commit or discard them, then retry. Nothing was removed." >&2
        exit 3
        ;;

    S2b)
        echo -e "${RED}worktree-cleanup: REFUSING — branch '$BR' is NOT merged into '$base'. Merge it first, then retry. Nothing was removed.${NC}" >&2
        exit 4
        ;;

    S2c-merged)
        n="$(count_pure_deletions)"
        run git -C "$repo" worktree remove --force "$WT"
        branch_msg=""
        branch_del_failed=0
        if [ "$branch_exists" -eq 1 ]; then
            if delete_branch_or_report; then
                branch_msg="deleted (was merged into '$base')"
            else
                branch_del_failed=1
            fi
        else
            branch_msg="was already absent"
        fi
        if [ "$branch_del_failed" -eq 1 ]; then
            echo -e "${RED}worktree-cleanup: RECOVERED — '$slug' had an interrupted prior removal: $n tracked path(s) were deleted from disk without being committed (pure worktree-side deletions, fully recoverable from git history — not genuine new work). Finished the removal, but branch '$BR' could NOT be auto-deleted (git says it isn't fully merged into the currently checked-out branch, which may differ from '$base'): $branch_del_err. Run notes retained alongside it. If you're confident the branch's work is safe, finish manually: git -C '$repo' branch -D '$BR' && rm -rf '$NOTES'${NC}" >&2
        else
            run rm -rf "$NOTES"
            echo "worktree-cleanup: RECOVERED — '$slug' had an interrupted prior removal: $n tracked path(s) were deleted from disk without being committed (pure worktree-side deletions, fully recoverable from git history — not genuine new work). Finished the removal. Branch '$BR': $branch_msg. Run notes: deleted."
        fi
        exit 0
        ;;

    S2c-unmerged)
        n="$(count_pure_deletions)"
        echo -e "${RED}worktree-cleanup: REFUSING — '$slug' has an interrupted prior removal ($n tracked path(s) already deleted from disk) AND branch '$BR' is NOT merged into '$base'. Not finishing the removal — the deleted paths are still recoverable if you want the worktree usable again (git -C '$WT' checkout -- .). Otherwise get the branch merged, then retry. Nothing was removed.${NC}" >&2
        exit 4
        ;;

    S3)
        run git -C "$repo" worktree prune
        if [ "$branch_exists" -eq 1 ]; then
            if [ "$branch_merged" -eq 1 ]; then
                if delete_branch_or_report; then
                    run rm -rf "$NOTES"
                    echo "worktree-cleanup: PRUNED — worktree directory for '$slug' was already missing; git metadata pruned. Branch '$BR': deleted (was merged into '$base'). Run notes: deleted."
                else
                    echo -e "${RED}worktree-cleanup: PRUNED — worktree directory for '$slug' was already missing; git metadata pruned, but branch '$BR' could NOT be auto-deleted (git says it isn't fully merged into the currently checked-out branch, which may differ from '$base'): $branch_del_err. Run notes retained alongside it. If you're confident the branch's work is safe, finish manually: git -C '$repo' branch -D '$BR' && rm -rf '$NOTES'${NC}" >&2
                fi
            else
                echo "worktree-cleanup: PRUNED — worktree directory for '$slug' was already missing; git metadata pruned. Branch '$BR': RETAINED — not merged into '$base'; verify no work was lost, then 'git branch -D $BR' manually if appropriate. Run notes: retained."
            fi
        else
            run rm -rf "$NOTES"
            echo "worktree-cleanup: PRUNED — worktree directory for '$slug' was already missing; git metadata pruned. Branch '$BR': already absent. Run notes: deleted."
        fi
        exit 0
        ;;

    S4)
        # PURELY OBSERVATIONAL — never delete, move, or modify anything under
        # $WT or its metadata, under any condition.
        wt_status_result=""
        if wt_status_lines="$(git -C "$WT" status --porcelain 2>&1)"; then
            if [ -z "$wt_status_lines" ]; then
                wt_status_result="succeeded, clean"
            else
                n_changes=0
                while IFS= read -r line; do
                    [ -z "$line" ] && continue
                    n_changes=$((n_changes + 1))
                done <<< "$wt_status_lines"
                wt_status_result="succeeded, $n_changes change(s) found"
            fi
        else
            wt_status_result="FAILED — broken .git linkage: $wt_status_lines"
        fi

        branch_result=""
        if [ "$branch_exists" -eq 1 ]; then
            if [ "$branch_merged" -eq 1 ]; then
                branch_result="merged into '$base'"
            else
                branch_result="NOT merged"
            fi
        else
            branch_result="does not exist"
        fi

        echo -e "${RED}worktree-cleanup: ORPHANED — needs a human. Directory '$WT' exists but git does not track it as a registered worktree at all (absent from 'git worktree list'). 'git status' inside it: $wt_status_result. Branch '$BR': $branch_result. This script never deletes unregistered directory content automatically — nothing was touched. Once you've confirmed by hand that nothing of value remains, finish it yourself:${NC}" >&2
        echo "  rm -rf '$WT' && git -C '$repo' worktree prune && git -C '$repo' branch -d '$BR' && rm -rf '$NOTES'" >&2
        exit 5
        ;;

    S5-merged)
        if delete_branch_or_report; then
            run rm -rf "$NOTES"
            echo "worktree-cleanup: PRUNED — no worktree directory or git registration exists for '$slug' (already removed by an earlier attempt). Branch '$BR': deleted (was merged into '$base'). Run notes: deleted."
        else
            echo -e "${RED}worktree-cleanup: PRUNED — no worktree directory or git registration exists for '$slug' (already removed by an earlier attempt), but branch '$BR' could NOT be auto-deleted (git says it isn't fully merged into the currently checked-out branch, which may differ from '$base'): $branch_del_err. Run notes retained alongside it. If you're confident the branch's work is safe, finish manually: git -C '$repo' branch -D '$BR' && rm -rf '$NOTES'${NC}" >&2
        fi
        exit 0
        ;;

    S5-unmerged)
        notes_presence="absent"
        [ -e "$NOTES" ] && notes_presence="present"
        echo -e "${RED}worktree-cleanup: DANGLING — needs a human. No worktree directory or git registration exists for '$slug', but branch '$BR' still exists and is NOT merged into '$base' (run notes at '$NOTES': $notes_presence). This is most likely leftover from an earlier cleanup that removed the worktree files but correctly refused to delete an unmerged branch. Nothing was touched. Once you've confirmed the branch's work is preserved or no longer needed:${NC}" >&2
        echo "  git -C '$repo' branch -D '$BR' && rm -rf '$NOTES'" >&2
        exit 5
        ;;

    *)
        echo -e "${RED}worktree-cleanup: internal error — unreachable state '$state'${NC}" >&2
        exit 2
        ;;
esac
