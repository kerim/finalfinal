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

Separately, --ratchet stops fixed sleeps from creeping back into the
*permanent* suite (final finalUITests/*.swift, scratch excluded) — the
per-file "sleep" rule count must never go UP from a baseline:

    python3 scripts/e2e-lint.py --ratchet
    python3 scripts/e2e-lint.py --ratchet --baseline path/to/baseline.json
    python3 scripts/e2e-lint.py --ratchet --update-baseline

--update-baseline regenerates the baseline from the CURRENT counts (run
after removing sleeps, to lock the lower number in) and always exits 0.
Without it, --ratchet exits 2 naming any file above its baseline count;
a file with no baseline entry is treated as baseline 0 (a brand-new file
with sleeps in it fails immediately, same as any existing file gaining
one). The baseline file itself is generated, never hand-edited.
"""

import json
import re
import sys
from pathlib import Path

DEFAULT_TARGET = "final finalUITests/E2EScratchTests.swift"
DEFAULT_BASELINE = "scripts/e2e-lint-baseline.json"
UI_TEST_DIR = "final finalUITests"
SCRATCH_CLASS_FILE = "E2EScratchTests.swift"
SLEEP_PATTERN = r"(?:Thread\.sleep|\busleep\(|(?<![\w.])sleep\()"

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
        "the xctrunner container, not the app's home. Use AppFileHelper to "
        "read app files, and attachEvidenceScreenshot(_:name:) to attach "
        "screenshots — both in UITestHelpers.swift.",
    ),
    (
        "abs-path",
        "error",
        r'"/Users/(?!\\\(NSUserName)',
        "Hardcoded host paths don't exist inside the VM guest. Read app "
        "files via AppFileHelper; attach screenshots with "
        "attachEvidenceScreenshot(_:name:). "
        '(The portable "/Users/\\(NSUserName())" idiom is allowed.)',
    ),
    (
        "shotdir-write",
        "error",
        r"\bE2EShotDir\s*\.\s*(?:url|path)\b",
        "A test's own write through E2EShotDir cannot work: the macOS "
        "XCUITest runner is sandboxed (app-sandbox=true, read-only \"/\") "
        "and vmtest's shot dir sits outside its container, so the write "
        "fails and a `try?` swallows it — the evidence never reaches the "
        "host. Use attachEvidenceScreenshot(_:name:) in UITestHelpers.swift, "
        "which goes through XCTAttachment's privileged export path. "
        "(E2EShotDir remains the env-var contract for host-side tooling "
        "only; see its doc comment.)",
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
        "in the guest. Prefer AppFileHelper from UITestHelpers.swift, "
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

# Co-occurrence rules with an exemption: pattern A and pattern B within
# WINDOW code lines, unless pattern C also appears in that window.
PAIR_UNLESS = [
    (
        "boundbyindex-bulk-read",
        "error",
        r"\ballElementsBoundByIndex\b",
        r"\.(?:compactMap|flatMap|map|reduce|filter)\b",
        r"\.exists\b",
        "Reading `.value`/`.label` off `allElementsBoundByIndex` in bulk "
        "(map/compactMap/reduce) re-resolves every element against a FRESH "
        "snapshot, so one element the tree drops mid-loop (the status-bar "
        "word count inside editor-area vanishes when a selection collapses) "
        "ends the test with 'Failed to get matching snapshot: No matches "
        "found for Element at index N' -- a hard XCTest failure, not a nil "
        "(CONFIRMED live: write-queue 3b M7, 2026-10-06). Read the whole "
        "tree from one snapshot -- editorStaticTextValues() in "
        "UITestQueryAndFixtureHelpers.swift -- or guard each element with "
        "`.exists` first.",
    ),
]

# Editor text found by its POSITION in the list (t-792d86a1). A handle built
# from `element(boundBy: 2)`, `.firstMatch` on an unfiltered collection or
# `allElementsBoundByIndex[2]` is re-resolved against the live accessibility
# tree at EVERY use, so a row the app adds or reorders while the test is
# working (a bibliography rebuild, a re-render) moves the position under it
# and the click or the typing lands in a different paragraph. CONFIRMED
# live: RebuildFlushTypingRaceE2ETests (2026-11-18, repaired in commit
# 87b173f). Both rules below are only checked in a function that types or
# clicks -- a position read just to report or assert on is harmless.
#
# 1. editor-text-by-position (error): the shapes with NO text filter between
#    the collection and the positional accessor, on the editor's own text
#    collections (editorArea, or app-wide staticTexts / textViews), directly
#    or through a name that holds the unfiltered collection. `.matching(...)`,
#    a string subscript and a scan loop over a filtered collection are
#    by-text and never flagged. (allElementsBoundByIndex followed by
#    .first/.last/.element(boundBy:) stays with the older
#    positional-index-boundbyindex rule above.)
# 2. editor-text-prefix-walk (warn): the literal shape that failed on
#    2026-11-18 -- editorStaticText(startingWith:) WITHOUT `exactLine:`,
#    whose handle is then clicked or typed through. Without `exactLine:`
#    the helper goes straight to an index walk (allElementsBoundByIndex) and
#    returns a handle bound to a POSITION; with it, the paragraph is first
#    found by one exact-value query. A warning, not an error: a heading
#    container or a leaf followed by an inline link has no single exact text,
#    and prefix matching is the right tool for those.
POSITION_RULE_ID = "editor-text-by-position"
POSITION_RULE_SEVERITY = "error"
POSITION_RULE_MESSAGE = (
    "This finds editor text by its POSITION in the list (`element(boundBy: N)`, "
    "`.firstMatch` on an unfiltered collection, `allElementsBoundByIndex[N]`) "
    "in a function that types or clicks. The position is re-read at every "
    "use, so a row the app adds or reorders while the test is working (a "
    "rebuild, a re-render) moves it and the click or typing lands in a "
    "different paragraph (CONFIRMED live: RebuildFlushTypingRaceE2ETests, "
    "2026-11-18, commit 87b173f). Find the paragraph by its EXACT TEXT "
    "instead: app.editorStaticText(startingWith: text, exactLine: text, "
    "timeout:) in UITestQueryAndFixtureHelpers.swift (or, to put the caret "
    "in it, app.placeCaretByClicking(paragraphStartingWith: text, atEnd:, "
    "exactLine: text) in UITestHelpers.swift). If the position really is "
    "what the test is about, suppress with "
    "`e2e-lint: allow editor-text-by-position` and say why."
)
PREFIX_WALK_RULE_ID = "editor-text-prefix-walk"
PREFIX_WALK_RULE_SEVERITY = "warn"
PREFIX_WALK_RULE_MESSAGE = (
    "editorStaticText(startingWith:) without `exactLine:` finds the paragraph "
    "with an index walk (allElementsBoundByIndex), so the handle it returns "
    "is bound to a POSITION -- and this function then clicks or types through "
    "it. A row the app adds or reorders in between (a rebuild, a re-render) "
    "moves that position and the click or typing lands in a different "
    "paragraph (CONFIRMED live: this was the old RebuildFlushTypingRace"
    "E2ETests lookup, repaired in commit 87b173f). When the paragraph's "
    "complete text is known and is one text run, pass it as `exactLine:` -- "
    "app.editorStaticText(startingWith: text, exactLine: text, timeout:) "
    "finds it by exact value first (placeCaretByClicking(paragraphStarting"
    "With: text, atEnd:, exactLine: text) does the same). A heading "
    "container or a leaf followed by an inline link has no single exact "
    "text; prefix matching is right for those -- suppress with "
    "`e2e-lint: allow editor-text-prefix-walk` and say why."
)
POSITION_TEXT_COLLECTION = (
    r"(?:staticTexts|textViews"
    r"|descendants\(\s*matching:\s*\.(?:staticText|textView)\s*\))"
)
POSITION_ACCESSOR = (
    r"(?:firstMatch\b"
    r"|element\(\s*boundBy:\s*\d+\s*\)"
    r"|allElementsBoundByIndex\s*\[\s*\d+\s*\])"
)
POSITION_DIRECT_RE = re.compile(
    POSITION_TEXT_COLLECTION + r"\s*\.\s*" + POSITION_ACCESSOR
)
# `let paragraphs = app.editorArea.staticTexts` (or a one-line computed
# property) -- an unfiltered collection held in a name, indexed later.
POSITION_ALIAS_RE = re.compile(
    r"^\s*(?:(?:private|fileprivate|static|lazy)\s+)*(?:let|var)\s+(\w+)\s*"
    r"(?::\s*[\w.?]+)?\s*(?:=|\{)\s*(.+?)\s*\}?\s*$"
)
POSITION_ALIAS_TAIL_RE = re.compile(POSITION_TEXT_COLLECTION + r"\s*$")
# What counts as typing or clicking in a test function: the XCUIElement calls
# and the suite's own click / press / type helpers (clickIntoEditor,
# pressUndo, typeTextVerifyingLanded, ...).
POSITION_ACTION_RE = re.compile(
    r"\b(?:typeText\w*|typeKey|click\w*|doubleClick|rightClick|tripleClick"
    r"|press\w*|tap|moveCaretToDocumentEnd|placeCaretByClicking)\s*\("
)
# The helper call whose result is bound to a name (`guard let x = ...`), and
# what counts as clicking or typing through that name later in the function.
PREFIX_WALK_CALL_RE = re.compile(r"\beditorStaticText\s*\(\s*startingWith:")
PREFIX_WALK_BIND_RE = re.compile(
    r"(?:guard\s+let|if\s+let|let|var)\s+(\w+)\s*(?::[^=]+)?=\s*(?:try\s+)?"
    r"[\w.]*?editorStaticText\s*\(\s*startingWith:"
)
PREFIX_WALK_USE_RE = re.compile(
    r"\.coordinate\s*\(|" + POSITION_ACTION_RE.pattern
)
FUNC_RE = re.compile(r"\bfunc\s+[\w`]+")
RETURNS_ELEMENT_RE = re.compile(r"->[^{]*\bXCUIElement\b")

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


def strip_comments(lines, keep_strings):
    """Each line with its `//` comment removed (and, unless keep_strings, the
    contents of its string literals emptied so a brace or a call-looking
    word inside a message cannot confuse scope or action detection). Tracks
    triple-quoted strings across lines."""
    out = []
    in_multi = False
    for line in lines:
        buf = []
        i, n = 0, len(line)
        while i < n:
            if in_multi:
                j = line.find('"""', i)
                if j < 0:
                    i = n
                else:
                    in_multi = False
                    i = j + 3
                continue
            if line.startswith('"""', i):
                in_multi = True
                i += 3
                continue
            c = line[i]
            if c == '"':
                j = i + 1
                while j < n and line[j] != '"':
                    j += 2 if line[j] == "\\" else 1
                buf.append(line[i : j + 1] if keep_strings else '""')
                i = j + 1
                continue
            if line.startswith("//", i):
                break
            buf.append(c)
            i += 1
        out.append("".join(buf))
    return out


def function_scopes(code):
    """(start, end, returns_element) line ranges for every `func` body in
    `code` (comment- and string-stripped lines); nested funcs are listed too."""
    scopes = []
    for start, line in enumerate(code):
        m = FUNC_RE.search(line)
        if not m:
            continue
        sig, depth, opened, end = [], 0, False, None
        for j in range(start, len(code)):
            text = code[j][m.start() :] if j == start else code[j]
            for ch in text:
                if not opened:
                    if ch == "{":
                        opened, depth = True, 1
                    else:
                        sig.append(ch)
                elif ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0:
                        end = j
                        break
            if end is not None or (not opened and j - start > 8):
                break
        if end is not None:
            scopes.append(
                (start, end, bool(RETURNS_ELEMENT_RE.search("".join(sig))))
            )
    return scopes


def statements(cleaned, code):
    """(first_line_index, text, code_text) for each statement of the
    comment-stripped lines `cleaned`: a line that opens a parenthesis it does
    not close, or that is followed by a method-chain continuation (a line
    starting with `.`), is joined with what follows. `code_text` is the same
    statement with string contents emptied (`code`), for matching calls and
    names without reading a message; parentheses are counted on it too, so
    one inside a message cannot swallow the statements after it."""
    out = []
    cur_start, cur_text, cur_code, paren = None, "", "", 0
    for i, line in enumerate(cleaned):
        if not line.strip():
            continue
        continues = line.lstrip().startswith((".", "?."))
        if cur_start is not None and (paren > 0 or continues):
            cur_text += " " + line.strip()
            cur_code += " " + code[i].strip()
        else:
            if cur_start is not None:
                out.append((cur_start, cur_text, cur_code))
            cur_start, cur_text, cur_code, paren = (
                i, line.strip(), code[i].strip(), 0
            )
        paren = max(0, paren + code[i].count("(") - code[i].count(")"))
    if cur_start is not None:
        out.append((cur_start, cur_text, cur_code))
    return out


def editor_scoped(prefix):
    """True when `prefix` (the statement text before a text collection)
    roots the collection in the editor: `editorArea` / "editor-area", or the
    app itself (an app-wide staticTexts also reaches editor paragraphs)."""
    return bool(
        re.search(r"\beditorArea\b|editor-area", prefix)
        or re.search(r"\bapp\s*\.\s*$", prefix)
    )


def position_findings(lines):
    """Findings of the two position rules: (line_index, rule_id, severity,
    message), every one inside a function that types or clicks."""
    cleaned = strip_comments(lines, keep_strings=True)
    code = strip_comments(lines, keep_strings=False)
    scopes = function_scopes(code)
    file_acts = any(POSITION_ACTION_RE.search(ln) for ln in code)

    def region_of(idx):
        """(key, end, acts): the outermost function around idx, its last line,
        and whether it (or, for a function that hands an element back, its
        file) types or clicks. Outside any function the key is -1 and the
        whole file counts."""
        around = [s for s in scopes if s[0] <= idx <= s[1]]
        if not around:
            return -1, len(code), file_acts
        start, end, _ = min(around, key=lambda s: s[0])
        acts = any(POSITION_ACTION_RE.search(ln) for ln in code[start : end + 1])
        if not acts and any(s[2] for s in around):
            acts = file_acts
        return start, end, acts

    found = []
    by_position = (
        POSITION_RULE_ID, POSITION_RULE_SEVERITY, POSITION_RULE_MESSAGE
    )
    prefix_walk = (
        PREFIX_WALK_RULE_ID, PREFIX_WALK_RULE_SEVERITY, PREFIX_WALK_RULE_MESSAGE
    )
    aliases = {}  # region key -> [alias names] (-1 is visible everywhere)
    stmts = statements(cleaned, code)
    for pos, (first, text, code_text) in enumerate(stmts):
        key, end, acts = region_of(first)

        # Rule 1: a positional accessor straight on an unfiltered editor
        # text collection, or on a name that holds one.
        reported = False
        for m in POSITION_DIRECT_RE.finditer(text):
            if editor_scoped(text[: m.start()]):
                if acts:
                    found.append((first, *by_position))
                reported = True
                break
        if not reported:
            visible = aliases.get(-1, []) + (aliases.get(key, []) if key != -1 else [])
            for name in visible:
                if re.search(
                    r"\b" + re.escape(name) + r"\s*\.\s*" + POSITION_ACCESSOR, text
                ):
                    if acts:
                        found.append((first, *by_position))
                    break
        alias = POSITION_ALIAS_RE.match(text)
        if alias:
            tail = POSITION_ALIAS_TAIL_RE.search(alias.group(2))
            if tail and editor_scoped(alias.group(2)[: tail.start()]):
                aliases.setdefault(key, []).append(alias.group(1))

        # Rule 2: the prefix-only helper call whose handle is then clicked
        # or typed through (bound to a name used later in the function, or
        # clicked in the same statement).
        if PREFIX_WALK_CALL_RE.search(code_text) and "exactLine" not in code_text:
            bound = PREFIX_WALK_BIND_RE.search(code_text)
            if bound:
                name = re.compile(r"\b" + re.escape(bound.group(1)) + r"\b")
                used = any(
                    name.search(later_code) and PREFIX_WALK_USE_RE.search(later_code)
                    for line_no, _, later_code in stmts[pos + 1 :]
                    if line_no <= end
                )
            else:
                used = bool(PREFIX_WALK_USE_RE.search(code_text))
            if used:
                found.append((first, *prefix_walk))
    return found


def lint_positional_editor_text(lines):
    findings = []
    for idx, rule_id, severity, message in position_findings(lines):
        sup = suppressions_for(lines, idx)
        findings.append((severity, idx + 1, rule_id, message, rule_id in sup))
    return findings


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

    # PAIR with an exemption: A and B together in a window, unless C is too.
    # The window starts AT the A line, so a guard (C) a few lines below it counts.
    for rule_id, sev, pat_a, pat_b, pat_c, msg in PAIR_UNLESS:
        for pos, (idx, ln) in enumerate(code):
            if not re.search(pat_a, ln):
                continue
            window = code[pos : pos + WINDOW + 1]
            if not any(re.search(pat_b, w) for _, w in window):
                continue
            if any(re.search(pat_c, w) for _, w in window):
                continue
            sup = suppressions_for(lines, idx)
            findings.append((sev, idx + 1, rule_id, msg, rule_id in sup))

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

    findings.extend(lint_positional_editor_text(lines))

    return findings


def sleep_hit_count(path):
    """Per-file count of the "sleep" rule's un-suppressed hits, code lines
    only (comments excluded, same as lint_file's SINGLE-rule pass)."""
    lines = Path(path).read_text().splitlines()
    count = 0
    pattern = re.compile(SLEEP_PATTERN)
    for i, line in enumerate(lines):
        if is_comment(line):
            continue
        if pattern.search(line):
            if "sleep" in suppressions_for(lines, i):
                continue
            count += 1
    return count


def permanent_ui_test_files(repo_root):
    """Every *.swift directly under the UI test dir, excluding the scratch
    class — that file is deliberately overwritten with throwaway content on
    every branch, so it has no baseline of its own worth tracking."""
    ui_dir = repo_root / UI_TEST_DIR
    return sorted(
        f for f in ui_dir.glob("*.swift") if f.name != SCRATCH_CLASS_FILE
    )


def ratchet(repo_root, baseline_path, update_baseline):
    files = permanent_ui_test_files(repo_root)
    counts = {f.name: sleep_hit_count(f) for f in files}

    if update_baseline:
        baseline_path.write_text(
            json.dumps(counts, indent=2, sort_keys=True) + "\n"
        )
        print(
            f"e2e-lint --ratchet: wrote {baseline_path} "
            f"({sum(counts.values())} sleep hit(s) across {len(counts)} file(s))."
        )
        return 0

    try:
        baseline = json.loads(baseline_path.read_text())
    except FileNotFoundError:
        baseline = {}
    except (OSError, json.JSONDecodeError) as e:
        print(f"e2e-lint --ratchet: cannot read {baseline_path}: {e}", file=sys.stderr)
        return 2

    regressions = []
    for name, count in sorted(counts.items()):
        base = baseline.get(name, 0)
        if count > base:
            regressions.append((name, count, base))

    if regressions:
        for name, count, base in regressions:
            print(
                f"e2e-lint --ratchet: {name}: {count} sleep hit(s), "
                f"baseline is {base} — new fixed sleeps are not allowed in "
                "the permanent suite."
            )
        print(
            f"\ne2e-lint --ratchet: {len(regressions)} file(s) regressed. "
            "Remove the sleep(s), or if this baseline itself is stale "
            "after a genuine cleanup, re-run with --update-baseline."
        )
        return 2

    print(
        f"e2e-lint --ratchet: clean — {sum(counts.values())} sleep hit(s) "
        f"across {len(counts)} file(s), none above baseline."
    )
    return 0


def main(argv):
    repo_root = Path(__file__).resolve().parent.parent

    if "--ratchet" in argv[1:]:
        rest = [a for a in argv[1:] if a != "--ratchet"]
        baseline_path = repo_root / DEFAULT_BASELINE
        update_baseline = False
        i = 0
        while i < len(rest):
            if rest[i] == "--baseline" and i + 1 < len(rest):
                baseline_path = Path(rest[i + 1])
                i += 2
            elif rest[i] == "--update-baseline":
                update_baseline = True
                i += 1
            else:
                print(
                    f"e2e-lint --ratchet: unknown argument {rest[i]!r}",
                    file=sys.stderr,
                )
                return 2
        return ratchet(repo_root, baseline_path, update_baseline)

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
