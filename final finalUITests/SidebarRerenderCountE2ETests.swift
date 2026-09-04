//
//  SidebarRerenderCountE2ETests.swift
//  final finalUITests
//
//  PERMANENT regression test for bt t-ef411da3 (sidebar re-render root-cause fix, round 3).
//
//  Ports the measurement approach that was originally prototyped as a disposable investigation
//  run using `final finalUITests/E2EScratchTests.swift` (a committed-empty scratch file --
//  see its own header for that mechanism) into a permanent, committed test. That earlier run's
//  diagnostic-log reader was un-deduped and produced a false pass -- see
//  `diagnosticLogCandidateURLs()`'s doc comment in `UnifiedUndoE2ETests+Helpers.swift` (cited in
//  point 1 below) for the full story of that tripling bug. Two changes from that disposable
//  predecessor matter for correctness, not just permanence:
//
//   1. This test reads the diagnostic log through `UnifiedUndoE2ETests.recordDiagnosticLogStartOffsets()`
//      / `UnifiedUndoE2ETests.currentDiagnosticLogContents()` -- the FIXED, deduped helpers in
//      `UnifiedUndoE2ETests+Helpers.swift` (`diagnosticLogCandidateURLs()`'s doc comment there has
//      the full story of the tripling bug this fixes). `E2ESectionReconcilerPseudoSectionTests.swift`
//      and `EditorModeSwitchUndoE2ETests.swift` still carry the OLD, un-deduped copy of that
//      helper -- deliberately untouched this round (out of scope: they only test marker
//      presence, where tripling is harmless) -- so this file must never crib its diagnostic-log
//      reading from either of those two.
//
//   2. The bound below (0.15) is only meaningful with that dedupe fix in place. The MAIN ratio
//      assertion (SidebarBody / ContentSyncObserved, round-3 must-fix-4, denominator updated by
//      bt t-63c521f5 -- see point 3 and its own comment below for why the denominator is
//      ContentSyncObserved, not ContentViewBody, and not raw keystrokes) is a SAME-LOG ratio, so a
//      uniform per-run multiplier bug (like the old 3x directory-aliasing tripling) would
//      actually CANCEL out of it either way -- both counters come from the identical log delta.
//      That is NOT what the dedupe fix protects there; ContentSyncObserved isn't causally
//      downstream of OutlineSidebar's own fix the way the original investigation's
//      WordCountLabel-based ratio was (a self-referential confound: that earlier ratio's
//      denominator, WordCountLabel re-renders, was itself partly caused by whichever sidebar
//      behavior was under test, so the ratio could look healthy or not for reasons unrelated to
//      whether the parent-cascade bug was actually fixed), so this ratio stays meaningful either
//      way. What the dedupe fix DOES protect: the POSITIVE CONTROL and the `keystrokes` sanity
//      gates below compare a log-derived count against the externally-known, NOT-read-from-the-log
//      `keystrokes` value -- a tripled count would corrupt exactly those comparisons. And more
//      fundamentally, every raw count in the UNCONDITIONALLY printed/attached `summary` (this
//      file's whole verification-integrity purpose -- see `diagnosticLogCandidateURLs()`'s doc
//      comment in `UnifiedUndoE2ETests+Helpers.swift`, cited in point 1 above, for the tripling
//      incident this exists to never repeat) needs to reflect ground truth, not a 3x-inflated
//      fiction, for a human reading that evidence later to draw the right conclusion from it.
//
//   3. bt t-63c521f5 (extract-content-sync-observers) moved `ContentView.body`'s content/
//      editor-mode/zoom `.onChange` handlers into their own host view, `ContentSyncObserverHost`
//      (`ViewNotificationModifiers.swift`), and added a fourth bracket marker,
//      `[ContentSyncObserved]`. That marker sits at the TOP of the content `.onChange` handler,
//      before its `.idle` guard, so it fires on every attempted invocation of that handler --
//      including no-op returns during bibliography rebuilds, zoom transitions, and mode switches
//      -- not only on completed syncs. This file's marker inventory is now `[ContentViewBody]`,
//      `[SidebarBody]`, `[WordCountLabel]`, `[ContentSyncObserved]`. `ContentViewBody` can no
//      longer serve as the MAIN ratio's denominator (the role it held as of round 3, must-fix-4):
//      t-63c521f5 deliberately drives it toward zero, so a near-zero denominator would make the
//      ratio explode into a false failure, and the old `if counts.contentViewBody > 0` guard would
//      otherwise just silently skip the assertion instead -- retiring the guard's protection
//      entirely rather than ever tripping it. `contentSyncObserved` (new counter, fires on every
//      `.onChange(of: editorState.content)` invocation, the same log-derived nature
//      `contentViewBody` had before this round) takes over that denominator role, preserving the
//      exact confound-resistance property the round-3 decision required, for the same underlying
//      reason: it tracks content-sync `.onChange` activity rather than SwiftUI's own per-keystroke
//      view-update bookkeeping, so it stays a stable stand-in denominator even as ContentViewBody
//      itself is optimized toward zero. The replacement `if counts.contentSyncObserved > 0` guard
//      below is NOT the same retired-protection problem: unlike `contentViewBody`, this fix does
//      not drive `contentSyncObserved` toward zero -- it is not what t-63c521f5 optimizes -- and
//      the positive-control assertion above already fails first if `contentSyncObserved` were ever
//      unexpectedly near zero, so this guard stays a live, meaningful trip wire rather than a
//      silently-skipped one. `keystrokes` remains explicitly rejected as the sidebar-ratio's
//      denominator, for the original round-3 reason above (point 2, unchanged): a ratio against
//      `keystrokes` alone could false-pass in a narrow band where keystroke loss and a
//      partially-broken re-render rate happened to offset each other. This round also adds a
//      SEPARATE new assertion -- `bodyRatio = ContentViewBody / ContentSyncObserved < 0.25` --
//      proving ContentView.body itself now stays near-idle while typing; see its own no-loosening
//      rule in KNOWN CONFOUNDERS below.
//
//  KNOWN CONFOUNDERS -- each of these can move the measured ratio for reasons unrelated to
//  whether the fix works, so a result landing right at the 0.15 bound should be RE-RUN, not
//  argued about:
//   - Log rotation mid-run: `diagnostic.log` rotates to `.log.1`/`.log.2` past a size threshold;
//     a rotation landing exactly inside a phase's typing window could split that phase's markers
//     across files in a way the offset-based delta reader wasn't positioned for.
//   - `typeText` character drops under VM load (documented and CONFIRMED live --
//     `UITestHelpers.swift`'s `typeTextVerifyingLanded` doc comment): a dropped keystroke changes
//     the true keystroke count the positive-control assertion and the `keystrokes > 20` sanity
//     gate depend on (the MAIN ratio's own denominator is `contentSyncObserved`, not `keystrokes`
//     -- see point 3 above -- and the new `bodyRatio` assertion below is ALSO denominated on
//     `contentSyncObserved` rather than `keystrokes`, for the identical same-log, drop-immune
//     reason, so heavy character loss moves only the positive control and the `keystrokes > 20`
//     gate, not the main ratio or `bodyRatio`), independent of any sidebar behavior.
//   - Heading-parse/reconciliation churn specifically during RAPID heading typing (phase 1 and
//     phase 3): each character typed into a heading can trigger `SectionReconciler` parsing work
//     downstream of the debounce, which is real, expected `SidebarBody` activity distinct from
//     the parent-cascade bug this test guards against -- a small nonzero `SidebarBody` count
//     during heading typing is not itself a failure signal; the 0.15 bound already allows room
//     for it.
//   - The new `bodyRatio` assertion (bt t-63c521f5, ContentViewBody / ContentSyncObserved < 0.25)
//     has its own no-loosening rule, same spirit as the 0.15 bound above but stricter: its 0.25
//     bound must never be raised to make a failing run pass. A failure there means some
//     `.onChange` (or other dependency) is still firing inside ContentView.body's own SwiftUI
//     dependency-tracking scope -- diagnose and report which one, don't widen the bound to paper
//     over it.
//

