//
//  E2EScratchTests.swift
//  final finalUITests
//
//  DISPOSABLE e2e-verification test for the annotation-collapse-on-blur fix
//  (bt task annotation-collapse-on-blur).
//
//  THE BUG: when a Comment's display-mode preference is Collapsed, a
//  brand-new annotation rendered collapsed at creation time (already
//  covered by web/milkdown/src/__tests__/annotation-collapse-on-create.test.ts),
//  but expanded to show its full text the moment the user finished typing
//  into its edit popup and clicked elsewhere -- i.e. the FIRST edit-commit
//  after creation silently un-collapsed it, even though the preference never
//  changed.
//
//  ROOT CAUSE (annotation-plugin.ts's NodeView.update(), fixed in this
//  branch): every update -- including the setNodeMarkup() that
//  commitAnnotationEdit() dispatches on blur -- rebuilt `dom.className`
//  wholesale from the node's attrs alone. That wiped the
//  `ff-annotation-collapsed` class ProseMirror's decoration plugin had
//  applied, and because the decoration ITSELF didn't change (same type, same
//  display mode), ProseMirror's own `sameOuterDeco()` short-circuit meant it
//  never got reapplied. The fix scopes the update to `classList.add`/`remove`
//  for only the classes the NodeView owns, leaving decoration-owned classes
//  alone.
//
//  THIS TEST proves that fix through the real running app (real WKWebView +
//  ProseMirror + real XCUITest keyboard/mouse input), not the vitest mock in
//  the file above. Its one load-bearing assertion is the frame-width check
//  right after the blur-commit below: the annotation's accessible name
//  (aria-label) carries the committed text either way -- that computation is
//  untouched by the bug -- so what actually discriminates broken vs fixed is
//  how WIDE the annotation renders on screen (a bare marker vs. the whole
//  sentence inline). See that assertion's own comment for why a plain
//  text-presence check would be vacuous here.
//
//  Delete this file's contents once its evidence has been captured -- see
//  the project skill `.claude/skills/e2e-verify` for the reset procedure
//  (`git restore -- "final finalUITests/E2EScratchTests.swift"`).
//

import XCTest

final class E2EScratchTests: XCTestCase {
    var app: XCUIApplication!

    /// Long and distinctive enough that (a) it can't collide with anything
    /// else in the seeded fixture and (b) rendered inline it is guaranteed to
    /// be far wider than a single collapsed marker glyph, however it wraps.
    private static let annotationText =
        "This entire sentence must stay off screen while Comment annotations are Collapsed."

