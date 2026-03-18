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

    /// Cooldown: last time the Zotero alert was shown (prevents spam from repeated resolution failures)
    private static var lastZoteroAlertTime: Date = .distantPast

    /// Show the Zotero "not running" alert if cooldown (60s) has elapsed.
    /// Uses the same NSAlert as the CAYW picker path for consistency.
    private func showZoteroAlertIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(Self.lastZoteroAlertTime) >= 60 else { return }
        Self.lastZoteroAlertTime = now
        showZoteroAlert(
            title: "Zotero Not Running",
            message: "Zotero is not running. Please open Zotero and try again."
        )
    }

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
            DebugLog.log(.zotero, "[MilkdownEditor] Pushing \(zotero.cachedItems.count) cached CSL items to editor")
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

        DebugLog.log(.editor, "[MilkdownEditor] batchInitialize: content length=\(content.count)")

        // First check if window.FinalFinal exists
        webView.evaluateJavaScript("typeof window.FinalFinal") { [weak self] result, error in
            guard let self else { return }

            if let error {
                DebugLog.log(.editor, "[MilkdownEditor] FinalFinal check failed: \(error.localizedDescription)")
            } else {
                DebugLog.log(.editor, "[MilkdownEditor] FinalFinal type: \(result ?? "nil")")
            }

            // If FinalFinal doesn't exist yet, schedule retry
            if result as? String != "object" {
                DebugLog.log(.editor, "[MilkdownEditor] FinalFinal not ready, scheduling retry in 100ms")
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

        // When isResettingContent is true, onWebViewReady will push content via
        // setContentWithBlockIds() (which includes image metadata like width/caption).
        // Skip content here to avoid a race where initialize() overwrites the metadata.
        let effectiveContent = isResettingContentBinding.wrappedValue ? "" : content

        // Always set lastPushedContent to the REAL content (not empty), so that
        // shouldPushContent() doesn't trigger a redundant push from updateNSView.
        lastPushedContent = content
        lastPushTime = Date()

        // Use cursorIsVisible to decide restore strategy:
        // - Cursor NOT visible (scrolled away or never clicked) + has topLine → restore scroll position
        // - Cursor IS visible → restore cursor + center on it
        let useScrollRestore = cursor.map { !$0.cursorIsVisible && $0.topLine > 1.0 } ?? false

        DebugLog.log(.editor, "[batchInitialize] isResettingContent=\(isResettingContentBinding.wrappedValue), content=\(content.count), effective=\(effectiveContent.count)")

        // Build options dictionary for JSON encoding
        // Using JSON instead of template literals handles ALL special characters safely
        var options: [String: Any] = [
            "content": effectiveContent,
            "theme": theme
        ]
        if let pos = cursor, !useScrollRestore {
            options["cursorPosition"] = ["line": pos.line, "column": pos.column]
        } else {
            // Don't pass cursor — prevents setCursorPosition(1,0) + scrollCursorToCenter
            options["cursorPosition"] = NSNull()
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: options),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            DebugLog.log(.editor, "[MilkdownEditor] Failed to encode options as JSON")
            return
        }

        DebugLog.log(.editor, "[MilkdownEditor] Initialize with content length: \(content.count) chars")

        // Pass JSON directly - JSON is valid JavaScript object literal syntax
        let script = "window.FinalFinal.initialize(\(jsonString))"

        webView.evaluateJavaScript(script) { [weak self] _, error in
            if let error {
                DebugLog.log(.editor, "[MilkdownEditor] Initialize error: \(error.localizedDescription)")
                // Check if it's a parsing error by trying to set empty content
                webView.evaluateJavaScript("window.FinalFinal.setContent('')") { _, err2 in
                    if let err2 {
                        DebugLog.log(.editor, "[MilkdownEditor] Even empty setContent failed: \(err2.localizedDescription)")
                    } else {
                        DebugLog.log(.editor, "[MilkdownEditor] Empty setContent worked - content may have parse issue")
                    }
                }
                // DEFENSIVE: If initialization failed, mark editor as NOT ready
                // so polling won't try to read from broken editor
                self?.isEditorReady = false
            } else {
                DebugLog.log(.editor, "[MilkdownEditor] Initialize successful")
            }
            // Only clear cursor binding if we actually pushed content.
            // When isResettingContent is true, content was skipped and cursor
            // will be restored after setContentWithBlockIds() via restoreCursorPositionIfNeeded().
            if !effectiveContent.isEmpty {
                // Restore scroll position when cursor is not visible (only if content was pushed)
                if useScrollRestore, let topLine = cursor?.topLine, topLine > 1.0 {
                    self?.scrollToLine(topLine)
                }

                self?.cursorPositionToRestoreBinding.wrappedValue = nil
            }
        }
    }

    /// Focus the editor so user can start typing immediately
    func focusEditor() {
        guard isEditorReady, let webView else { return }
        webView.evaluateJavaScript("window.FinalFinal.focus()") { _, _ in }
    }

    func restoreCursorPositionIfNeeded() {
        guard let position = cursorPositionToRestoreBinding.wrappedValue else { return }
        cursorPositionToRestoreBinding.wrappedValue = nil

        let useScrollRestore = !position.cursorIsVisible && position.topLine > 1.0

        if useScrollRestore {
            // Cursor not visible — restore scroll position only
            scrollToLine(position.topLine)
        } else if position.line != 1 || position.column != 0 {
            // Cursor was placed and is visible — set cursor and center on it
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.setCursorPosition(position) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.scrollCursorToCenter()
                    }
                }
            }
        }
        // Default cursor at top with scrollFraction 0 — do nothing
    }

    func scrollCursorToCenter() {
        guard isEditorReady, let webView else { return }
        webView.evaluateJavaScript("window.FinalFinal.scrollCursorToCenter()") { _, _ in }
    }

    func scrollToFraction(_ fraction: Double) {
        guard isEditorReady, let webView else { return }
        guard fraction.isFinite else { return }
        let clamped = max(0, min(1, fraction))
        webView.evaluateJavaScript("window.FinalFinal.scrollToFraction(\(clamped))") { _, _ in }
    }

    func scrollToLine(_ line: Double) {
        guard isEditorReady, let webView else { return }
        guard line > 0, line.isFinite else { return }
        webView.evaluateJavaScript("window.FinalFinal.scrollToLine(\(line))") { _, _ in }
    }

    // Handle JS messages from WKScriptMessageHandler
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Hot path: push-based section change from JS (instant sidebar highlight)
        if message.name == "sectionChanged",
           let data = message.body as? [String: Any] {
            let title = (data["title"] as? String) ?? ""
            let blockId = data["blockId"] as? String
            Task { @MainActor in
                guard self.contentState == .idle else { return }
                guard !self.isResettingContentBinding.wrappedValue else { return }
                self.onSectionChange(title)
                self.onSectionIdChange?(blockId, title)
            }
            return
        }

        // Hot path: push-based content change from JS (replaces polling as primary)
        if message.name == "contentChanged", let content = message.body as? String {
            Task { @MainActor in
                self.handleContentPush(content)
            }
            return
        }

        // DebugLog handles #if DEBUG gating internally
        if message.name == "errorHandler", let body = message.body as? [String: Any] {
            let msgType = body["type"] as? String ?? "unknown"
            let msg = body["message"] as? String ?? "unknown"
            let prefix = "[MilkdownEditor]"

            switch msgType {
            case "sync-diag":
                DebugLog.log(.sync, "\(prefix) JS SYNC-DIAG: \(msg)")
            case "debug", "slash-diag":
                DebugLog.log(.editor, "\(prefix) JS \(msgType.uppercased()): \(msg)")
            case "plugin-error", "unhandledrejection", "error":
                DebugLog.log(.editor, "\(prefix) JS ERROR: \(msg)")
            default:
                DebugLog.log(.editor, "\(prefix) JS \(msgType.uppercased()): \(msg)")
            }
        }

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

        // Handle footnote inserted notification from JS (slash command or evaluateJavaScript path)
        // Sync editor content BEFORE posting notification to prevent stale DB body overwrite
        if message.name == "footnoteInserted", let body = message.body as? [String: Any],
           let label = body["label"] as? String, !label.isEmpty {
            Task { @MainActor [weak self] in
                guard let self, let webView = self.webView else { return }
                webView.evaluateJavaScript("window.FinalFinal.getContent()") { [weak self] result, _ in
                    guard let self, let content = result as? String else { return }
                    Task { @MainActor in
                        self.lastPushedContent = content
                        self.lastReceivedFromEditor = Date()
                        self.contentBinding.wrappedValue = content
                        NotificationCenter.default.post(
                            name: .footnoteInsertedImmediate, object: nil,
                            userInfo: ["label": label]
                        )
                    }
                }
            }
        }

        // Handle footnote navigation requests from editor
        if message.name == "navigateToFootnote", let body = message.body as? [String: Any] {
            Task { @MainActor in
                guard let label = body["label"] as? String,
                      let direction = body["direction"] as? String else { return }
                self.handleNavigateToFootnote(label: label, direction: direction)
            }
        }

        // Handle image paste from editor (base64 data)
        if message.name == "pasteImage", let body = message.body as? [String: Any] {
            Task { @MainActor in
                self.handlePasteImage(body)
            }
        }

        // Handle image picker request from editor
        if message.name == "requestImagePicker" {
            Task { @MainActor in
                self.handleImagePicker()
            }
        }

        // Handle image metadata update from editor (caption, alt, width)
        if message.name == "updateImageMeta", let body = message.body as? [String: Any] {
            Task { @MainActor in
                self.handleUpdateImageMeta(body)
            }
        }

        // Handle spellcheck messages from editor
        if message.name == "spellcheck" {
            Task { @MainActor in
                guard let body = message.body as? [String: Any],
                      let action = body["action"] as? String else { return }

                switch action {
                case "check":
                    guard let segmentsData = body["segments"] as? [[String: Any]],
                          let requestId = body["requestId"] as? Int else { return }
                    let segments = segmentsData.compactMap { dict -> SpellCheckService.TextSegment? in
                        guard let text = dict["text"] as? String,
                              let from = dict["from"] as? Int,
                              let to = dict["to"] as? Int else { return nil }
                        let blockId = dict["blockId"] as? Int
                        return SpellCheckService.TextSegment(text: text, from: from, to: to, blockId: blockId)
                    }
                    self.spellcheckTask?.cancel()
                    self.spellcheckTask = Task {
                        let results = await SpellCheckService.shared.check(segments: segments)
                        guard !Task.isCancelled else { return }
                        let encoder = JSONEncoder()
                        guard let data = try? encoder.encode(results),
                              let json = String(data: data, encoding: .utf8) else { return }
                        let escaped = json.escapedForJSTemplateLiteral
                        self.webView?.evaluateJavaScript(
                            "window.FinalFinal.setSpellcheckResults(\(requestId), JSON.parse(`\(escaped)`))"
                        ) { _, _ in }
                    }

                case "learn":
                    guard let word = body["word"] as? String else { return }
                    SpellCheckService.shared.learnWord(word)

                case "ignore":
                    guard let word = body["word"] as? String else { return }
                    SpellCheckService.shared.ignoreWord(word)

                case "disableRule":
                    guard let ruleId = body["ruleId"] as? String else { return }
                    ProofingSettings.shared.disableRule(ruleId)
                    NotificationCenter.default.post(name: .proofingSettingsChanged, object: nil)

                default: break
                }
            }
        }
    }

    /// Handle footnote navigation — find offset of target and scroll to it
    @MainActor
    func handleNavigateToFootnote(label: String, direction: String) {
        // Get current content from the binding to search for offset
        let content = contentBinding.wrappedValue

        if direction == "toDefinition" {
            // Find [^N]: definition in #Notes section
            let pattern = "[^\(label)]:"
            if let range = content.range(of: pattern) {
                let offset = content.distance(from: content.startIndex, to: range.lowerBound)
                scrollToOffset(offset)
            }
        } else if direction == "toReference" {
            // Find first [^N] reference in document body (not in #Notes)
            // Use regex to match [^N] but NOT [^N]:
            let pattern = "\\[\\^\(label)\\](?!:)"
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) {
                let offset = match.range.location
                scrollToOffset(offset)
            }
        }
    }

    /// Handle citation search request from web editor
    /// Splits multi-term queries: first term goes to BBT, additional terms filter client-side
    @MainActor
    func handleCitationSearch(_ query: String) async {
        guard let webView else { return }

        DebugLog.log(.zotero, "[MilkdownEditor] Citation search: '\(query)'")

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

            DebugLog.log(.zotero, "[MilkdownEditor] Search returned \(items.count) results (filter terms: \(filterTerms))")

            // Encode results as JSON
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(items)
            guard let jsonString = String(data: data, encoding: .utf8) else {
                sendCitationSearchCallback(webView: webView, json: "[]")
                return
            }

            sendCitationSearchCallback(webView: webView, json: jsonString)
        } catch ZoteroError.notRunning {
            DebugLog.log(.zotero, "[MilkdownEditor] Citation search: Zotero not running")
            showZoteroAlertIfNeeded()
            sendCitationSearchCallback(webView: webView, json: "[]")
        } catch ZoteroError.networkError(_) {
            DebugLog.log(.zotero, "[MilkdownEditor] Citation search: network error")
            showZoteroAlertIfNeeded()
            sendCitationSearchCallback(webView: webView, json: "[]")
        } catch ZoteroError.noResponse {
            DebugLog.log(.zotero, "[MilkdownEditor] Citation search: no response")
            showZoteroAlertIfNeeded()
            sendCitationSearchCallback(webView: webView, json: "[]")
        } catch {
            DebugLog.log(.zotero, "[MilkdownEditor] Citation search error: \(error.localizedDescription)")
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
            DebugLog.log(.zotero, "[MilkdownEditor] handleResolveCitekeys: webView or editor not ready")
            return
        }

        guard !citekeys.isEmpty else { return }

        DebugLog.log(.zotero, "[MilkdownEditor] Resolving \(citekeys.count) citekeys: \(citekeys)")

        do {
            // Fetch CSL items from Zotero via BBT
            let items = try await ZoteroService.shared.fetchItemsForCitekeys(citekeys)

            guard !items.isEmpty else {
                DebugLog.log(.zotero, "[MilkdownEditor] No items found for citekeys")
                return
            }

            DebugLog.log(.zotero, "[MilkdownEditor] Resolved \(items.count) items")

            // Encode as JSON
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(items)
            guard let json = String(data: data, encoding: .utf8) else {
                DebugLog.log(.zotero, "[MilkdownEditor] Failed to encode items as JSON")
                return
            }

            // Push items to editor
            addCitationItems(json)
        } catch ZoteroError.notRunning {
            DebugLog.log(.zotero, "[MilkdownEditor] Zotero not running - cannot resolve citekeys")
            // Confirm with a real ping before alerting (isConnected defaults to false at launch)
            let actuallyDown = !(await ZoteroService.shared.ping())
            if actuallyDown {
                showZoteroAlertIfNeeded()
            }
        } catch {
            DebugLog.log(.zotero, "[MilkdownEditor] Failed to resolve citekeys: \(error.localizedDescription)")
            // Don't show "Zotero not running" for decoding/format errors
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
            DebugLog.log(.zotero, "[MilkdownEditor] refreshAllCitations: editor not ready")
            return
        }

        DebugLog.log(.zotero, "[MilkdownEditor] Refreshing all citations...")

        // Get all citekeys from the document
        webView.evaluateJavaScript("JSON.stringify(window.FinalFinal.getAllCitekeys())") { [weak self] result, error in
            guard let self else { return }

            if let error {
                DebugLog.log(.zotero, "[MilkdownEditor] Failed to get citekeys: \(error.localizedDescription)")
                return
            }

            guard let jsonString = result as? String,
                  let data = jsonString.data(using: .utf8),
                  let citekeys = try? JSONDecoder().decode([String].self, from: data) else {
                DebugLog.log(.zotero, "[MilkdownEditor] Failed to decode citekeys")
                return
            }

            guard !citekeys.isEmpty else {
                DebugLog.log(.zotero, "[MilkdownEditor] No citations in document")
                return
            }

            DebugLog.log(.zotero, "[MilkdownEditor] Found \(citekeys.count) citekeys to refresh: \(citekeys)")

            // Fetch all citekeys from Zotero
            Task { @MainActor in
                await self.handleResolveCitekeys(citekeys)
            }
        }
    }

    // MARK: - Push-based content messaging

    /// Handle content pushed from JS via window.webkit.messageHandlers.contentChanged
    /// This is the primary content sync path (replaces 500ms polling)
    func handleContentPush(_ content: String) {
        guard !self.isCleanedUp, self.isEditorReady else { return }
        guard !self.isResettingContentBinding.wrappedValue else { return }
        guard self.contentState == .idle else {
            DebugLog.log(.sync, "[SYNC-DIAG:ContentPush] REJECTED: contentState=\(self.contentState)")
            return
        }

        // Grace period: 200ms for push-based flow (reduced from 600ms polling)
        let timeSincePush = Date().timeIntervalSince(self.lastPushTime)
        if timeSincePush < 0.2 && content != self.lastPushedContent { return }
        guard content != self.lastPushedContent else { return }

        // Corruption check (Milkdown-specific)
        let pushedFirstLine = self.lastPushedContent.components(separatedBy: "\n").first ?? ""
        let receivedFirstLine = content.components(separatedBy: "\n").first ?? ""
        if pushedFirstLine.hasPrefix("#") && receivedFirstLine.hasPrefix("<br") { return }

        DebugLog.log(.sync, "[SYNC-DIAG:ContentPush] ACCEPTED: len=\(content.count) firstH=\"\(content.components(separatedBy: "\n").first(where: { $0.hasPrefix("#") })?.prefix(60) ?? "(none)")\"")
        self.lastReceivedFromEditor = Date()
        self.lastPushedContent = content
        self.contentBinding.wrappedValue = content
        self.onContentChange(content)
    }

    // MARK: - 3s Fallback Polling (stats + section title only)

    func startPolling() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollContent()
            }
        }
    }

    func pollContent() {
        guard !isCleanedUp, isEditorReady, let webView else { return }

        // Skip polling during content reset (project switch)
        guard !isResettingContentBinding.wrappedValue else {
            DebugLog.log(.sync, "[SYNC-DIAG:Poll] SKIPPED: isResettingContent=true")
            return
        }

        // Skip polling during content transitions (zoom, hierarchy enforcement)
        guard contentState == .idle else {
            DebugLog.log(.sync, "[SYNC-DIAG:Poll] SKIPPED: contentState=\(contentState)")
            return
        }

        let generationAtPoll = contentGeneration  // Capture BEFORE async call

        // Batched poll: stats + section title in a single JS call
        webView.evaluateJavaScript("window.FinalFinal.getPollData()") { [weak self] result, _ in
            guard let self, !self.isCleanedUp else { return }
            // Discard stale result if a state transition happened during the JS roundtrip
            guard self.contentGeneration == generationAtPoll else {
                DebugLog.log(.sync, "[MilkdownPoll] Discarded stale result (gen \(generationAtPoll) != \(self.contentGeneration))")
                return
            }
            guard let jsonString = result as? String,
                  let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            if let stats = json["stats"] as? [String: Any],
               let words = stats["words"] as? Int,
               let chars = stats["characters"] as? Int {
                self.onStatsChange(words, chars)
            }

            let sectionTitle = (json["sectionTitle"] as? String) ?? ""
            let sectionBlockId = json["sectionBlockId"] as? String
            self.onSectionChange(sectionTitle)
            self.onSectionIdChange?(sectionBlockId, sectionTitle)
        }
    }

    // MARK: - Image Handling

    /// Handle pasted image data from JS (base64-encoded)
    @MainActor
    func handlePasteImage(_ body: [String: Any]) {
        guard let base64Data = body["data"] as? String,
              let data = Data(base64Encoded: base64Data) else {
            DebugLog.log(.editor, "[MilkdownEditor] Invalid paste image data")
            return
        }

        let mimeType = body["type"] as? String
        let suggestedName = body["name"] as? String

        guard let mediaDir = MediaSchemeHandler.shared.mediaDirectoryURL else {
            DebugLog.log(.editor, "[MilkdownEditor] No media directory — cannot paste image")
            return
        }

        do {
            let relativePath = try ImageImportService.importFromData(
                data, suggestedName: suggestedName, mimeType: mimeType, mediaDir: mediaDir
            )

            // Create image block in database
            insertImageBlock(src: relativePath, alt: suggestedName ?? "")
        } catch {
            DebugLog.log(.editor, "[MilkdownEditor] Image paste failed: \(error.localizedDescription)")
            let window = webView?.window ?? NSApp.keyWindow
            if let window {
                let alert = NSAlert()
                alert.messageText = "Image Import Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window)
            }
        }
    }

    /// Handle native file picker request
    @MainActor
    func handleImagePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImageImportService.allowedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select an image to insert"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let mediaDir = MediaSchemeHandler.shared.mediaDirectoryURL else {
            DebugLog.log(.editor, "[MilkdownEditor] No media directory — cannot import image")
            return
        }

        do {
            let relativePath = try ImageImportService.importFromURL(url, mediaDir: mediaDir)
            let alt = (url.lastPathComponent as NSString).deletingPathExtension
            insertImageBlock(src: relativePath, alt: alt)
        } catch {
            DebugLog.log(.editor, "[MilkdownEditor] Image import failed: \(error.localizedDescription)")
            let window = webView?.window ?? NSApp.keyWindow
            if let window {
                let alert = NSAlert()
                alert.messageText = "Image Import Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window)
            }
        }
    }

    /// Handle image metadata update from JS (caption, alt, width)
    @MainActor
    func handleUpdateImageMeta(_ body: [String: Any]) {
        guard let blockId = body["blockId"] as? String else {
            DebugLog.log(.editor, "[MilkdownEditor] updateImageMeta missing blockId")
            return
        }

        guard let db = DocumentManager.shared.projectDatabase else { return }

        do {
            try db.updateBlockImageMeta(
                id: blockId,
                imageSrc: body["src"] as? String,
                imageAlt: body["alt"] as? String,
                imageCaption: body["caption"] as? String,
                imageWidth: body["width"] as? Int
            )
        } catch {
            DebugLog.log(.editor, "[MilkdownEditor] Failed to update image meta: \(error)")
        }
    }

    /// Insert figure node into editor via JS (editor-first approach).
    /// No DB write — BlockSyncService detects the new node on its next poll
    /// and creates the block record via the normal insert path.
    @MainActor
    private func insertImageBlock(src: String, alt: String) {
        let escapedAlt = alt.escapedForJSTemplateLiteral
        webView?.evaluateJavaScript(
            "window.FinalFinal.insertImage && window.FinalFinal.insertImage({src: `\(src)`, alt: `\(escapedAlt)`, caption: '', width: null, blockId: ''})"
        ) { _, error in
            if let error {
                DebugLog.log(.editor, "[MilkdownEditor] insertImage JS error: \(error)")
            }
        }
    }
}