import XCTest

final class SidebarRerenderCountE2ETests: XCTestCase {
    var app: XCUIApplication!

    /// Same anchor + two-H2-siblings shape as `UnifiedUndoE2ETests+Helpers.swift`'s
    /// `canonicalMarkdown` -- duplicated here rather than reused across test classes, matching
    /// this suite's established per-file convention (see e.g.
    /// `E2ESectionReconcilerPseudoSectionTests.swift`'s own `seedMarkdown`/`replacementMarkdown`,
    /// which duplicate fixture markdown locally for the identical reason).
    static let canonicalMarkdown = """
    # Anchor Section

    Anchor section body text for word counting.

    ## Middle Section

    Middle section body text for word counting purposes.

    ## Last Section

    Last section body text for word counting purposes too.
    """

    override func setUpWithError() throws {
        // A heading-phase assertion failure must not prevent the body-phase (or structural-
        // phase) assertions from running -- all three phases' evidence is independently
        // valuable, and only running phase 1 on the first failure would silently hide whatever
        // phases 2/3 would otherwise have shown.
        continueAfterFailure = true
        app = XCUIApplication.targetApp()
        app.terminate()
        try TestFixtureHelper.setupFixture(from: self)

        // Belt-and-braces diagnostics enablement: the launch-argument approach (this suite's
        // established convention, e.g. UnifiedUndoE2ETests+Helpers.swift's
        // launchAndWaitForEditor) PLUS the env-var force-on override
        // (DiagnosticLogFile.isEnabled's doc comment) -- the latter sidesteps
        // TestMode.clearTestState()'s unconditional wipe of the UserDefaults-backed toggle under
        // UI testing, so this test's diagnostics stay on even if some earlier test-lifecycle step
        // clears defaults after the launch argument was applied.
        app.launchArguments += ["-com.kerim.final-final.diagnosticsLoggingEnabled", "YES"]
        app.launchEnvironment["FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING"] = "1"
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }

