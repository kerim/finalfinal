//
//  HoverTooltipSizingBridgeTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//
//  Regression test for the shared hover-tooltip singleton (hover-tooltip.ts), introduced to
//  fix the collapsed-annotation and footnote-reference hover tooltips, which previously always
//  rendered at a fixed, too-narrow width regardless of their content -- a CSS shrink-to-fit
//  sizing bug (see hover-tooltip.ts's and styles.css's own top comments for the full history:
//  two prior "fixes" both passed the jsdom suite and were both still wrong in real WebKit).
//
//  web/milkdown/src/__tests__/hover-tooltip.test.ts already hardens the show/hide/dismiss
//  DELEGATION LOGIC thoroughly at the jsdom level, but that file's own header says jsdom has no
//  real layout engine, so it structurally cannot prove the tooltip actually renders at the
//  right pixel WIDTH, wraps its text, or respects the viewport-edge collision clamp in
//  positionPopup() -- it can only prove positionPopup() was CALLED, not what it computed.
//
//  This test drives the real WKWebView-hosted Milkdown editor end-to-end (via EditorTestHelper,
//  the same helper EditorBridgeTests.swift uses), inserts real annotation/footnote content,
//  dispatches synthetic DOM `mouseover`/`keydown` events directly on the real rendered elements
//  (exercising hover-tooltip.ts's real delegated listener, installed on the real editor root by
//  main.ts, exactly as a live hover/keypress would -- no XCUITest/accessibility/OS-input
//  involved), and reads back the tooltip's ACTUAL `getBoundingClientRect()` from real WebKit
//  layout immediately afterward. positionPopup() runs synchronously (no requestAnimationFrame --
//  see its own doc comment in web/shared/position-popup.ts), so dispatch-then-measure within a
//  single evaluateJavaScript round-trip is safe and atomic.
//

import XCTest
@testable import final_final

