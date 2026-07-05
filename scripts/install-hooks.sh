#!/bin/bash
#
# install-hooks.sh — Install git hooks for test enforcement
#
# Currently: Documents the Claude Code PreToolUse agent hook approach.
# Future: Will install a terminal-level pre-commit hook for non-Claude commits.
#
# Usage: ./scripts/install-hooks.sh
#

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}Test Enforcement Setup${NC}"
echo ""

# ─────────────────────────────────────────────
# 1. Claude Code hook (already configured in .claude/settings.json)
# ─────────────────────────────────────────────
if grep -q "PreToolUse" "$PROJECT_DIR/.claude/settings.json" 2>/dev/null; then
    echo -e "  ${GREEN}OK${NC}  Claude Code pre-commit hook configured (.claude/settings.json)"
else
    echo -e "  ${YELLOW}MISSING${NC}  Claude Code pre-commit hook not found in .claude/settings.json"
    echo "         See the Testing Improvement Plan for the hook configuration."
fi

# ─────────────────────────────────────────────
# 2. Terminal git hook (future)
# ─────────────────────────────────────────────
HOOKS_DIR="$(git -C "$PROJECT_DIR" rev-parse --git-path hooks)"
case "$HOOKS_DIR" in /*) ;; *) HOOKS_DIR="$PROJECT_DIR/$HOOKS_DIR" ;; esac
mkdir -p "$HOOKS_DIR"
if [ -f "$HOOKS_DIR/pre-commit" ]; then
    echo -e "  ${GREEN}OK${NC}  Git pre-commit hook installed ($HOOKS_DIR/pre-commit)"
else
    echo -e "  ${YELLOW}SKIP${NC}  Git pre-commit hook not installed (terminal commits not enforced)"
    echo "         This is expected — enforcement currently runs through Claude Code only."
fi

# ─────────────────────────────────────────────
# 3. Merge-check script
# ─────────────────────────────────────────────
if [ -x "$PROJECT_DIR/scripts/merge-check.sh" ]; then
    echo -e "  ${GREEN}OK${NC}  Merge-check script available (./scripts/merge-check.sh)"
else
    echo -e "  ${YELLOW}MISSING${NC}  Merge-check script not found or not executable"
fi

# ─────────────────────────────────────────────
# 4. Install the post-merge hook (tracked wrapper)
# ─────────────────────────────────────────────
POST_MERGE="$HOOKS_DIR/post-merge"
# Belt-and-suspenders: if something already occupies this path and it is NOT
# already our own wrapper (idempotent re-installs must not pile up backups),
# preserve it before overwriting.
if [ -f "$POST_MERGE" ] && ! grep -q "scripts/hooks/post-merge" "$POST_MERGE" 2>/dev/null; then
    BACKUP="$POST_MERGE.pre-install-backup.$(date +%Y%m%d%H%M%S)"
    cp "$POST_MERGE" "$BACKUP"
    echo -e "  ${YELLOW}NOTE${NC}  Backed up pre-existing post-merge hook to $(basename "$BACKUP")"
fi
cat > "$POST_MERGE" <<'WRAPPER'
#!/bin/bash
# Auto-installed by scripts/install-hooks.sh — do not edit here.
# Real hook body is tracked at scripts/hooks/post-merge in the SAME working
# tree this merge just happened in. This file is one shared hook serving
# every worktree and the main checkout, so it must never hardcode a path to
# one specific checkout — it resolves the tracked body fresh on every run via
# `git rev-parse --show-toplevel`, which git guarantees points at the
# top level of whichever worktree is running this hook right now.
TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "post-merge: could not resolve this worktree's top level, skipping web rebuild."
    exit 0
}
BODY="$TOPLEVEL/scripts/hooks/post-merge"
if [ ! -x "$BODY" ]; then
    echo "post-merge: scripts/hooks/post-merge not found (or not executable) in $TOPLEVEL"
    echo "  — this worktree may be on a commit that predates the tracked hook."
    echo "  Skipping automatic web rebuild. Run manually if needed:"
    echo "  cd web && pnpm install && pnpm build"
    exit 0
fi
cd "$TOPLEVEL" || exit 0
exec "$BODY" "$@"
WRAPPER
chmod +x "$POST_MERGE"
echo -e "  ${GREEN}OK${NC}  Installed post-merge hook (wrapper -> scripts/hooks/post-merge)"

echo ""
echo -e "${BOLD}Usage:${NC}"
echo "  Before merging:  ./scripts/merge-check.sh"
echo "  Claude commits:  Tier 1 tests run automatically via agent hook"
echo ""
