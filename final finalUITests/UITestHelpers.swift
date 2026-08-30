//
//  UITestHelpers.swift
//  final finalUITests
//
//  Helpers for XCUITest smoke tests: launch configuration,
//  fixture setup, and wait utilities.
//

import XCTest

// MARK: - Launch Helpers

extension XCUIApplication {
    /// Creates an XCUIApplication targeting our app by bundle identifier.
    /// Explicit ID avoids issues with the pipe character in PRODUCT_NAME.
    static func targetApp() -> XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.kerim.final-final.testhost")
    }

    /// Launches the app in UI testing mode without a fixture (shows picker)
    func launchForTesting() {
        Self.cleanSavedApplicationState()
        // Defense-in-depth: Apple documents that `launch()` already terminates any
        // running instance before starting fresh, so this call is expected to be a
        // no-op in the common case. It costs nothing if redundant and closes the
        // gap if that documented behavior ever doesn't hold in practice.
        terminate()
        launchEnvironment["FF_UI_TESTING"] = "1"
        launch()
        activateAndWaitForForeground()
    }

    /// Launches the app in UI testing mode with a fixture (shows editor)
    func launchForTesting(fixturePath: String) {
        Self.cleanSavedApplicationState()
        terminate()
        launchEnvironment["FF_UI_TESTING"] = "1"
        launchEnvironment["FF_TEST_FIXTURE_PATH"] = fixturePath
        launch()
        activateAndWaitForForeground()
    }

    /// Re-activates the app and waits for it to report the foreground state
    /// before returning. `launch()`/`activate()` only guarantee foreground state
    /// at the instant they return (per Apple's XCUIApplication.h) — nothing
    /// guarantees focus is still there by the time a later keyboard-shortcut
    /// action fires. Call this immediately before any `typeKey` call, not just
    /// after launch, so a focus problem produces a clear, self-describing
    /// failure instead of an unrelated-looking assertion failure downstream.
    @discardableResult
    func activateAndWaitForForeground(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        activate()
        let result = wait(for: .runningForeground, timeout: timeout)
        if !result {
            XCTFail("""
                App did not reach the foreground within \(timeout)s. This is a \
                window-focus/process collision, not a real test failure — see \
                "UI test environment requirements" in docs/guides/running-tests.md.
                """, file: file, line: line)
        }
        return result
    }

    /// Remove saved window state so each test run starts fresh.
    /// This replaces `-ApplePersistenceIgnoreState YES` which prevents
    /// SwiftUI's WindowGroup from creating any window at all.
    ///
    /// Note: NSHomeDirectory() in the test runner may differ from the app's home.
    /// We clean both the test runner's home AND the real user home to be safe.
    private static func cleanSavedApplicationState() {
        // The Test action builds the app as com.kerim.final-final.testhost
        // (project.yml's DebugTest config), so only the testhost domain is
        // cleaned. The production domain (com.kerim.final-final.savedState)
        // is deliberately untouched — an earlier version deleted it from the
        // real user home on every test launch, silently discarding the
        // user's own saved window state.
        let bundleState = "Library/Saved Application State/com.kerim.final-final.testhost.savedState"
        let testRunnerPath = NSHomeDirectory() + "/" + bundleState

        // Also try the real user home (in case test runner home differs)
        let realUserHome = FileManager.default.homeDirectoryForCurrentUser.path
        let realUserPath = realUserHome + "/" + bundleState

        try? FileManager.default.removeItem(atPath: testRunnerPath)
        if realUserPath != testRunnerPath {
            try? FileManager.default.removeItem(atPath: realUserPath)
        }
    }
}

// MARK: - Wait Helpers

extension XCUIElement {
    /// Waits for the element to exist and returns it, or fails.
    @discardableResult
    func waitForExistenceOrFail(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if !waitForExistence(timeout: timeout) {
            XCTFail("Element \(debugDescription) did not appear within \(timeout)s", file: file, line: line)
        }
        return self
    }

