#!/bin/bash
#
# e2e-lint-position-test.sh — fixture-based test for the "editor text found by
# its position" rules of scripts/e2e-lint.py (t-792d86a1):
#
#   editor-text-by-position (error): element(boundBy: N), .firstMatch or
#       allElementsBoundByIndex[N] on an unfiltered editor text collection, in
#       a function that types or clicks.
#   editor-text-prefix-walk (warn):  app.editorStaticText(startingWith:)
#       WITHOUT exactLine: whose handle is then clicked or typed through -- the
#       literal lookup RebuildFlushTypingRaceE2ETests used before commit 87b173f.
#
# Writes small Swift fixtures under a throwaway directory in $TMPDIR (never
# inside final finalUITests), runs the lint on each, and asserts on the exit
# code, the reported line and the message. The last two cases run the lint on
# the real repo: the default scratch-file run must exit 0 and no permanent UI
# test may carry an unsuppressed editor-text-by-position error. Removes its own
# fixture directory on exit.
#
# Run: bash scripts/tests/e2e-lint-position-test.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LINT="$SCRIPT_DIR/e2e-lint.py"

if [ ! -f "$LINT" ]; then
    echo "FAIL: lint script not found: $LINT" >&2
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

# ── Fixture setup ────────────────────────────────────────────────────

FIX="$(mktemp -d "${TMPDIR:-/tmp}/e2e-lint-position-test.XXXXXX")"

cleanup() {
    if [ -n "${FIX:-}" ] && [ -d "$FIX" ]; then
        rm -rf "$FIX" 2>/dev/null
    fi
}
trap cleanup EXIT

# fixture NAME < swift-source  -- writes $FIX/NAME.swift from stdin.
fixture() {
    cat > "$FIX/$1.swift"
}

# target_line NAME -- the line number of the first `TARGET` marker comment.
target_line() {
    grep -n 'TARGET' "$FIX/$1.swift" | head -1 | cut -d: -f1
}

# run_lint NAME -- sets $out (stdout+stderr) and $rc (exit code).
run_lint() {
    out="$(python3 "$LINT" "$FIX/$1.swift" 2>&1)"
    rc=$?
}

# assert_flagged NAME RULE SEVERITY -- the lint reports RULE as SEVERITY on
# the line carrying the TARGET marker of fixture NAME.
assert_flagged() {
    local name="$1" rule="$2" severity="$3" line
    line="$(target_line "$name")"
    run_lint "$name"
    if printf '%s\n' "$out" | grep -qE ":${line}: \[${severity}\] ${rule}:"; then
        pass "$name: $rule flagged as $severity on line $line"
    else
        fail "$name: expected $rule as $severity on line $line; lint said: $out"
    fi
}

# assert_not_flagged NAME RULE -- the lint reports no RULE finding (flagged
# or suppressed) anywhere in fixture NAME.
assert_not_flagged() {
    local name="$1" rule="$2"
    run_lint "$name"
    if printf '%s\n' "$out" | grep -qE "\] ${rule}:"; then
        fail "$name: expected no $rule finding; lint said: $out"
    else
        pass "$name: no $rule finding"
    fi
}

# ── Must be flagged: editor-text-by-position (error) ─────────────────

fixture bound_by_literal <<'EOF'
import XCTest

final class FixtureTests: XCTestCase {
    var app: XCUIApplication!

    func testTypesIntoSecondParagraph() {
        let second = app.editorArea.staticTexts.element(boundBy: 1) // TARGET
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        app.typeTextVerifyingLanded(" more")
    }
}
EOF
assert_flagged bound_by_literal editor-text-by-position error
assert_eq "$rc" "2" "bound_by_literal: lint exits 2 (error)"
assert_contains "$out" "exactLine: text" "bound_by_literal: message names the by-text helper (editorStaticText ... exactLine:)"
assert_contains "$out" "editorStaticText(startingWith:" "bound_by_literal: message names editorStaticText(startingWith:"
assert_contains "$out" "placeCaretByClicking" "bound_by_literal: message names placeCaretByClicking for the caret case"

fixture first_match_click <<'EOF'
import XCTest

final class FixtureTests: XCTestCase {
    var app: XCUIApplication!

    func testClicksFirstLeaf() {
        let leaf = app.editorArea.staticTexts.firstMatch // TARGET
        leaf.click()
    }
}
EOF
assert_flagged first_match_click editor-text-by-position error

fixture subscript_index <<'EOF'
import XCTest

final class FixtureTests: XCTestCase {
    var app: XCUIApplication!

    func testClicksThirdLeaf() {
        let leaf = app.editorArea.staticTexts.allElementsBoundByIndex[2] // TARGET
        leaf.click()
    }
}
EOF
assert_flagged subscript_index editor-text-by-position error

fixture alias_held <<'EOF'
import XCTest

final class FixtureTests: XCTestCase {
    var app: XCUIApplication!

