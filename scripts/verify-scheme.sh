#!/bin/bash
#
# verify-scheme.sh — Golden-guard for the generated .xcscheme
#
# xcodegen regenerates "final final.xcscheme" on every `xcodegen generate`
# run. A prior xcodegen bug (or a project.yml edit) can silently drop or
# flip the per-target `parallelizable` attribute on the TestAction's
# TestableReference entries — this shipped once and caused flaky
# `isHittable` UI test failures that took a while to root-cause, because
# Xcode ran the UI tests concurrently with each other.
#
# This script re-checks the generated scheme after every regen: every
# <TestableReference> inside <TestAction> must carry parallelizable="NO".
# It does not hardcode the number of test targets — it walks whatever
# TestableReference entries are present, so adding/removing a test target
# doesn't require touching this file.
#
# Usage: bash scripts/verify-scheme.sh
# Exit 0 + "scheme OK" on success. Exit 1 naming the offending target(s)
# on failure.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCHEMES_DIR="$PROJECT_DIR/final final.xcodeproj/xcshareddata/xcschemes"

if [ ! -d "$SCHEMES_DIR" ]; then
    echo "error: schemes directory not found at $SCHEMES_DIR — run 'xcodegen generate' first." >&2
    exit 1
fi

fail=0
checked=0

# Plain-bash state machine (no python/jq/xmllint dependency, matching the
# grep/awk/sed toolset the rest of scripts/ already relies on). Walks each
# line, tracks whether we're inside <TestAction>...</TestAction> and then
# inside a <TestableReference>...</TestableReference> block, and evaluates
# each block independently as soon as it closes.
check_scheme() {
    local scheme_file="$1"
    local scheme_name
    scheme_name="$(basename "$scheme_file")"
    local in_test_action=0
    local in_testable=0
    local parallelizable=""
    local target=""

    while IFS= read -r line; do
        if [[ "$line" == *"<TestAction"* ]]; then
            in_test_action=1
        fi
        if [ "$in_test_action" -eq 0 ]; then
            continue
        fi

        if [[ "$line" == *"<TestableReference"* ]]; then
            in_testable=1
            parallelizable="__MISSING__"
            target=""
        fi

        if [ "$in_testable" -eq 1 ]; then
            if [[ "$line" == *"parallelizable"* ]]; then
                parallelizable=$(printf '%s' "$line" | sed -E 's/.*parallelizable[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/')
            fi
            if [[ "$line" == *"BlueprintName"* && -z "$target" ]]; then
                target=$(printf '%s' "$line" | sed -E 's/.*BlueprintName[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/')
            fi
        fi

        if [[ "$line" == *"</TestableReference>"* ]]; then
            in_testable=0
            checked=$((checked + 1))
            [ -z "$target" ] && target="(unnamed test target #$checked in $scheme_name)"
            if [ "$parallelizable" = "__MISSING__" ]; then
                echo "error: $target in $scheme_name is missing the parallelizable attribute on its TestableReference (expected parallelizable=\"NO\")." >&2
                fail=1
            elif [ "$parallelizable" != "NO" ]; then
                echo "error: $target in $scheme_name has parallelizable=\"$parallelizable\" (expected \"NO\")." >&2
                fail=1
            fi
        fi

        if [[ "$line" == *"</TestAction>"* ]]; then
            in_test_action=0
        fi
    done < "$scheme_file"
}

while IFS= read -r -d '' scheme_file; do
    check_scheme "$scheme_file"
done < <(find "$SCHEMES_DIR" -name "*.xcscheme" -print0)

if [ "$checked" -eq 0 ]; then
    echo "error: no <TestableReference> entries found under $SCHEMES_DIR — scheme may be malformed." >&2
    exit 1
fi

if [ "$fail" -ne 0 ]; then
    exit 1
fi

echo "scheme OK — $checked test target(s) verified parallelizable=\"NO\"."
