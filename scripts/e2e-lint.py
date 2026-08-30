#!/usr/bin/env python3
"""Pre-flight lint for agent-authored XCUITest e2e classes.

Encodes the mechanically checkable subset of the e2e-verify skill's
"Proven patterns" section (.claude/skills/e2e-verify/SKILL.md) so a
test-authoring bug is caught before it costs a VM cycle plus a diagnosis
round. Run it after authoring, before the test joins the e2e queue:

    python3 scripts/e2e-lint.py                  # lints the scratch file
    python3 scripts/e2e-lint.py path/to/Test.swift ...

Exit codes: 0 = clean or warnings only, 2 = at least one error.

A finding can be suppressed where the flagged usage is genuinely intended:
put `e2e-lint: allow <rule-id>` in a comment on the same line or the line
above. Suppressions are printed so they never pass silently.
"""

import re
import sys
from pathlib import Path

DEFAULT_TARGET = "final finalUITests/E2EScratchTests.swift"

# Single-line rules: (id, severity, regex, message). Messages cite the
# proven pattern they enforce.
SINGLE = [
    (
        "cgevent",
        "error",
        r"\bCGEvent\b",
        "CGEvent posting is untrusted in the VM guest (no HID trust) — "
        "modifiers and drags silently no-op. Use XCUIElement APIs and the "
        "existing helpers.",
    ),
    (
        "bare-app",
        "error",
        r"XCUIApplication\(\)",
        "Bare XCUIApplication() skips fixture isolation. Use "
        "XCUIApplication.targetApp() + launchForTesting(fixturePath:).",
    ),
    (
        "raw-launch",
        "error",
        r"\.launch\(\)",
        "Direct .launch() skips FF_UI_TESTING and the fixture copy. Use "
        "launchForTesting(fixturePath:).",
    ),
    (
        "nshome",
        "error",
        r"NSHomeDirectory\(\)",
        "The runner's home is containerized — NSHomeDirectory() points at "
        "the xctrunner container, not the app's home. Use AppFileReader / "
        "E2EShotDir from UITestHelpers.swift.",
    ),
    (
        "abs-path",
        "error",
        r'"/Users/(?!\\\(NSUserName)',
        "Hardcoded host paths don't exist inside the VM guest. Read app "
        "files via AppFileReader; write screenshots via E2EShotDir. "
        '(The portable "/Users/\\(NSUserName())" idiom is allowed.)',
    ),
    (
        "cmd-w",
        "error",
        r'typeKey\(\s*"w"\s*,\s*(?:modifierFlags:\s*)?\.command',
        "⌘W is rebound app-wide to Close Project — it tears the document "
        "down, and every later assertion fails against an empty project "
        "picker. Close auxiliary windows via their close button. (If "
        "closing the project is genuinely the goal, suppress with "
        "`e2e-lint: allow cmd-w`.)",
    ),
    (
        "home-url",
        "warn",
        r"homeDirectoryForCurrentUser",
        "homeDirectoryForCurrentUser resolves to the xctrunner container "
        "in the guest. Prefer AppFileReader from UITestHelpers.swift, "
        "which already tries the correct roots.",
    ),
    (
        "sleep",
        "warn",
        r"(?:Thread\.sleep|\busleep\(|(?<![\w.])sleep\()",
        "Fixed sleeps are the leading flake seed — every quarantined test "
        "in known-flaky.txt lives in a sleep-heavy file. Prefer "
        "waitForExistenceOrFail / waitForValue / waitForLabel; keep a "
        "sleep only where nothing observable changes (and say so in a "
        "comment).",
    ),
    (
        "dialog-button",
        "warn",
        r'app\.buttons\["(?:OK|Save|Cancel|Don\'t Save|Delete|Replace)"\]',
        'A bare app.buttons["OK"-style] query can resolve to the guest\'s '
        "Touch Bar mirror of a dialog's default button. Use "
        "clickDialogButton(_:) or scope to app.dialogs.",
    ),
    (
        "windows-dialog-button",
        "warn",
        r'app\.windows\.buttons\['
        r'"(?:OK|Save|Cancel|Don\'t Save|Delete|Replace)"\]',
        "Alerts raised from menu commands (NSAlert.runModal()) are "
        "top-level Dialog siblings of the windows — app.windows.buttons "
        "can never reach them. Query app.dialogs.buttons.",
    ),
    (
        "raw-typetext",
        "warn",
        r"app\.typeText\(",
        "typeText can silently drop characters mid-string while "
        "synthesizing keystrokes, especially under VM load (CONFIRMED live — "
        "see typeTextVerifyingLanded's doc comment in UITestHelpers.swift). "
        "Prefer app.typeTextVerifyingLanded(_:) when the typed text must "
        "land intact and is the last static text in the editor.",
    ),
]

