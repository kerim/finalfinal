//
//  EditorFocusRestorationTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//  Unit coverage for the shared EditorFocusRestoration helper (Phase C, focus-restoration
//  audit). Uses the `testSpy` ordering hook (mirrors StructuralUndoController's
//  testOrderingSpy) to assert BOTH halves actually fire, in order -- not just "does not
//  crash." A synthetic, unwindowed WKWebView still can't prove the AppKit half (that
//  genuinely needs a live NSWindow -- see the "no window" test below and
//  final finalUITests/E2EScratchTests.swift's Phase C header for the live proof), but the
//  spy lets this file assert the CALL happened without needing one.
//

import Testing
import Foundation
import WebKit
@testable import final_final

@Suite("EditorFocusRestoration — Tier 2: Visible Breakage")
struct EditorFocusRestorationTests {

    @Test("restoreFocus(to: nil) is a safe no-op and never spies")
    @MainActor
    func nilWebViewIsSafeNoOp() {
        var calls: [String] = []
        EditorFocusRestoration.testSpy = { context, step in calls.append("\(context):\(step)") }
        defer { EditorFocusRestoration.testSpy = nil }

        EditorFocusRestoration.restoreFocus(to: nil, context: "unit-test nil webView")

        #expect(calls.isEmpty)
    }

    @Test("restoreFocus(to:) with an unwindowed webView spies the JS half only")
    @MainActor
    func unwindowedWebViewSpiesJSHalfOnly() {
        // No NSWindow (not embedded in any view hierarchy) -- makeFirstResponder has nothing
        // to call on, so only the JS half should be attempted/spied.
        var calls: [String] = []
        EditorFocusRestoration.testSpy = { context, step in calls.append("\(context):\(step)") }
        defer { EditorFocusRestoration.testSpy = nil }

        let webView = WKWebView()
        EditorFocusRestoration.restoreFocus(to: webView, context: "unit-test unwindowed webView")

        #expect(calls == ["unit-test unwindowed webView:js"])
    }

    @Test("restoreFocus(to:) with a windowed webView spies both halves, in order")
    @MainActor
    func windowedWebViewSpiesBothHalvesInOrder() {
        // A real (offscreen) NSWindow gives makeFirstResponder something to act on, so both
        // halves should fire -- JS half first (matches FindBarState.hide()'s original call
        // order), AppKit half second. This is the assertion item 6 of the review round asked
        // for: proof both the JS call AND the makeFirstResponder call actually happened, in
        // order, not just that neither crashed.
        var calls: [String] = []
        EditorFocusRestoration.testSpy = { context, step in calls.append("\(context):\(step)") }
        defer { EditorFocusRestoration.testSpy = nil }

        let webView = WKWebView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = webView

        EditorFocusRestoration.restoreFocus(to: webView, context: "unit-test windowed webView")

        #expect(calls == [
            "unit-test windowed webView:js",
            "unit-test windowed webView:makeFirstResponder"
        ])
    }

    @Test("restoreFocus(to:) with distinct contexts keeps each call site's label separate")
    @MainActor
    func repeatedCallsKeepContextsDistinct() {
        // Every dismissal-path call site shares this one implementation now -- confirm
        // calling it repeatedly with different context labels (mirroring several dismissal
        // sites firing across a session) keeps each spy entry attributable to its own site,
        // not just that it's safe to call repeatedly.
        var calls: [String] = []
        EditorFocusRestoration.testSpy = { context, step in calls.append("\(context):\(step)") }
        defer { EditorFocusRestoration.testSpy = nil }

        let webView = WKWebView()
        let contexts = ["find-bar hide", "version-history close", "MilkdownEditor equation dialog dismiss"]
        for context in contexts {
            EditorFocusRestoration.restoreFocus(to: webView, context: context)
        }

        #expect(calls == contexts.map { "\($0):js" })
    }
}
