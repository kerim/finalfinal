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
HOOKS_DIR="$PROJECT_DIR/.git/hooks"
if [ -f "$HOOKS_DIR/pre-commit" ]; then
    echo -e "  ${GREEN}OK${NC}  Git pre-commit hook installed (.git/hooks/pre-commit)"
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

echo ""
echo -e "${BOLD}Usage:${NC}"
echo "  Before merging:  ./scripts/merge-check.sh"
echo "  Claude commits:  Tier 1 tests run automatically via agent hook"
echo ""