final class HoverTooltipSizingBridgeTests: XCTestCase {
    private var helper: EditorTestHelper!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        helper = EditorTestHelper(editorType: .milkdown)
        try await helper.loadAndWaitForReady(timeout: 15)
    }

    // MARK: - Fixtures

    // Mirrors the shape of the original bug report's Ambrose Bierce quote: a full sentence
    // well over 250 characters, long enough that the tooltip MUST hit its max-width cap
    // rather than its shrink-to-fit min-content width (the old bug) to display sanely.
    private static let longAnnotationText =
        "A soldier is a man whose business it is to kill people he has never met, who never " +
        "harmed him, on behalf of strangers who sent him to do it, in a war whose causes he " +
        "was never given the time to fully understand before being asked to die for it, and " +
        "whose outcome he will not live to see decided either way."
    private static let shortAnnotationText = "Needs more detail here"
    private static let oneWordAnnotationText = "Important"
    private static let longFootnoteText =
        "This footnote definition is deliberately long -- well over one hundred characters -- " +
        "so we can confirm the shared tooltip renders wide rather than tall, proving the fix " +
        "uses width instead of vertical scrolling for overflow."

    // MARK: - JS bridge helpers not wrapped by EditorTestHelper

    private struct TooltipMeasurement: Codable {
        let anchorFound: Bool
        let tooltipExists: Bool
        let visibility: String
        let opacity: String
        let width: Double
        let height: Double
        let left: Double
        let right: Double
        let top: Double
        let bottom: Double
        let scrollHeight: Double
        let text: String
        let isFootnoteVariant: Bool
        let innerWidth: Double
        let innerHeight: Double
        let anchorLeft: Double
        /// `getComputedStyle(tip).fontSize`, parsed to a bare px number. Added for the
        /// annotation/footnote font-size-parity fix (both variants must render at the same
        /// computed size, scaled off --font-size-body, instead of the old mismatched hardcoded
        /// 12px vs. 0.9rem-off-the-browser-default).
        let fontSize: Double

        /// `visibility`/`opacity` above are read from the tooltip's INLINE style
        /// (`tip.style.visibility`/`tip.style.opacity`), not `getComputedStyle()` -- this
        /// matters, and matches hover-tooltip.ts's own `isHoverTooltipVisible()` export
        /// (`tooltipEl.style.visibility !== 'hidden'`), for a real reason found while writing
        /// this test: `.ff-hover-tooltip`'s CSS lists `visibility` in its `transition`, and per
        /// the CSS Transitions spec, a `visible`→`hidden` transition only flips the COMPUTED
        /// value to `hidden` at the transition's END (100% progress), not its start -- so
        /// `getComputedStyle().visibility` reads back `visible` for the full ~150ms after a
        /// dismiss, even though the dismiss fired correctly and the INLINE value is already
        /// `hidden`. (The reverse, `hidden`→`visible` on show, flips immediately at the start,
        /// which is why relying on computed style happened to look fine for every show-path
        /// assertion in this file but broke specifically for the dismiss-path one.) The inline
        /// style is what hover-tooltip.ts itself sets and is therefore the correct source of
        /// truth for "did show/hide actually run" -- `display` is still deliberately excluded,
        /// per the task brief, since this tooltip is never toggled via `display: none`.
        var isVisible: Bool { visibility == "visible" && opacity != "0" }
    }

    @MainActor
    private func setAnnotationDisplayModes(_ modes: [String: String]) async throws {
        let pairs = modes.map { "\"\($0.key)\": \"\($0.value)\"" }.joined(separator: ", ")
        _ = try await helper.webView.evaluateJavaScript("window.FinalFinal.setAnnotationDisplayModes({\(pairs)})")
    }

    @MainActor
    private func setFootnoteDefinitions(_ defs: [String: String]) async throws {
        let pairs = defs.map { "\"\($0.key)\": \(jsString($0.value))" }.joined(separator: ", ")
        _ = try await helper.webView.evaluateJavaScript("window.FinalFinal.setFootnoteDefinitions({\(pairs)})")
    }

    /// Mirrors AppearanceSettings.cssOverrides' `--font-size-body: <N>px;` format and
    /// MilkdownCoordinator+Content.setTheme's `window.FinalFinal.setTheme(...)` call --
    /// exercises the real runtime path Swift uses to push the user's body-font-size
    /// preference into the editor, rather than relying on styles.css's own 18px default.
    @MainActor
    private func setBodyFontSize(_ px: Int) async throws {
        _ = try await helper.webView.evaluateJavaScript("window.FinalFinal.setTheme('--font-size-body: \(px)px;')")
    }

    private func jsString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    /// The shared JS snippet that reads back `.ff-hover-tooltip`'s current real-WebKit-computed
    /// state as a TooltipMeasurement-shaped JSON object. `anchorLeft` defaults to 0 for callers
    /// that don't compute it (only the edge-collision test does).
    private static let readTooltipStateJS = """
        (function(anchorLeft) {
          const tip = document.querySelector('.ff-hover-tooltip');
          if (!tip) {
            return JSON.stringify({
              anchorFound: true, tooltipExists: false, visibility: '', opacity: '',
              width: 0, height: 0, left: 0, right: 0, top: 0, bottom: 0, scrollHeight: 0,
              text: '', isFootnoteVariant: false,
              innerWidth: window.innerWidth, innerHeight: window.innerHeight, anchorLeft: anchorLeft,
              fontSize: 0
            });
          }
          const rect = tip.getBoundingClientRect();
          return JSON.stringify({
            anchorFound: true,
            tooltipExists: true,
            visibility: tip.style.visibility,
            opacity: tip.style.opacity,
            width: rect.width,
            height: rect.height,
            left: rect.left,
            right: rect.right,
            top: rect.top,
            bottom: rect.bottom,
            scrollHeight: tip.scrollHeight,
            text: tip.textContent || '',
            isFootnoteVariant: tip.classList.contains('ff-hover-tooltip--footnote'),
            innerWidth: window.innerWidth,
            innerHeight: window.innerHeight,
            anchorLeft: anchorLeft,
            fontSize: parseFloat(getComputedStyle(tip).fontSize)
          });
        })
        """

    /// Dispatches a real `mouseover` DOM event on the element matched by `selector`
    /// (bubbles: true, exactly like a real hover reaching hover-tooltip.ts's delegated
    /// listener on the editor root), then immediately reads back the resulting
    /// `.ff-hover-tooltip` element's real WebKit layout in the same synchronous script.
    @MainActor
    private func hoverAndMeasure(selector: String) async throws -> TooltipMeasurement {
        let script = """
        (function() {
          const el = document.querySelector(\(jsString(selector)));
          if (!el) {
            return JSON.stringify({
              anchorFound: false, tooltipExists: false, visibility: '', opacity: '',
              width: 0, height: 0, left: 0, right: 0, top: 0, bottom: 0, scrollHeight: 0,
              text: '', isFootnoteVariant: false,
              innerWidth: window.innerWidth, innerHeight: window.innerHeight, anchorLeft: 0,
              fontSize: 0
            });
          }
          el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
          return (\(Self.readTooltipStateJS))(el.getBoundingClientRect().left);
        })();
        """
        return try await evaluateMeasurement(script)
    }

    /// Dispatches `keydown` on `document` (hideOnDismiss's keydown listener is registered
    /// there, not on the editor root -- see hover-tooltip.ts's installHoverTooltipListeners)
    /// and reads back the tooltip's resulting visibility state in the same synchronous script.
    @MainActor
    private func dispatchKeydownAndReadTooltipState() async throws -> TooltipMeasurement {
        let script = """
        (function() {
          document.dispatchEvent(new KeyboardEvent('keydown', { bubbles: true, key: 'a' }));
          return (\(Self.readTooltipStateJS))(0);
        })();
        """
        return try await evaluateMeasurement(script)
    }

    @MainActor
    private func evaluateMeasurement(_ script: String) async throws -> TooltipMeasurement {
        let json = try await helper.webView.evaluateJavaScript(script) as? String
        guard let json, let data = json.data(using: .utf8) else {
            throw EditorTestError.snapshotFailed
        }
        return try JSONDecoder().decode(TooltipMeasurement.self, from: data)
    }

    // MARK: - 1. Long content sizing

    @MainActor
    func testLongAnnotationTooltipWidthAndWrap() async throws {
        XCTAssertGreaterThanOrEqual(
            Self.longAnnotationText.count, 250,
            "Fixture must actually be long enough to exercise the wide case"
        )

        try await setAnnotationDisplayModes(["reference": "collapsed"])
        try await helper.setContent("Some lead-in text. <!-- ::reference:: \(Self.longAnnotationText) --> Some trailing text.")
        try await Task.sleep(nanoseconds: 300_000_000)

        let measurement = try await hoverAndMeasure(selector: ".ff-annotation-collapsed")

        XCTAssertTrue(measurement.anchorFound, "Collapsed annotation anchor must be present in the DOM")
        XCTAssertTrue(measurement.tooltipExists, "Tooltip element must exist after mouseover")
        XCTAssertTrue(measurement.isVisible, "Tooltip must be visible (visibility:visible, opacity!=0) after mouseover")
        XCTAssertEqual(measurement.text, Self.longAnnotationText)

        XCTAssertGreaterThanOrEqual(
            measurement.width, 350,
            "Long content should approach the 420px cap -- NOT the old bug's ~70px or the first failed fix's ~160px"
        )
        // `.ff-hover-tooltip` has no `box-sizing: border-box` (verified: no box-sizing rule
        // anywhere in styles.css or typography.css), so `max-width: 420px` bounds the CONTENT
        // box only. getBoundingClientRect().width is the BORDER box, which for content-box
        // elements also includes horizontal padding (6px 10px -> 10px each side = 20px) -- so
        // the real rendered ceiling here is 420 + 20 = 440px, not 420px flat. This was found by
        // this test (measured 440.0 against an initial 421px assumption); positionPopup()'s own
        // viewport-edge clamp (exercised separately below) is unaffected since it measures real
        // pixels via getBoundingClientRect() rather than trusting the CSS value.
        XCTAssertLessThanOrEqual(measurement.width, 441, "Must respect the max-width cap (420px content + up to 20px horizontal padding, content-box)")

        // Confirm the text actually wrapped onto multiple lines, not just that the box is wide.
        // Single-line height at line-height:1.4/font-size:12px + 6px top/bottom padding is
        // ~28.8px; a real wrap onto several lines should clear that by a wide margin.
        XCTAssertGreaterThan(
            measurement.scrollHeight, 40,
            "Long text rendered at ~400px width must wrap onto multiple lines"
        )
    }

    // MARK: - 2. Short content sizing

    @MainActor
    func testShortAnnotationTooltipWidth() async throws {
        try await setAnnotationDisplayModes(["reference": "collapsed"])
        try await helper.setContent("Some lead-in text. <!-- ::reference:: \(Self.shortAnnotationText) --> Some trailing text.")
        try await Task.sleep(nanoseconds: 300_000_000)

        let measurement = try await hoverAndMeasure(selector: ".ff-annotation-collapsed")

        XCTAssertTrue(measurement.tooltipExists)
        XCTAssertTrue(measurement.isVisible)
        XCTAssertEqual(measurement.text, Self.shortAnnotationText)

        XCTAssertGreaterThanOrEqual(measurement.width, 160, "Must not render below the 160px floor")
        XCTAssertLessThan(measurement.width, 300, "Short content should be meaningfully narrower than the long-content case (~420px)")
    }

    // MARK: - 3. One-word content (floor)

    @MainActor
    func testOneWordAnnotationTooltipHitsFloor() async throws {
        try await setAnnotationDisplayModes(["reference": "collapsed"])
        try await helper.setContent("Some lead-in text. <!-- ::reference:: \(Self.oneWordAnnotationText) --> Some trailing text.")
        try await Task.sleep(nanoseconds: 300_000_000)

        let measurement = try await hoverAndMeasure(selector: ".ff-annotation-collapsed")

        XCTAssertTrue(measurement.tooltipExists)
        XCTAssertTrue(measurement.isVisible)
        XCTAssertEqual(measurement.text, Self.oneWordAnnotationText)

        XCTAssertGreaterThanOrEqual(measurement.width, 160, "A one-word annotation must be clamped UP to the 160px floor, not shrink below it")
        XCTAssertLessThan(measurement.width, 200, "A single word's min-content width is well under 160px, so this should sit right at the floor")
    }

    // MARK: - 4. Edge collision (right edge)

    @MainActor
    func testTooltipDoesNotOverflowRightEdge() async throws {
        try await setAnnotationDisplayModes(["reference": "collapsed"])

        // Pack many collapsed (tiny-marker) annotations into one paragraph so several wrap
        // across multiple lines at varying horizontal offsets, then -- in JS, after real
        // WebKit has laid them out -- pick whichever one actually ended up closest to the
        // right edge, rather than trying to predict exact word-wrap pixel positions ourselves.
        // `--column-max-width`/`--column-min-width` are never set in this test (no setTheme()
        // call), so #editor's content box spans nearly the full 800px WKWebView width (just
        // its own 48px left/right padding), which is exactly what makes a wrapped line's right
        // edge land close to window.innerWidth's right edge -- required to actually exercise
        // positionPopup()'s clamp.
        let prefix = "Filler lead-in text so this paragraph is not parsed as an HTML block."
        let markers = (0..<80).map { "<!-- ::reference:: Item \($0) \(Self.shortAnnotationText) -->" }.joined(separator: " ")
        try await helper.setContent("\(prefix) \(markers)")
        try await Task.sleep(nanoseconds: 300_000_000)

        let script = """
        (function() {
          const spans = Array.from(document.querySelectorAll('.ff-annotation-collapsed'));
          if (spans.length === 0) {
            return JSON.stringify({
              anchorFound: false, tooltipExists: false, visibility: '', opacity: '',
              width: 0, height: 0, left: 0, right: 0, top: 0, bottom: 0, scrollHeight: 0,
              text: '', isFootnoteVariant: false,
              innerWidth: window.innerWidth, innerHeight: window.innerHeight, anchorLeft: 0,
              fontSize: 0
            });
          }
          let best = spans[0];
          let bestLeft = best.getBoundingClientRect().left;
          for (const s of spans) {
            const l = s.getBoundingClientRect().left;
            if (l > bestLeft) { best = s; bestLeft = l; }
          }
          best.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
          return (\(Self.readTooltipStateJS))(bestLeft);
        })();
        """
        let measurement = try await evaluateMeasurement(script)

        XCTAssertTrue(measurement.anchorFound, "At least one collapsed annotation must have rendered")
        XCTAssertTrue(measurement.tooltipExists)
        XCTAssertTrue(measurement.isVisible)

        // Sanity check that this test actually exercises the edge-collision clamp: the picked
        // anchor must genuinely sit toward the right portion of the viewport, otherwise a
        // passing assertion below would prove nothing.
        XCTAssertGreaterThan(
            measurement.anchorLeft, measurement.innerWidth * 0.4,
            "Fixture must produce at least one annotation positioned toward the right side of the viewport, or this test can't exercise the collision clamp"
        )

        XCTAssertLessThanOrEqual(
            measurement.right, measurement.innerWidth,
            "The tooltip must not overflow past the visible viewport at the right edge -- the core guarantee positionPopup() provides"
        )
    }

    // MARK: - 5. Cleanup — keydown dismissal

    @MainActor
    func testKeydownDismissesTooltip() async throws {
        try await setAnnotationDisplayModes(["reference": "collapsed"])
        try await helper.setContent("Some lead-in text. <!-- ::reference:: \(Self.shortAnnotationText) --> Some trailing text.")
        try await Task.sleep(nanoseconds: 300_000_000)

        let shown = try await hoverAndMeasure(selector: ".ff-annotation-collapsed")
        XCTAssertTrue(shown.tooltipExists)
        XCTAssertTrue(shown.isVisible, "Tooltip must be visible immediately after mouseover, before testing dismissal")

        let afterKeydown = try await dispatchKeydownAndReadTooltipState()
        XCTAssertTrue(
            afterKeydown.tooltipExists,
            "The singleton tooltip element itself persists in the DOM (hidden via visibility, never removed/display:none)"
        )
        XCTAssertEqual(afterKeydown.visibility, "hidden", "keydown must dismiss the tooltip -- the specific regression fix under test this round")
        XCTAssertFalse(afterKeydown.isVisible)
    }

    // MARK: - 6. Footnote tooltip

    @MainActor
    func testFootnoteTooltipWidthAndHeight() async throws {
        XCTAssertGreaterThanOrEqual(Self.longFootnoteText.count, 100, "Fixture must actually be long enough to exercise the width fix")

        try await helper.setContent("See the analysis for details[^1].")
        try await Task.sleep(nanoseconds: 300_000_000)
        try await setFootnoteDefinitions(["1": Self.longFootnoteText])

        let measurement = try await hoverAndMeasure(selector: ".ff-footnote-ref")

        XCTAssertTrue(measurement.anchorFound, "Footnote reference anchor must be present in the DOM")
        XCTAssertTrue(measurement.tooltipExists)
        XCTAssertTrue(measurement.isVisible)
        XCTAssertTrue(measurement.isFootnoteVariant, "Footnote hover must use the .ff-hover-tooltip--footnote variant class")
        XCTAssertEqual(measurement.text, Self.longFootnoteText)

        XCTAssertGreaterThan(measurement.width, 91, "Must be noticeably wider than the old footnote tooltip bug's measured ~91px")
        // See testLongAnnotationTooltipWidthAndWrap's comment: content-box sizing means the
        // real ceiling is 420px content + this variant's own horizontal padding (8px 12px ->
        // 12px each side = 24px) = 444px, not 420px flat.
        XCTAssertLessThanOrEqual(measurement.width, 445, "Must still respect the max-width cap (420px content + up to 24px horizontal padding, content-box)")
        XCTAssertLessThan(
            measurement.height, 150,
            "Must use width instead of vertical scrolling for overflow -- the old bug measured ~216px tall for want of width"
        )
    }

    // MARK: - 7. Font-size parity (annotation vs. footnote)

    /// Regression test for the font-size mismatch fix: `.ff-hover-tooltip` used to hardcode
    /// `font-size: 12px` (always small, ignoring the user's body-text-size preference) while
    /// `.ff-hover-tooltip--footnote` used `font-size: 0.9rem` (relative to the *browser's*
    /// default root size, not this app's `--font-size-body`) -- so the two tooltip kinds
    /// rendered at different, both-wrong sizes. Both rules now derive from `--font-size-body`
    /// (set at runtime by Swift via setTheme), and the footnote variant no longer declares its
    /// own font-size at all, inheriting the base rule's instead.
    ///
    /// Drives the real runtime path Swift uses (AppearanceSettings.cssOverrides ->
    /// MilkdownCoordinator+Content.setTheme -> window.FinalFinal.setTheme) to push a known,
    /// non-default body font size, then reads back each tooltip variant's real WebKit
    /// `getComputedStyle().fontSize` to confirm both (a) match each other exactly and (b) are
    /// smaller than the configured body size -- both parts of the user's explicit ask.
    @MainActor
    func testAnnotationAndFootnoteTooltipFontSizesMatchAndScaleWithBodySize() async throws {
        let bodyFontSizePx = 30

        try await setBodyFontSize(bodyFontSizePx)
        try await setAnnotationDisplayModes(["reference": "collapsed"])
        try await helper.setContent(
            "Some lead-in text. <!-- ::reference:: \(Self.shortAnnotationText) --> " +
                "Also see the footnote[^1]."
        )
        try await Task.sleep(nanoseconds: 300_000_000)
        try await setFootnoteDefinitions(["1": Self.longFootnoteText])

        let annotationMeasurement = try await hoverAndMeasure(selector: ".ff-annotation-collapsed")
        XCTAssertTrue(annotationMeasurement.tooltipExists)
        XCTAssertTrue(annotationMeasurement.isVisible)
        XCTAssertFalse(annotationMeasurement.isFootnoteVariant)

        let footnoteMeasurement = try await hoverAndMeasure(selector: ".ff-footnote-ref")
        XCTAssertTrue(footnoteMeasurement.tooltipExists)
        XCTAssertTrue(footnoteMeasurement.isVisible)
        XCTAssertTrue(footnoteMeasurement.isFootnoteVariant)

        // The core user complaint: both tooltip kinds must render at IDENTICAL computed size.
        XCTAssertEqual(
            annotationMeasurement.fontSize, footnoteMeasurement.fontSize, accuracy: 0.05,
            "Annotation and footnote tooltips must render at exactly the same computed font-size"
        )

        // Both must scale off --font-size-body (30px here), not a hardcoded/browser-default
        // value: calc(var(--font-size-body) * 0.85) = 25.5px at this configured size.
        let expectedPx = Double(bodyFontSizePx) * 0.85
        XCTAssertEqual(
            annotationMeasurement.fontSize, expectedPx, accuracy: 0.5,
            "Annotation tooltip font-size must track --font-size-body (calc(30px * 0.85) = 25.5px), not a hardcoded 12px"
        )
        XCTAssertEqual(
            footnoteMeasurement.fontSize, expectedPx, accuracy: 0.5,
            "Footnote tooltip font-size must track --font-size-body (calc(30px * 0.85) = 25.5px), not 0.9rem off the browser default"
        )

        // Both must still read as "slightly smaller than body text" per the user's explicit ask.
        XCTAssertLessThan(annotationMeasurement.fontSize, Double(bodyFontSizePx))
        XCTAssertLessThan(footnoteMeasurement.fontSize, Double(bodyFontSizePx))
    }
}
