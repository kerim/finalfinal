//
//  OutlineSidebarScrollE2ETests.swift
//  final finalUITests
//
//  Permanent regression test: scrolling the Outline sidebar's ScrollView moves its cards, even
//  though each card, queried individually, reports `isHittable=false` at the moment of the
//  scroll. Originally written as a repro for bt t-a48f8d30 ("Outline sidebar's card hosting hides
//  it from XCUITest's scroll driver"); two identical VM runs on unchanged app code showed
//  scrolling already works, so this file now guards that behavior going forward instead of
//  diagnosing it.
//
//  Observed baseline (two passing VM runs, 2026-09-24): scrollView.isHittable=true
//  card.isHittable=false minYBefore=147.0 minYAfter=-453.0 delta=-600.0 -- i.e. the ScrollView
//  element itself is hittable and the scroll moves the card by the full requested 600pt, even
//  though the card element's own `isHittable` reads false throughout. `.claude/skills/e2e-verify/
//  SKILL.md`'s "Proven patterns" section documents this same finding, and marks its own earlier
//  claim that this gesture was "inert" against this app's sidebar as superseded.
//
//  Possibly related to (not verified -- a hedge, not a settled cause) a LazyVStack->VStack
//  refactor in `OutlineSidebar.swift` on 2026-09-06. Nobody has confirmed that specific link.
//
//  Platform-API note: `XCUIElement.scroll(byDeltaX:deltaY:)` is declared in this SDK's
//  `XCUIAutomation.framework/XCUIElement.h` as `API_AVAILABLE(ios(15.0), macCatalyst(13.0))`, with
//  no explicit `macos(...)` clause. Researched before use (no macOS-specific alternative API
//  exists on `XCUIElement` for a native, non-Catalyst macOS scroll gesture): that attribute only
//  states each platform's OWN minimum-version floor and, per Apple's established convention for
//  APIs that predate a given platform's annotation, does not restrict a platform it does not name
//  -- confirmed against real-world macOS XCUITest usage of this exact method
//  (pfandrade.me/blog/ui-testing-and-nsscrollview, "UI Testing and NSScrollView", tagged macOS),
//  which calls `scrollByDeltaX:deltaY:` against an `XCUIElementTypeScrollView` in a Mac app's own
//  UI tests. Used here as specified by the approved plan.
//

import XCTest

final class OutlineSidebarScrollE2ETests: XCTestCase {
    var app: XCUIApplication!

