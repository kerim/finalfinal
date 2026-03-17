#!/bin/bash
#
# merge-check.sh — Merge-readiness gate
#
# Runs Tier 1 (Silent Killers) + Tier 2 (Visible Breakage) tests sequentially.
# Exit 0 = READY, Exit 1 = NOT READY.
#
# Usage: ./scripts/merge-check.sh
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
SCHEME="final final"
DESTINATION='platform=macOS'

pass_count=0
fail_count=0
skip_count=0
failures=()

print_header() {
    echo ""
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_result() {
    local name="$1"
    local status="$2"
    local duration="$3"
    if [ "$status" = "pass" ]; then
        echo -e "  ${GREEN}PASS${NC}  $name  ${YELLOW}(${duration})${NC}"
        ((pass_count++))
    elif [ "$status" = "skip" ]; then
        echo -e "  ${YELLOW}SKIP${NC}  $name  ${YELLOW}(${duration})${NC}"
        ((skip_count++))
    else
        echo -e "  ${RED}FAIL${NC}  $name  ${YELLOW}(${duration})${NC}"
        ((fail_count++))
        failures+=("$name")
    fi
}

run_step() {
    local name="$1"
    shift
    local start_time=$(date +%s)

    if "$@" > /dev/null 2>&1; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        print_result "$name" "pass" "${duration}s"
        return 0
    else
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        print_result "$name" "fail" "${duration}s"
        return 1
    fi
}

# ─────────────────────────────────────────────
# Step 1: Web tests (if configured)
# ─────────────────────────────────────────────
print_header "Step 1/3: Web Tests"

cd "$PROJECT_DIR"
if grep -q '"test"' web/package.json 2>/dev/null; then
    start_time=$(date +%s)
    if (cd web && pnpm test --run) > /dev/null 2>&1; then
        end_time=$(date +%s)
        print_result "Web tests (pnpm test)" "pass" "$((end_time - start_time))s"
    else
        end_time=$(date +%s)
        print_result "Web tests (pnpm test)" "fail" "$((end_time - start_time))s"
    fi
else
    print_result "Web tests (not configured)" "skip" "0s"
fi

# ─────────────────────────────────────────────
# Step 2: Tier 1 + Tier 2 — Unit Tests (Silent Killers + Visible Breakage)
# ─────────────────────────────────────────────
print_header "Step 2/3: Tier 1 + Tier 2 — Unit Tests"

cd "$PROJECT_DIR"
start_time=$(date +%s)
if xcodebuild test \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -only-testing "final finalTests" \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
    -quiet \
    2>&1 | tail -5; then
    end_time=$(date +%s)
    print_result "Unit tests (final finalTests)" "pass" "$((end_time - start_time))s"
else
    end_time=$(date +%s)
    print_result "Unit tests (final finalTests)" "fail" "$((end_time - start_time))s"
fi

# ─────────────────────────────────────────────
# Step 3: Tier 2 — UI Tests (Visible Breakage)
# ─────────────────────────────────────────────
print_header "Step 3/3: Tier 2 — UI Tests (Visible Breakage)"

cd "$PROJECT_DIR"
start_time=$(date +%s)
if xcodebuild test \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -only-testing "final finalUITests" \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
    -quiet \
    2>&1 | tail -5; then
    end_time=$(date +%s)
    print_result "UI tests (final finalUITests)" "pass" "$((end_time - start_time))s"
else
    end_time=$(date +%s)
    print_result "UI tests (final finalUITests)" "fail" "$((end_time - start_time))s"
fi

# ─────────────────────────────────────────────
# Verdict
# ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${BOLD}Results:${NC}  ${GREEN}${pass_count} passed${NC}  ${RED}${fail_count} failed${NC}  ${YELLOW}${skip_count} skipped${NC}"

if [ "$fail_count" -gt 0 ]; then
    echo ""
    echo -e "  ${RED}Failures:${NC}"
    for f in "${failures[@]}"; do
        echo -e "    ${RED}- $f${NC}"
    done
    echo ""
    echo -e "  ${RED}${BOLD}NOT READY${NC}  — Fix failing tests before merging."
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit 1
else
    echo ""
    echo -e "  ${GREEN}${BOLD}READY${NC}  — All tests passed. Safe to merge."
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    exit 0
fi
