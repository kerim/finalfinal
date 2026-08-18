//
//  FindBarStateTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//  Tests for FindBarState: show/hide/toggle, clear, match modes,
//  and safe no-op behavior when no webView is attached.
//

import Testing
import Foundation
import WebKit
@testable import final_final

@Suite("Find Bar State — Tier 2: Visible Breakage")
struct FindBarStateTests {

    // MARK: - Show

    @Test("show() sets isVisible and increments focusRequestCount")
    @MainActor
    func showSetsVisibleAndFocus() {
        let state = FindBarState()
        let initialCount = state.focusRequestCount

        state.show()

        #expect(state.isVisible == true)
        #expect(state.focusRequestCount == initialCount + 1)
    }

    @Test("show(withReplace: true) sets showReplace")
    @MainActor
    func showWithReplace() {
        let state = FindBarState()

        state.show(withReplace: true)

        #expect(state.isVisible == true)
        #expect(state.showReplace == true)
    }

    // MARK: - Hide

    @Test("hide() sets isVisible = false and clears match counts")
    @MainActor
    func hideClearsState() {
        let state = FindBarState()
        state.show()
        state.currentMatch = 3
        state.totalMatches = 10

        state.hide()

        #expect(state.isVisible == false)
        // After clearHighlights completes async (no webview → immediate),
        // counts should be reset
        #expect(state.currentMatch == 0)
        #expect(state.totalMatches == 0)
    }

    @Test("hide() with an attached (unwindowed) webView does not crash restoring focus")
    @MainActor
    func hideWithWebViewDoesNotCrash() {
        // Regression coverage for the fix to the live bug "search breaks undo": hide() now
        // also calls restoreEditorFocus(), which evaluates JS on activeWebView and (when the
        // webview has a window) calls window.makeFirstResponder(webView). This webview has no
        // window (not embedded in any view hierarchy), so only the JS-focus half is exercised
        // here -- the native-first-responder half genuinely needs a live NSWindow to mean
        // anything, which is why the actual fix is proven end-to-end by
        // final finalUITests/E2EScratchTests.swift
        // (testUndoSurvivesFindBarSearchForPriorAndSubsequentEdits) rather than here. This test
        // exists only to confirm the new code path is a safe no-op, matching this file's
        // existing "Safe No-Ops" coverage for find()/findNext()/findPrevious().
        let state = FindBarState()
        state.activeWebView = WKWebView()
        state.show()
        state.currentMatch = 3
        state.totalMatches = 10

        state.hide()

        // currentMatch/totalMatches reset happens inside clearHighlights()'s
        // evaluateJavaScript completion handler -- genuinely async, tied to a JS round trip.
        // This synthetic, unwindowed WKWebView has no loaded page, so that completion may
        // never fire within this test's synchronous execution -- asserting isVisible alone
        // (the synchronous half of hide()) plus "did not crash" is what this test can
        // actually prove; the match-count reset is not observable here.
        #expect(state.isVisible == false)
    }

    // MARK: - Toggle

    @Test("toggle() flips visibility")
    @MainActor
    func toggleFlipsVisibility() {
        let state = FindBarState()
        #expect(state.isVisible == false)

        state.toggle()
        #expect(state.isVisible == true)

        state.toggle()
        #expect(state.isVisible == false)
    }

    // MARK: - Clear Search

    @Test("clearSearch() resets query, replaceText, counts, and statusMessage")
    @MainActor
    func clearSearchResetsAll() {
        let state = FindBarState()
        state.searchQuery = "hello"
        state.replaceText = "world"
        state.currentMatch = 2
        state.totalMatches = 5
        state.statusMessage = "Found 5 matches"

        state.clearSearch()

        #expect(state.searchQuery == "")
        #expect(state.replaceText == "")
        #expect(state.currentMatch == 0)
        #expect(state.totalMatches == 0)
        #expect(state.statusMessage == nil)
    }

    // MARK: - MatchMode

    @Test("MatchMode.allCases has 3 modes with correct raw values")
    func matchModeAllCases() {
        let modes = FindBarState.MatchMode.allCases
        #expect(modes.count == 3)
        #expect(FindBarState.MatchMode.contains.rawValue == "Contains")
        #expect(FindBarState.MatchMode.startsWith.rawValue == "Starts With")
        #expect(FindBarState.MatchMode.fullWord.rawValue == "Full Word")
    }

    // MARK: - Safe No-Ops

    @Test("find() with empty query and no webView doesn't crash")
    @MainActor
    func findEmptyQueryNoWebView() {
        let state = FindBarState()
        // activeWebView is nil, searchQuery is empty
        state.find()

        #expect(state.currentMatch == 0)
        #expect(state.totalMatches == 0)
    }

    @Test("findNext() with no webView is a safe no-op")
    @MainActor
    func findNextNoWebView() {
        let state = FindBarState()
        state.searchQuery = "test"
        // No webView attached — should not crash
        state.findNext()
    }

    @Test("findPrevious() with no webView is a safe no-op")
    @MainActor
    func findPreviousNoWebView() {
        let state = FindBarState()
        state.searchQuery = "test"
        // No webView attached — should not crash
        state.findPrevious()
    }
}
