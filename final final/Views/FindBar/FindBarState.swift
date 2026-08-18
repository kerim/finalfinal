//
//  FindBarState.swift
//  final final
//
//  Observable state for find and replace functionality.
//  Uses JavaScript API (window.FinalFinal.find*) for editor-native search.
//

import Foundation
import WebKit

/// Observable state for find and replace bar
@Observable
@MainActor
final class FindBarState {
    /// Whether the find bar is visible
    var isVisible = false

    /// Whether to show the replace field
    var showReplace = false

    /// Counter to request focus on search field (incrementing guarantees change detection)
    var focusRequestCount = 0

    /// Current search query
    var searchQuery = ""

    /// Replace text
    var replaceText = ""

    /// Search options
    var ignoreCase = true
    var wrapAround = true

    /// Match mode
    enum MatchMode: String, CaseIterable {
        case contains = "Contains"
        case startsWith = "Starts With"
        case fullWord = "Full Word"
    }
    var matchMode: MatchMode = .contains

    /// Current match info
    var currentMatch = 0
    var totalMatches = 0

    /// Status message (for errors or info)
    var statusMessage: String?

    /// Reference to the active WebView for find operations
    weak var activeWebView: WKWebView?

    // MARK: - Actions

    /// Show the find bar
    func show(withReplace: Bool = false) {
        isVisible = true
        showReplace = withReplace
        // Increment to trigger focus (always changes, unlike boolean toggle)
        focusRequestCount += 1
    }

    /// Hide the find bar
    func hide() {
        isVisible = false
        clearHighlights()
        restoreEditorFocus()
    }

    /// Toggle visibility
    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    /// Clear search state (when switching editors)
    func clearSearch() {
        searchQuery = ""
        replaceText = ""
        currentMatch = 0
        totalMatches = 0
        statusMessage = nil
        clearHighlights()
    }

    /// Perform find operation
    func find() {
        guard !searchQuery.isEmpty else {
            currentMatch = 0
            totalMatches = 0
            clearHighlights()
            return
        }

        performJSFind()
    }

    /// Find next match
    func findNext() {
        guard !searchQuery.isEmpty else { return }
        performJSFindNext()
    }

    /// Find previous match
    func findPrevious() {
        guard !searchQuery.isEmpty else { return }
        performJSFindPrevious()
    }

    /// Replace current match
    func replaceCurrent() {
        guard !searchQuery.isEmpty else { return }
        performJSReplace(all: false)
    }

    /// Replace all matches
    func replaceAll() {
        guard !searchQuery.isEmpty else { return }
        performJSReplace(all: true)
    }