    /// A collapsed annotation is just one marker glyph plus ~4px of CSS
    /// padding (`.ff-annotation { font-size: 0.9em; padding: 0 2px; }`,
    /// `.ff-annotation-marker { margin-right: 2px; }` -- styles.css). Either
    /// dimension of `Self.annotationText` rendered inline blows well past
    /// this on a single normal-width editor column, wrapped or not.
    private static let collapsedWidthCeiling: CGFloat = 50
    private static let collapsedHeightCeiling: CGFloat = 26

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication.targetApp()
        app.terminate()
        try TestFixtureHelper.setupFixture(from: self)
        // Known, minimal content with a predictable insertion point at doc
        // end -- never assume the committed fixture's own content (see the
        // e2e-verify skill's "Never assume a committed fixture's initial
        // state" proven pattern).
        FixtureDatabase.seedMarkdown(
            fixturePath: TestFixtureHelper.fixturePath,
            markdown: "# Test Document\n\nBody paragraph for annotation testing.\n"
        )
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }

    func testNewCommentAnnotationStaysCollapsedAfterItsFirstEditCommitsOnBlur() throws {
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)

        let editorArea = app.editorArea
        XCTAssertTrue(editorArea.waitForExistence(timeout: 10), "Editor area should appear")
        let wordCount = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(
            wordCount.waitForValue("CONTAINS 'words'", timeout: 10),
            "Status bar should report a word count once editor JS is ready"
        )
        Thread.sleep(forTimeInterval: 1.5) // let the editor finish settling; no AX signal for "fully idle"

        let shotDir = E2EShotDir.url

        // --- User-verification step 1: set Comment's display-mode preference to
        // Collapsed via the Annotations panel. ---
        setCommentDisplayMode(to: "Collapsed")

        // --- User-verification step 2: create a brand-new comment annotation. It
        // should already render collapsed at creation -- that specific moment is
        // already covered by annotation-collapse-on-create.test.ts's real-editor
        // unit coverage, so this test only confirms creation itself succeeded
        // (the edit popup auto-opens right after /comment inserts the node) before
        // moving on to the actual regression this test exists for. ---
        guard let bodyParagraph = app.editorStaticText(startingWith: "Body paragraph") else {
            XCTFail("Seeded body paragraph not found in editor")
            return
        }
        bodyParagraph.click()
        app.activateAndWaitForForeground()
        app.typeKey(.downArrow, modifierFlags: .command) // jump to the true end of the document
        app.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3) // let the fresh empty paragraph settle before typing into it
        // Not app.typeTextVerifyingLanded(_:): "/comment" is consumed by the slash-command
        // handler on the very next Return (deleted and replaced by the annotation node), so it
        // is never a persisted static text in editor-area to verify against.
        app.typeText("/comment")
        Thread.sleep(forTimeInterval: 0.3) // let the slash menu's filtered-command list render
        app.typeKey(.return, modifierFlags: []) // executes the (only) matching slash command

        // Scoped to the popup's own <textarea> via its placeholder (annotation-edit-popup.ts:
        // `textarea.placeholder = 'Annotation text...'`) -- NOT a bare app-wide
        // textViews/textFields existence check, which a WKWebView contenteditable body or the
        // find bar could ALSO satisfy with zero popup actually on screen, silently misdirecting
        // the typeText call below into the wrong place and corrupting everything downstream.
        let popupTextArea = app.textViews
            .matching(NSPredicate(format: "placeholderValue == %@", "Annotation text..."))
            .firstMatch
        let popupTextField = app.textFields
            .matching(NSPredicate(format: "placeholderValue == %@", "Annotation text..."))
            .firstMatch
        let popupAppeared = popupTextArea.waitForExistence(timeout: 3)
            || popupTextField.waitForExistence(timeout: 3)
        XCTAssertTrue(
            popupAppeared,
            "Comment annotation's edit popup (its <textarea placeholder=\"Annotation text...\">) " +
            "should auto-open right after the /comment slash command inserts the node"
        )

        try? app.screenshot().pngRepresentation
            .write(to: shotDir.appendingPathComponent("01-fresh-annotation-popup-open.png"))

        // --- Creation-time collapse is deliberately NOT re-checked here via a frame/label
        // lookup on the document-side element (an earlier version of this test tried exactly
        // that and it can never pass). Two independent reasons:
        //
        // 1. `attrs.text` is `''` immediately after creation, so `.ff-annotation-text` renders
        //    empty in BOTH collapsed and inline modes -- the rendered frame stays marker-sized
        //    either way, so a frame check at this exact moment can't discriminate broken vs.
        //    fixed at all.
        // 2. Even locating the element is structurally impossible while collapsed:
        //    `applyAnnotationAccessibilityAttrs()` (annotation-plugin.ts) sets `role="img"` on
        //    the wrapper unconditionally whenever Comment's mode is Collapsed -- independent of
        //    the edit-commit bug this test targets -- and per ARIA/AX semantics an element with
        //    `role="img"` is an atomic leaf: its children (including the marker span holding
        //    "◇") are folded into the wrapper's own accessible name (here the empty string) and
        //    are never separately exposed to a `label CONTAINS` descendant search. That's a
        //    structural fact of collapsed rendering, not a timing race -- it can't resolve in a
        //    correct build either.
        //
        // Real creation-time collapse coverage already exists in
        // web/milkdown/src/__tests__/annotation-collapse-on-create.test.ts's real-editor unit
        // test (see this file's header). This test's one load-bearing assertion is the
        // post-commit frame check further down, where `attrs.text` is finally non-empty and a
        // frame check actually discriminates collapsed vs. expanded.

        // --- User-verification step 3: type into the popup WITHOUT committing.
        // The marker in the document must stay bare: the typed text has not
        // reached the ProseMirror node yet, it only lives in the popup's own
        // <textarea> (appended directly to document.body by
        // annotation-edit-popup.ts, outside editor-area's DOM subtree). ---
        // Not app.typeTextVerifyingLanded(_:): that helper verifies text landed inside
        // editor-area, which is exactly the thing this assertion needs to stay FALSE here --
        // the popup's <textarea> lives outside editor-area by design (see comment above).
        app.typeText(Self.annotationText)
        Thread.sleep(forTimeInterval: 0.3) // let the keystrokes settle into the popup's textarea

        // NOT a document-side lookup (app.editorContainsText, or a smallestAccessibleMatch scan of
        // editor-area): for the same structural reason documented at the creation-time
        // checkpoint above, the annotation wrapper is unreachable by label search while
        // collapsed (role="img" folds its children out of the accessibility tree), and even if
        // it weren't, `attrs.text` is STILL `''` on the document side at this point -- the typed
        // text hasn't reached the node yet -- so neither a label nor a frame check on it could
        // prove anything here. What actually proves "typed but not committed" is the popup's OWN
        // <textarea>: its value still holds what was typed, and the popup is still on screen.
        // commitAnnotationEdit() (annotation-edit-popup.ts) calls hideAnnotationEditPopup(),
        // which sets `display: none` -- dropping the popup out of the accessibility tree -- the
        // instant a commit actually fires, so both checks below would fail the moment an early
        // commit happened. Re-read via the SAME `popupTextArea`/`popupTextField` queries from
        // creation above rather than caching a value from back then: XCUIElement queries
        // re-resolve against the live tree on every access, so this reflects the current state
        // after the typeText call, not a stale snapshot.
        let activePopupInput = popupTextArea.exists ? popupTextArea : popupTextField
        XCTAssertTrue(
            activePopupInput.exists,
            "Annotation edit popup should still be open right after typing, before any " +
            "blur/click-out -- if it's already gone, commitAnnotationEdit() fired earlier than expected"
        )
        XCTAssertEqual(
            activePopupInput.value as? String, Self.annotationText,
            "Popup's own textarea should still hold the freshly typed text -- proves the edit " +
            "hasn't reached the document node yet (commitAnnotationEdit() only dispatches its " +
            "setNodeMarkup() on blur)"
        )

        // --- User-verification step 4 (THE BUG): click elsewhere in the document
        // -- blur/click-out -- which commits the new text via
        // annotation-edit-popup.ts's ~150ms blur timeout. This is the exact
        // moment the bug fired: the committed setNodeMarkup() transaction reached
        // the NodeView's update(), which used to overwrite dom.className wholesale
        // and silently drop the ff-annotation-collapsed class. ---
        guard let heading = app.editorStaticText(startingWith: "Test Document") else {
            XCTFail("Seeded heading not found in editor")
            return
        }
        heading.click()
        app.activateAndWaitForForeground()
        Thread.sleep(forTimeInterval: 1.5) // past the popup's ~150ms blur-commit timeout, generous margin

        try? app.screenshot().pngRepresentation
            .write(to: shotDir.appendingPathComponent("02-after-blur-commit.png"))

        // The annotation wrapper's accessible name (aria-label) is set
        // unconditionally by applyAnnotationAccessibilityAttrs() whenever the
        // type's mode is 'collapsed', independently of dom.classList -- so THAT
        // computation is unaffected by the bug and this element is findable by
        // its committed text in both the broken and fixed builds. A bare
        // text-presence assertion here would therefore be vacuous (see this
        // file's header). What actually discriminates broken vs fixed is how
        // WIDE the element renders: the bug leaves `.ff-annotation-text` visible
        // (`display: inline`, no longer `display: none`), so the whole sentence
        // renders next to the marker and the element's frame balloons; the fix
        // keeps only the bare marker glyph on screen.
        //
        // smallestAccessibleMatch, not `.firstMatch`: `.firstMatch` resolves in AX tree order,
        // and an ancestor (e.g. the paragraph wrapping this annotation) whose own AX description
        // happens to concatenate the same committed text -- the identical hazard editorStaticText's
        // own doc comment records for heading containers -- can resolve BEFORE the actual annotation
        // span, handing back a paragraph-width frame and failing this check even when the fix is
        // working correctly. smallestAccessibleMatch also handles the "does it even exist" check
        // internally (fails loudly with the match count on zero), so there's no separate
        // waitForExistence here.
        guard let committedAnnotation = smallestAccessibleMatch(containing: Self.annotationText) else {
            return
        }
        let committedFrame = committedAnnotation.frame
        XCTAssertTrue(
            committedFrame.width < Self.collapsedWidthCeiling && committedFrame.height < Self.collapsedHeightCeiling,
            "Annotation rendered \(committedFrame.width)pt x \(committedFrame.height)pt right after " +
            "blur committed its first edit -- expected a narrow, marker-only collapsed annotation " +
            "(<\(Self.collapsedWidthCeiling)pt x <\(Self.collapsedHeightCeiling)pt). A larger render " +
            "here means the full text is showing inline, i.e. the collapse decoration was lost on " +
            "edit-commit -- this is the exact regression annotation-plugin.ts's NodeView.update() fix guards."
        )

        // --- User-verification step 5: toggle the preference to Inline. The
        // annotation should now expand and show the text that was actually
        // typed -- confirming the text was SAVED (not silently lost) while it
        // sat collapsed. If the fix silently discarded the edit instead of just
        // mis-rendering it, this assertion (not the one above) is what would
        // catch that. ---
        setCommentDisplayMode(to: "Inline")
        // Let the Swift -> JS bridge call (window.FinalFinal.setAnnotationDisplayModes, fired
        // from EditorViewState.annotationDisplayModes's onChange) round-trip and the decoration
        // re-render before checking the DOM; no AX signal marks that async hop complete.
        Thread.sleep(forTimeInterval: 1.0)

        try? app.screenshot().pngRepresentation
            .write(to: shotDir.appendingPathComponent("03-after-toggle-to-inline.png"))

        // NOT a bare app.editorContainsText(Self.annotationText, ...) text-presence check:
        // switching Comment's display mode DOES trigger a real re-render here -- the mode-change
        // dispatch is an empty ProseMirror transaction whose changed outer decoration (see
        // annotation-display-plugin.ts's decoration diffing, driven from api-annotations.ts's
        // setAnnotationDisplayModes) causes prosemirror-view to call the NodeView's update(),
        // same as any other decoration change -- so a plain presence check would pass without
        // actually exercising anything interesting. What it proves is more specific:
        // applyAnnotationAccessibilityAttrs() (annotation-plugin.ts) recomputes accessibility
        // attrs on every such update, and for Inline mode its else-branch REMOVES role/aria-label
        // entirely and sets `dom.title` instead -- which WebKit maps to AXHelp, not the
        // accessible `label` XCUITest reads. So once toggled to Inline, the committed text is
        // genuinely on screen but reachable only via the annotation's visible text-run `value`,
        // not `label` -- exactly why this lookup must check `value` too (see
        // smallestAccessibleMatch's doc comment). Re-resolve the SAME annotation (now findable by
        // value instead of the old, now-removed label) and check its FRAME: only if the collapse
        // decoration was actually removed does the full text become visible and the frame grow
        // past the collapsed ceilings -- that's what actually proves the toggle propagated, not
        // just that the text is attached to the element somewhere.
        guard let toggledAnnotation = smallestAccessibleMatch(containing: Self.annotationText) else {
            return
        }
        let toggledFrame = toggledAnnotation.frame
        XCTAssertTrue(
            toggledFrame.width >= Self.collapsedWidthCeiling || toggledFrame.height >= Self.collapsedHeightCeiling,
            "Annotation rendered \(toggledFrame.width)pt x \(toggledFrame.height)pt after switching " +
            "Comment's display mode to Inline -- expected it to grow past the collapsed ceilings " +
            "(width >=\(Self.collapsedWidthCeiling)pt or height >=\(Self.collapsedHeightCeiling)pt) " +
            "now that the full text should render inline next to the marker, proving the edit " +
            "survived being collapsed rather than being lost or staying stuck hidden"
        )
    }

    // MARK: - Annotation element lookup

    /// Finds every descendant of editor-area whose accessible `label` OR `value` contains
    /// `text`, and returns the one with the SMALLEST frame area (width x height) -- never
    /// `.firstMatch`, which resolves in AX tree order and can hand back an ANCESTOR whose own AX
    /// description happens to concatenate the same text (the identical hazard `editorStaticText`'s
    /// own doc comment records for heading containers: a container's label concatenates all its
    /// children's text). Since any such ancestor necessarily contains the target text PLUS more,
    /// the actual annotation span is always the smallest match among the candidates.
    ///
    /// Checks BOTH `label` and `value`, mirroring `editorContainsText`'s existing two-part
    /// approach (UITestHelpers.swift): this app's WKWebView content exposes text through `value`,
    /// not `label`, in the general case, and `applyAnnotationAccessibilityAttrs()`
    /// (annotation-plugin.ts) confirms the annotation-specific instance of that split -- it sets
    /// `role="img"` + `aria-label` (a real `label`) while Collapsed, but REMOVES both and sets
    /// `dom.title` (which WebKit maps to AXHelp, not `label`) once Inline, leaving the committed
    /// text reachable only via the element's `value`. The `value` check is a Swift-side
    /// `as? String` cast + `.contains`, never an `NSPredicate CONTAINS` against `value` directly
    /// -- this tree exposes some elements with a non-`String` value (a heading container's level,
    /// a checkbox marker) that throw under a direct predicate, exactly as `editorContainsText`'s
    /// own doc comment warns.
    ///
    /// Polls up to `timeout` (mirrors `editorContainsText`'s poll loop), since a label/value may
    /// not have propagated to the DOM/AX tree the instant a JS-side mutation is dispatched. Fails
    /// loudly via XCTFail (never returns a silent nil that a caller could mistake for "correctly
    /// found nothing") when no descendant matches within `timeout`, dumping every editor-area
    /// descendant's type/label/value/frame so a future failure shows what the tree actually held.
    @discardableResult
    private func smallestAccessibleMatch(
        containing text: String, timeout: TimeInterval = 5,
        file: StaticString = #filePath, line: UInt = #line
    ) -> XCUIElement? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        var matches: [XCUIElement] = []
        repeat {
            let labelMatches = app.editorArea.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", text))
                .allElementsBoundByIndex
                .filter { $0.exists }
            let valueMatches = app.editorArea.descendants(matching: .any)
                .allElementsBoundByIndex
                .filter { $0.exists && (($0.value as? String)?.contains(text) ?? false) }
            matches = labelMatches + valueMatches
            if !matches.isEmpty { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        } while Date() < deadline

        guard !matches.isEmpty else {
            let elements = app.editorArea.descendants(matching: .any).allElementsBoundByIndex
            var dump: [String] = []
            for (idx, element) in elements.enumerated() {
                guard element.exists else {
                    dump.append("  [\(idx)]: <stale, skipped>")
                    continue
                }
                let value = (element.value as? String) ?? "<non-string value>"
                dump.append(
                    "  [\(idx)]: type=\(element.elementType.rawValue) label=\"\(element.label)\" " +
                    "value=\"\(value)\" frame=\(element.frame)"
                )
            }
            XCTFail(
                "No descendant of editor-area has a label or value containing \"\(text)\" (0 " +
                "matches after \(timeout)s) -- expected the annotation element to be findable " +
                "this way. editor-area currently holds \(elements.count) descendant(s):\n" +
                dump.joined(separator: "\n"),
                file: file, line: line
            )
            return nil
        }

        return matches.min { lhs, rhs in
            let lhsFrame = lhs.frame
            let rhsFrame = rhs.frame
            return (lhsFrame.width * lhsFrame.height) < (rhsFrame.width * rhsFrame.height)
        }
    }

    // MARK: - Annotations panel helper

    /// Sets the Comment annotation type's display mode via the real Annotations panel UI: click
    /// the filter bar's "Adjust display modes" (eye) button to open its popover, then pick
    /// `modeTitle` ("Inline" or "Collapsed") from the Comment row's menu-style Picker.
    ///
    /// No accessibilityIdentifier exists on any AnnotationFilterBar control (verified by reading
    /// the file), and this codebase has no prior e2e precedent driving a SwiftUI popover + menu
    /// Picker -- so this locates elements two ways that ARE grounded in the source, not guessed:
    ///   - The eye button (`Image(systemName: "eye")` / `"eye.slash"`, no explicit accessibility
    ///     label in AnnotationFilterBar.swift) is looked up by SF Symbol name, which macOS
    ///     commonly (not by contractual guarantee) exposes as an unlabeled symbol image's default
    ///     accessibility label.
    ///   - The Comment row's Picker is the SECOND of three `.pickerStyle(.menu)` pickers rendered
    ///     by `ForEach(AnnotationType.allCases)`. `AnnotationType`'s cases are declared
    ///     `task, comment, reference` in that order (Models/Annotation.swift), and Swift's
    ///     `CaseIterable` synthesis preserves declaration order, so index 1 is always Comment.
    ///     `.pickerStyle(.menu)` on macOS backs onto a real `NSPopUpButton`, which XCUITest
    ///     exposes as `app.popUpButtons`; the pop-up's own menu is a standalone `NSMenu` overlay,
    ///     reached the same way this suite already reaches every other native menu -- by `title`,
    ///     via the existing `menuItem(titleStartingWith:)` helper (UITestHelpers.swift), never
    ///     `label` (menu items expose no `label` to XCUITest).
    ///
    /// If this lookup chain is wrong, it fails loudly with a descriptive message instead of
    /// silently mis-clicking -- re-inspect the live accessibility tree around
    /// AnnotationFilterBar.swift if it does.
    ///
    /// This helper is called twice per test run with a DIFFERENT `modeTitle` each time (see the
    /// two call sites above), which matters for two reasons this implementation guards against:
    ///
    ///   - `.pickerStyle(.menu)` on macOS backs onto a genuine AppKit "pop-up" menu (not a
    ///     pull-down): it opens with its CURRENTLY SELECTED item positioned at the click anchor,
    ///     so the on-screen layout of "Inline" vs "Collapsed" shifts depending on which one is
    ///     selected when the menu opens -- i.e. differently on the two calls, since the second
    ///     call always opens with the mode the first call just set. A `waitForExistence`-then-
    ///     `.click()` right as that repositioning/opening animation is still settling can miss.
    ///   - Between the two calls, the test clicks back into the document and re-establishes
    ///     foreground focus for its own purposes (`heading.click()` +
    ///     `activateAndWaitForForeground()`) -- but this helper is invoked again right after that
    ///     without any further activation of its own, so it re-activates foreground itself rather
    ///     than assume the app is still key.
    ///
    /// After making the selection, the Comment row's own PopUpButton `.value` is re-queried and
    /// checked against `modeTitle` (the same check the AX dump used to diagnose the original
    /// failure) rather than trusted blindly; a mismatch retries the whole open-select-verify
    /// sequence once before failing loudly with the actually-observed value, so a still-broken
    /// interaction shows up here -- not as a confusing, much-later frame-size assertion.
    private func setCommentDisplayMode(to modeTitle: String) {
        app.activateAndWaitForForeground()

        var eyeButton = app.buttons["eye"]
        if !eyeButton.waitForExistence(timeout: 3) {
            eyeButton = app.buttons["eye.slash"]
        }
        XCTAssertTrue(
            eyeButton.waitForExistence(timeout: 5),
            "Annotations panel 'Adjust display modes' button not found via SF Symbol name " +
            "\"eye\"/\"eye.slash\" -- AnnotationFilterBar.swift has no accessibilityIdentifier on " +
            "it; re-inspect its live accessibility label if this fails."
        )
        eyeButton.click()

        let popover = app.popovers.firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5), "Display-modes popover did not open")

        let commentPicker = app.popovers.popUpButtons.element(boundBy: 1)
        XCTAssertTrue(
            commentPicker.waitForExistence(timeout: 5),
            "Comment row's display-mode Picker (expected at index 1 of task/comment/reference) " +
            "not found in the popover"
        )

        var observedValue: String?
        for _ in 1...2 {
            commentPicker.click()
            Thread.sleep(forTimeInterval: 0.3) // let the pop-up menu finish opening/positioning
            // (see doc comment: its layout shifts with the currently-selected item)

            // NOT app.menuItem(titleStartingWith:): that helper runs an APP-WIDE `title
            // BEGINSWITH` query, and "Inline" is not a unique prefix app-wide -- the main menu
            // bar's Edit -> Format -> "Inline Code" item also matches and can steal the click,
            // leaving the popover's own picker untouched. Scope the lookup to the picker's own
            // pop-up menu and match the title exactly instead.
            let option = commentPicker.menuItems
                .matching(NSPredicate(format: "title == %@", modeTitle)).firstMatch
            if !option.waitForExistence(timeout: 5) {
                // AppKit can render a pop-up button's menu as a top-level overlay rather than a
                // true descendant of the PopUpButton -- fall back to an app-wide exact match,
                // which (unlike the prefix match above) is safe now: "Inline Code" != "Inline".
                let fallbackOption = app.menuItems
                    .matching(NSPredicate(format: "title == %@", modeTitle)).firstMatch
                XCTAssertTrue(fallbackOption.waitForExistence(timeout: 5),
                              "Comment picker's \"\(modeTitle)\" menu item did not appear")
                fallbackOption.click()
            } else {
                option.click()
            }
            Thread.sleep(forTimeInterval: 0.3) // let the selection propagate to the PopUpButton's value

            // Guard the readback itself: a false pass here (the popover already closed, or
            // index 1 no longer being the Comment row) would make `commentPicker.value` read
            // back stale/wrong data while looking like a successful selection.
            XCTAssertTrue(popover.exists, "Display-modes popover closed before the value readback")
            XCTAssertEqual(app.popovers.popUpButtons.count, 3,
                           "Popover no longer shows task/comment/reference rows; index 1 is not " +
                           "the Comment picker")

            observedValue = commentPicker.value as? String
            if observedValue == modeTitle {
                break
            }
        }
        XCTAssertEqual(
            observedValue, modeTitle,
            "Comment row's display-mode Picker still reads \"\(observedValue ?? "nil")\" after " +
            "clicking \"\(modeTitle)\" and retrying once -- the menu selection isn't registering " +
            "(see setCommentDisplayMode's doc comment for the suspected cause)"
        )

        app.typeKey(.escape, modifierFlags: []) // dismiss the popover
        Thread.sleep(forTimeInterval: 0.5) // let the popover's dismiss animation finish before the next click
    }
}
