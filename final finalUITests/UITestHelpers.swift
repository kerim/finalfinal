//
//  UITestHelpers.swift
//  final finalUITests
//
//  Helpers for XCUITest smoke tests: launch configuration,
//  fixture setup, and wait utilities.
//
//  The query/fixture-database/document-note-seeding helpers were split out to
//  UITestQueryAndFixtureHelpers.swift to keep this file under SwiftLint's file_length limit.
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
        logLaunchWindowFrames()
    }

    /// Phase 7 diagnostic (2026-11-11): one line per launch with every window's frame next to the screen's, so a shard that starts in
    /// native full screen (the cascade of the Esc-ladder class) shows it at the launch that inherits it instead of only at a later
    /// teardown. Prints frames only, no document text.
    func logLaunchWindowFrames() {
        let screen = NSScreen.main?.frame ?? .zero
        // `.exists`-guarded: a window the tree drops mid-loop is skipped, not a "No matches found for Element at index N" failure.
        let frames = windows.allElementsBoundByIndex.compactMap { window -> String? in
            guard window.exists else { return nil }
            return "\(Int(window.frame.width))x\(Int(window.frame.height))"
        }
        print("[LaunchFrame] windows=\(frames) screen=\(Int(screen.width))x\(Int(screen.height))")
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
    /// Note: the test runner is unsandboxed for this project (see
    /// `final finalUITests/final finalUITests.entitlements`, wired via the
    /// `CODE_SIGN_ENTITLEMENTS` build setting in `project.yml`), so
    /// NSHomeDirectory() there now resolves to the same real user home the
    /// app sees. Both paths are still cleaned as belt-and-braces, not
    /// because they currently differ.
    private static func cleanSavedApplicationState() {
        // The Test action builds the app as com.kerim.final-final.testhost
        // (project.yml's DebugTest config), so only the testhost domain is
        // cleaned. The production domain (com.kerim.final-final.savedState)
        // is deliberately untouched — an earlier version deleted it from the
        // real user home on every test launch, silently discarding the
        // user's own saved window state.
        let bundleState = "Library/Saved Application State/com.kerim.final-final.testhost.savedState"
        // e2e-lint: allow nshome -- the saved state is cleaned from BOTH homes on purpose (see the doc comment above); no app file is read here.
        let testRunnerPath = NSHomeDirectory() + "/" + bundleState

        // Also try the real user home (in case test runner home differs)
        // e2e-lint: allow home-url -- same reason: the runner home and the real user home are both cleaned, belt and braces.
        let realUserHome = FileManager.default.homeDirectoryForCurrentUser.path
        let realUserPath = realUserHome + "/" + bundleState

        for path in Set([testRunnerPath, realUserPath]) {
            do { try FileManager.default.removeItem(atPath: path) } catch {
                // Was a silent `try?`: a failed delete leaves saved window state (e.g. full screen) for the next launch.
                guard ![NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains((error as NSError).code) else { continue }
                XCTContext.runActivity(named: "Could not remove saved state \(path)") { $0.add(XCTAttachment(string: "\(error)")) }
            }
        }
    }
}

// MARK: - Caret Placement by Click (confirmed)

/// What `XCUIApplication.placeCaretByClicking` did, with the evidence for each click attempt.
struct CaretClickResult {
    /// One entry per click attempt: attempt, dx, leaf value, the in-view note, leaf frame, click point, editor frame, whether the
    /// point had to be clamped into the editor frame, hittable, and that attempt's probe result.
    var attempts: [[String: Any]] = []
    /// "ok" (the selection probe confirmed the caret sits at that line's edge), "wrong (...)", "unreadable (...)", "retired" (the
    /// caller switched the probe off) or "not-found" (no such paragraph in the editor).
    var probe = "not-run"
    var confirmed: Bool { probe == "ok" }
}

extension XCUIApplication {
    /// Click a paragraph so the caret lands in it, and CONFIRM that it did. Use this instead of a bare click on a leaf.
    ///
    /// LESSON (write-queue Phase 3b key-replay POC, second VM run, 2026-10-06, CONFIRMED from the exported `placement`
    /// evidence): a click at `dx: 0.02` of a leaf's reported frame landed at x=281-293 while the editor's own frame began at
    /// x=301 -- LEFT of the editor, so it hit nothing -- because the leaf's frame is stale (20-32 pt left of where it settles)
    /// for a moment after the previous repetition's typing/switch. The same click in the middle of the leaf (`dx: 0.5`, x=462)
    /// worked on every on-screen anchor. Separately, a leaf within about a line of the editor's bottom edge (y=679-701 in an
    /// editor ending at y=710) could not be clicked at all: the click was inert and the status bar kept the old selection.
    /// So this helper (1) waits for the leaf's frame to settle, (2) scrolls a leaf that is within about two lines of the
    /// editor's top or bottom edge toward the middle first and re-resolves it, (3) clicks the MIDDLE of the leaf (first
    /// attempt; the second attempt a quarter along), keeping the click point inside the editor frame, and (4) checks the
    /// outcome with `caretSelectionProbe`, retrying once with the different click. Every step lands in `attempts`.
    ///
    /// Not for a paragraph that contains an inline annotation (a click on or near it opens its popup or selects the atom) nor
    /// for one that wraps onto several visual lines (the probe selects one visual line). `runProbe: false` skips the
    /// confirmation (the click, the Cmd-Left/Right to the exact line edge and the evidence still happen).
    ///
    /// `exactLine` (default nil: today's behaviour) is the paragraph's complete text when the caller knows it and it is one text run: the
    /// paragraph is then found by one exact-value query (about 1.5 s on a book) before the index walk of `editorStaticText(startingWith:)`
    /// (two round trips per leaf, 1000-2000 s to reach a paragraph behind 662 leaves). Speed only; nothing else changes.
    func placeCaretByClicking(paragraphStartingWith text: String, atEnd: Bool, runProbe: Bool = true,
                              findTimeout: TimeInterval = 45, exactLine: String? = nil) -> CaretClickResult {
        var result = CaretClickResult()
        for attempt in 1...2 {
            if attempt == 2 { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8)) }
            let (found, inViewNote) = bringParagraphIntoView(startingWith: text, findTimeout: findTimeout, exactLine: exactLine)
            guard let leaf = found else {
                result.probe = "not-found"
                return result
            }
            let along: CGFloat = attempt == 1 ? 0.5 : 0.25
            let value = leaf.exists ? ((leaf.value as? String) ?? leaf.label) : text
            var info: [String: Any] = ["attempt": attempt, "dx": Double(along), "leafValue": String(value.prefix(60))]
            if !inViewNote.isEmpty { info["inView"] = inViewNote }
            let probe: String
            if clickParagraphLeaf(leaf, dx: along, into: &info) {
                typeKey(atEnd ? .rightArrow : .leftArrow, modifierFlags: .command)
                let words = value.split(whereSeparator: { $0.isWhitespace }).count
                probe = runProbe ? caretSelectionProbe(expectedWords: words, atEnd: atEnd) : "retired"
            } else {
                probe = "wrong (no click was made: the leaf is not inside the editor frame)"
            }
            info["probe"] = probe
            result.attempts.append(info)
            result.probe = probe
            if !probe.hasPrefix("wrong") { break }
        }
        return result
    }

    /// Finds the paragraph and, when it sits within about two lines of the editor's top or bottom edge, moves it toward the
    /// middle: up to two mouse-wheel scrolls of the editor area by the MEASURED distance (the same `scroll(byDeltaX:deltaY:)`
    /// the Outline-sidebar scroll test proves; the sign is flipped if the first scroll moved the leaf the wrong way, and a
    /// scroll that loses the leaf from the accessibility tree is undone), then one Page Down / Page Up key as a last resort.
    /// Each step re-resolves the leaf and waits for its frame to settle. Bounded; never fails: when nothing helps it returns
    /// the leaf as it is and says so in the note, and the caller's own checks decide what that means. Returns a nil leaf only
    /// when the paragraph cannot be found at all.
    func bringParagraphIntoView(
        startingWith text: String, findTimeout: TimeInterval = 45, exactLine: String? = nil
    ) -> (leaf: XCUIElement?, note: String) {
        var steps: [String] = []
        var current = editorStaticText(startingWith: text, exactLine: exactLine, timeout: findTimeout)
        var wheelSign: CGFloat = 1
        for round in 1...4 {
            guard let leaf = current else { break }
            waitForStableFrame(leaf)
            guard leaf.exists else {
                steps.append("the leaf vanished while its frame settled")
                current = editorStaticText(startingWith: text, exactLine: exactLine, timeout: 10)
                continue
            }
            let frame = leaf.frame
            let editor = editorArea.frame
            let margin = frame.height * 2 + 8
            guard frame.maxY > editor.maxY - margin || frame.minY < editor.minY + margin else {
                if round > 1 { steps.append("now in view at y=\(Int(frame.minY))") }
                return (leaf, steps.joined(separator: "; "))
            }
            if round == 4 {
                steps.append("still within two lines of an editor edge at y=\(Int(frame.minY)) (editor y=\(Int(editor.minY))-\(Int(editor.maxY)))")
                return (leaf, steps.joined(separator: "; "))
            }
            let before = frame.minY
            let wanted = editor.midY - frame.midY
            var wheelDelta: CGFloat = 0
            if round <= 2 {
                wheelDelta = wanted * wheelSign
                editorArea.scroll(byDeltaX: 0, deltaY: wheelDelta)
                steps.append("wheel \(Int(wheelDelta)) from y=\(Int(before))")
            } else {
                typeKey(wanted < 0 ? .pageDown : .pageUp, modifierFlags: [])
                steps.append("\(wanted < 0 ? "PageDown" : "PageUp") from y=\(Int(before))")
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8))
            current = editorStaticText(startingWith: text, exactLine: exactLine, timeout: 10)
            if current == nil, wheelDelta != 0 {
                steps[steps.count - 1] += " (leaf left the accessibility tree; scrolled back)"
                editorArea.scroll(byDeltaX: 0, deltaY: -wheelDelta)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8))
                current = editorStaticText(startingWith: text, exactLine: exactLine, timeout: 10)
            }
            if let after = current, after.exists {
                waitForStableFrame(after)
                let now = after.frame.minY
                steps[steps.count - 1] += " to y=\(Int(now))"
                if round == 1, wheelDelta != 0, (now - before) * wanted < 0 { wheelSign = -1 }
            }
        }
        return (current, steps.joined(separator: "; "))
    }

    /// One click on a leaf, `dx` (the fraction `along`) of the way along its middle line. The point is kept inside the editor frame
    /// (12 pt in from each edge); a leaf whose middle line lies outside the editor frame vertically gets no click (returns false). Fills `info`.
    func clickParagraphLeaf(_ leaf: XCUIElement, dx along: CGFloat, into info: inout [String: Any]) -> Bool {
        let editor = editorArea.frame
        info["editorFrame"] = Self.describeFrame(editor)
        guard leaf.exists else {
            info["leafFrame"] = "leaf vanished before its frame could be read"
            return false
        }
        let frame = leaf.frame
        info["leafFrame"] = Self.describeFrame(frame)
        info["leafHittable"] = leaf.isHittable
        let wantedX = frame.minX + frame.width * along
        let wantedY = frame.midY
        let pointX = min(max(wantedX, editor.minX + 12), editor.maxX - 12)
        let pointY = min(max(wantedY, editor.minY + 12), editor.maxY - 12)
        info["clickPoint"] = "(\(Int(pointX)), \(Int(pointY)))"
        let clamped = abs(pointX - wantedX) > 0.5 || abs(pointY - wantedY) > 0.5
        info["clamped"] = clamped
        guard wantedY >= editor.minY, wantedY <= editor.maxY else { return false }
        activateAndWaitForForeground()
        if clamped {
            editorArea.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: pointX - editor.minX, dy: pointY - editor.minY)).click()
        } else {
            leaf.coordinate(withNormalizedOffset: CGVector(dx: along, dy: 0.5)).click()
        }
        return true
    }

    /// Reads where the caret is without touching the document: selects from the caret to the line's other end (Shift-Cmd-Left
    /// when the caret should be at the end, Shift-Cmd-Right at the start), reads the status bar's "N of M words" selection count,
    /// then collapses the selection back to the caret's own edge. For a single-visual-line paragraph of `expectedWords` words, a
    /// selection of exactly that many means the caret is at that line's edge. It cannot say WHICH such line (equal lines read
    /// alike); that needs the app's own caret position. Returns "ok", "wrong (...)" (a selection of another size: the caret is
    /// somewhere else) or "unreadable (...)" (the status bar showed no new selection at all).
    func caretSelectionProbe(expectedWords: Int, atEnd: Bool) -> String {
        let baseline = wordCountStatusText()
        typeKey(atEnd ? .leftArrow : .rightArrow, modifierFlags: [.command, .shift])
        var seen = baseline
        let deadline = Date(timeIntervalSinceNow: 2.5)
        repeat {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
            seen = wordCountStatusText()
            if seen != baseline, Self.leadingNumber(seen) == expectedWords { break }
        } while Date() < deadline
        typeKey(atEnd ? .rightArrow : .leftArrow, modifierFlags: [])
        if seen == baseline { return "unreadable (status bar still read \"\(seen)\")" }
        if Self.leadingNumber(seen) == expectedWords { return "ok" }
        return "wrong (status bar read \"\(seen)\", expected a selection of \(expectedWords) words)"
    }

    /// The status bar's word-count text: "N words", or "K of N words" while a selection exists. Empty if the element is absent.
    func wordCountStatusText() -> String {
        let element = staticTexts["status-bar-word-count"]
        guard element.exists else { return "" }
        return (element.value as? String) ?? element.label
    }

    static func leadingNumber(_ text: String) -> Int? {
        text.split(separator: " ").first.flatMap { Int($0) }
    }

    static func describeFrame(_ frame: CGRect) -> String {
        "x=\(Int(frame.minX)) y=\(Int(frame.minY)) w=\(Int(frame.width)) h=\(Int(frame.height))"
    }

    /// Polls an element's frame until two reads 0.4 s apart agree (at most `timeout`). An element's frame is stale for a moment
    /// after a layout change; clicking from a stale frame is how a click ends up outside the editor.
    func waitForStableFrame(_ element: XCUIElement, timeout: TimeInterval = 3) {
        guard element.exists else { return }
        var last = element.frame
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.4))
            guard element.exists else { return }
            let now = element.frame
            if now == last { return }
            last = now
        }
    }
}

