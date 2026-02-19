//
//  MilkdownCoordinator+MessageHandlers.swift
//  final final
//
//  Navigation, message handling, citation resolution, and polling
//  for MilkdownEditor.Coordinator.
//

import SwiftUI
import WebKit

extension MilkdownEditor.Coordinator {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isEditorReady = true
        batchInitialize()
        startPolling()

        // Push cached citation library to editor (ensures citations format correctly
        // when switching from CodeMirror where CSL items were fetched)
        pushCachedCitationLibrary()

        // Notify parent that WebView is ready (for find operations)
        onWebViewReady?(webView)
    }

    /// Push cached CSL items from ZoteroService to the editor's citeproc engine
    func pushCachedCitationLibrary() {
        let zotero = ZoteroService.shared
        let cachedJSON = zotero.cachedItemsJSON()

        // Only push if there are cached items
        if cachedJSON != "[]" {
            print("[MilkdownEditor] Pushing \(zotero.cachedItems.count) cached CSL items to editor")
            setCitationLibrary(cachedJSON)
        }
    }

    /// Called when using a preloaded WebView (navigation already finished)
    func handlePreloadedView() {
        isEditorReady = true
        batchInitialize()
        startPolling()
        pushCachedCitationLibrary()

        // Notify parent that WebView is ready (for find operations)
        if let webView = webView {
            onWebViewReady?(webView)
        }
    }

    /// Batch initialization - sends all setup data in a single JS call
    func batchInitialize() {
        guard let webView else { return }

        let content = contentBinding.wrappedValue
        let theme = ThemeManager.shared.cssVariables
        let cursor = cursorPositionToRestoreBinding.wrappedValue

        #if DEBUG
        print("[MilkdownEditor] batchInitialize: content length=\(content.count)")
        #endif

        // First check if window.FinalFinal exists
        webView.evaluateJavaScript("typeof window.FinalFinal") { [weak self] result, error in
            guard let self else { return }

            #if DEBUG
            if let error {
                print("[MilkdownEditor] FinalFinal check failed: \(error.localizedDescription)")
            } else {
                print("[MilkdownEditor] FinalFinal type: \(result ?? "nil")")
            }
            #endif

            // If FinalFinal doesn't exist yet, schedule retry
            if result as? String != "object" {
                #if DEBUG
                print("[MilkdownEditor] FinalFinal not ready, scheduling retry in 100ms")
                #endif
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.batchInitialize()
                }
                return
            }

            self.performBatchInitialize(content: content, theme: theme, cursor: cursor)
        }
    }

    /// Actually perform the batch initialization after verifying FinalFinal exists
    func performBatchInitialize(content: String, theme: String, cursor: CursorPosition?) {
        guard let webView else { return }

        // Prevent updateNSView from calling setContent() after initialize().
        // Milkdown's async typeof check currently delays initialize() past
        // updateNSView, but this makes the protection explicit.
        lastPushedContent = content
        lastPushTime = Date()

        // Build options dictionary for JSON encoding
        // Using JSON instead of template literals handles ALL special characters safely
        var options: [String: Any] = [
            "content": content,
            "theme": theme
        ]
        if let pos = cursor {
            options["cursorPosition"] = ["line": pos.line, "column": pos.column]
        } else {
            options["cursorPosition"] = NSNull()
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: options),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            #if DEBUG
            print("[MilkdownEditor] Failed to encode options as JSON")
            #endif
            return
        }

        #if DEBUG
        print("[MilkdownEditor] Initialize with content length: \(content.count) chars")
        let preview = String(content.prefix(200))
        print("[MilkdownEditor] Content preview: \(preview)...")
        #endif

        // Pass JSON directly - JSON is valid JavaScript object literal syntax
        let script = "window.FinalFinal.initialize(\(jsonString))"

        webView.evaluateJavaScript(script) { [weak self] _, error in
            if let error {
                #if DEBUG
                print("[MilkdownEditor] Initialize error: \(error.localizedDescription)")
                // Check if it's a parsing error by trying to set empty content
                webView.evaluateJavaScript("window.FinalFinal.setContent('')") { _, err2 in
                    if let err2 {
                        print("[MilkdownEditor] Even empty setContent failed: \(err2.localizedDescription)")
                    } else {
                        print("[MilkdownEditor] Empty setContent worked - content may have parse issue")
                    }
                }
                #endif
                // DEFENSIVE: If initialization failed, mark editor as NOT ready
                // so polling won't try to read from broken editor
                self?.isEditorReady = false
            } else {
                #if DEBUG
                print("[MilkdownEditor] Initialize successful")
                #endif
            }
            self?.cursorPositionToRestoreBinding.wrappedValue = nil
        }
    }

    /// Focus the editor so user can start typing immediately
    func focusEditor() {
        guard isEditorReady, let webView else { return }
        webView.evaluateJavaScript("window.FinalFinal.focus()") { _, _ in }
    }

    func restoreCursorPositionIfNeeded() {
        guard let position = cursorPositionToRestoreBinding.wrappedValue else { return }
        // Small delay to ensure content is fully loaded
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.setCursorPosition(position) {
                // Scroll cursor to center after cursor is set
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.scrollCursorToCenter()
                }
            }
            self?.cursorPositionToRestoreBinding.wrappedValue = nil
        }
    }

    func scrollCursorToCenter() {
        guard isEditorReady, let webView else { return }
        webView.evaluateJavaScript("window.FinalFinal.scrollCursorToCenter()") { _, _ in }
    }

    // Handle JS messages from WKScriptMessageHandler
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        #if DEBUG
        if message.name == "errorHandler", let body = message.body as? [String: Any] {
            let msgType = body["type"] as? String ?? "unknown"
            let errorMsg = body["message"] as? String ?? "unknown"
            print("[MilkdownEditor] JS \(msgType.uppercased()): \(errorMsg)")
        }
        #endif

        // Handle citation search requests from web editor (legacy)
        if message.name == "searchCitations", let query = message.body as? String {
            Task { @MainActor in
                await self.handleCitationSearch(query)
            }
        }

        // Handle CAYW citation picker request from web editor
        if message.name == "openCitationPicker", let cmdStart = message.body as? Int {
            Task { @MainActor in
                await self.handleOpenCitationPicker(cmdStart: cmdStart)
            }
        }

        // Handle lazy citation resolution request from web editor
        if message.name == "resolveCitekeys", let citekeys = message.body as? [String] {
            Task { @MainActor in
                await self.handleResolveCitekeys(citekeys)
            }
        }

        // Handle paint complete signal for zoom transitions
        // This is called after the double RAF pattern ensures paint is complete
        if message.name == "paintComplete" {
            Task { @MainActor in
                self.handlePaintComplete()
            }
        }

        // Handle openURL requests from editor (Cmd+click on links)
        if message.name == "openURL", let urlString = message.body as? String {
            Task { @MainActor in
                if let url = URL(string: urlString),
                   let scheme = url.scheme?.lowercased(),
                   ["http", "https", "mailto"].contains(scheme) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    /// Handle citation search request from web editor
    /// Splits multi-term queries: first term goes to BBT, additional terms filter client-side
    @MainActor
    func handleCitationSearch(_ query: String) async {
        guard let webView else { return }

        print("[MilkdownEditor] Citation search: '\(query)'")

        // Split query into terms (BBT search only supports single-term reliably)
        let terms = query.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        guard !terms.isEmpty else {
            sendCitationSearchCallback(webView: webView, json: "[]")
            return
        }

        // Use first term for BBT search
        let searchTerm = terms[0]
        let filterTerms = Array(terms.dropFirst()).map { $0.lowercased() }

        do {
            var items = try await ZoteroService.shared.search(query: searchTerm)

            // Client-side filtering for additional terms
            if !filterTerms.isEmpty {
                items = items.filter { item in
                    let searchText = item.searchText.lowercased()
                    return filterTerms.allSatisfy { searchText.contains($0) }
                }
            }

            print("[MilkdownEditor] Search returned \(items.count) results (filter terms: \(filterTerms))")

            // Encode results as JSON
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(items)
            guard let jsonString = String(data: data, encoding: .utf8) else {
                sendCitationSearchCallback(webView: webView, json: "[]")
                return
            }

            sendCitationSearchCallback(webView: webView, json: jsonString)
        } catch {
            print("[MilkdownEditor] Citation search error: \(error.localizedDescription)")
            sendCitationSearchCallback(webView: webView, json: "[]")
        }
    }

    /// Send search results back to web editor via callback
    @MainActor
    func sendCitationSearchCallback(webView: WKWebView, json: String) {
        let escaped = json.escapedForJSTemplateLiteral
        webView.evaluateJavaScript("window.FinalFinal.searchCitationsCallback(JSON.parse(`\(escaped)`))") { _, _ in }
    }

    /// Show a native NSAlert for Zotero-related errors
    /// JS alert() is silently swallowed in WKWebView (no WKUIDelegate), so we must use native alerts.
    @MainActor
    private func showZoteroAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Handle CAYW citation picker request from web editor
    /// Opens Zotero's native citation picker, returns parsed citation + CSL items
    @MainActor
    func handleOpenCitationPicker(cmdStart: Int) async {
        guard let webView else {
            return
        }

        // Pre-check: ping Zotero before opening the picker
        let isRunning = await ZoteroService.shared.ping()
        if !isRunning {
            showZoteroAlert(
                title: "Zotero Not Running",
                message: "Zotero is not running. Please open Zotero and try again."
            )
            sendCitationPickerCancelled(webView: webView)
            return
        }

        do {
            // Call CAYW picker - this blocks until user selects references
            let (parsed, items) = try await ZoteroService.shared.openCAYWPicker()

            // Bring app back to foreground after Zotero picker closes
            NSApp.activate(ignoringOtherApps: true)

            // Encode CSL items as JSON for web
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let itemsData = try encoder.encode(items)
            guard let itemsJSON = String(data: itemsData, encoding: .utf8) else {
                sendCitationPickerCancelled(webView: webView)
                return
            }

            // Build callback data object
            let callbackData: [String: Any] = [
                "rawSyntax": parsed.rawSyntax,
                "citekeys": parsed.citekeys,
                "locators": parsed.locatorsJSON,
                "prefix": parsed.entries.first?.prefix ?? "",
                "suppressAuthor": parsed.entries.first?.suppressAuthor ?? false,
                "cmdStart": cmdStart
            ]

            guard let callbackJSON = try? JSONSerialization.data(withJSONObject: callbackData),
                  let callbackStr = String(data: callbackJSON, encoding: .utf8) else {
                sendCitationPickerCancelled(webView: webView)
                return
            }

            // Send both parsed data and CSL items to web editor
            let escapedCallback = callbackStr.escapedForJSTemplateLiteral
            let escapedItems = itemsJSON.escapedForJSTemplateLiteral

            let script = "window.FinalFinal.citationPickerCallback(JSON.parse(`\(escapedCallback)`), JSON.parse(`\(escapedItems)`))"
            webView.evaluateJavaScript(script) { _, _ in }
        } catch ZoteroError.userCancelled {
            // User cancelled - bring app back to foreground, no error
            NSApp.activate(ignoringOtherApps: true)
            sendCitationPickerCancelled(webView: webView)
        } catch ZoteroError.notRunning {
            NSApp.activate(ignoringOtherApps: true)
            showZoteroAlert(
                title: "Zotero Connection Lost",
                message: "Zotero is not running. Please open Zotero and try again."
            )
            sendCitationPickerCancelled(webView: webView)
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            showZoteroAlert(
                title: "Citation Error",
                message: error.localizedDescription
            )
            sendCitationPickerCancelled(webView: webView)
        }
    }

    /// Send citation picker error to web editor
    @MainActor
    func sendCitationPickerError(webView: WKWebView, message: String) {
        // Note: Escapes " instead of ${ — different pattern from escapedForJSTemplateLiteral
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "\"", with: "\\\"")
        webView.evaluateJavaScript("window.FinalFinal.citationPickerError(`\(escaped)`)") { _, _ in }
    }

    /// Send citation picker cancelled to web editor
    @MainActor
    func sendCitationPickerCancelled(webView: WKWebView) {
        webView.evaluateJavaScript("window.FinalFinal.citationPickerCancelled()") { _, _ in }
    }

    /// Handle lazy citation resolution request from web editor
    /// Fetches CSL-JSON for unresolved citekeys and pushes back to editor
    @MainActor
    func handleResolveCitekeys(_ citekeys: [String]) async {
        guard let webView, isEditorReady else {
            print("[MilkdownEditor] handleResolveCitekeys: webView or editor not ready")
            return
        }

        guard !citekeys.isEmpty else { return }

        print("[MilkdownEditor] Resolving \(citekeys.count) citekeys: \(citekeys)")

        do {
            // Fetch CSL items from Zotero via BBT
            let items = try await ZoteroService.shared.fetchItemsForCitekeys(citekeys)

            guard !items.isEmpty else {
                print("[MilkdownEditor] No items found for citekeys")
                return
            }

            print("[MilkdownEditor] Resolved \(items.count) items")

            // Encode as JSON
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(items)
            guard let json = String(data: data, encoding: .utf8) else {
                print("[MilkdownEditor] Failed to encode items as JSON")
                return
            }

            // Push items to editor
            addCitationItems(json)
        } catch ZoteroError.notRunning {
            print("[MilkdownEditor] Zotero not running - cannot resolve citekeys")
            // Don't show error to user for lazy resolution - just log it
        } catch {
            print("[MilkdownEditor] Failed to resolve citekeys: \(error.localizedDescription)")
        }
    }

    /// Push citation items to editor without replacing existing library
    @MainActor
    func addCitationItems(_ itemsJSON: String) {
        guard isEditorReady, let webView else { return }
        let escaped = itemsJSON.escapedForJSTemplateLiteral
        webView.evaluateJavaScript("window.FinalFinal.addCitationItems(JSON.parse(`\(escaped)`))") { _, _ in }
    }

    /// Handle paint complete signal from web editor (for zoom transitions)
    /// Called after double RAF pattern ensures browser has painted all content
    @MainActor
    func handlePaintComplete() {
        // Show WebView now that paint is complete
        webView?.alphaValue = 1

        // Call acknowledgement callback if registered (for zoom sync)
        if let callback = onContentAcknowledged {
            onContentAcknowledged = nil  // One-shot callback
            callback()
        }
    }

    /// Refresh all citations in the document
    /// Gets all citekeys from the editor, fetches their CSL data, and pushes it back
    @MainActor
    func refreshAllCitations() async {
        guard isEditorReady, let webView else {
            print("[MilkdownEditor] refreshAllCitations: editor not ready")
            return
        }

        print("[MilkdownEditor] Refreshing all citations...")

        // Get all citekeys from the document
        webView.evaluateJavaScript("JSON.stringify(window.FinalFinal.getAllCitekeys())") { [weak self] result, error in
            guard let self else { return }

            if let error {
                print("[MilkdownEditor] Failed to get citekeys: \(error.localizedDescription)")
                return
            }

            guard let jsonString = result as? String,
                  let data = jsonString.data(using: .utf8),
                  let citekeys = try? JSONDecoder().decode([String].self, from: data) else {
                print("[MilkdownEditor] Failed to decode citekeys")
                return
            }

            guard !citekeys.isEmpty else {
                print("[MilkdownEditor] No citations in document")
                return
            }

            print("[MilkdownEditor] Found \(citekeys.count) citekeys to refresh: \(citekeys)")

            // Fetch all citekeys from Zotero
            Task { @MainActor in
                await self.handleResolveCitekeys(citekeys)
            }
        }
    }

    func startPolling() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollContent()
            }
        }
    }

    func pollContent() {
        guard !isCleanedUp, isEditorReady, let webView else { return }

        // Skip polling during content reset (project switch)
        guard !isResettingContentBinding.wrappedValue else { return }

        // Skip polling during content transitions (zoom, hierarchy enforcement)
        // This prevents stale content from being read during transitions
        guard contentState == .idle else { return }

        webView.evaluateJavaScript("window.FinalFinal.getContent()") { [weak self] result, _ in
            guard let self, !self.isCleanedUp,
                  let content = result as? String else { return }

            // Double-check reset flag in callback (may have changed)
            guard !self.isResettingContentBinding.wrappedValue else { return }

            // Double-check contentState in callback (may have changed)
            guard self.contentState == .idle else { return }

            if content.isEmpty && !self.contentBinding.wrappedValue.isEmpty {
                #if DEBUG
                print("[MilkdownEditor] pollContent: Accepting empty content (user deleted all)")
                #endif
            }

            // Grace period guard: don't overwrite recent pushes (race condition fix)
            // Extended from 300ms to 600ms to better match polling interval + processing time
            let timeSincePush = Date().timeIntervalSince(self.lastPushTime)
            if timeSincePush < 0.6 && content != self.lastPushedContent {
                #if DEBUG
                let pollPreview = String(content.prefix(50)).replacingOccurrences(of: "\n", with: "\\n")
                let pushPreview = String(self.lastPushedContent.prefix(50)).replacingOccurrences(of: "\n", with: "\\n")
                print("[MilkdownEditor] pollContent: BLOCKED during grace period (\(String(format: "%.2f", timeSincePush))s)")
                print("[MilkdownEditor]   polled: \(pollPreview)...")
                print("[MilkdownEditor]   pushed: \(pushPreview)...")
                #endif
                return  // JS hasn't processed our push yet
            }

            guard content != self.lastPushedContent else { return }

            // DEFENSIVE: Reject clearly corrupted content from Milkdown serialization bugs
            // If we pushed a header and got back `<br />`, Milkdown's getMarkdown() is broken
            let pushedFirstLine = self.lastPushedContent.components(separatedBy: "\n").first ?? ""
            let polledFirstLine = content.components(separatedBy: "\n").first ?? ""

            if pushedFirstLine.hasPrefix("#") && polledFirstLine.hasPrefix("<br") {
                print("[MilkdownEditor] REJECTED: Milkdown returned corrupted content")
                print("[MilkdownEditor]   pushed first line: '\(pushedFirstLine)'")
                print("[MilkdownEditor]   polled first line: '\(polledFirstLine)'")
                return  // Don't accept corrupted content
            }

            // DIAGNOSTIC: Detect unexpected content length changes (e.g., missing heading markers)
            // This helps diagnose the section deletion cascade bug
            let lengthDiff = content.count - self.lastPushedContent.count
            if abs(lengthDiff) > 0 && abs(lengthDiff) <= 10 {
                // Small length change (1-10 chars) might indicate missing # markers
                if pushedFirstLine != polledFirstLine {
                    print("[MilkdownEditor] DIAGNOSTIC: First line changed unexpectedly")
                    print("[MilkdownEditor]   pushed first line: '\(pushedFirstLine)'")
                    print("[MilkdownEditor]   polled first line: '\(polledFirstLine)'")
                    print("[MilkdownEditor]   length diff: \(lengthDiff) chars")
                }
            }

            #if DEBUG
            // PASTE DEBUG: Log when poll updates the binding
            let pollPreview = String(content.prefix(100)).replacingOccurrences(of: "\n", with: "\\n")
            print("[MilkdownEditor] pollContent: Updating binding with \(content.count) chars: \(pollPreview)...")
            print("[MilkdownEditor] pollContent: timeSincePush=\(String(format: "%.2f", timeSincePush))s")
            #endif

            self.lastReceivedFromEditor = Date()
            self.lastPushedContent = content
            self.contentBinding.wrappedValue = content
            self.onContentChange(content)
        }

        webView.evaluateJavaScript("window.FinalFinal.getStats()") { [weak self] result, _ in
            guard let self, !self.isCleanedUp,
                  let dict = result as? [String: Any],
                  let words = dict["words"] as? Int, let chars = dict["characters"] as? Int else { return }
            self.onStatsChange(words, chars)
        }
    }
}
