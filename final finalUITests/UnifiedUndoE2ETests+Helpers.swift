//
//  UnifiedUndoE2ETests+Helpers.swift
//  final finalUITests
//
//  Shared helpers for UnifiedUndoE2ETests.swift. Split into its own file (rather than left in
//  the primary file) purely to keep SwiftLint's file_length under this repo's error threshold
//  (1000 lines) -- no behavior change beyond access level: Swift's `private` same-file/same-type
//  relaxation only covers extensions in the SAME file, so every member here is `internal`
//  (module-default) instead, matching this codebase's established `Type+Feature.swift`
//  convention (e.g. ContentView+SectionOperations.swift) -- not part of this test target's public
//  API surface in any meaningful sense, just visible to the rest of the target the way any
//  same-module extension's members are.
//

import XCTest

extension UnifiedUndoE2ETests {
    // MARK: - Shared fixture content

    /// Anchor (H1) + two H2 siblings, distinctly titled so each is unambiguously findable in the
    /// sidebar by exact text and never collides with a duplicate's " copy"-suffixed title.
    /// Seeded via a raw `content.markdown` UPDATE (app terminated -- established pattern, see
    /// E2ESectionReconcilerPseudoSectionTests.swift's file header), not live-typed: what matters
    /// for the canonical scenario is the structural undo/redo/restore/reorder behavior once the
    /// sections exist, not how they were typed. Only the H1/H2 siblings never get
    /// reordered/touched directly (reorder targets the two H2s) to avoid any hierarchy-
    /// enforcement side effect ("first section must be H1") unrelated to what's under test.
    static let canonicalMarkdown = """
    # Anchor Section

    Anchor section body text for word counting.

    ## Middle Section

    Middle section body text for word counting purposes.

    ## Last Section

    Last section body text for word counting purposes too.
    """