// MARK: - System Alert Interruption Handling

extension XCTestCase {
    /// Registers a UI interruption monitor that dismisses the macOS "<app> would like to find
    /// and connect to devices on your local network" permission dialog (owned by
    /// `com.apple.UserNotificationCenter`, not our app) if it ever appears mid-test.
    ///
    /// Belt-and-braces, not the real fix: this dialog's actual cause was a real `URLSession`
    /// request `ZoteroService.fetchItemsForCitekeys`/`fetchItemsForCitekeysViaExport` made to
    /// `127.0.0.1:23119` even under `FF_UI_TESTING_ZOTERO_MOCK` -- fixed at the source by giving
    /// both a UI-testing mock short-circuit (see their doc comments). That fix should mean this
    /// dialog never appears at all; this monitor exists so that if it ever does (a future call
    /// site reintroducing a real Zotero network call under mock mode, or some other local-network
    /// API), it gets dismissed immediately instead of sitting on screen and swallowing the next
    /// test's clicks/keystrokes in the same shard -- confirmed live: this exact dialog surfacing
    /// during `ProjectSwitchBibliographyE2ETests` was still on screen when
    /// `SidebarRerenderCountE2ETests` (the next class in the shard) tried to click "Middle
    /// Section", and XCTest's own BUILT-IN interruption handling ("Checking for user permission
    /// dialogs...") did not recognize or dismiss it (xcodebuild.log: "No monitors handled UI
    /// interruption... Did not handle the interruption, but will attempt to continue").
    ///
    /// Registered from `TestFixtureHelper.setupFixture(from:)` -- the one setup path essentially
    /// every permanent e2e test class already calls from its own `setUpWithError()`, rather than
    /// inventing a new shared base class this codebase doesn't have (every e2e test class here
    /// subclasses `XCTestCase` directly).
    ///
    /// Matches on the dialog's own body text, per this task's instruction to check the
    /// accessibility tree before hardcoding a button title: `staticTexts` containing "find
    /// devices on local networks" (the standard macOS local-network-access prompt wording,
    /// case-insensitive to tolerate any macOS-version wording drift), then clicks "Don't Allow"
    /// -- the privacy-preserving choice, matching this app's own "decline non-essential" default
    /// -- falling back to whatever button is present if "Don't Allow" isn't found verbatim, since
    /// dismissing SOME way is strictly better than leaving the dialog to interrupt the next test.
    @discardableResult
    func installLocalNetworkPermissionInterruptionMonitor() -> NSObjectProtocol {
        addUIInterruptionMonitor(withDescription: "Local network permission dialog") { alert in
            // e2e-lint: allow statictext-contains -- scoped to the system alert (`alert.staticTexts`), never app-wide: no heading container.
            let bodyMatches = alert.staticTexts.matching(
                NSPredicate(
                    format: "(label CONTAINS[c] %@) OR (value CONTAINS[c] %@)",
                    "find devices on local networks", "find devices on local networks"
                )
            )
            guard bodyMatches.count > 0 else { return false }

            let dontAllow = alert.buttons["Don't Allow"]
            if dontAllow.exists {
                dontAllow.click()
                return true
            }
            // Wording/localization drift fallback: dismissing via whichever button exists beats
            // leaving the dialog on screen to interrupt whatever test runs next.
            if alert.buttons.count > 0 {
                alert.buttons.firstMatch.click()
                return true
            }
            return false
        }
    }