    // MARK: - Diagnostic log delta helpers (see this file's header for how this measurement
    // approach originated; log READING itself is not duplicated here -- it calls through to
    // UnifiedUndoE2ETests's FIXED, deduped statics)

    struct ViewUpdateCounts {
        let contentViewBody: Int
        let sidebarBody: Int
        let wordCountLabel: Int
        let contentSyncObserved: Int

        var total: Int { contentViewBody + sidebarBody + wordCountLabel + contentSyncObserved }
    }

    /// Counts occurrences of each bracketed marker substring in a diagnostic-log delta. A plain
    /// substring count is exact here: each marker is a single, distinct bracket tag that never
    /// appears elsewhere in this app's DebugLog output, and DiagnosticLogFile.append() never
    /// dedupes repeated lines.
    static func countViewUpdateMarkers(in log: String) -> ViewUpdateCounts {
        func count(_ marker: String) -> Int {
            log.components(separatedBy: marker).count - 1
        }
        return ViewUpdateCounts(
            contentViewBody: count("[ContentViewBody]"),
            sidebarBody: count("[SidebarBody]"),
            wordCountLabel: count("[WordCountLabel]"),
            contentSyncObserved: count("[ContentSyncObserved]")
        )
    }

    /// Types one character at a time until `duration` has elapsed. A deadline-driven loop so VM
    /// slowness stretches the keystroke COUNT rather than shrinking the measurement WINDOW, and
    /// content is throwaway (this measures re-render counts, not resulting text) so `typeText`'s
    /// known character-drop flakiness under VM load doesn't corrupt what's being measured -- using
    /// `typeTextVerifyingLanded`'s retry/repair loop here would actively corrupt the cadence.
    @discardableResult
    func typeContinuously(for duration: TimeInterval, charInterval: TimeInterval = 0.15) -> Int {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        let deadline = Date(timeIntervalSinceNow: duration)
        var count = 0
        while Date() < deadline {
            // e2e-lint: allow raw-typetext -- measures re-render COUNTS, not landed text.
            app.typeText(String(alphabet[count % alphabet.count]))
            count += 1
            // e2e-lint: allow sleep -- sets the keystroke cadence this measurement depends on.
            Thread.sleep(forTimeInterval: charInterval)
        }
        return count
    }