    /// ~40 `##` sections -- enough that the Outline sidebar's own (non-lazy, see
    /// `OutlineSidebar.swift`'s `sectionsList`) VStack of cards overflows any reasonable window
    /// height and needs scrolling to reach cards past the first handful.
    static let fortySectionMarkdown: String = {
        (1...40).map { index in
            """
            ## Section \(index)

            Body text for section \(index), long enough to give this fixture a realistic amount \
            of content per section so the Outline sidebar's scroll content genuinely overflows \
            its visible viewport once all 40 sections are present.
            """
        }.joined(separator: "\n\n")
    }()

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication.targetApp()
        app.terminate()
        try TestFixtureHelper.setupFixture(from: self)
    }

    override func tearDownWithError() throws {
        app.terminate()
        TestFixtureHelper.cleanupFixture()
    }

    func testScrollingOutlineSidebarMovesFirstCardsFrame() throws {
        FixtureDatabase.seedMarkdown(fixturePath: TestFixtureHelper.fixturePath, markdown: Self.fortySectionMarkdown)
        app.launchForTesting(fixturePath: TestFixtureHelper.fixturePath)

        let editorArea = app.editorArea
        XCTAssertTrue(editorArea.waitForExistence(timeout: 10), "Editor area should appear")
        let wordCount = app.staticTexts["status-bar-word-count"]
        XCTAssertTrue(
            wordCount.waitForValue("CONTAINS 'words'", timeout: 10),
            "Status bar should show word count (editor JS ready) before querying the sidebar"
        )

        let sidebarScrollView = app.groups["outline-sidebar"].scrollViews.firstMatch
        XCTAssertTrue(
            sidebarScrollView.waitForExistence(timeout: 10),
            "Outline sidebar's ScrollView should appear once the fixture's 40 sections have loaded"
        )

        // Scoped to the sidebar ScrollView, matching this suite's established
        // `sidebarCard(titled:)` pattern (UnifiedUndoE2ETests+Helpers.swift,
        // SidebarRerenderCountE2ETests.swift): matches BOTH label and value, since a sidebar
        // card's title StaticText exposes its text via `value`, not `label` (confirmed there
        // against a real AX-tree dump).
        let firstCard = sidebarScrollView.descendants(matching: .staticText)
            .matching(NSPredicate(format: "label == %@ OR value == %@", "Section 1", "Section 1"))
            .firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 10), "Sidebar card titled \"Section 1\" should appear")

        // Evidence captured AT THE MOMENT OF SCROLLING -- i.e. immediately before the
        // scroll(byDeltaX:deltaY:) call fires -- so it reflects the actual state XCTest's scroll
        // driver saw, not a state that may have changed by the time the summary is assembled.
        let scrollViewHittableAtScrollTime = sidebarScrollView.isHittable
        let scrollViewFrameAtScrollTime = sidebarScrollView.frame
        let cardHittableAtScrollTime = firstCard.isHittable
        let cardFrameAtScrollTime = firstCard.frame
        let minYBefore = cardFrameAtScrollTime.minY

        sidebarScrollView.scroll(byDeltaX: 0, deltaY: -600)

        // There is nothing AX-observable to key a wait on for "the scroll gesture's effect on a
        // card's frame has settled" (frame is a plain CGRect snapshot, not KVO/NSPredicate-
        // observable the way `.value`/`.label` are via waitForValue/waitForLabel); matches this
        // suite's own established convention of a short fixed settle after a synthesized gesture
        // with no other signal to wait on (e.g. SidebarRerenderCountE2ETests.swift's post-typing
        // settle sleep).
        // e2e-lint: allow sleep
        Thread.sleep(forTimeInterval: 1.5)

        let minYAfter = firstCard.frame.minY
        let delta = minYAfter - minYBefore

        // UNCONDITIONAL evidence -- printed and attached regardless of pass/fail, so a future
        // regression's failure carries the full frame/hittability picture (see this file's
        // header for the observed-passing baseline), not just the numeric assertion below.
        let evidence = """
        [E2E-OUTLINE-SCROLL] scrollView.isHittable=\(scrollViewHittableAtScrollTime) \
        scrollView.frame=\(scrollViewFrameAtScrollTime) card.isHittable=\(cardHittableAtScrollTime) \
        card.frame=\(cardFrameAtScrollTime) minYBefore=\(minYBefore) minYAfter=\(minYAfter) delta=\(delta)
        """
        print(evidence)
        let attachment = XCTAttachment(string: evidence)
        attachment.lifetime = .keepAlways
        attachment.name = "outline-sidebar-scroll-evidence"
        add(attachment)

        // Prove movement unambiguously BY POSITION, not just "scroll(byDeltaX:deltaY:) threw no
        // error" -- a >50pt change rules out incidental sub-pixel/layout jitter while still being
        // far smaller than the 600pt requested delta, so a partially-working scroll still passes.
        XCTAssertGreaterThan(
            abs(delta), 50,
            "Regression: scrolling the Outline sidebar's ScrollView by 600pt should move the " +
            "first card's frame.minY by more than 50pt -- this has held since 2026-09-24 (see " +
            "this file's header comment for the observed-passing baseline), but moved by " +
            "\(delta)pt (minYBefore=\(minYBefore), minYAfter=\(minYAfter)). Check whether a " +
            "recent change to OutlineSidebar.swift or DraggableCardView.swift's " +
            "PassthroughHostingView.hitTest broke sidebar scrolling. \(evidence)"
        )
    }
}