    /// Attach a screenshot as e2e evidence. THE way to produce screenshot
    /// evidence in this suite.
    ///
    /// A plain `FileManager` write from a UI-test method cannot work: Xcode's
    /// own RunnerEntitlements.plist sandboxes every macOS XCUITest runner
    /// (app-sandbox=true, read-only "/"), so writes outside the runner's
    /// container fail with "Operation not permitted" — silently, wherever the
    /// call site uses `try?`. Confirmed live, two instrumented VM runs,
    /// 2026-09-12. XCTAttachment goes through XCTest's own privileged export
    /// path and is unaffected; vmtest exports attachments after every run,
    /// pass or fail.
    func attachEvidenceScreenshot(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
    /// Example: `element.waitForValue("== 'Rich Text'")`
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
    /// Example: `element.waitForLabel("== 'Rich Text'")`
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
    /// Example: `element.waitForLabelNot("== 'Markdown'")` waits until the label
    /// is no longer "Markdown", correctly building `NOT (label == 'Markdown')`.
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

// MARK: - Screenshot Evidence Plumbing (E2EShotDir)

enum E2EShotDir {
    /// The `FF_E2E_SHOT_DIR` env-var contract — NOT itself a route for a
    /// disposable e2e test to write its screenshot evidence; see the next
    /// paragraph. Screenshot evidence goes through
    /// `attachEvidenceScreenshot(_:name:)` (above) instead.
    ///
    /// This type's WRITE path (a plain `FileManager`/`Data.write(to:)` call
    /// from inside a UI test method) now succeeds for any absolute path,
    /// including one outside the runner's own home. The XCUITest runner
    /// process for this project is unsandboxed (see
    /// `final finalUITests/final finalUITests.entitlements`, wired via the
    /// `CODE_SIGN_ENTITLEMENTS` build setting in `project.yml`), unlike
    /// Xcode's shipped default (app-sandbox=true, read-only "/"), which
    /// used to confine writes to
    /// `NSHomeDirectory()`/`NSTemporaryDirectory()` and fail with "Operation
    /// not permitted" on any target outside that — including `vmtest`'s
    /// `/tmp/vmtest-e2e-shots` (below), which sits outside the runner's own
    /// home. That old failure is why screenshot evidence was routed through
    /// `attachEvidenceScreenshot(_:name:)` (above) instead — XCTest's own
    /// privileged `XCTAttachment` export path. Evidence should still go
    /// that way, and `FF_E2E_SHOT_DIR`/`E2EShotDir` remains the contract
    /// for writers other than the runner process itself (e.g. host-side
    /// tooling) — but a direct write from the runner now works too, should
    /// one ever be added.
    ///
    /// Reads `FF_E2E_SHOT_DIR` from the process environment — set by
    /// `vmtest` (as `TEST_RUNNER_FF_E2E_SHOT_DIR`, which xcodebuild forwards
    /// to the runner process with the prefix stripped).
    ///
    /// Two cases, deliberately distinct:
    /// - Unset → `NSTemporaryDirectory()` (already relied on by
    ///   `TestFixtureHelper.fixturePath` above). This is the safe default
    ///   when nobody wired anything up.
    /// - Set to an absolute path (starts with "/") → used as-is. `vmtest`
    ///   sets it to an absolute path under `/tmp/` (e.g.
    ///   `/tmp/vmtest-e2e-shots`), the same convention its video-recording
    ///   feature already uses, and a write there from the runner now
    ///   succeeds since the runner is unsandboxed. History: before the
    ///   runner's entitlements were fixed, an earlier convention had
    ///   `vmtest` pass a bare relative name for the runner to resolve
    ///   against its own (then-sandboxed) `NSHomeDirectory()` — that write
    ///   succeeded, but still produced no usable evidence, because an
    ///   external SSH session could not read into the runner's sandboxed
    ///   container afterward. Confirmed live, two instrumented VM runs,
    ///   2026-09-12 (the run that diagnosed the sandbox as the cause).
    ///
    /// A bare relative value (no leading "/") still resolves against
    /// `NSHomeDirectory()` rather than silently falling back to the temp
    /// dir, so a misconfiguration stays visible instead of hidden — but
    /// nothing in this codebase passes one anymore.
    static var path: String {
        guard let dir = ProcessInfo.processInfo.environment["FF_E2E_SHOT_DIR"], !dir.isEmpty else {
            return NSTemporaryDirectory() + "ff-e2e-shots"
        }
        if dir.hasPrefix("/") {
            return dir
        }
        // e2e-lint: allow nshome -- the screenshot-directory helper itself: a relative value stays visibly relative to the runner home (see above).
        return NSHomeDirectory() + "/" + dir
    }

    /// `path` as a URL, creating the directory if it does not exist yet.
    static var url: URL {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Editor mode toggle: never resend a toggle the app already received (t-177a10f1, t-46e4c125)

/// Readers for the app's own `diagnostic.log` (and its two rotated copies), plus the line the app writes where a mode-toggle press
/// arrives. The app writes the file only when launched with `FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING=1`.
enum DiagnosticLogReader {
    /// The line the app persists at its two press sites (the Cmd-/ menu command, `ViewCommands.swift`, and the status-bar badge click,
    /// `StatusBar.swift`) the moment a press reaches it, before the caret-save round trip and any gate. It continues with
    /// ` to=markdown` or ` to=rich text`: the mode the press switches TO.
    static let toggleReceivedMarker = "[TRANS] toggle received"

    /// Every spelling of the three log files' paths. One file is named through several home-directory spellings, so use `sizesNow()`
    /// (deduplicated by resolved path) for anything that counts lines.
    static func candidateURLs() -> [URL] {
        let directory = "Library/Application Support/com.kerim.final-final/Diagnostics"
        return ["diagnostic.log", "diagnostic.log.1", "diagnostic.log.2"].flatMap {
            AppFileHelper.candidateURLs(appRelativePath: directory + "/" + $0)
        }
    }

    /// Each distinct diagnostic-log file's size right now, deduplicated by resolved path: a count over the text must not see the same
    /// line two or three times.
    static func sizesNow() -> [URL: UInt64] {
        var sizes: [URL: UInt64] = [:]
        var seenPaths = Set<String>()
        for url in candidateURLs() {
            guard seenPaths.insert(url.resolvingSymlinksInPath().standardizedFileURL.path).inserted else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)
                .flatMap { $0 }?.uint64Value ?? 0
            sizes[url] = size
        }
        return sizes
    }

    /// The log text appended since `offsets` (from `sizesNow()`), one block per file. Reads the files only, never truncates the real,
    /// shared log, and keeps no offsets of its own. A file now SMALLER than its stored offset was rotated (or truncated) since:
    /// everything in it is new, so it is read from 0. Decoded with `String(decoding:as:)`, which turns a bad byte into U+FFFD instead of
    /// dropping the whole chunk the way `String(data:encoding:)` does (a dropped chunk could hide the very line a check is looking for).
    static func text(since offsets: [URL: UInt64]) -> String {
        offsets.keys.sorted { $0.path < $1.path }.compactMap { url -> String? in
            guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
            defer { try? handle.close() }
            let stored = offsets[url] ?? 0
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size < stored ? 0 : stored)
            let data = handle.readDataToEndOfFile()
            guard !data.isEmpty else { return nil }
            // The lossy decode is the point (a bad byte must not drop the chunk), which is what the rule below would forbid.
            // swiftlint:disable:next optional_data_string_conversion
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n---\n")
    }

    /// How many mode toggles the app has received since `offsets`. `target` (nil: any) is the mode the press switched to, spelled as the
    /// app writes it: "markdown" or "rich text".
    static func toggleReceivedCount(since offsets: [URL: UInt64], to target: String? = nil) -> Int {
        let line = target.map { "\(toggleReceivedMarker) to=\($0)" } ?? toggleReceivedMarker
        return text(since: offsets).components(separatedBy: line).count - 1
    }
}

/// What `toggleEditorModeUntilReceived` saw.
struct ModeToggleOutcome {
    /// The app received a toggle (the label shows the target, or the log has the "toggle received" line).
    let received: Bool
    /// The status-bar label shows the target.
    let flipped: Bool
    /// How many presses were sent (0 when the label already showed the target).
    let presses: Int
    /// How long the wait for the label took after receipt.
    let flipSeconds: TimeInterval
}

extension XCTestCase {
    /// Sends a mode toggle until the app has RECEIVED one, then waits for the status-bar label to show `target` ("Markdown" or "Rich
    /// Text") and never presses again.
    ///
    /// Why "press again if the label has not flipped" is wrong: since the carried switch (Phase 5, 2026-11-06) the label flips only after
    /// the incoming page is ready (up to 15 s, slower with two VMs running), and the app deliberately HOLDS a second toggle and runs it
    /// afterwards (`handleEditorModeToggle` -> `runAfterPendingStructuralWork`; a keypress is never dropped). A resend of a press the app
    /// already has therefore switches the app straight back, and the test fails far from the cause.
    ///
    /// A press counts as received when the label already shows `target`, or the app's diagnostic log has a "[TRANS] toggle received to="
    /// line for it, written since before the first press (the app persists it the moment the press reaches the Cmd-/ menu command or the
    /// badge button, before the caret-save round trip and any gate, which on a loaded host can take longer than the receipt window by
    /// itself). Only a press that neither shows nor logs within `receiptWindow` seconds is treated as dropped and sent again, at most
    /// `maxPresses` times. Once received, the label gets `flipTimeout` seconds (the carried switch is slow on a loaded host).
    ///
    /// "Received" means the app's main thread ran the menu command or the badge click: a Cmd-/ queued behind a main thread blocked for
    /// longer than `receiptWindow` is still resent, and the app then switches back, so this is not a guarantee against that.
    ///
    /// The app must be launched with `FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING=1` (set it on `app.launchEnvironment` in `setUpWithError`,
    /// before the launch), or no log file exists: without it this fails as a TEST-SETUP error and presses nothing.
    ///
    /// This asserts nothing but that setup: each caller keeps its own assertion and wording on the outcome. A failed toggle attaches the
    /// diagnostic-log tail ("diagnostic-log-tail-mode-toggle-never-received" / "...-label-did-not-flip") so it explains itself.
    /// `press` is one press of the trigger (default: bring the app to the front, then Cmd-/).
    func toggleEditorModeUntilReceived(
        _ app: XCUIApplication, to target: String, trigger: String = "Cmd-/ keystroke", maxPresses: Int = 5,
        receiptWindow: TimeInterval = 2, flipTimeout: TimeInterval = 30, press: (() -> Void)? = nil
    ) -> ModeToggleOutcome {
        guard app.launchEnvironment["FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING"] == "1" else {
            XCTFail(
                "TEST-SETUP: the \(trigger) to \(target) cannot tell a dropped press from a slow switch: this test class must launch the " +
                "app with FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING=1 (app.launchEnvironment, in setUpWithError, before the launch), or no " +
                "diagnostic log exists for the app's \"\(DiagnosticLogReader.toggleReceivedMarker)\" line."
            )
            return ModeToggleOutcome(received: false, flipped: false, presses: 0, flipSeconds: 0)
        }
        let editorMode = app.buttons["status-bar-editor-mode"]
        let labelIsTarget = "== '\(target)'"
        if editorMode.exists, editorMode.label == target {
            return ModeToggleOutcome(received: true, flipped: true, presses: 0, flipSeconds: 0)
        }
        let logTarget = target.lowercased()
        let logOffsets = DiagnosticLogReader.sizesNow()
        func appHasReceivedToggle() -> Bool {
            DiagnosticLogReader.toggleReceivedCount(since: logOffsets, to: logTarget) > 0
        }

        var presses = 0
        var received = false
        while !received, presses < maxPresses {
            if let press {
                press()
            } else {
                app.activateAndWaitForForeground()
                app.typeKey("/", modifierFlags: .command)
            }
            presses += 1
            let deadline = Date().addingTimeInterval(receiptWindow)
            repeat {
                received = appHasReceivedToggle() || editorMode.waitForLabel(labelIsTarget, timeout: 0.5)
            } while !received && Date() < deadline
            // A line written in the last half second of the window still counts.
            if !received { received = appHasReceivedToggle() }
        }
        guard received else {
            attachDiagnosticLogTail(since: logOffsets, name: "never-received", note: "\(trigger) to \(target), \(presses) press(es)")
            return ModeToggleOutcome(received: false, flipped: false, presses: presses, flipSeconds: 0)
        }

        let started = Date()
        let flipped = editorMode.waitForLabel(labelIsTarget, timeout: flipTimeout)
        let flipSeconds = Date().timeIntervalSince(started)
        if !flipped {
            attachDiagnosticLogTail(since: logOffsets, name: "label-did-not-flip", note: "\(trigger) to \(target), \(presses) press(es)")
        }
        return ModeToggleOutcome(received: true, flipped: flipped, presses: presses, flipSeconds: flipSeconds)
    }

    /// Attaches the diagnostic-log text written since `offsets`, so a failed toggle explains itself.
    private func attachDiagnosticLogTail(since offsets: [URL: UInt64], name: String, note: String) {
        let attachment = XCTAttachment(string: "// \(note)\n" + DiagnosticLogReader.text(since: offsets))
        attachment.name = "diagnostic-log-tail-mode-toggle-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

extension XCUIApplication {
    /// Waits until some node under the editor area shows `text` in its label or value (any element type), polling about every quarter
    /// second for at most `timeout`. Crash-safe where the old `label CONTAINS ... OR value CONTAINS ...` predicate was not: an element
    /// whose `value` is a number (a heading container carries its level) makes `value CONTAINS` throw NSInvalidArgumentException, so
    /// `value` is read with `as? String`. Each poll takes one fresh snapshot of the whole editor subtree (one accessibility round trip),
    /// never a handle reused from an earlier poll.
    func waitForEditorText(_ text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var failedPolls = 0
        repeat {
            do {
                if Self.snapshotShowsText(try editorArea.snapshot(), text) { return true }
            } catch {
                failedPolls += 1
                if failedPolls == 1 { print("[waitForEditorText] snapshot() of editor-area failed: \(error)") }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return false
    }

    private static func snapshotShowsText(_ snapshot: XCUIElementSnapshot, _ text: String) -> Bool {
        snapshot.children.contains { child in
            child.label.contains(text) || ((child.value as? String)?.contains(text) ?? false) || snapshotShowsText(child, text)
        }
    }
}
