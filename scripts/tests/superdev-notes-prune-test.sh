#!/bin/bash
#
# superdev-notes-prune-test.sh — fixture-based test suite for
# scripts/superdev-notes-prune.sh.
#
# Builds a throwaway git repo (plus one non-git directory, for the
# guard-failure case) under $TMPDIR, exercises the target script's report
# mode and --prune mode against them, and asserts on the output and
# resulting filesystem state. Touches nothing in the real repo. Cleans up
# its own fixtures on exit, success or failure.
#
# Run: bash scripts/tests/superdev-notes-prune-test.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$SCRIPT_DIR/superdev-notes-prune.sh"

if [ ! -f "$TARGET" ]; then
    echo "FAIL: target script not found: $TARGET" >&2
    exit 1
fi
if [ ! -x "$TARGET" ]; then
    echo "FAIL: target script is not executable: $TARGET" >&2
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

assert_contains() {
    local haystack="$1" needle="$2" label="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        pass "$label"
    else
        fail "$label -- expected to find: $needle"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" label="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        fail "$label -- expected NOT to find: $needle"
    else
        pass "$label"
    fi
}

assert_eq() {
    local actual="$1" expected="$2" label="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$label"
    else
        fail "$label -- expected '$expected', got '$actual'"
    fi
}

assert_dir_exists() {
    local dir="$1" label="$2"
    if [ -d "$dir" ]; then
        pass "$label"
    else
        fail "$label -- expected directory to still exist: $dir"
    fi
}

assert_dir_absent() {
    local dir="$1" label="$2"
    if [ ! -d "$dir" ]; then
        pass "$label"
    else
        fail "$label -- expected directory to be gone: $dir"
    fi
}

# ── Fixture setup ────────────────────────────────────────────────────

STAMP="$$-$(date +%s)"
BASE_TMP="${TMPDIR:-/tmp}"
REPO="${BASE_TMP%/}/superdev-notes-prune-test-repo-$STAMP"
NOGIT="${BASE_TMP%/}/superdev-notes-prune-test-nogit-$STAMP"
EMPTY_SUPERDEV="${BASE_TMP%/}/superdev-notes-prune-test-emptysuperdev-$STAMP"

cleanup() {
    rm -rf "$REPO" "$NOGIT" "$EMPTY_SUPERDEV" 2>/dev/null
}
trap cleanup EXIT

mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"
echo "hello" > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "init" >/dev/null

SUPERDEV="$REPO/.claude/superdev"
WORKTREES="$REPO/.claude/worktrees"
mkdir -p "$SUPERDEV" "$WORKTREES"

old_ts="$(date -v-3H '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '-3 hours' '+%Y%m%d%H%M.%S')"