    /// Waits for the element to disappear.
    func waitForDisappearance(timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Waits for the element's accessibility value to match a predicate.
    /// SwiftUI `Text` views with explicit `.accessibilityIdentifier()` put their
    /// content in `value`, not `label`.
    /// Example: `element.waitForValue("== 'WYSIWYG'")`
    /// Example: `element.waitForValue("CONTAINS 'words'")`
    ///
    /// `predicateFormat` is prefixed with `"value "`, so it must be an infix
    /// comparison (`== 'x'`, `CONTAINS 'x'`, `!= 'x'`, ...), not an expression
    /// that starts with a logical operator like `NOT (...)` — prefixing that
    /// produces invalid predicate syntax (`value NOT (...)`) and throws at
    /// parse time. Use `waitForValueNot(_:)` for negation.
    func waitForValue(_ predicateFormat: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "value \(predicateFormat)")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Waits for the element's accessibility value to NOT match a predicate.
    /// Example: `element.waitForValueNot("CONTAINS 'words'")` waits until the
    /// value no longer contains "words", correctly building `NOT (value CONTAINS 'words')`.
    /// `predicateFormat` must still be an infix comparison, same as `waitForValue(_:)`.
    ///
    /// Guarded with `exists == true`: NSPredicate comparison operators evaluate
    /// to false when an operand is nil, so an ungated `NOT (value ...)` would
    /// be TRUE the instant the element doesn't exist yet (its `value` reads as
    /// nil) — a silent false pass for "the UI hasn't come up yet". Folding the
    /// existence check into the same compound predicate makes this one atomic
    /// wait: the negation is only ever evaluated once the element genuinely
    /// exists, and if it never does, the expectation times out and this
    /// returns `false` rather than reporting the negation satisfied.
    func waitForValueNot(_ predicateFormat: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND NOT (value \(predicateFormat))")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Waits for the element's accessibility label to match a predicate.
    /// SwiftUI `Button` elements expose their `Text` label content in `label`, not `value`.
    /// Example: `element.waitForLabel("== 'WYSIWYG'")`
    ///
    /// `predicateFormat` is prefixed with `"label "`, so it must be an infix
    /// comparison, not a NOT/AND/OR-prefixed expression — see `waitForValue(_:)`.
    /// Use `waitForLabelNot(_:)` for negation.
    func waitForLabel(_ predicateFormat: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label \(predicateFormat)")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Waits for the element's accessibility label to NOT match a predicate.
    /// Example: `element.waitForLabelNot("== 'Source'")` waits until the label
    /// is no longer "Source", correctly building `NOT (label == 'Source')`.
    /// `predicateFormat` must still be an infix comparison, same as `waitForLabel(_:)`.
    ///
    /// Guarded with `exists == true`, same rationale as `waitForValueNot(_:)`:
    /// without it, `NOT (label ...)` reads TRUE the instant the element
    /// doesn't exist yet, silently passing before the UI has come up.
    func waitForLabelNot(_ predicateFormat: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND NOT (label \(predicateFormat))")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}

// MARK: - Screenshot Evidence Helpers

enum E2EShotDir {
    /// Where a disposable e2e test should write its screenshot evidence.
    ///
    /// Reads `FF_E2E_SHOT_DIR` from the process environment — set by
    /// `vmtest` (as `TEST_RUNNER_FF_E2E_SHOT_DIR`, which xcodebuild forwards
    /// to the runner process with the prefix stripped) or directly by the
    /// `e2e-verify` skill for a host run.
    ///
    /// Three cases, deliberately distinct:
    /// - Unset → `NSTemporaryDirectory()`, which the runner can always write
    ///   to (already relied on by `TestFixtureHelper.fixturePath` above).
    ///   This is the safe default when nobody wired anything up.
    /// - Set to an absolute path (starts with "/") → used as-is. This is the
    ///   host case: `e2e-verify`/superdev pass an explicit run-notes folder.
    /// - Set to a bare relative name → resolved against `NSHomeDirectory()`
    ///   **at runtime, inside this process**. This is the VM-guest case:
    ///   `vmtest` cannot know the runner's container path in advance (it
    ///   contains a UUID chosen when the runner launches), so it passes a
    ///   relative name and lets the sandboxed process resolve its own home —
    ///   which the POC proved is the one writable location in the guest, and
    ///   which matches `export-evidence.sh`'s existing container-glob
    ///   discovery (`Containers/*xctrunner/Data/e2e-shots`).
    ///
    /// Never a *bare* `NSHomeDirectory()` default — outside a VM the runner's
    /// home can be the user's real home, and a silent default there would
    /// grow an unpruned `~/e2e-shots/`. Here it is only ever reached when
    /// `vmtest` deliberately opts in with a relative value.
    static var path: String {
        guard let dir = ProcessInfo.processInfo.environment["FF_E2E_SHOT_DIR"], !dir.isEmpty else {
            return NSTemporaryDirectory() + "ff-e2e-shots"
        }
        if dir.hasPrefix("/") {
            return dir
        }
        return NSHomeDirectory() + "/" + dir
    }

    /// `path` as a URL, creating the directory if it does not exist yet.
    static var url: URL {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Proven-Pattern Query Helpers
//
// Each helper below encodes a failure mode diagnosed live in the 2026-08-16
// superdev batch (see "Proven patterns" in .claude/skills/e2e-verify/SKILL.md).
// Disposable e2e tests should compose these instead of re-deriving queries.

extension XCUIApplication {
    /// The WKWebView editor container. Every query for editor content must be
    /// scoped here: a bare `app.staticTexts[...]` also matches the outline
    /// sidebar's mirror of each heading, and `.firstMatch` resolves to the
    /// *sidebar* match first — so an unscoped "click the heading" clicks a
    /// sidebar row instead.
    var editorArea: XCUIElement {
        groups["editor-area"]
    }

    /// First StaticText inside the editor whose value (or, for heading
    /// containers, label) starts with `text`, or nil if none appears within
    /// `timeout`.
    ///
    /// Matching is done in Swift, not NSPredicate: heading containers carry a
    /// non-string value (the heading level, an NSNumber), and any substring
    /// predicate (`CONTAINS`, `BEGINSWITH`) evaluated against one throws
    /// NSInvalidArgumentException at resolution time. Prefix (not exact)
    /// matching, because a leaf text run carries a trailing space when an
    /// inline link follows, and a heading container's label concatenates all
    /// child text — exact equality matches neither.
    ///
    /// Re-call after every mutation: a handle resolved before typing goes
    /// stale once the text changes.
    ///
    /// `element.exists`-guarded per element (round-2 fix, vmtest strike-2 diagnosis on
    /// E2EScratchTests.swift: "Failed to get matching snapshot: No matches found for Element
    /// at index 3"): `allElementsBoundByIndex` snapshots a positional index into the AX tree,
    /// and touching `.value`/`.label` on an element the tree has since invalidated (a real risk
    /// while a WebView is still mid-mount/mid-content-replay, e.g. right after a document open
    /// or reopen -- this app's most AX-tree-mutation-heavy moment) throws instead of returning
    /// nil. Same fix EditorModeSwitchUndoE2ETests.markerPresent's own doc comment documents for
    /// the identical failure class: `.exists` is a documented-safe, non-throwing existence
    /// check, so guarding with it before either property access skips a vanished element
    /// instead of crashing the scan.
    func editorStaticText(startingWith text: String, timeout: TimeInterval = 10) -> XCUIElement? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            for element in editorArea.staticTexts.allElementsBoundByIndex {
                guard element.exists else { continue }
                if let value = element.value as? String, value.hasPrefix(text) {
                    return element
                }
                if element.label.hasPrefix(text) {
                    return element
                }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return nil
    }

    /// Waits for a menu item by TITLE and returns it, or fails. XCUITest gives
    /// `NSMenuItem` only `title` and an identifier (`menuAction:`) — no
    /// `label` — so a `label BEGINSWITH` query against `menuItems` matches
    /// nothing, forever, while the item sits open and visible on screen.
    /// Prefix matching, for items whose title embeds a document name
    /// ("Undo Restore of ...").
    @discardableResult
    func menuItem(titleStartingWith prefix: String, timeout: TimeInterval = 10,
                  file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let item = menuItems.matching(
            NSPredicate(format: "title BEGINSWITH %@", prefix)
        ).firstMatch
        if !item.waitForExistence(timeout: timeout) {
            XCTFail("No menu item with title starting \"\(prefix)\" appeared within \(timeout)s "
                + "(note: menu items match on title, never label)", file: file, line: line)
        }
        return item
    }

    /// Waits for and clicks a button in a modal alert raised via
    /// `NSAlert.runModal()` (e.g. from a menu command). Those alerts are
    /// top-level Dialog siblings of the windows, so `windows.buttons[...]`
    /// can never reach them; and a bare `app.buttons[...]` can resolve to the
    /// Touch Bar mirror of the dialog's default button instead of the real
    /// one. Dialog scope avoids both.
    func clickDialogButton(_ title: String, timeout: TimeInterval = 10,
                           file: StaticString = #filePath, line: UInt = #line) {
        let button = dialogs.buttons[title]
        if !button.waitForExistence(timeout: timeout) {
            XCTFail("Dialog button \"\(title)\" did not appear within \(timeout)s "
                + "(runModal alerts live under app.dialogs, not app.windows)", file: file, line: line)
            return
        }
        button.click()
    }

    /// True if `text` appears in full anywhere inside editor-area. Scans EVERY
    /// element and skips ones the tree has invalidated -- never indexes a single
    /// position. Fresh fetch per poll. Substring, not equality: a leaf run can
    /// carry a leading/trailing space and a heading container concatenates its
    /// children (see editorStaticText's doc comment).
    func editorContainsText(_ text: String, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            for element in editorArea.staticTexts.allElementsBoundByIndex {
                guard element.exists else { continue }
                if let value = element.value as? String, value.contains(text) { return true }
                if element.label.contains(text) { return true }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return false
    }

    /// Types `text` at the current caret position -- assumed to land on its own,
    /// otherwise-empty line (true immediately after a fresh `Return`) -- then verifies via the
    /// editor's own accessibility tree that it landed byte-for-byte, retyping on a mismatch
    /// rather than trusting `typeText` blindly.
    ///
    /// Guards against a known XCUITest flakiness class: `typeText` occasionally drops
    /// characters mid-string while synthesizing keystrokes, especially under VM load. CONFIRMED
    /// via a real vmtest run (E2EScratchTests.swift, swiftlint-param-refactor task, 2026-08-30):
    /// a typed paragraph was found in the block table as "Newly typed paragra Alpha while
    /// zoomed." -- "ph" silently dropped from "paragraph" -- with every other assertion in that
    /// run passing, i.e. the flakiness is in `typeText` itself, not whatever code the test was
    /// exercising.
    ///
    /// Verification is scan-based via `editorContainsText`, never positional: an earlier
    /// version trusted `editorArea.staticTexts.allElementsBoundByIndex.last` as "the editor is
    /// empty" when that one index's `.exists` read false -- but a WKWebView mid-repaint can fail
    /// ONE positional index while the tree still holds several live elements, so that read a
    /// populated tree as empty (diagnosed live: "Checking existence of Element at index 6" was
    /// logged 3 times, impossible if the array were actually empty, since a nil `.last` would
    /// short-circuit before `.exists` is ever called). `editorContainsText` scans every element
    /// and only trusts the ones still present, so a single stale index can never masquerade as
    /// "nothing here."
    ///
    /// On a mismatch, this looks for a PARTIAL/corrupted landing of `text` -- an element whose
    /// value or label shares `text`'s first 8+ characters -- rather than assuming the editor is
    /// empty. If found, it clears exactly what actually landed (the READ-BACK length, not
    /// `text.count`): those two can differ precisely because of the drop this method exists to
    /// catch, so backspacing the intended length risks eating past this line's own content into
    /// whatever preceded it. If nothing resembling `text` is found at all -- no exact match, no
    /// partial-prefix match -- this does NOT blind-retype (that would compound garbage on top of
    /// garbage against who-knows-what state); it fails immediately with every surviving
    /// element's value/label dumped, so the failure is legible instead of misleadingly claiming
    /// "empty" against a tree that may still hold plenty of content.
    func typeTextVerifyingLanded(
        _ text: String, maxAttempts: Int = 3,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for attempt in 1...maxAttempts {
            activateAndWaitForForeground()
            typeText(text)
            Thread.sleep(forTimeInterval: 1.0)

            if editorContainsText(text) {
                return
            }

            // Not an exact landing -- look for a partial/corrupted version of what we just
            // typed (shares a meaningful prefix) so we can clean it up before retrying.
            let prefixLen = min(8, text.count)
            let expectedPrefix = String(text.prefix(prefixLen))
            var partialElement: XCUIElement?
            var partialLanded = ""
            for element in editorArea.staticTexts.allElementsBoundByIndex {
                guard element.exists else { continue }
                let candidate = (element.value as? String) ?? element.label
                if candidate.hasPrefix(expectedPrefix) {
                    partialElement = element
                    partialLanded = candidate
                    break
                }
            }

            guard partialElement != nil else {
                // Nothing recognizable at all: not "empty" (that misreading is exactly the bug
                // this method used to have), but nothing resembling `text` either. Fail loud
                // with a full dump instead of guessing by blind-retyping.
                let elements = editorArea.staticTexts.allElementsBoundByIndex
                var dump: [String] = []
                for (idx, element) in elements.enumerated() {
                    guard element.exists else {
                        dump.append("  [\(idx)]: <stale, skipped>")
                        continue
                    }
                    let value = (element.value as? String) ?? "<non-string value>"
                    dump.append("  [\(idx)]: value=\"\(value)\" label=\"\(element.label)\"")
                }
                XCTFail(
                    "typeTextVerifyingLanded: expected \"\(text)\" but found no exact or "
                        + "partial-prefix match among \(elements.count) editor static text(s) "
                        + "after attempt \(attempt) of \(maxAttempts):\n"
                        + dump.joined(separator: "\n"), file: file, line: line
                )
                return
            }

            if attempt == maxAttempts {
                XCTFail(
                    "Typed text never landed correctly after \(maxAttempts) attempts -- known "
                        + "XCUITest typeText character-drop flakiness (see this method's doc "
                        + "comment). Expected \"\(text)\", last landed value: \"\(partialLanded)\"",
                    file: file, line: line
                )
                return
            }

            for _ in 0..<partialLanded.count {
                typeKey(.delete, modifierFlags: [])
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }
}

extension XCUIElement {
    /// Clicks via coordinates instead of element hit-testing. Sidebar cards
    /// are non-hittable by design — `PassthroughHostingView.hitTest` returns
    /// nil for anything but right-clicks — so `element.click()` on one can
    /// never land, and the failure masquerades as a layout/obstruction
    /// problem. Every positioned click in this suite goes through
    /// coordinates; this wraps that precedent.
    func clickViaCoordinate(dx: CGFloat = 0.5, dy: CGFloat = 0.5,
                            timeout: TimeInterval = 10,
                            file: StaticString = #filePath, line: UInt = #line) {
        if !waitForExistence(timeout: timeout) {
            XCTFail("Element \(debugDescription) did not appear within \(timeout)s "
                + "for coordinate click", file: file, line: line)
            return
        }
        coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).click()
    }
}

// MARK: - App File Helpers

/// Reads files the APP writes (logs, exports) from inside the test runner.
/// The runner's own home is containerized: `NSHomeDirectory()` and
/// `FileManager.default.homeDirectoryForCurrentUser` point at the xctrunner
/// container, not the app's home — a read helper built on either silently
/// returns nothing.
enum AppFileHelper {
    struct ReadError: Error, CustomStringConvertible {
        let relativePath: String
        let attempted: [String]
        var description: String {
            "AppFileHelper: \"\(relativePath)\" not found. Attempted: \(attempted.joined(separator: ", ")). "
                + "A missing file is a real failure — never treat it as \"the app wrote nothing\"."
        }
    }

    /// Candidate locations for an app-written path relative to the app's home
    /// (e.g. "Library/Application Support/com.kerim.final-final/..."), as
    /// home roots in the order worth trying: the real user home by name
    /// (works around the runner's containerized home), the home implied by
    /// the standard Application Support lookup, then the runner's own idea
    /// of home as a last resort.
    static func candidateURLs(appRelativePath: String) -> [URL] {
        let fm = FileManager.default
        var homes: [URL] = [URL(fileURLWithPath: "/Users/\(NSUserName())")]
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            // Strip "Application Support" and "Library" to get a home root.
            homes.append(appSupport.deletingLastPathComponent().deletingLastPathComponent())
        }
        homes.append(fm.homeDirectoryForCurrentUser)
        // De-dup while preserving order (the three often agree outside a VM).
        var seen = Set<String>()
        return homes.filter { seen.insert($0.path).inserted }
            .map { $0.appendingPathComponent(appRelativePath) }
    }

    /// Returns the contents of the first candidate that exists. Throws a
    /// descriptive error naming every attempted path — never an empty string
    /// for a missing file, which made a wrong path indistinguishable from
    /// "the app never wrote" and burned three VM cycles on one silent read
    /// failure.
    static func read(appRelativePath: String) throws -> String {
        var attempted: [String] = []
        for url in candidateURLs(appRelativePath: appRelativePath) {
            attempted.append(url.path)
            if FileManager.default.fileExists(atPath: url.path) {
                return try String(contentsOf: url, encoding: .utf8)
            }
        }
        throw ReadError(relativePath: appRelativePath, attempted: attempted)
    }
}

// MARK: - Fixture Database Helpers (sqlite3 CLI)
//
// Reads are safe to run WHILE the app holds the DB open -- WAL mode allows concurrent readers,
// the same pattern already proven in E2ESectionReconcilerPseudoSectionTests.swift/
// NestedListE2ETests.swift/HrTypedConversionE2ETests.swift. Writes (fixture doctoring) must only
// ever run with the app terminated, never against a live connection -- callers are responsible
// for that ordering, matching those same precedents.
//
// MISDIAGNOSIS, CORRECTED (2026-08-22 vmtest investigation, UnifiedUndoE2ETests): a real failure
// once showed the app's own diagnostic log reporting a structural delete completed end-to-end,
// while `read()` moments later still saw the pre-delete row count -- diagnosed at the time as
// cross-process WAL visibility latency (a separate `sqlite3` CLI connection not yet seeing the
// app's committed frames) and "fixed" by forcing `PRAGMA wal_checkpoint(TRUNCATE)` on every
// `read()` call. A later review traced the ACTUAL cause: `querySectionCount()`/
// `queryOrderedSectionTitles()` read `FROM section` (the legacy mirror table), and the
// `deleteSections`/`duplicateSections` bug active at the time (`Database+SectionOps.swift`,
// since fixed) matched `section` rows by `block` ids -- an ID space `section` never used -- so
// it deleted nothing there at all. The read was reporting the DB's true, unchanged `section`
// state correctly the whole time; there was never a visibility race to fix. The forced
// checkpoint was not just inert but a live liability: `TRUNCATE` is an aggressive checkpoint
// mode that blocks readers/writers and rewrites the WAL file, and this ran 4x/second (once per
// `waitUntil` poll tick) from a separate process against the live app's actively-writing
// database -- exactly the kind of contention this suite's own eviction-cap test (rapid
// back-to-back structural ops) is most sensitive to. Removed entirely; `read()` below is a
// plain query again.

/// Shared `sqlite3` CLI wrapper for reading/writing a test fixture's `content.sqlite` from
/// inside the test runner. Factored out of the section-reconciler pattern above so new e2e tests
/// don't each re-derive the same `Process`/`Pipe` boilerplate.
enum FixtureDatabase {
    /// Runs a write statement (UPDATE/INSERT/etc.) against `<fixturePath>/content.sqlite`.
    /// Caller must ensure the app is terminated first -- see this enum's own doc comment. No
    /// checkpoint needed here (unlike `read` below): the app hasn't opened its own connection
    /// yet at the point this is used (fixture seeding, before `launchForTesting`), so there is no
    /// concurrent writer whose frames could be sitting unmerged in the WAL.
    static func write(fixturePath: String, sql: String, file: StaticString = #filePath, line: UInt = #line) {
        _ = run(dbPath: fixturePath + "/content.sqlite", sql: sql, file: file, line: line)
    }

    /// Runs a `SELECT` against `<fixturePath>/content.sqlite` and returns raw stdout. Safe to
    /// call while the app is open (WAL mode) -- see this enum's own doc comment. No checkpoint
    /// forced here (there was one; removed 2026-08-22 -- see this enum's own doc comment for
    /// why it was a misdiagnosis, not a real fix).
    @discardableResult
    static func read(fixturePath: String, sql: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        run(dbPath: fixturePath + "/content.sqlite", sql: sql, file: file, line: line)
    }

    /// Escapes a raw string for embedding in a single-quoted SQL literal.
    static func escape(_ rawValue: String) -> String {
        rawValue.replacingOccurrences(of: "'", with: "''")
    }

    /// Seeds `content.markdown` AND clears `block` in the same statement. Clearing `block` is
    /// mandatory: `ContentView+ProjectLifecycle.loadInitialContent` assembles the document from
    /// `block` rows whenever any exist and never reads `content.markdown` in that case -- the
    /// committed fixture ships block rows (`TestFixtureFactory.createFixture` populates them), so
    /// a content-only seed is silently discarded and the app loads stale fixture content instead.
    /// Pass `appending: true` to append to the existing `content.markdown` (fixture doctoring)
    /// instead of replacing it outright. Caller must ensure the app is terminated first -- see
    /// `write` above.
    static func seedMarkdown(
        fixturePath: String,
        markdown: String,
        appending: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let assignment = appending
            ? "markdown = markdown || '\(escape(markdown))'"
            : "markdown = '\(escape(markdown))'"
        write(fixturePath: fixturePath, sql: "DELETE FROM block; UPDATE content SET \(assignment);", file: file, line: line)
    }

    @discardableResult
    private static func run(dbPath: String, sql: String, file: StaticString, line: UInt) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, sql]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            XCTFail("FixtureDatabase: sqlite3 failed to launch: \(error)", file: file, line: line)
            return ""
        }
        // Deadlock fix (2026-08-22): both pipes MUST be drained CONCURRENTLY, before
        // `waitUntilExit()`, not read sequentially or after. A pipe's buffer is small (~64KB) --
        // if sqlite3 ever writes more than that to EITHER stdout or stderr, the child blocks on
        // a full pipe nobody is reading. `waitUntilExit()` alone would then deadlock forever
        // (this process waiting for a child that can't finish); reading stdout-then-stderr
        // sequentially on one thread is not safe either -- a child that blocks mid-write on a
        // full stderr buffer while this process is still draining stdout would never produce
        // stdout's EOF either, hanging the FIRST read. Draining both pipes on separate queues at
        // the same time removes any ordering dependency between them. Safe today only because
        // the committed fixture is tiny -- `queryAllMarkdownConcatenated()` is exactly the query
        // whose output scales with document size, and would be the first to hit this the moment
        // this suite (or a future one reusing this helper) points at a realistic document.
        let stdoutQueue = DispatchQueue(label: "FixtureDatabase.stdout")
        var stdoutData = Data()
        let stdoutDone = DispatchSemaphore(value: 0)
        stdoutQueue.async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            stdoutDone.signal()
        }
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        stdoutDone.wait()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            XCTFail(
                "FixtureDatabase: sqlite3 query failed (status \(process.terminationStatus)) "
                    + "against \(dbPath): \(stderr)\nSQL: \(sql)",
                file: file, line: line
            )
        }
        return String(data: stdoutData, encoding: .utf8) ?? ""
    }
}

// MARK: - Fixture Helpers

enum TestFixtureHelper {
    /// Backing storage for the per-test fixture path. XCTest runs one test's
    /// setUp -> test -> tearDown serially before starting the next, so there is
    /// no real concurrent access here -- `nonisolated(unsafe)` documents that
    /// this mutable static is safe under that serial-execution contract, which
    /// Swift 6 strict concurrency cannot see on its own.
    private nonisolated(unsafe) static var currentFixturePath: String?

    /// The per-test fixture path, assigned fresh by `setupFixture(from:)` and
    /// cleared by `cleanupFixture()`. Each test gets its own
    /// `ff-test-fixture-<UUID>.ff` under `NSTemporaryDirectory()` rather than a
    /// single shared path, so one test's fixture file can't be read, mutated,
    /// or torn down out from under a previously-running test.
    ///
    /// Reading this before `setupFixture(from:)` has run (or after
    /// `cleanupFixture()` already ran) is a test-authoring bug: the old shared
    /// `static let` would have silently handed back a stale path left over
    /// from whatever test ran last, which is exactly the cross-test pollution
    /// this per-test isolation exists to prevent. Fail loudly instead of
    /// reproducing that silently-stale behavior -- via `XCTFail` rather than
    /// `fatalError`, so the misuse fails only the one offending test instead
    /// of killing the whole XCUITest runner process. Every current call site
    /// runs with `continueAfterFailure = false`, so `XCTFail` unwinds the test
    /// immediately and the sentinel path below is never actually consumed in
    /// practice; it exists only to satisfy this property's non-throwing
    /// `String` return type.
    static var fixturePath: String {
        guard let currentFixturePath else {
            XCTFail(
                "TestFixtureHelper.fixturePath read before setupFixture(from:) was called (or after "
                    + "cleanupFixture() already ran) -- call setupFixture(from:) in this test's setUp first."
            )
            return "/dev/null/TestFixtureHelper-fixturePath-read-before-setupFixture"
        }
        return currentFixturePath
    }

    /// Copies the committed fixture from the UI test bundle to a fresh,
    /// per-test path in the temp directory. Must be called in setUp before
    /// launching the app.
    static func setupFixture(from testCase: XCTestCase) throws {
        let fm = FileManager.default
        let path = NSTemporaryDirectory() + "ff-test-fixture-\(UUID().uuidString).ff"

        // Find fixture in the UI test bundle using URL-based path
        let bundle = Bundle(for: type(of: testCase))
        guard let fixtureSource = bundle.resourceURL?
            .appendingPathComponent("Fixtures/test-fixture.ff"),
              fm.fileExists(atPath: fixtureSource.path) else {
            XCTFail("Test fixture not found in UI test bundle. Ensure FixtureGeneratorTests has run and fixture is committed.")
            return
        }

        // Fresh copy for test isolation
        try? fm.removeItem(atPath: path)
        try fm.copyItem(at: fixtureSource, to: URL(fileURLWithPath: path))

        // Only publish the path once the copy has actually succeeded --
        // assigning it earlier would let a failed bundle lookup or copy leave
        // `currentFixturePath` pointing at a file that doesn't exist.
        currentFixturePath = path

        print("[TestFixture] Fixture copied to: \(path)")
    }

    /// Removes the test fixture and clears the stored path. Call from
    /// tearDown. A documented no-op when no fixture is currently set -- e.g. a
    /// test method that never called `setupFixture(from:)` sharing a
    /// `tearDown`/`tearDownWithError` with a sibling method that did (see
    /// ProjectOpenErrorE2ETests, where `tearDownWithError` calls this
    /// unconditionally but only one of its two test methods calls
    /// `setupFixture`).
    static func cleanupFixture() {
        guard let path = currentFixturePath else { return }
        try? FileManager.default.removeItem(atPath: path)
        currentFixturePath = nil
    }
}