    /// Use current selection as search query
    func useSelectionForFind() {
        guard let webView = activeWebView else { return }

        webView.evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
            if let selection = result as? String, !selection.isEmpty {
                self?.searchQuery = selection
                self?.find()
            }
        }
    }

    // MARK: - Private - JavaScript API calls

    /// Build JSON options for JavaScript find API
    private func buildFindOptions() -> String {
        let caseSensitive = !ignoreCase
        let wholeWord = matchMode == .fullWord
        let regexp = false  // Not using regex mode for now

        return """
        { caseSensitive: \(caseSensitive), wholeWord: \(wholeWord), regexp: \(regexp) }
        """
    }

    /// Escape a string for JavaScript
    private func escapeForJS(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    /// Perform initial find using JavaScript API
    private func performJSFind() {
        guard let webView = activeWebView else { return }

        let escapedQuery = escapeForJS(searchQuery)
        let options = buildFindOptions()

        let script = """
        (function() {
            const result = window.FinalFinal.find('\(escapedQuery)', \(options));
            return result;
        })()
        """

        webView.evaluateJavaScript(script) { [weak self] result, error in
            if let error = error {
                DebugLog.log(.editor, "[FindBarState] find error: \(error)")
                return
            }

            if let dict = result as? [String: Any] {
                self?.totalMatches = dict["matchCount"] as? Int ?? 0
                self?.currentMatch = dict["currentIndex"] as? Int ?? 0
            }
        }
    }

    /// Find next match using JavaScript API
    private func performJSFindNext() {
        guard let webView = activeWebView else { return }

        // If no active search, start a new one
        if totalMatches == 0 {
            performJSFind()
            return
        }

        let script = """
        (function() {
            const result = window.FinalFinal.findNext();
            return result;
        })()
        """

        webView.evaluateJavaScript(script) { [weak self] result, error in
            if let error = error {
                DebugLog.log(.editor, "[FindBarState] findNext error: \(error)")
                return
            }

            if let dict = result as? [String: Any] {
                self?.totalMatches = dict["matchCount"] as? Int ?? 0
                self?.currentMatch = dict["currentIndex"] as? Int ?? 0
            }
        }
    }

    /// Find previous match using JavaScript API
    private func performJSFindPrevious() {
        guard let webView = activeWebView else { return }

        // If no active search, start a new one
        if totalMatches == 0 {
            performJSFind()
            return
        }

        let script = """
        (function() {
            const result = window.FinalFinal.findPrevious();
            return result;
        })()
        """

        webView.evaluateJavaScript(script) { [weak self] result, error in
            if let error = error {
                DebugLog.log(.editor, "[FindBarState] findPrevious error: \(error)")
                return
            }

            if let dict = result as? [String: Any] {
                self?.totalMatches = dict["matchCount"] as? Int ?? 0
                self?.currentMatch = dict["currentIndex"] as? Int ?? 0
            }
        }
    }

    /// Replace using JavaScript API
    private func performJSReplace(all: Bool) {
        guard let webView = activeWebView else { return }

        let escapedReplace = escapeForJS(replaceText)

        if all {
            let script = """
            (function() {
                return window.FinalFinal.replaceAll('\(escapedReplace)');
            })()
            """

            webView.evaluateJavaScript(script) { [weak self] result, error in
                if let error = error {
                    self?.statusMessage = "Replace failed: \(error.localizedDescription)"
                    return
                }

                if let count = result as? Int {
                    self?.statusMessage = "Replaced \(count) occurrence\(count == 1 ? "" : "s")"
                    self?.totalMatches = 0
                    self?.currentMatch = 0
                }
            }
        } else {
            let script = """
            (function() {
                const success = window.FinalFinal.replaceCurrent('\(escapedReplace)');
                if (success) {
                    // After replacement, get updated search state
                    const state = window.FinalFinal.getSearchState();
                    return state;
                }
                return null;
            })()
            """

            webView.evaluateJavaScript(script) { [weak self] result, error in
                if let error = error {
                    DebugLog.log(.editor, "[FindBarState] replaceCurrent error: \(error)")
                    return
                }

                if let dict = result as? [String: Any] {
                    self?.totalMatches = dict["matchCount"] as? Int ?? 0
                    self?.currentMatch = dict["currentIndex"] as? Int ?? 0
                } else {
                    // Replacement succeeded but no more matches
                    self?.totalMatches = 0
                    self?.currentMatch = 0
                }
            }
        }
    }

    /// Return keyboard focus to the editor webview when the find bar closes.
    ///
    /// Root cause of "search breaks undo permanently" (live user report): closing the find
    /// bar unmounts its SwiftUI `TextField` (`ContentView+ContentRebuilding.swift` only
    /// instantiates `FindBarView` while `isVisible` is true), but nothing ever explicitly
    /// hands the window's native first-responder status back to the editor's `WKWebView`.
    /// `UndoRedoCommands.performUndo()/performRedo()` route to the editor's JS undo/redo ONLY
    /// when a `WKWebView` is found by walking up from `NSApp.keyWindow?.firstResponder`
    /// (`UndoRedoCommands.focusedWebView()`) -- otherwise they fall through to a nil-target
    /// `undo:`/`redo:` responder-chain send, which is a silent no-op once the find bar's own
    /// field (the prior first responder) has been torn down and nothing meaningful claims the
    /// role. This reproduces exactly as reported: Cmd-Z appears to "completely stop working",
    /// for actions before AND after the search, until the user happens to click directly in
    /// the editor (which naturally reclaims first responder via normal AppKit mouse handling).
    ///
    /// Mirrors the established two-step pattern already used elsewhere in this codebase for
    /// returning focus to the editor after another control held it
    /// (`MilkdownCoordinator+Content.swift.scrollToFootnoteDefinition`): JS `view.focus()`
    /// sets DOM/ProseMirror focus only, never the NSWindow responder chain, so both calls are
    /// required.
    private func restoreEditorFocus() {
        guard let webView = activeWebView else { return }
        webView.evaluateJavaScript("window.FinalFinal.focus()") { _, _ in }
        if let window = webView.window {
            window.makeFirstResponder(webView)
        }
    }

    /// Clear search highlights
    private func clearHighlights() {
        guard let webView = activeWebView else {
            currentMatch = 0
            totalMatches = 0
            return
        }

        let script = "window.FinalFinal.clearSearch()"

        webView.evaluateJavaScript(script) { [weak self] _, _ in
            self?.currentMatch = 0
            self?.totalMatches = 0
        }
    }
}
