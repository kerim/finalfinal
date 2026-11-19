#!/bin/bash
#
# worktree-cleanup-test.sh — fixture-based test for scripts/worktree-cleanup.sh,
# covering worktrees at a detached HEAD (no branch) and, as a guard that the
# ordinary path did not change, one merged and one unmerged branch worktree.
#
# Builds a throwaway git repo under $TMPDIR, registers worktrees in it, runs
# the target script with --repo pointing at that repo, and asserts on exit
# codes, output and what is left on disk / in git. Touches nothing in the real
# repo. Removes its own fixtures on exit.
#
# Run: bash scripts/tests/worktree-cleanup-test.sh
# (worktree-cleanup.sh deletes directories: from Claude Code, run this with the
# sandbox disabled, as the script's own header says.)

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$SCRIPT_DIR/worktree-cleanup.sh"

if [ ! -f "$TARGET" ]; then
    echo "FAIL: target script not found: $TARGET" >&2
    exit 1
fi

pass_count=0
fail_count=0

pass() {
    pass_count=$((pass_count + 1))
    echo "PASS: $1"
}

fail() {
    fail_count=$((fail_count + 1))
    echo "FAIL: $1" >&2
}

assert_eq() {
    local actual="$1" expected="$2" label="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$label"
    else
        fail "$label -- expected '$expected', got '$actual'"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" label="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        pass "$label"
    else
        fail "$label -- expected to find: $needle -- in: $haystack"
    fi
}

assert_dir_exists() {
    if [ -d "$1" ]; then pass "$2"; else fail "$2 -- expected directory to exist: $1"; fi
}

assert_dir_absent() {
    if [ ! -d "$1" ]; then pass "$2"; else fail "$2 -- expected directory to be gone: $1"; fi
}

# ── Fixture repo ─────────────────────────────────────────────────────
# main/integration have commits A (ancestor) and B (tip). ORPHAN is a commit
# on top of B that no branch contains, so it is NOT an ancestor of the base.

STAMP="$$-$(date +%s)"
# pwd -P: git reports worktree paths with symlinks resolved ($TMPDIR is under
# /var -> /private/var on macOS), and the script compares them as strings.
BASE_TMP="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
REPO="$BASE_TMP/worktree-cleanup-test-repo-$STAMP"

cleanup() {
    rm -rf "$REPO" 2>/dev/null
}
trap cleanup EXIT

mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"
echo one > "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -q -m "A"
ANCESTOR="$(git -C "$REPO" rev-parse HEAD)"
echo two >> "$REPO/a.txt"
git -C "$REPO" commit -q -a -m "B"
git -C "$REPO" branch -q integration
ORPHAN="$(git -C "$REPO" commit-tree 'HEAD^{tree}' -p HEAD -m "not in base")"

WORKTREES="$REPO/.claude/worktrees"
SUPERDEV="$REPO/.claude/superdev"
mkdir -p "$WORKTREES" "$SUPERDEV"

# new_notes <slug>: the run-notes directory the script deletes with the worktree.
new_notes() {
    mkdir -p "$SUPERDEV/$1"
    echo "# $1" > "$SUPERDEV/$1/notes.md"
}

# cleanup_run <slug> [extra args]: runs the target against the fixture repo,
# base "integration"; sets $out (stdout+stderr) and $rc.
cleanup_run() {
    local slug="$1"
    shift
    out="$("$TARGET" --slug "$slug" --base integration --repo "$REPO" "$@" 2>&1)"
    rc=$?
}

branch_present() {
    [ -n "$(git -C "$REPO" branch --list "$1")" ]
}

listed() {
    git -C "$REPO" worktree list --porcelain | grep -qxF "worktree $1"
}

# ── 1. Detached HEAD at a commit already in the base: removed
# (the reported bug: this was refused with exit 4, "branch autodev/<slug> is
# NOT merged", although no such branch exists)

git -C "$REPO" worktree add -q --detach "$WORKTREES/det-merged" "$ANCESTOR"
new_notes det-merged

cleanup_run det-merged --dry-run
assert_eq "$rc" "0" "detached+ancestor, --dry-run: exits 0"
assert_dir_exists "$WORKTREES/det-merged" "detached+ancestor, --dry-run: worktree still present"

cleanup_run det-merged
assert_eq "$rc" "0" "detached+ancestor: exits 0"
assert_contains "$out" "REMOVED" "detached+ancestor: reports REMOVED"
assert_contains "$out" "$ANCESTOR" "detached+ancestor: names the commit"
assert_dir_absent "$WORKTREES/det-merged" "detached+ancestor: worktree directory removed"
assert_dir_absent "$SUPERDEV/det-merged" "detached+ancestor: run notes removed"
if listed "$WORKTREES/det-merged"; then fail "detached+ancestor: worktree no longer registered"; else pass "detached+ancestor: worktree no longer registered"; fi