    func seedCanonicalDocument() {
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: Self.canonicalMarkdown)
    }

    // MARK: - Launch / editor-ready

    func launchAndWaitForEditor() {
        // Diagnostics logging on for every test in this file, matching
        // E2ESectionReconcilerPseudoSectionTests.swift/EditorModeSwitchUndoE2ETests.swift's own
        // established convention -- turns on the runtime Diagnostics toggle so DebugLog's
        // `.undo`-category output (routing decisions, refusals, structural-op steps) reaches the
        // persistent diagnostic log file `captureDiagnostics`/the H1-probe helpers can read from,
        // independent of which categories happen to be console-enabled in a DEBUG build.
        app.launchArguments += ["-com.kerim.final-final.diagnosticsLoggingEnabled", "YES"]
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)
        waitForEditorReady()
        Self.recordDiagnosticLogStartOffsets()
    }

    func waitForEditorReady() {
        let editorArea = app.groups["editor-area"]
        XCTAssertTrue(editorArea.waitForExistence(timeout: 10), "Editor area should appear")
        let wordCount = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(wordCount.waitForValue("CONTAINS 'words'", timeout: 10), "Status bar should show word count (editor JS ready)")
    }

    func currentWordCountValue() -> String {
        (app.staticTexts["status-bar-word-count"].value as? String) ?? ""
    }

    func clickIntoEditor() {
        app.editorArea.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).click()
    }

    /// FINDING (2026-08-22, eviction-cap test failure round): `pressUndo`/`pressRedo` used to
    /// click into the editor BEFORE calling `activateAndWaitForForeground()` -- the opposite
    /// order from every other keystroke helper in this file (`saveVersion(named:)`,
    /// `dragSidebarCard`'s own drop-then-verify flow, etc.), all of which activate/foreground
    /// FIRST and only then interact. The eviction-cap test's diagnostic log delta for its first
    /// Cmd-Z (after 4 back-to-back sidebar right-click-then-menu-select operations, the most
    /// rapid-fire native-menu-interaction sequence in this file) showed ZERO `.undo`-category
    /// activity at all -- not even a declined/fallthrough entry -- meaning the keystroke never
    /// reached the WebView's JS layer at all, consistent with the native click not actually
    /// landing/taking first-responder focus in whatever transient window/foreground state a
    /// just-dismissed NSMenu leaves behind. Activating first (this file's own established,
    /// working pattern elsewhere) before the click removes that ordering gap.
    func pressUndo() {
        app.activateAndWaitForForeground()
        clickIntoEditor()
        app.typeKey("z", modifierFlags: .command)
    }

    func pressRedo() {
        app.activateAndWaitForForeground()
        clickIntoEditor()
        app.typeKey("z", modifierFlags: [.command, .shift])
    }

    // MARK: - Mode switch helper (Test 7 only -- N1's CodeMirror path requires Source mode)

    /// Switches to Source mode via Cmd-/. Local copy of
    /// `EditorModeSwitchUndoE2ETests.toggleWysiwygToSource`'s established two-part pattern:
    /// retry-the-keystroke (Cmd-/ can drop if the app isn't reliably foreground at the instant
    /// it's sent) plus a mount-completion gate (the status-bar label flip is synchronous, but the
    /// actual WYSIWYG->CodeMirror view swap runs through an async callback chain that can lag
    /// behind it -- typing immediately after only the label flips risks landing in the
    /// still-live Milkdown instance instead of the new CodeMirror one, silently defeating the
    /// whole point of this test).
    func switchToSourceMode() {
        let editorMode = app.buttons["status-bar-editor-mode"]
        XCTAssertTrue(editorMode.waitForExistence(timeout: 10), "Editor mode button should appear")

        var toggled = false
        for _ in 1...5 {
            if editorMode.label == "Source" { toggled = true; break }
            app.activateAndWaitForForeground()
            app.typeKey("/", modifierFlags: .command)
            if editorMode.waitForLabel("== 'Source'", timeout: 2) { toggled = true; break }
        }
        XCTAssertTrue(toggled, "Editor-mode button should report Source after retrying the toggle keystroke")

        // Mount-completion gate: this suite's own seeded canonical document opens with the
        // literal line "# Anchor Section" -- Milkdown's WYSIWYG rendering strips markdown syntax
        // (exposed to accessibility as "Anchor Section", never with the leading "#"), so only
        // CodeMirror (which renders raw source verbatim) will ever expose an element containing
        // the literal "# Anchor Section". Its appearance is proof the source editor actually
        // mounted, not just that the status-bar button re-labeled itself.
        let editorArea = app.groups["editor-area"]
        let sourceEvidence = editorArea.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS '# Anchor Section' OR value CONTAINS '# Anchor Section'")
        ).firstMatch
        XCTAssertTrue(
            sourceEvidence.waitForExistence(timeout: 10),
            "CodeMirror source editor should render the raw markdown after toggling, not just flip the status-bar label"
        )
    }

    // MARK: - Sidebar helpers

    /// Locates a sidebar card by its EXACT title text, scoped to the sidebar's `ScrollView` (not
    /// the whole `outline-sidebar` group -- see below) and never the editor's own heading mirror
    /// (e2e-verify skill's "every editor heading matches three StaticTexts" gotcha). NSPredicate
    /// exact match, re-resolved fresh on every call rather than cached, so a card that moved
    /// after a prior reorder/duplicate is still found.
    ///
    /// Matches BOTH `label` and `value` (confirmed against a real vmtest AX-tree dump, not
    /// speculative): the sidebar card's title `StaticText` exposes its text via `value`, with no
    /// `label` at all --
    /// `StaticText, 0x92ba0a080, {{20.0, 239.0}, {163.0, 28.0}}, value: Second Section` -- the
    /// exact same "editor text lives in value, not label" gotcha class the e2e-verify skill
    /// documents for editor content, applying here too. A bare `label == title` predicate can
    /// never match, so every call using it timed out at the full `timeout` regardless of whether
    /// the app was doing anything right -- confirmed as the root cause of 6 of this file's 8
    /// first-round vmtest failures. `==` (not `CONTAINS`) is safe against a non-String `value`
    /// (an NSNumber heading-level, say) -- unlike `CONTAINS`/`IN`, `==` between mismatched types
    /// just evaluates false rather than throwing (the skill's CONTAINS-throws gotcha doesn't
    /// apply to plain equality), matching this codebase's own established `waitForValue`/
    /// `waitForLabel` helpers' use of `==`.
    ///
    /// Scoped to the sidebar's `ScrollView`, NOT the whole `outline-sidebar` group -- CONFIRMED
    /// (vmtest AX-tree dump, run-1787343833-30932, attachment
    /// 9B6146FB-6FB1-4122-9D91-B4B58BB52A2C.txt, the actual failure-time hierarchy for
    /// testStructuralOpRefusedWhileZoomedStaysConsistent's post-zoom lookup): while zoomed into a
    /// section, `outline-sidebar` gains a SECOND element carrying the section's title -- a zoom
    /// breadcrumb ("All Sections › Second Section"), which appears as its OWN `StaticText`
    /// SIBLING of the real card, positioned BEFORE the `ScrollView` in tree order:
    /// ```
    /// Group, identifier: 'outline-sidebar'
    ///   Button, label: 'All Sections'
    ///   StaticText, value: ›
    ///   StaticText, {{117.5, 89.0}, {84.5, 14.0}}, value: Second Section   <- breadcrumb (NOT a card)
    ///   ScrollView
    ///     ... Group > StaticText, {{20.0, 176.0}, {163.0, 28.0}}, value: Second Section   <- the real card
    /// ```
    /// An unscoped query's `.firstMatch` resolved to the breadcrumb (it precedes the real card in
    /// tree order) -- confirmed as the root cause of `testStructuralOpRefusedWhileZoomedStaysConsistent`'s
    /// "Delete Section" menu item never appearing: the right-click landed on a small breadcrumb
    /// label with no context menu, not on any card at all. Confirmed absent before any zoom (a
    /// non-zoomed dump from the same run has no breadcrumb elements, same `ScrollView` position)
    /// -- this scoping doesn't change behavior for the non-zoomed case, only removes the
    /// zoomed-only false match.
    func sidebarCard(titled title: String, timeout: TimeInterval = 10) -> XCUIElement {
        let sidebarScrollView = app.groups["outline-sidebar"].scrollViews.firstMatch
        let card = sidebarScrollView.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", title, title))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: timeout), "Sidebar card titled \"\(title)\" should appear")
        return card
    }

    /// Right-click (real NSEvent path -- sidebar cards allow right-clicks through their
    /// otherwise-non-hittable wrapper by design, `PassthroughHostingView.hitTest`, e2e-verify
    /// skill) a sidebar card and choose a context-menu item by title prefix.
    ///
    /// Its "Pattern 1" diagnostic instrumentation (screenshot + AX-tree dump + a 4s DB
    /// immediate-vs-settled re-check after EVERY call) is gone as of 2026-08-22: that
    /// investigation's root cause (`Database+SectionOps.swift`'s `deleteSections`/
    /// `duplicateSections` operating on the wrong id space against the legacy `section` table)
    /// is fixed and confirmed via a live vmtest pass, so the extra ~4.5s of overhead per call --
    /// 4 calls deep in `testEvictionCapEvictsOldestEntryAndStaysConsistent` alone, roughly 18s --
    /// was purely a diagnostic aid for a bug that no longer exists. `captureDiagnostics` below
    /// still runs (now genuinely lightweight: a screenshot, an AX-tree dump, and the log delta,
    /// no DB re-check or extra sleep) since it's useful general-purpose evidence capture, not
    /// because this call site still needs Pattern 1's specific data.
    func rightClickSidebarCard(titled cardTitle: String, thenChooseMenuItem menuTitle: String) {
        Self.recordDiagnosticLogStartOffsets()
        let card = sidebarCard(titled: cardTitle)
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        app.menuItem(titleStartingWith: menuTitle).click()
        // Brief settle: deleteSectionFromSidebar/duplicateSectionFromSidebar dispatch their real
        // work in a `Task { }`, which hasn't necessarily started running (let alone logged
        // anything) in the instant right after `.click()` returns -- this is NOT the same wait as
        // the caller's own subsequent `waitUntil` (that one waits for DB completion; this one
        // just gives the Task a chance to have started before capturing a snapshot of it).
        Thread.sleep(forTimeInterval: 0.5)
        captureDiagnostics(context: "rightClickSidebarCard(\(cardTitle), \(menuTitle))")
    }

    /// Captures a screenshot, a full AX-tree text dump (`app.debugDescription`), and the app's
    /// diagnostic log delta since the last `Self.recordDiagnosticLogStartOffsets()` checkpoint,
    /// all as XCTest attachments (visible in the .xcresult regardless of pass/fail -- `vmtest
    /// run` exports failure attachments from its own `-resultBundlePath`, but a `.keepAlways`
    /// attachment is retrievable either way). General-purpose evidence capture -- not tied to any
    /// one investigation (the "Pattern 1" DB-recheck variant this used to also do is gone; see
    /// `rightClickSidebarCard`'s doc comment).
    ///
    /// Opt-in, default OFF (review round, 2026-08-22): this used to run unconditionally on every
    /// call, permanently -- a screenshot plus a full cross-process AX-tree dump on every
    /// structural op, forever, in what is now a permanent regression suite, not throwaway
    /// investigation scaffolding. Set `TEST_RUNNER_FF_UI_TESTING_VERBOSE_DIAGNOSTICS=1` (the
    /// established `vmtest`/xcodebuild env-forwarding convention -- see `E2EShotDir`'s own doc
    /// comment for why the `TEST_RUNNER_` prefix is needed on the CALLER's side but not when
    /// reading it here) to opt back in for an active investigation.
    func captureDiagnostics(context: String) {
        guard ProcessInfo.processInfo.environment["FF_UI_TESTING_VERBOSE_DIAGNOSTICS"] == "1" else { return }
        let screenshotAttachment = XCTAttachment(screenshot: app.screenshot())
        screenshotAttachment.name = "\(context) -- screenshot"
        screenshotAttachment.lifetime = .keepAlways
        add(screenshotAttachment)

        let treeAttachment = XCTAttachment(string: app.debugDescription)
        treeAttachment.name = "\(context) -- AX tree"
        treeAttachment.lifetime = .keepAlways
        add(treeAttachment)

        let logDelta = Self.currentDiagnosticLogContents()
        let logAttachment = XCTAttachment(
            string: logDelta.isEmpty ? "(no diagnostic log output since the last checkpoint)" : logDelta
        )
        logAttachment.name = "\(context) -- diagnostic log delta"
        logAttachment.lifetime = .keepAlways
        add(logAttachment)
    }

    /// Drags `sourceTitle`'s sidebar card to just AFTER `targetTitle`'s card.
    ///
    /// TWO CONFIRMED FIXES landed here across live vmtest rounds (2026-08-22); this is the
    /// settled state, not a hypothesis:
    ///
    /// 1. Drag registration: `DraggableNSView` (`DraggableCardView.swift`) is real AppKit, not a
    ///    SwiftUI `.onDrag`/`.draggable` gesture -- `mouseDragged` only calls
    ///    `beginDraggingSession` once cumulative movement from `mouseDown` exceeds a 5pt
    ///    threshold. A plain `press(forDuration:thenDragTo:)` collapsed to (effectively) one
    ///    jump and never registered as a drag at all (confirmed: the first live run's reorder
    ///    assertion found the section order completely unchanged). `withVelocity: .slow,
    ///    thenHoldForDuration:` is the fix -- the only public XCUICoordinate lever for a
    ///    slower, explicitly multi-sample synthetic path, which does clear the threshold and
    ///    gives `performDrop` a settled read instead of racing a same-instant release.
    ///
    /// 2. Drop-zone targeting: `sidebarCard(titled:)` returns the title `StaticText`, not the
    ///    card row `SectionDropDelegate`'s `.onDrop` is attached to (`OutlineSidebar.swift`'s
    ///    `sectionCard(...)` -- the modifier chain including `.onDrop` sits on the whole
    ///    `DraggableCardView`). `dropUpdated` computes `relativeY = info.location.y / cardHeight`
    ///    in that CARD's coordinate space (`OutlineSidebar+DropDelegates.swift:40`), then
    ///    `relativeY < 0.30 -> insertBefore` else `insertAfter`. `SectionCardView.swift`'s layout
    ///    is `VStack { HStack(HashBar/StatusBadge); Text(title, .sectionTitle(level:)); metadataRow }`
    ///    with 8pt vertical padding and 4pt spacing -- for an H2 title (`SectionTypography.swift`:
    ///    24pt font, well above the ~20pt header row it sits below), the title's own top edge
    ///    already sits at roughly 32pt down a nominal 70pt-tall card -- past the 21pt
    ///    (0.30 * 70) `insertBefore` cutoff before even considering where WITHIN the text label
    ///    a normalized offset lands. Any coordinate inside the title text -- any `dy` -- therefore
    ///    always resolves to `insertAfter`, never `insertBefore`: the zone this helper's dx/dy
    ///    values were originally chosen to hit (aiming for `insertBefore`, `dy: 0.15`) is
    ///    unreachable from this element, no matter how that fraction is tuned. `performDrop`
    ///    itself is not a separate source of staleness -- it reads the `dropPosition` binding
    ///    `dropUpdated` last set, rather than re-deriving from its own `info.location`, so
    ///    whatever zone `dropUpdated` last computed is exactly what gets acted on.
    ///
    /// Fixed by choosing a scenario that only needs `insertAfter` -- the zone a title-text
    /// coordinate can actually reach -- instead of chasing sub-pixel placement against an
    /// estimate of a layout this test has no way to measure precisely. `dx: 0.05` (near the
    /// card's left edge) still keeps `calculateZoneLevel(x:...)`'s nesting-level math at the
    /// shallowest available level (always H1 here, regardless of predecessor level -- verified
    /// by hand for both directions), so this can never silently re-nest the dragged section as a
    /// child of the target.
    func dragSidebarCard(titled sourceTitle: String, toward targetTitle: String) {
        Self.recordDiagnosticLogStartOffsets()
        let source = sidebarCard(titled: sourceTitle)
        let target = sidebarCard(titled: targetTitle)
        let sourceCoordinate = source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let targetCoordinate = target.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.15))
        sourceCoordinate.press(
            forDuration: 0.5,
            thenDragTo: targetCoordinate,
            withVelocity: .slow,
            thenHoldForDuration: 0.3
        )
        Thread.sleep(forTimeInterval: 1.5)
        captureDiagnostics(context: "dragSidebarCard(\(sourceTitle) -> \(targetTitle))")
    }

    // MARK: - Save Version / Version History dialog helpers

    /// Waits for and returns whichever XCUIElementType AppKit actually used for the
    /// currently-presented alert/confirmation surface.
    ///
    /// CONFIRMED (vmtest AX-tree dump, run-1787342653-25801, attachment
    /// 41814F1C-BDFC-4C17-A437-2979DE8B2ED1.txt -- the actual failure-time hierarchy for
    /// testCanonicalRestoreReorderUndoUndoRedoRedo's saveVersion call, not a guess): this app's
    /// SwiftUI `.alert()` renders as `XCUIElementTypeSheet`, NOT `XCUIElementTypeDialog` --
    /// `Sheet, ..., identifier: '_NS:87', label: 'alert'` was right there in the tree, containing
    /// the "Save Version" text, the `TextField` (placeholderValue: 'Version name'), and both
    /// buttons (`identifier: 'action-button-2', label: 'Cancel'` /
    /// `identifier: 'action-button-1', label: 'Save'`). `app.dialogs.firstMatch` can never match
    /// a `Sheet` -- that was the confirmed root cause of the failure (a real 10s timeout on a
    /// query that could never succeed, not an app bug). This is DIFFERENT from
    /// `clickDialogButton`'s own established `app.dialogs` scoping (UITestHelpers.swift) -- that
    /// helper is specifically for alerts raised via `NSAlert.runModal()` (a different, genuinely
    /// Dialog-typed presentation mechanism used elsewhere in this app, e.g. the Zotero-not-running
    /// alerts) -- SwiftUI's own `.alert()`/`.confirmationDialog()` modifiers are a different
    /// mechanism under the hood and were wrongly assumed to share that same AX shape.
    ///
    /// Checks `.sheets` first (the confirmed real shape for the one alert directly observed) then
    /// falls back to `.dialogs`, so a DIFFERENT alert/confirmationDialog elsewhere in this file
    /// that turns out to use the other type is still found rather than assuming every surface in
    /// this app uses the newly-confirmed shape.
    func waitForAlertSurface(timeout: TimeInterval = 10) -> XCUIElement {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            let sheet = app.sheets.firstMatch
            if sheet.exists { return sheet }
            let dialog = app.dialogs.firstMatch
            if dialog.exists { return dialog }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline
        return app.sheets.firstMatch
    }

    /// Cmd-Shift-S -> "Save Version..." -> types `name` into the alert's text field -> Save.
    func saveVersion(named name: String) {
        app.activateAndWaitForForeground()
        app.typeKey("s", modifierFlags: [.command, .shift])
        let alert = waitForAlertSurface()
        XCTAssertTrue(alert.exists, "Save Version alert should appear")
        let nameField = alert.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Save Version alert should have a name field")
        nameField.click()
        nameField.typeText(name)
        let saveButton = alert.buttons["Save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "\"Save\" button should appear in the Save Version alert")
        saveButton.click()
        Thread.sleep(forTimeInterval: 1.0)
    }

    /// Cmd-Opt-V -> Version History -> select the NAMED snapshot by its exact row text -> click
    /// "Restore All" -> confirm "Restore Entire Project" (identifier
    /// "version-history-full-restore-confirm", set explicitly on that button --
    /// VersionHistoryWindow+Restore.swift). The window auto-closes on a `.performed` outcome
    /// (`performFullRestore()`), which is used as the completion signal.
    ///
    /// Window scoped by IDENTIFIER "version-history", NOT the title "Version History" --
    /// docs/architecture/unified-undo.md's Tier-1 account documents this exact confusion as a
    /// previously-diagnosed query bug ("a window's identifier, not its title, the real
    /// identifier being \"version-history\" from the `Window(id:)` scene declaration").
    func restoreFullProject(snapshotNamed name: String) {
        app.activateAndWaitForForeground()
        app.typeKey("v", modifierFlags: [.command, .option])

        let window = app.windows["version-history"]
        XCTAssertTrue(window.waitForExistence(timeout: 10), "Version History window should appear")

        // Matches both label AND value -- same defensive fix as sidebarCard(titled:) above,
        // applied here too even though this specific site's AX shape hasn't been independently
        // confirmed by a vmtest dump the way the sidebar card was: SnapshotRowView's name Text
        // is the same shape of plain-Text-in-a-List element, and `==` is safe against either
        // property regardless of which one turns out to actually carry the text.
        let snapshotRow = window.staticTexts.matching(
            NSPredicate(format: "label == %@ OR value == %@", name, name)
        ).firstMatch
        XCTAssertTrue(snapshotRow.waitForExistence(timeout: 10), "Named snapshot \"\(name)\" should appear in the version list")
        snapshotRow.click()

        let restoreAllButton = window.buttons["Restore All"]
        XCTAssertTrue(restoreAllButton.waitForExistence(timeout: 10), "\"Restore All\" button should appear once a snapshot is selected")
        restoreAllButton.click()

        // Scoped to the actual alert surface via waitForAlertSurface() (checks .sheets before
        // .dialogs -- confirmed real shape for this app's SwiftUI .alert(), see that helper's own
        // doc comment), not a bare app.buttons[...] -- an explicit identifier doesn't exempt this
        // button from either the Touch-Bar-mirror ambiguity or the Sheet-vs-Dialog type mismatch.
        let confirmationSurface = waitForAlertSurface()
        XCTAssertTrue(confirmationSurface.exists, "\"Restore Entire Project\" confirmation alert should appear")
        let confirmButton = confirmationSurface.buttons["version-history-full-restore-confirm"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 10), "\"Restore Entire Project\" confirmation button should appear")
        confirmButton.click()

        XCTAssertTrue(
            window.waitForDisappearance(timeout: 15),
            "Version History window should auto-close after a successful full restore (performFullRestore()'s .performed branch)"
        )
        Thread.sleep(forTimeInterval: 1.0)
    }

    // MARK: - DB ground-truth queries (see file header for why -- reorder is order-sensitive,
    // not word/section-count-sensitive). Safe to run while the app is open (WAL mode) -- see
    // `FixtureDatabase`'s own doc comment (UITestHelpers.swift).

    static let rowSentinel = "###ROWEND###"

    /// Ordered titles of every real (non-pseudo, non-bibliography, non-notes) section, by
    /// sortOrder.
    func queryOrderedSectionTitles() -> [String] {
        let sql = "SELECT title || '\(Self.rowSentinel)' FROM section " +
            "WHERE isPseudoSection = 0 AND isBibliography = 0 AND isNotes = 0 ORDER BY sortOrder;"
        let stdout = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
        return stdout.components(separatedBy: "\(Self.rowSentinel)\n").filter { !$0.isEmpty }
    }

    func querySectionCount() -> Int {
        let sql = "SELECT count(*) FROM section WHERE isPseudoSection = 0 AND isBibliography = 0 AND isNotes = 0;"
        let stdout = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
        return Int(stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    /// Total row count in the `block` table -- ground truth for the H1 laundering probe's
    /// stronger claim: a laundered duplicate BLOCK inside an otherwise-unchanged section would
    /// move neither section count nor section titles/order, so those two checks alone can't see
    /// it.
    func queryBlockCount() -> Int {
        let sql = "SELECT count(*) FROM block;"
        let stdout = FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
        return Int(stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }

    /// The whole document's `content.markdown` PLUS every section's own `markdownContent`,
    /// concatenated -- belt-and-suspenders ground truth for "did this citekey land ANYWHERE,"
    /// independent of which of those two representations happens to be freshest at read time.
    func queryAllMarkdownConcatenated() -> String {
        let sql = "SELECT COALESCE((SELECT markdown FROM content), '') || char(10) || " +
            "COALESCE((SELECT group_concat(markdownContent, char(10)) FROM section), '');"
        return FixtureDatabase.read(fixturePath: TestFixtureHelper.fixturePath, sql: sql)
    }

    /// Polls `probe` until `predicate` is true or `timeout` elapses, returning the last probed
    /// value either way (never fails the test itself -- callers assert on the return value, so a
    /// timeout produces a clear, specific assertion failure rather than an opaque helper
    /// failure). Structural ops commit their DB write mid-sequence, not necessarily before the
    /// click/keystroke that triggered them returns -- a fixed sleep here would either flake (too
    /// short) or waste suite runtime every single run (generous enough to never flake).
    @discardableResult
    func waitUntil<T>(
        timeout: TimeInterval = 10, pollInterval: TimeInterval = 0.25,
        probe: () -> T, predicate: (T) -> Bool
    ) -> T {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var last = probe()
        while Date() < deadline {
            last = probe()
            if predicate(last) { return last }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: pollInterval))
        }
        return last
    }

    // MARK: - Editor text helpers

    /// Whether `marker` currently appears anywhere in editor-area (label or value -- editor text
    /// lives in `value`, not `label`, per e2e-verify skill). Mirrors
    /// `EditorModeSwitchUndoE2ETests.markerPresent`'s proven-safe two-part approach (predicate
    /// label match, `.exists`-guarded manual value scan with a bounded retry) rather than a
    /// single CONTAINS predicate against `value` -- WebKit's AX tree exposes some elements (a
    /// scroll indicator, a checkbox marker) with a non-String `value`, which throws under
    /// CONTAINS.
    func markerPresent(_ marker: String) -> Bool {
        let editorArea = app.editorArea

        let labelMatch = editorArea.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", marker))
            .firstMatch
        if labelMatch.exists { return true }

        let maxAttempts = 5
        for attempt in 1...maxAttempts {
            for element in editorArea.descendants(matching: .any).allElementsBoundByIndex {
                guard element.exists else { continue }
                if let stringValue = element.value as? String, stringValue.contains(marker) {
                    return true
                }
            }
            if attempt < maxAttempts {
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
        return false
    }

    /// Short random suffix so each marker is unique -- avoids a genuinely failed undo in an
    /// earlier assertion (leaving stale marker text behind) from being mistaken for evidence in
    /// a later one.
    func shortUUID() -> String {
        String(UUID().uuidString.prefix(8))
    }

    // MARK: - Diagnostic log reading (backs `captureDiagnostics` -- Pattern 1 investigation,
    // 2026-08-22 vmtest round). Offset-based reader, same proven pattern as
    // E2ESectionReconcilerPseudoSectionTests.swift/EditorModeSwitchUndoE2ETests.swift -- reads
    // only bytes appended since the last checkpoint, never truncates/deletes the real, shared log.

    static var diagnosticLogStartOffsets: [URL: UInt64] = [:]

    static func diagnosticLogCandidateURLs() -> [URL] {
        let relativePath = "Library/Application Support/com.kerim.final-final/Diagnostics"
        var directories: [URL] = []
        directories.append(
            URL(fileURLWithPath: "/Users/\(NSUserName())").appendingPathComponent(relativePath, isDirectory: true)
        )
        directories.append(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.kerim.final-final/Diagnostics", isDirectory: true)
        )
        directories.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(relativePath, isDirectory: true)
        )
        let fileNames = ["diagnostic.log", "diagnostic.log.1", "diagnostic.log.2"]
        return directories.flatMap { dir in fileNames.map { dir.appendingPathComponent($0) } }
    }

    static func recordDiagnosticLogStartOffsets() {
        diagnosticLogStartOffsets = [:]
        for url in diagnosticLogCandidateURLs() {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)
                .flatMap { $0 }?.uint64Value ?? 0
            diagnosticLogStartOffsets[url] = size
        }
    }

    static func currentDiagnosticLogContents() -> String {
        diagnosticLogCandidateURLs().compactMap { url -> String? in
            guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
            defer { try? handle.close() }
            try? handle.seek(toOffset: diagnosticLogStartOffsets[url] ?? 0)
            let data = handle.readDataToEndOfFile()
            guard !data.isEmpty else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n---\n")
    }
}