# Backdate a fixture dir (and its immediate contents) so the recency
# guard reads it as old. Fixtures here are all flat (one notes.md), so a
# single-level touch is enough -- no need for a recursive find.
backdate() {
    local dir="$1" f
    touch -t "$old_ts" "$dir"
    for f in "$dir"/*; do
        [ -e "$f" ] || continue
        touch -t "$old_ts" "$f"
    done
}

# Case 1: truly orphaned -- no worktree, no branch, no marker, backdated.
mkdir -p "$SUPERDEV/orphan-slug"
cat > "$SUPERDEV/orphan-slug/notes.md" <<EOF
# orphan-slug
- worktree: $WORKTREES/orphan-slug
- branch: worktree-orphan-slug
EOF
backdate "$SUPERDEV/orphan-slug"

# Case 2: a marker present ("parked"), but no worktree, no branch,
# backdated -- proves the marker guard alone can preserve, even though
# nothing in the pipeline actually writes this marker today.
mkdir -p "$SUPERDEV/parked-slug"
cat > "$SUPERDEV/parked-slug/notes.md" <<EOF
# parked-slug
- worktree: $WORKTREES/parked-slug
- branch: worktree-parked-slug
- status: PARKED pending user decision
EOF
backdate "$SUPERDEV/parked-slug"

# Case 2b (regression -- prose containing "unverified"/"parked" must NOT
# trip the marker guard): notes.md describes an e2e test result using
# the word "unverified" in ordinary prose, but has no actual "- status:"
# declaration line. No worktree, no branch, backdated -- must classify
# ORPHANED. Before the fix, the marker guard did a recursive,
# case-insensitive free-text grep across the whole directory and would
# have matched this prose, wrongly PRESERVING the directory forever.
mkdir -p "$SUPERDEV/prose-mentions-unverified-slug"
cat > "$SUPERDEV/prose-mentions-unverified-slug/notes.md" <<EOF
# prose-mentions-unverified-slug
- worktree: $WORKTREES/prose-mentions-unverified-slug
- branch: worktree-prose-mentions-unverified-slug

## e2e notes
- item 5's fix is unverified
- UNVERIFIED (fix applied, not confirmed)
- this pipeline was never parked, just describing test results
EOF
backdate "$SUPERDEV/prose-mentions-unverified-slug"

# Case 3: live worktree.
git -C "$REPO" worktree add -q "$WORKTREES/live-wt-slug" -b "worktree-live-wt-slug" >/dev/null
mkdir -p "$SUPERDEV/live-wt-slug"
cat > "$SUPERDEV/live-wt-slug/notes.md" <<EOF
# live-wt-slug
- worktree: $WORKTREES/live-wt-slug
- branch: worktree-live-wt-slug
EOF
backdate "$SUPERDEV/live-wt-slug"

# Case 4: branch exists, no live worktree.
git -C "$REPO" branch -q "worktree-branch-only-slug"
mkdir -p "$SUPERDEV/branch-only-slug"
cat > "$SUPERDEV/branch-only-slug/notes.md" <<EOF
# branch-only-slug
- worktree: $WORKTREES/branch-only-slug
- branch: worktree-branch-only-slug
EOF
backdate "$SUPERDEV/branch-only-slug"

# Case 5: brand new -- within the age window. No worktree, no branch, no
# marker, but NOT backdated (mtime is "now").
mkdir -p "$SUPERDEV/brand-new-slug"
cat > "$SUPERDEV/brand-new-slug/notes.md" <<EOF
# brand-new-slug
- worktree: $WORKTREES/brand-new-slug
- branch: worktree-brand-new-slug
EOF

# Case 6: board-style directory -- no notes.md at all. Must be SKIPPED,
# never a prune candidate, mirroring the real .claude/superdev/board/.
mkdir -p "$SUPERDEV/board-style/sub"
echo '{}' > "$SUPERDEV/board-style/data.json"
echo '<html></html>' > "$SUPERDEV/board-style/board.html"

# Case 7: dot-directory -- must be skipped silently, mirroring the real
# .claude/superdev/.claude/ entry. Never printed, never a candidate.
mkdir -p "$SUPERDEV/.claude/hooks"

# Case 8 (M2 regression -- branch-fallback union): notes.md has NO
# "- branch:" line at all, but a real live git branch matching the
# conventional fallback name worktree-<slug> exists. Must be classified
# PRESERVED via the branch-fallback candidates, proving the guard checks
# the fallback names even when notes.md is silent on branch (not just
# whatever name happens to be recorded).
git -C "$REPO" branch -q "worktree-branch-fallback-slug"
mkdir -p "$SUPERDEV/branch-fallback-slug"
cat > "$SUPERDEV/branch-fallback-slug/notes.md" <<EOF
# branch-fallback-slug
- worktree: $WORKTREES/branch-fallback-slug
EOF
backdate "$SUPERDEV/branch-fallback-slug"

# Case 9 (M2 regression -- empty recorded value falls back to default):
# a notes.md line of exactly "- worktree: " (label present, value empty
# -- e.g. from a truncated write). A live worktree actually exists at
# the computed DEFAULT path ($WORKTREES/emptyval-slug). Before the fix,
# the empty extracted value would be used as WT verbatim instead of
# falling back to that default, silently defeating the live-worktree
# guard for a worktree that really is live. Built with printf (not a
# heredoc) so the trailing space after "worktree:" survives intact.
git -C "$REPO" worktree add -q "$WORKTREES/emptyval-slug" -b "worktree-emptyval-slug" >/dev/null
mkdir -p "$SUPERDEV/emptyval-slug"
printf '%s\n%s\n%s\n' \
    "# emptyval-slug" \
    "- worktree: " \
    "- branch: worktree-emptyval-slug" \
    > "$SUPERDEV/emptyval-slug/notes.md"
backdate "$SUPERDEV/emptyval-slug"

# ── Report mode against the real fixture repo ───────────────────────

report_out="$("$TARGET" --repo "$REPO" --age-hours 1 2>&1)"
report_rc=$?

assert_eq "$report_rc" "10" "report mode exits 10 when orphans are found"
assert_contains "$report_out" "orphan-slug: ORPHANED" "orphan-slug classified ORPHANED"
assert_contains "$report_out" "parked-slug: PRESERVED" "parked-slug classified PRESERVED (marker guard)"
assert_contains "$report_out" "prose-mentions-unverified-slug: ORPHANED" "prose-mentions-unverified-slug classified ORPHANED, not PRESERVED by ordinary prose using \"unverified\"/\"parked\" (regression)"
assert_contains "$report_out" "live-wt-slug: PRESERVED" "live-wt-slug classified PRESERVED (live worktree)"
assert_contains "$report_out" "branch-only-slug: PRESERVED" "branch-only-slug classified PRESERVED (branch exists)"
assert_contains "$report_out" "brand-new-slug: PRESERVED" "brand-new-slug classified PRESERVED (too recent)"
assert_contains "$report_out" "board-style: SKIPPED" "board-style (no notes.md) classified SKIPPED, not ORPHANED"
assert_not_contains "$report_out" ".claude:" "dot-directory .claude/ is skipped silently, never printed"
assert_contains "$report_out" "branch-fallback-slug: PRESERVED" "branch-fallback-slug classified PRESERVED via fallback branch names (M2 regression, no recorded branch line)"
assert_contains "$report_out" "emptyval-slug: PRESERVED" "emptyval-slug (empty worktree value) falls back to computed default and catches its live worktree (M2 regression)"

# Report mode must never mutate anything.
assert_dir_exists "$SUPERDEV/orphan-slug" "report mode performed zero mutations (orphan-slug still present after report)"

# ── --prune deletes only the true orphan ────────────────────────────

prune_out="$("$TARGET" --repo "$REPO" --age-hours 1 --prune 2>&1)"
prune_rc=$?

assert_eq "$prune_rc" "0" "prune run exits 0 when it completes cleanly"
assert_dir_absent "$SUPERDEV/orphan-slug" "prune deleted the true orphan"
assert_dir_absent "$SUPERDEV/prose-mentions-unverified-slug" "prune deleted the prose-only dir the buggy marker guard would have preserved (regression)"
assert_dir_exists "$SUPERDEV/parked-slug" "prune left the marker-guarded dir alone"
assert_dir_exists "$SUPERDEV/live-wt-slug" "prune left the live-worktree dir alone"
assert_dir_exists "$SUPERDEV/branch-only-slug" "prune left the branch-only dir alone"
assert_dir_exists "$SUPERDEV/brand-new-slug" "prune left the brand-new dir alone"
assert_dir_exists "$SUPERDEV/board-style" "prune left the board-style (non-run-notes) dir alone"
assert_dir_exists "$SUPERDEV/branch-fallback-slug" "prune left the branch-fallback-guarded dir alone (M2 regression)"
assert_dir_exists "$SUPERDEV/emptyval-slug" "prune left the empty-worktree-value dir alone (M2 regression)"
assert_contains "$prune_out" "orphan-slug" "prune printed the path it deleted"

# ── Idempotency -- second report run is clean ───────────────────────

report2_out="$("$TARGET" --repo "$REPO" --age-hours 1 2>&1)"
report2_rc=$?
assert_eq "$report2_rc" "0" "second report run is clean after pruning the only orphan"
assert_not_contains "$report2_out" "ORPHANED" "second report run finds no more orphans"

# ── Must-fix 2: a guard whose underlying command errors must PRESERVE,
# never let the directory fall through to ORPHANED. Point --repo at a
# directory that is not a git repository at all, so every git-backed
# guard (live-worktree, branch-exists) fails outright with a non-zero
# exit rather than an empty "guard clear" result.

mkdir -p "$NOGIT/.claude/superdev/broken-guard-slug"
cat > "$NOGIT/.claude/superdev/broken-guard-slug/notes.md" <<EOF
# broken-guard-slug
- worktree: $NOGIT/.claude/worktrees/broken-guard-slug
- branch: worktree-broken-guard-slug
EOF
backdate "$NOGIT/.claude/superdev/broken-guard-slug"

broken_report_out="$("$TARGET" --repo "$NOGIT" --age-hours 1 2>&1)"
assert_contains "$broken_report_out" "broken-guard-slug: PRESERVED" "unevaluable-guard directory classified PRESERVED, not ORPHANED"
assert_not_contains "$broken_report_out" "broken-guard-slug: ORPHANED" "unevaluable-guard directory never reads as ORPHANED"

broken_prune_out="$("$TARGET" --repo "$NOGIT" --age-hours 1 --prune 2>&1)"
broken_prune_rc=$?
assert_eq "$broken_prune_rc" "6" "prune aborts (exit 6) when a guard could not be evaluated cleanly"
assert_dir_exists "$NOGIT/.claude/superdev/broken-guard-slug" "prune performed zero deletions when aborting on an unevaluable guard"

# ── M1 regression: an existing-but-empty .claude/superdev/ (no
# subdirectories at all) must not crash. On this machine's bash 3.2.57,
# `set -u` plus `for entry in "${entries[@]}"` over a genuinely empty
# array throws "unbound variable" and kills the script -- a state that
# arises normally right after successfully pruning the last orphan.

mkdir -p "$EMPTY_SUPERDEV/.claude/superdev"

empty_report_out="$("$TARGET" --repo "$EMPTY_SUPERDEV" --age-hours 1 2>&1)"
empty_report_rc=$?
assert_eq "$empty_report_rc" "0" "existing-but-empty .claude/superdev/ exits cleanly instead of crashing (M1 regression)"
assert_not_contains "$empty_report_out" "unbound variable" "existing-but-empty .claude/superdev/ produces no unbound-variable error (M1 regression)"

# ── Summary ──────────────────────────────────────────────────────────

echo ""
echo "----------------------------------------"
echo "Results: $pass_count passed, $fail_count failed"

if [ "$fail_count" -gt 0 ]; then
    exit 1
fi
exit 0