# A same-named leftover branch (merged into the base) must survive: a detached
# worktree has no branch, so none may be deleted in its name.
git -C "$REPO" branch -q autodev/det-decoy "$ANCESTOR"
git -C "$REPO" worktree add -q --detach "$WORKTREES/det-decoy" "$ANCESTOR"
new_notes det-decoy

cleanup_run det-decoy
assert_eq "$rc" "0" "detached+ancestor, same-named leftover branch: exits 0"
assert_dir_absent "$WORKTREES/det-decoy" "detached+ancestor, same-named leftover branch: worktree removed"
if branch_present autodev/det-decoy; then pass "detached+ancestor, same-named leftover branch: no branch deleted"; else fail "detached+ancestor, same-named leftover branch: no branch deleted -- autodev/det-decoy is gone"; fi

# ── 2. Detached HEAD at a commit NOT in the base: refused, names the commit

git -C "$REPO" worktree add -q --detach "$WORKTREES/det-unmerged" "$ORPHAN"
new_notes det-unmerged

cleanup_run det-unmerged
assert_eq "$rc" "4" "detached+not-ancestor: exits 4"
assert_contains "$out" "REFUSING" "detached+not-ancestor: reports REFUSING"
assert_contains "$out" "$ORPHAN" "detached+not-ancestor: names the commit"
assert_dir_exists "$WORKTREES/det-unmerged" "detached+not-ancestor: worktree directory kept"
assert_dir_exists "$SUPERDEV/det-unmerged" "detached+not-ancestor: run notes kept"

# ── 3. Detached HEAD, worktree directory already gone

git -C "$REPO" worktree add -q --detach "$WORKTREES/det-gone-merged" "$ANCESTOR"
new_notes det-gone-merged
rm -rf "$WORKTREES/det-gone-merged"

cleanup_run det-gone-merged
assert_eq "$rc" "0" "detached+ancestor, directory already gone: exits 0"
assert_contains "$out" "PRUNED" "detached+ancestor, directory already gone: reports PRUNED"
assert_dir_absent "$SUPERDEV/det-gone-merged" "detached+ancestor, directory already gone: run notes removed"
if listed "$WORKTREES/det-gone-merged"; then fail "detached+ancestor, directory already gone: registration pruned"; else pass "detached+ancestor, directory already gone: registration pruned"; fi

git -C "$REPO" worktree add -q --detach "$WORKTREES/det-gone-unmerged" "$ORPHAN"
new_notes det-gone-unmerged
rm -rf "$WORKTREES/det-gone-unmerged"

cleanup_run det-gone-unmerged
assert_eq "$rc" "4" "detached+not-ancestor, directory already gone: exits 4"
assert_contains "$out" "$ORPHAN" "detached+not-ancestor, directory already gone: names the commit"
assert_dir_exists "$SUPERDEV/det-gone-unmerged" "detached+not-ancestor, directory already gone: run notes kept"
if listed "$WORKTREES/det-gone-unmerged"; then pass "detached+not-ancestor, directory already gone: registration kept (the commit stays referenced)"; else fail "detached+not-ancestor, directory already gone: registration kept"; fi

# ── 4. Ordinary branch worktrees behave as before ───────────────────

git -C "$REPO" worktree add -q -b autodev/br-merged "$WORKTREES/br-merged" "$ANCESTOR"
new_notes br-merged
cleanup_run br-merged
assert_eq "$rc" "0" "branch worktree, merged: exits 0"
assert_dir_absent "$WORKTREES/br-merged" "branch worktree, merged: worktree removed"
if branch_present autodev/br-merged; then fail "branch worktree, merged: branch deleted"; else pass "branch worktree, merged: branch deleted"; fi

git -C "$REPO" worktree add -q -b autodev/br-unmerged "$WORKTREES/br-unmerged" "$ORPHAN"
new_notes br-unmerged
cleanup_run br-unmerged
assert_eq "$rc" "4" "branch worktree, unmerged: exits 4"
assert_contains "$out" "autodev/br-unmerged" "branch worktree, unmerged: names the branch"
assert_dir_exists "$WORKTREES/br-unmerged" "branch worktree, unmerged: worktree kept"
if branch_present autodev/br-unmerged; then pass "branch worktree, unmerged: branch kept"; else fail "branch worktree, unmerged: branch kept"; fi

# ── Summary ──────────────────────────────────────────────────────────

echo ""
echo "----------------------------------------"
echo "Results: $pass_count passed, $fail_count failed"

if [ "$fail_count" -gt 0 ]; then
    exit 1
fi
exit 0
