#!/bin/bash
#
# verify-scheme.sh — Golden-guard for the generated .xcscheme
#
# xcodegen regenerates "final final.xcscheme" on every `xcodegen generate`
# run. Two independent things can silently corrupt that output:
#
# 1. A prior xcodegen bug (or a project.yml edit) can silently drop or
#    flip the per-target `parallelizable` attribute on the TestAction's
#    TestableReference entries — this shipped once and caused flaky
#    `isHittable` UI test failures that took a while to root-cause, because
#    Xcode ran the UI tests concurrently with each other.
# 2. Xcode.app holding the project open re-imposes its own stale
#    in-memory scheme onto disk within seconds of any regen. The stale
#    blob this project has seen downgrades <Scheme version> from "1.7" to
#    "1.3", mangles the main app target's BuildableName (e.g. to
#    "FINAL|FINAL.app"), and drops runPostActionsOnFailure /
#    onlyGenerateCoverageForSpecifiedTargets — all while still carrying
#    parallelizable="NO" on the test targets, so check #1 alone gives
#    false confidence against this failure mode.
#
# This script re-checks the generated scheme after every regen:
#   - every <TestableReference> inside <TestAction> must carry
#     parallelizable="NO"
#   - the <Scheme version=...> attribute must be "1.7" (xcodegen's own
#     hardcoded value)
#   - <BuildAction runPostActionsOnFailure=...> must be "NO"
#   - <TestAction onlyGenerateCoverageForSpecifiedTargets=...> must be "NO"
#   - every <BuildableReference>'s BuildableName must start with its
#     sibling BlueprintName and contain no "|" — a general invariant (not
#     hardcoded to one product name) that catches the BuildableName
#     mangling for any target
#
# It does not hardcode the number of test targets or targets in general —
# it walks whatever entries are present, so adding/removing a target
# doesn't require touching this file.
#
# Usage: bash scripts/verify-scheme.sh [path-to-.xcscheme-or-dir]
#   With no argument, walks every *.xcscheme under the project's own
#   xcshareddata/xcschemes directory (the normal, production use).
#   With an argument, checks just that one file, or walks that directory —
#   this exists so a scratch/mutated copy can be checked in isolation for
#   regression testing.
# Exit 0 + "scheme OK" on success. Exit 1 naming the offending target(s)
# and attribute(s) on failure.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_SCHEMES_DIR="$PROJECT_DIR/final final.xcodeproj/xcshareddata/xcschemes"
TARGET="${1:-$DEFAULT_SCHEMES_DIR}"

SCHEME_FILES=()
if [ -f "$TARGET" ]; then
    SCHEME_FILES=("$TARGET")
elif [ -d "$TARGET" ]; then
    while IFS= read -r -d '' f; do
        SCHEME_FILES+=("$f")
    done < <(find "$TARGET" -name "*.xcscheme" -print0)
else
    echo "error: '$TARGET' is neither a file nor a directory." >&2
    exit 1
fi

fail=0
checked=0
bref_checked=0