    /// Local copy of `UnifiedUndoE2ETests+Helpers.swift`'s `sidebarCard(titled:)` -- same
    /// scoping/predicate rationale (sidebar `ScrollView`, not the whole `outline-sidebar` group,
    /// to avoid the zoom-breadcrumb false match; `label == title OR value == title`, matching
    /// this AX tree's title-lives-in-`value` shape) -- duplicated per this suite's established
    /// per-file convention rather than reached into another test class.
    func sidebarCard(titled title: String, timeout: TimeInterval = 10) -> XCUIElement {
        let sidebarScrollView = app.groups["outline-sidebar"].scrollViews.firstMatch
        let card = sidebarScrollView.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", title, title))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: timeout), "Sidebar card titled \"\(title)\" should appear")
        return card
    }

    // MARK: - The measurement

    func testSidebarBodySkipsReRenderOnTypingAndStillUpdatesOnStructuralChange() throws {
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: Self.canonicalMarkdown)
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)

        let editorArea = app.editorArea
        XCTAssertTrue(editorArea.waitForExistence(timeout: 10), "Editor area should appear")
        let wordCount = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(
            wordCount.waitForValue("CONTAINS 'words'", timeout: 10),
            "Status bar should show word count (editor JS ready)"
        )
        XCTAssertNotNil(
            app.editorStaticText(startingWith: "Anchor Section", timeout: 10),
            "Editor should render its first heading before this test's first interaction"
        )

        // ---- Phase 1: type into an EXISTING section's HEADING ----
        runTypingPhase(
            name: "heading",
            findElement: { self.app.editorStaticText(startingWith: "Middle Section", timeout: 10) }
        )

        // ---- Phase 2: type into that SAME EXISTING section's BODY TEXT ----
        let bodyText = "Middle section body text for word counting purposes."
        runTypingPhase(
            name: "body",
            findElement: { self.app.editorStaticText(startingWith: bodyText, timeout: 10) }
        )

        // ---- Phase 3: prove the sidebar STILL updates when it genuinely should -- the
        // automated half of proving OutlineSidebar's `==` isn't just hardcoded `true`. A new
        // heading must produce a new sidebar card, and undoing it must remove that card again. ----
        let uniqueTitle = "New Structural Section \(shortUUID())"
        app.activateAndWaitForForeground()
        app.typeKey(.downArrow, modifierFlags: .command)  // jump to end of document
        app.typeKey(.return, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        // "## " at the start of a brand-new, empty paragraph invokes Milkdown's commonmark
        // heading input rule and converts that paragraph into an H2 -- distinct from typing
        // "### " at position 0 of an EXISTING heading (which ADDS to that heading's level
        // instead; see EditorModeSwitchUndoE2ETests.testUndoAfterHeadingBreakingEditInWysiwyg's
        // doc comment for that other case). There is no existing heading here to extend --
        // this line was just created empty -- so the input rule's only sensible action is the
        // paragraph-to-heading conversion this phase depends on. Not verified byte-for-byte: a
        // dropped character here would just change the sidebar card's exact title, which
        // sidebarCard(titled:) below would then simply fail to find (a loud, legible failure).
        // e2e-lint: allow raw-typetext
        app.typeText("## ")
        // e2e-lint: allow sleep -- brief settle between the heading-conversion input rule firing
        // and typing the title text into the now-converted heading node; nothing AX-observable
        // to wait on in between.
        Thread.sleep(forTimeInterval: 0.3)
        // e2e-lint: allow raw-typetext -- see the allow comment on "## " above; same rationale.
        app.typeText(uniqueTitle)
        // e2e-lint: allow sleep -- real debounce (~100ms JS) + poll (~2s Swift) cycle margin,
        // matching this suite's own established timing (e.g. HrTypedConversionE2ETests's
        // identical wait after live typing); nothing AX-observable marks "sync settled".
        Thread.sleep(forTimeInterval: 4.0)

        let newCard = sidebarCard(titled: uniqueTitle, timeout: 10)
        XCTAssertTrue(newCard.exists, "A new sidebar card titled \"\(uniqueTitle)\" should exist after typing the heading")

        app.activateAndWaitForForeground()
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(
            newCard.waitForNonExistence(timeout: 10),
            "Sidebar card titled \"\(uniqueTitle)\" should disappear after Cmd-Z undoes the new heading"
        )
    }

    private func shortUUID() -> String {
        String(UUID().uuidString.prefix(8))
    }

    /// Runs one typing phase end-to-end: locate `findElement()`, click into it, type
    /// continuously for 16s, read the diagnostic-log delta, attach + print the summary
    /// unconditionally, then run every phase assertion. Shared by phases 1 and 2 -- their only
    /// difference is which editor element they click into.
    private func runTypingPhase(name: String, findElement: () -> XCUIElement?) {
        UnifiedUndoE2ETests.recordDiagnosticLogStartOffsets()
        guard let element = findElement() else {
            XCTFail("Phase \"\(name)\": target element should be findable in editor-area before typing")
            return
        }
        app.activateAndWaitForForeground()
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).click()
        app.activateAndWaitForForeground()
        let keystrokes = typeContinuously(for: 16.0)
        // e2e-lint: allow sleep -- lets the LAST keystroke's re-render (and its DebugLog line)
        // actually land before the delta is read; nothing AX-observable marks "re-render done"
        // (matching UnifiedUndoE2ETests+Helpers.swift's rightClickSidebarCard settle comment).
        Thread.sleep(forTimeInterval: 1.0)
        let logDelta = UnifiedUndoE2ETests.currentDiagnosticLogContents()
        let counts = Self.countViewUpdateMarkers(in: logDelta)

        // UNCONDITIONAL print + attachment -- printed/attached regardless of pass/fail, so a
        // passing OR failing run always leaves recoverable evidence of what was actually
        // measured (the verification-integrity bug this whole test class exists to never repeat
        // -- see `diagnosticLogCandidateURLs()`'s doc comment in `UnifiedUndoE2ETests+Helpers.swift`,
        // cited in this file's header point 1, for the original tripling incident).
        let summary = "[E2E-VIEWUPDATES] phase=\(name) keystrokes=\(keystrokes) " +
            "ContentViewBody=\(counts.contentViewBody) SidebarBody=\(counts.sidebarBody) " +
            "WordCountLabel=\(counts.wordCountLabel) ContentSyncObserved=\(counts.contentSyncObserved)"
        print(summary)
        let attachment = XCTAttachment(string: summary)
        attachment.lifetime = .keepAlways
        attachment.name = "viewupdates-\(name)"
        add(attachment)

        // Sanity gate 1: the log delta itself must be non-empty, or every count below is
        // trivially (and meaninglessly) zero.
        XCTAssertFalse(
            logDelta.isEmpty,
            "Phase \"\(name)\": diagnostic log delta was empty -- likely causes: wrong log path " +
            "(diagnosticLogCandidateURLs() resolving somewhere unexpected on this machine), " +
            "diagnostics not actually enabled (launch argument/env var not taking effect), " +
            "stale start offsets (recordDiagnosticLogStartOffsets() not called immediately before " +
            "this phase), or the log having rotated past this phase's offset."
        )

        // Sanity gate 2: SOME view-update marker must have fired at all.
        XCTAssertGreaterThan(
            counts.total, 0,
            "Phase \"\(name)\": ContentViewBody + SidebarBody + WordCountLabel + ContentSyncObserved " +
            "was 0 -- likely causes: wrong log path, diagnostics off, stale offsets, or log rotation " +
            "(see this test's file header for the full confounder list). \(summary)"
        )

        // Positive control: proves keystrokes actually landed AND logging actually ran --
        // a SEPARATE assertion from the main ratio below, never used as its divisor. Every
        // keystroke that reaches the editor and propagates back to SwiftUI state triggers (at
        // least roughly) one `.onChange(of: editorState.content)` firing -- ContentSyncObserved
        // counts these before the `.idle` guard (attempted invocations, not just completed
        // syncs), so a healthy run should show ContentSyncObserved firing on well over half the
        // typed keystrokes.
        XCTAssertGreaterThan(
            counts.contentSyncObserved, keystrokes / 2,
            "Phase \"\(name)\": ContentSyncObserved (\(counts.contentSyncObserved)) should track keystrokes " +
            "typed (\(keystrokes)) reasonably closely -- if it doesn't, keystrokes may not be " +
            "landing or the positive-control signal itself is broken, and the main ratio " +
            "assertion below is not trustworthy. \(summary)"
        )

        XCTAssertGreaterThan(keystrokes, 20, "Phase \"\(name)\": expected more than 20 keystrokes typed in 16s")

        // New for bt t-63c521f5: ContentView.body itself must now redraw on only a SMALL
        // fraction of real content-sync activity -- the whole point of extracting the
        // content-sync observers into their own host view. Denominator is `contentSyncObserved`,
        // not `keystrokes`: `keystrokes` counts `typeText` calls, not landed characters, so it's
        // drop-sensitive (see KNOWN CONFOUNDERS below), while `contentSyncObserved` is a SAME-LOG
        // count, immune to that drop -- the identical property the sidebar ratio's own denominator
        // swap (point 3 above) defends. Do not raise 0.25 to make this pass; if it fails, diagnose
        // what's still firing inside ContentView.body's own dependency scope (likely
        // .onChange(of: editorState.contentState) at ContentView.swift:214) and report it.
        let bodyRatio = Double(counts.contentViewBody) / Double(counts.contentSyncObserved)
        XCTAssertLessThan(
            bodyRatio, 0.25,
            "Phase \"\(name)\": ContentViewBody (\(counts.contentViewBody)) should stay a small " +
            "fraction of ContentSyncObserved (\(counts.contentSyncObserved)), ratio \(bodyRatio) " +
            "-- bt t-63c521f5 expects this near zero. Do not raise 0.25 to make this pass; " +
            "diagnose what's still firing inside ContentView.body's own dependency scope (likely " +
            ".onChange(of: editorState.contentState) at ContentView.swift:214) and report it " +
            "instead. \(summary)"
        )

        // Main assertion: a healthy sidebar (bt t-ef411da3 fixed) re-renders on only a SMALL
        // fraction of real content-sync activity -- not close to 1:1. Divided by the MEASURED
        // `contentSyncObserved` count, not the test-counted `keystrokes` -- round-3 review
        // finding: those two denominators can diverge (e.g. under significant typeText
        // character-drop loss), and a ratio against `keystrokes` alone could false-pass in a
        // narrow band where keystroke loss and a partially-broken re-render rate happened to
        // offset each other. `contentViewBody` can no longer serve as this denominator either
        // (see this file's header) -- `contentSyncObserved` takes over its role for the exact
        // same reason. The positive-control assertion above (against `keystrokes`) stays as a
        // separate sanity gate that keystrokes actually landed; this one measures the actual
        // invalidation coupling between the two counters the log itself recorded. This bound
        // (0.15) is only meaningful once the §3 diagnostic-log dedupe fix has landed (it has, in
        // this same round) -- see this file's header for why an un-deduped log would make this
        // number meaningless in either direction.
        if counts.contentSyncObserved > 0 {
            let ratio = Double(counts.sidebarBody) / Double(counts.contentSyncObserved)
            XCTAssertLessThan(
                ratio, 0.15,
                "Phase \"\(name)\": SidebarBody (\(counts.sidebarBody)) should stay a small fraction " +
                "of ContentSyncObserved (\(counts.contentSyncObserved)), not track it close to 1:1. " +
                "keystrokes=\(keystrokes) WordCountLabel=\(counts.wordCountLabel). " +
                "A result right at this 0.15 bound should be re-run rather than argued about -- see " +
                "this file's header for known confounders (log rotation, typeText character drops, " +
                "heading-parse/reconciliation churn). \(summary)"
            )
        }
    }
}