# Co-occurrence rules: both regexes within WINDOW code lines.
WINDOW = 3
PAIR = [
    (
        "statictext-contains",
        "error",
        r"staticTexts\s*$|staticTexts\.(?:matching|containing|element)",
        r"\bCONTAINS\b",
        "CONTAINS predicates against staticTexts app-wide crash: heading "
        "containers carry an NSNumber value, and `value CONTAINS` on that "
        "throws NSInvalidArgumentException. Scope the query to the "
        "editor-area container and match on textViews/value instead.",
    ),
    (
        "menuitem-label",
        "error",
        r"\bmenuItems\b",
        r"\blabel\b",
        "NSMenuItem exposes only `title` and `identifier` to XCUITest — a "
        "`label` query against menuItems matches nothing, forever, while "
        "the item sits open on screen. Query by title or identifier.",
    ),
    (
        "statictext-firstmatch",
        "warn",
        r"staticTexts\s*$|staticTexts\.(?:matching|containing|element)",
        r"\bfirstMatch\b",
        "Every editor heading matches three StaticTexts, and .firstMatch "
        "resolves to the *sidebar mirror*, not the editor. Scope the "
        "query to the editor-area container explicitly.",
    ),
    (
        "positional-index-boundbyindex",
        "error",
        r"\ballElementsBoundByIndex\b",
        r"\.last\b|\.first\b|\.element\(\s*boundBy:",
        "allElementsBoundByIndex snapshots a positional index into the AX "
        "tree -- a WKWebView mid-repaint can fail ONE index's `.exists` "
        "while the tree still holds several live elements, so trusting "
        "`.last`/`.first`/`.element(boundBy:)` off it can misread a "
        "populated tree as empty (CONFIRMED live: typeTextVerifyingLanded's "
        "old implementation did exactly this -- see its doc comment in "
        "UITestHelpers.swift). Scan every element instead and skip ones "
        "the tree has invalidated, e.g. editorContainsText/editorStaticText "
        "in UITestHelpers.swift.",
    ),
]

# Negative co-occurrence rules: pattern A flagged unless its required
# safety pattern B appears within NEG_WINDOW code lines either side. Unlike
# PAIR above (which flags when two patterns land together), these flag a
# pattern that shows up ALONE -- the shape of the block-table-seeding bug
# fixed 2026-08-29 (see UITestHelpers.swift's `FixtureDatabase.seedMarkdown`
# doc comment): 5 call sites wrote `content.markdown` directly without also
# clearing `block`, and ContentView+ProjectLifecycle's loadInitialContent
# silently discards a content-only seed whenever `block` rows already exist
# (the committed fixture ships some), so the write was never read back.
NEG_WINDOW = 2
NEGATIVE_PAIR = [
    (
        "content-seed-missing-block-clear",
        "error",
        r"UPDATE\s+content\s+SET\s+markdown",
        r"DELETE\s+FROM\s+block",
        "Seeding content.markdown without also clearing `block` in the same "
        "statement (or an adjacent line) is silently discarded: "
        "ContentView+ProjectLifecycle.loadInitialContent assembles the "
        "document from `block` rows whenever any exist and never reads "
        "content.markdown in that case -- the committed fixture ships block "
        "rows. Use FixtureDatabase.seedMarkdown(fixturePath:markdown:"
        "appending:) from UITestHelpers.swift instead of raw SQL.",
    ),
]

SUPPRESS_RE = re.compile(r"e2e-lint:\s*allow\s+([\w-]+)")


def suppressions_for(lines, idx):
    found = set()
    for j in (idx - 1, idx):
        if 0 <= j < len(lines):
            for m in SUPPRESS_RE.finditer(lines[j]):
                found.add(m.group(1))
    return found


def is_comment(line):
    return line.lstrip().startswith("//")


def lint_file(path):
    findings = []  # (severity, line_no, rule_id, message, suppressed)
    try:
        lines = Path(path).read_text().splitlines()
    except OSError as e:
        print(f"e2e-lint: cannot read {path}: {e}", file=sys.stderr)
        return None

    for i, line in enumerate(lines):
        if is_comment(line):
            continue
        sup = suppressions_for(lines, i)
        for rule_id, sev, pattern, msg in SINGLE:
            if re.search(pattern, line):
                findings.append((sev, i + 1, rule_id, msg, rule_id in sup))

    # Sliding window over code lines only, so doc comments that merely
    # *mention* a pattern don't trip the co-occurrence rules.
    code = [(i, ln) for i, ln in enumerate(lines) if not is_comment(ln)]
    for rule_id, sev, pat_a, pat_b, msg in PAIR:
        flagged = set()
        for w in range(len(code)):
            window = code[w : w + WINDOW]
            if not window:
                continue
            hit_a = [i for i, ln in window if re.search(pat_a, ln)]
            hit_b = [i for i, ln in window if re.search(pat_b, ln)]
            if hit_a and hit_b:
                anchor = hit_a[0]
                if anchor in flagged:
                    continue
                flagged.add(anchor)
                sup = suppressions_for(lines, anchor)
                findings.append(
                    (sev, anchor + 1, rule_id, msg, rule_id in sup)
                )

    # Same code-lines-only list as PAIR above, but inverted: flag pattern A
    # unless pattern B shows up within NEG_WINDOW code lines either side.
    for rule_id, sev, pat_a, pat_b, msg in NEGATIVE_PAIR:
        for pos, (idx, ln) in enumerate(code):
            if not re.search(pat_a, ln):
                continue
            nearby = code[max(0, pos - NEG_WINDOW) : pos + NEG_WINDOW + 1]
            if any(re.search(pat_b, ln2) for _, ln2 in nearby):
                continue
            sup = suppressions_for(lines, idx)
            findings.append((sev, idx + 1, rule_id, msg, rule_id in sup))

    return findings


def main(argv):
    repo_root = Path(__file__).resolve().parent.parent
    targets = argv[1:] or [str(repo_root / DEFAULT_TARGET)]
    errors = warnings = 0
    for target in targets:
        findings = lint_file(target)
        if findings is None:
            return 2
        for sev, line_no, rule_id, msg, suppressed in sorted(
            findings, key=lambda f: f[1]
        ):
            tag = "suppressed" if suppressed else sev
            print(f"{target}:{line_no}: [{tag}] {rule_id}: {msg}")
            if not suppressed:
                if sev == "error":
                    errors += 1
                else:
                    warnings += 1
    if errors:
        print(
            f"\ne2e-lint: {errors} error(s), {warnings} warning(s) — "
            "fix errors before spending a VM cycle."
        )
        return 2
    if warnings:
        print(f"\ne2e-lint: {warnings} warning(s), no errors.")
    else:
        print("e2e-lint: clean.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