    func testClicksThirdThroughAName() {
        let paragraphs = app.editorArea.staticTexts
        let third = paragraphs.element(boundBy: 2) // TARGET
        third.click()
    }
}
EOF
assert_flagged alias_held editor-text-by-position error

fixture chain_over_lines <<'EOF'
import XCTest

final class FixtureTests: XCTestCase {
    var app: XCUIApplication!

    func testClicksFirstLeafOfAMultiLineChain() {
        let leaf = app.editorArea // TARGET
            .staticTexts
            .element(boundBy: 0)
        leaf.click()
    }
}
EOF
assert_flagged chain_over_lines editor-text-by-position error

fixture click_through_helper <<'EOF'
import XCTest

final class FixtureTests: XCTestCase {
    var app: XCUIApplication!

    func testClicksOnlyThroughASuiteHelper() {
        let second = app.editorArea.staticTexts.element(boundBy: 1) // TARGET
        XCTAssertTrue(second.exists)
        app.clickIntoEditor()
    }
}
EOF
assert_flagged click_through_helper editor-text-by-position error

fixture paren_in_message <<'EOF'
import XCTest

final class FixtureTests: XCTestCase {
    var app: XCUIApplication!

    func testReportsOnTheRightLineAfterAnUnbalancedParenInAMessage() {
        XCTAssertTrue(app.exists, "App (not running")
        let leaf = app.editorArea.staticTexts.element(boundBy: 0) // TARGET
        leaf.click()
    }
}
EOF
assert_flagged paren_in_message editor-text-by-position error

fixture text_views_app_wide <<'EOF'
import XCTest

final class FixtureTests: XCTestCase {
    var app: XCUIApplication!

    func testTypesIntoFirstTextView() {
        let view = app.textViews.firstMatch // TARGET
        view.typeText("x")
    }
}
EOF
assert_flagged text_views_app_wide editor-text-by-position error

# ── Must NOT be flagged: by-text lookups, scans, non-clicking tests ──

fixture by_text_predicate <<'EOF'
import XCTest

final class FixtureTests: XCTestCase {
    var app: XCUIApplication!

    func testClicksParagraphByItsExactValue() {
        let leaf = app.editorArea.staticTexts.matching(NSPredicate(format: "value == %@", "Alpha paragraph text.")).firstMatch
        leaf.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }
}
EOF
assert_not_flagged by_text_predicate editor-text-by-position
assert_not_flagged by_text_predicate editor-text-prefix-walk

fixture by_text_helper <<'EOF'
import XCTest

final class FixtureTests: XCTestCase {
    var app: XCUIApplication!
    private static let alphaText = "Alpha paragraph text."

    func testClicksParagraphThroughTheExactTextHelper() {
        guard let alpha = app.editorStaticText(startingWith: Self.alphaText, exactLine: Self.alphaText, timeout: 10) else {
            XCTFail("Alpha not found")
            return
        }
        alpha.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).click()
        app.typeTextVerifyingLanded(" more")
    }
}
EOF
assert_not_flagged by_text_helper editor-text-by-position
assert_not_flagged by_text_helper editor-text-prefix-walk
assert_eq "$rc" "0" "by_text_helper: lint exits 0"

fixture scan_loop <<'EOF'
import XCTest

final class FixtureTests: XCTestCase {
    var app: XCUIApplication!

    func testScansAFilteredCollectionAndClicksTheMatch() {
        let leaves = app.editorArea.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "Alpha"))
        for index in 0..<leaves.count {
            let leaf = leaves.element(boundBy: index)
            if leaf.exists {
                leaf.click()
                break
            }
        }
    }
}
EOF
assert_not_flagged scan_loop editor-text-by-position

fixture reads_only <<'EOF'
import XCTest

final class FixtureTests: XCTestCase {
    var app: XCUIApplication!
    private static let alphaText = "Alpha paragraph text."

    func testReadsTheFirstLeafFrame() {
        let frame = app.editorArea.staticTexts.element(boundBy: 0).frame
        XCTAssertGreaterThan(frame.width, 0)
    }

    func testClicksByText() {
        guard let alpha = app.editorStaticText(startingWith: Self.alphaText, exactLine: Self.alphaText, timeout: 10) else { return }
        alpha.click()
    }
}
EOF
assert_not_flagged reads_only editor-text-by-position

fixture action_word_in_message <<'EOF'
import XCTest

final class FixtureTests: XCTestCase {
    var app: XCUIApplication!

    func testMessagesThatMentionClicksAndPresses() {
        let frame = app.editorArea.staticTexts.element(boundBy: 0).frame
        XCTAssertGreaterThan(frame.width, 0, "the leaf is clicked (or not)")
        XCTAssertNotNil(app.editorStaticText(startingWith: "Alpha", timeout: 10),
                        "Alpha is on screen after two quick Cmd-Z presses (or the line is gone)")
    }
}
EOF
assert_not_flagged action_word_in_message editor-text-by-position
assert_not_flagged action_word_in_message editor-text-prefix-walk

fixture other_collections <<'EOF'
import XCTest

