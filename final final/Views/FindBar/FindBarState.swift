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
                print("[FindBarState] find error: \(error)")
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
                print("[FindBarState] findNext error: \(error)")
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
                print("[FindBarState] findPrevious error: \(error)")
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
                    print("[FindBarState] replaceCurrent error: \(error)")
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