check_scheme() {
    local scheme_file="$1"
    local scheme_name
    scheme_name="$(basename "$scheme_file")"
    local in_test_action=0
    local in_testable=0
    local parallelizable=""
    local target=""

    local scheme_version="__MISSING__"
    local run_post_actions="__MISSING__"
    local only_coverage="__MISSING__"

    local in_buildable_ref=0
    local buildable_name=""
    local blueprint_name=""

    while IFS= read -r line; do
        # --- scalar, file-wide attributes (independent of TestAction scope) ---
        if [[ "$scheme_version" == "__MISSING__" && "$line" =~ ^[[:space:]]*version[[:space:]]*=[[:space:]]*\"([^\"]*)\" ]]; then
            scheme_version="${BASH_REMATCH[1]}"
        fi
        if [[ "$line" == *"runPostActionsOnFailure"* ]]; then
            run_post_actions=$(printf '%s' "$line" | sed -E 's/.*runPostActionsOnFailure[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/')
        fi
        if [[ "$line" == *"onlyGenerateCoverageForSpecifiedTargets"* ]]; then
            only_coverage=$(printf '%s' "$line" | sed -E 's/.*onlyGenerateCoverageForSpecifiedTargets[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/')
        fi

        # --- BuildableReference: BuildableName must start with BlueprintName, no "|" ---
        if [[ "$line" == *"<BuildableReference"* ]]; then
            in_buildable_ref=1
            buildable_name=""
            blueprint_name=""
        fi
        if [ "$in_buildable_ref" -eq 1 ]; then
            if [[ "$line" == *"BuildableName"* ]]; then
                buildable_name=$(printf '%s' "$line" | sed -E 's/.*BuildableName[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/')
            fi
            if [[ "$line" == *"BlueprintName"* ]]; then
                blueprint_name=$(printf '%s' "$line" | sed -E 's/.*BlueprintName[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/')
            fi
        fi
        if [[ "$line" == *"</BuildableReference>"* ]]; then
            in_buildable_ref=0
            bref_checked=$((bref_checked + 1))
            if [[ "$buildable_name" == *"|"* ]]; then
                echo "error: BuildableReference '$blueprint_name' in $scheme_name has a '|' in BuildableName (\"$buildable_name\") — looks like the known Xcode-reimposed-stale-scheme mangling." >&2
                fail=1
            elif [[ -n "$blueprint_name" && "$buildable_name" != "$blueprint_name"* ]]; then
                echo "error: BuildableReference '$blueprint_name' in $scheme_name has BuildableName \"$buildable_name\", which does not start with its BlueprintName." >&2
                fail=1
            fi
        fi

        # --- existing parallelizable check, scoped to TestAction ---
        if [[ "$line" == *"<TestAction"* ]]; then
            in_test_action=1
        fi
        if [ "$in_test_action" -eq 1 ]; then
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
        fi
    done < "$scheme_file"

    if [ "$scheme_version" = "__MISSING__" ]; then
        echo "error: $scheme_name has no <Scheme version=...> attribute (expected \"1.7\")." >&2
        fail=1
    elif [ "$scheme_version" != "1.7" ]; then
        echo "error: $scheme_name has <Scheme version=\"$scheme_version\"> (expected \"1.7\") — looks like the known Xcode-reimposed-stale-scheme downgrade." >&2
        fail=1
    fi

    if [ "$run_post_actions" = "__MISSING__" ]; then
        echo "error: $scheme_name is missing runPostActionsOnFailure on <BuildAction> (expected \"NO\")." >&2
        fail=1
    elif [ "$run_post_actions" != "NO" ]; then
        echo "error: $scheme_name has runPostActionsOnFailure=\"$run_post_actions\" (expected \"NO\")." >&2
        fail=1
    fi

    if [ "$only_coverage" = "__MISSING__" ]; then
        echo "error: $scheme_name is missing onlyGenerateCoverageForSpecifiedTargets on <TestAction> (expected \"NO\")." >&2
        fail=1
    elif [ "$only_coverage" != "NO" ]; then
        echo "error: $scheme_name has onlyGenerateCoverageForSpecifiedTargets=\"$only_coverage\" (expected \"NO\")." >&2
        fail=1
    fi
}

for f in "${SCHEME_FILES[@]}"; do
    check_scheme "$f"
done

if [ "$checked" -eq 0 ]; then
    echo "error: no <TestableReference> entries found under '$TARGET' — scheme may be malformed." >&2
    exit 1
fi

if [ "$fail" -ne 0 ]; then
    exit 1
fi

echo "scheme OK — $checked test target(s) verified parallelizable=\"NO\", $bref_checked BuildableReference(s) verified, version/runPostActionsOnFailure/onlyGenerateCoverageForSpecifiedTargets verified for ${#SCHEME_FILES[@]} scheme file(s)."
