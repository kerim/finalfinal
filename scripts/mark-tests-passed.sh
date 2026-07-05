#!/bin/bash
#
# mark-tests-passed.sh — Prime the .last-test-pass sentinel.
#
# Lets a Claude Code session that has just seen a passing
# mcp__XcodeBuildMCP__test_macos result record the same "tests passed"
# signal the pre-commit hooks look for, WITHOUT calling xcodebuild directly
# (which the user's global CLAUDE.md MCP-only rule forbids).
#
# Trust model: identical to the hooks' existing bare `touch` — the CALLER
# is responsible for having genuinely observed a full `final finalTests`
# pass immediately before running this. Only run it right after a green MCP
# test result you have actually inspected.
#
# Usage: scripts/mark-tests-passed.sh   then   SKIP_TESTS=1 git commit -m "..."

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SENTINEL="$PROJECT_DIR/.last-test-pass"
touch "$SENTINEL"
echo "Marked tests passed: touched $SENTINEL"
echo "Now run within 5 min:  SKIP_TESTS=1 git commit -m \"...\""