final class FixtureTests: XCTestCase {
    var app: XCUIApplication!

    func testClicksInAWindowAndASheet() {
        let window = app.windows.firstMatch
        let row = window.staticTexts.element(boundBy: 0)
        row.click()
        let field = app.sheets.firstMatch.textFields.firstMatch
        field.typeText("x")
    }
}
EOF
assert_not_flagged other_collections editor-text-by-position

fixture comment_only <<'EOF'
import XCTest

final class FixtureTests: XCTestCase {
    var app: XCUIApplication!

    func testMentionsTheOldShapeInAComment() {
        // The old shape was app.editorArea.staticTexts.element(boundBy: 0).click()
        app.editorStaticText(startingWith: "x", exactLine: "x", timeout: 1)?.click()
    }
}
EOF
assert_not_flagged comment_only editor-text-by-position

# ── Suppression comment ──────────────────────────────────────────────

fixture suppressed <<'EOF'
import XCTest

final class FixtureTests: XCTestCase {
    var app: XCUIApplication!

    func testClicksFirstLeafOnPurpose() {
        // e2e-lint: allow editor-text-by-position -- the position IS what this test is about.
        let leaf = app.editorArea.staticTexts.element(boundBy: 0)
        leaf.click()
    }
}
EOF
run_lint suppressed
assert_contains "$out" "[suppressed] editor-text-by-position" "suppressed: the finding is printed as suppressed"
assert_not_contains "$out" "[error]" "suppressed: no error remains"
assert_eq "$rc" "0" "suppressed: lint exits 0"

# ── editor-text-prefix-walk (warn): the 2026-11-18 lookup ────────────

fixture prefix_only_then_click <<'EOF'
import XCTest

final class FixtureTests: XCTestCase {
    var app: XCUIApplication!
    private static let alphaText = "Alpha paragraph text."

    func testClicksAlphaFoundByPrefixOnly() {
        guard let alphaParagraph = app.editorStaticText(startingWith: Self.alphaText, timeout: 10) else { // TARGET
            XCTFail("Alpha not found")
            return
        }
        alphaParagraph.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).click()
    }
}
EOF
assert_flagged prefix_only_then_click editor-text-prefix-walk warn
assert_eq "$rc" "0" "prefix_only_then_click: a warning alone does not fail the lint (exit 0)"
assert_contains "$out" "exactLine:" "prefix_only_then_click: message names exactLine:"
assert_contains "$out" "editorStaticText(startingWith: text, exactLine: text" "prefix_only_then_click: message names the by-text helper call"

fixture prefix_only_multiline <<'EOF'
import XCTest

final class FixtureTests: XCTestCase {
    var app: XCUIApplication!
    private static let betaText = "Beta paragraph text."

    func testClicksBetaFoundByPrefixOnlyOverSeveralLines() {
        guard let beta = app.editorStaticText( // TARGET
            startingWith: Self.betaText,
            timeout: 10
        ) else { return }
        beta.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).click()
    }

    func testClicksBetaFoundByExactTextOverSeveralLines() {
        guard let beta = app.editorStaticText(
            startingWith: Self.betaText,
            exactLine: Self.betaText,
            timeout: 10
        ) else { return }
        beta.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).click()
    }
}
EOF
assert_flagged prefix_only_multiline editor-text-prefix-walk warn
prefix_multiline_hits="$(printf '%s\n' "$out" | grep -c '\] editor-text-prefix-walk:')"
assert_eq "$prefix_multiline_hits" "1" "prefix_only_multiline: only the prefix-only function is flagged, not the exactLine one"

fixture prefix_only_no_click <<'EOF'
import XCTest

final class FixtureTests: XCTestCase {
    var app: XCUIApplication!

    func testOnlyChecksTheParagraphIsThere() {
        let leaf = app.editorStaticText(startingWith: "Alpha", timeout: 10)
        XCTAssertNotNil(leaf)
        XCTAssertNotNil(app.editorStaticText(startingWith: "Beta", timeout: 10))
        app.typeKey("k", modifierFlags: [.command, .shift])
    }
}
EOF
assert_not_flagged prefix_only_no_click editor-text-prefix-walk

# ── The real repo ────────────────────────────────────────────────────

repo_out="$(python3 "$LINT" 2>&1)"
repo_rc=$?
assert_eq "$repo_rc" "0" "repo: python3 scripts/e2e-lint.py (the scratch file) exits 0"

suite_out="$(python3 "$LINT" "$REPO_ROOT"/final\ finalUITests/*.swift 2>&1)"
suite_hits="$(printf '%s\n' "$suite_out" | grep -c '\[error\] editor-text-by-position:')"
assert_eq "$suite_hits" "0" "repo: no permanent UI test carries an unsuppressed editor-text-by-position error"

# ── Summary ──────────────────────────────────────────────────────────

echo ""
echo "----------------------------------------"
echo "Results: $pass_count passed, $fail_count failed"

if [ "$fail_count" -gt 0 ]; then
    exit 1
fi
exit 0
