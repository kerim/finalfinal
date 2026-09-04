#!/bin/bash
#
# merge-check.sh — Merge-readiness gate
#
# Runs Tier 1 (Silent Killers, host unit tests) + Tier 2 (Visible Breakage,
# a small UI smoke set) sequentially. Exit 0 = READY, Exit 1 = NOT READY.
#
# The UI step runs `vmtest run --suite smoke` — macOS UI tests run in a
# disposable VM, not on this screen (see scripts/vmtest/README.md). Since
# 2026-09-04 (test-tiers-ship plan) this is a small golden-path smoke set
# under 5 minutes, not the whole scheme — the full UI suite runs at release
# time instead, driven by `/ship` (`scripts/vmtest/vmtest run --suite full`).
# This script itself detaches the smoke run and polls it in bounded slices
# via `vmtest wait --timeout`, so the script is safe to invoke directly from
# Claude too, not just from your own terminal — no separate --detach dance
# needed at the call site.
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
# Step 3: Tier 2 — UI smoke tests (Visible Breakage), via vmtest
#
# --suite smoke, not the whole scheme — see the file header. Detached +
# polled in bounded slices (vmtest wait --timeout, looping on its exit 124)
# rather than a single blocking `vmtest run`, so this step never risks the
# Bash tool's 600s cap when this script is run directly from Claude, and
# still finishes just as fast from a real terminal.
# ─────────────────────────────────────────────
print_header "Step 3/3: Tier 2 — UI smoke tests (Visible Breakage) — vmtest"

cd "$PROJECT_DIR"
start_time=$(date +%s)
smoke_run_output="$("$PROJECT_DIR/scripts/vmtest/vmtest" run --suite smoke --detach 2>&1)" || true
echo "$smoke_run_output" | tail -5
smoke_run_id="$(printf '%s\n' "$smoke_run_output" | sed -n 's/^run id: //p')"
smoke_status=1
smoke_wait_out="$(mktemp)"
if [ -n "$smoke_run_id" ]; then
    while true; do
        # A plain statement here (not inside this if) would trip `set -e` on
        # the very first exit-124 slice, since a bare command's non-zero exit
        # is fatal under set -e outside an if/while condition.
        if "$PROJECT_DIR/scripts/vmtest/vmtest" wait "$smoke_run_id" --timeout 540 > "$smoke_wait_out" 2>&1; then
            smoke_status=0
            break
        else
            smoke_status=$?
            [ "$smoke_status" -eq 124 ] || break
        fi
    done
    tail -20 "$smoke_wait_out"
fi
rm -f "$smoke_wait_out"
end_time=$(date +%s)
if [ "$smoke_status" -eq 0 ]; then
    print_result "UI smoke tests (final finalUITests, via vmtest --suite smoke)" "pass" "$((end_time - start_time))s"
else
    print_result "UI smoke tests (final finalUITests, via vmtest --suite smoke)" "fail" "$((end_time - start_time))s"
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
