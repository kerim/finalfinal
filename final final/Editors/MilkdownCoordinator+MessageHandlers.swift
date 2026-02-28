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
        // Hot path: push-based content change from JS (replaces polling as primary)
        if message.name == "contentChanged", let content = message.body as? String {
            Task { @MainActor in
                self.handleContentPush(content)
            }
            return
        }

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
        } catch ZoteroError.notRunning {
            print("[MilkdownEditor] Citation search: Zotero not running")
            showZoteroAlertIfNeeded()
            sendCitationSearchCallback(webView: webView, json: "[]")
        } catch ZoteroError.networkError(_) {
            print("[MilkdownEditor] Citation search: network error")
            showZoteroAlertIfNeeded()
            sendCitationSearchCallback(webView: webView, json: "[]")
        } catch ZoteroError.noResponse {
            print("[MilkdownEditor] Citation search: no response")
            showZoteroAlertIfNeeded()
            sendCitationSearchCallback(webView: webView, json: "[]")
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
            // Confirm with a real ping before alerting (isConnected defaults to false at launch)
            let actuallyDown = !(await ZoteroService.shared.ping())
            if actuallyDown {
                showZoteroAlertIfNeeded()
            }
        } catch {
            print("[MilkdownEditor] Failed to resolve citekeys: \(error.localizedDescription)")
            showZoteroAlertIfNeeded()
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

    // MARK: - Push-based content messaging

    /// Handle content pushed from JS via window.webkit.messageHandlers.contentChanged
    /// This is the primary content sync path (replaces 500ms polling)
    func handleContentPush(_ content: String) {
        guard !self.isCleanedUp, self.isEditorReady else { return }
        guard !self.isResettingContentBinding.wrappedValue else { return }
        guard self.contentState == .idle else { return }

        // Grace period: 200ms for push-based flow (reduced from 600ms polling)
        let timeSincePush = Date().timeIntervalSince(self.lastPushTime)
        if timeSincePush < 0.2 && content != self.lastPushedContent { return }
        guard content != self.lastPushedContent else { return }

        // Corruption check (Milkdown-specific)
        let pushedFirstLine = self.lastPushedContent.components(separatedBy: "\n").first ?? ""
        let receivedFirstLine = content.components(separatedBy: "\n").first ?? ""
        if pushedFirstLine.hasPrefix("#") && receivedFirstLine.hasPrefix("<br") { return }

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
        guard !isResettingContentBinding.wrappedValue else { return }

        // Skip polling during content transitions (zoom, hierarchy enforcement)
        guard contentState == .idle else { return }

        // Batched poll: stats + section title in a single JS call
        webView.evaluateJavaScript("window.FinalFinal.getPollData()") { [weak self] result, _ in
            guard let self, !self.isCleanedUp,
                  let jsonString = result as? String,
                  let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            if let stats = json["stats"] as? [String: Any],
               let words = stats["words"] as? Int,
               let chars = stats["characters"] as? Int {
                self.onStatsChange(words, chars)
            }

            self.onSectionChange((json["sectionTitle"] as? String) ?? "")
        }
    }

    // MARK: - Image Handling

    /// Handle pasted image data from JS (base64-encoded)
    @MainActor
    func handlePasteImage(_ body: [String: Any]) {
        guard let base64Data = body["data"] as? String,
              let data = Data(base64Encoded: base64Data) else {
            print("[MilkdownEditor] Invalid paste image data")
            return
        }

        let mimeType = body["type"] as? String
        let suggestedName = body["name"] as? String

        guard let mediaDir = MediaSchemeHandler.shared.mediaDirectoryURL else {
            print("[MilkdownEditor] No media directory — cannot paste image")
            return
        }

        do {
            let relativePath = try ImageImportService.importFromData(
                data, suggestedName: suggestedName, mimeType: mimeType, mediaDir: mediaDir
            )

            // Create image block in database
            insertImageBlock(src: relativePath, alt: suggestedName ?? "")
        } catch {
            print("[MilkdownEditor] Image paste failed: \(error.localizedDescription)")
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
            print("[MilkdownEditor] No media directory — cannot import image")
            return
        }

        do {
            let relativePath = try ImageImportService.importFromURL(url, mediaDir: mediaDir)
            let alt = (url.lastPathComponent as NSString).deletingPathExtension
            insertImageBlock(src: relativePath, alt: alt)
        } catch {
            print("[MilkdownEditor] Image import failed: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Image Import Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// Handle image metadata update from JS (caption, alt, width)
    @MainActor
    func handleUpdateImageMeta(_ body: [String: Any]) {
        guard let blockId = body["blockId"] as? String else {
            print("[MilkdownEditor] updateImageMeta missing blockId")
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
            print("[MilkdownEditor] Failed to update image meta: \(error)")
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
                print("[MilkdownEditor] insertImage JS error: \(error)")
            }
        }
    }
}
