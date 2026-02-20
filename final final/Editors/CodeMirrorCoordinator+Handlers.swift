//
//  CodeMirrorCoordinator+Handlers.swift
//  final final
//
//  Content management, navigation, message handling, and polling
//  for CodeMirrorEditor.Coordinator.
//

import SwiftUI
import WebKit

extension CodeMirrorEditor.Coordinator {

    func cleanup() {
        isCleanedUp = true
        spellcheckTask?.cancel()
        spellcheckTask = nil
        pollingTimer?.invalidate()
        pollingTimer = nil
        if let observer = toggleObserver {
            NotificationCenter.default.removeObserver(observer)
            toggleObserver = nil
        }
        if let observer = insertBreakObserver {
            NotificationCenter.default.removeObserver(observer)
            insertBreakObserver = nil
        }
        if let observer = annotationDisplayModesObserver {
            NotificationCenter.default.removeObserver(observer)
            annotationDisplayModesObserver = nil
        }
        if let observer = insertAnnotationObserver {
            NotificationCenter.default.removeObserver(observer)
            insertAnnotationObserver = nil
        }
        if let observer = toggleHighlightObserver {
            NotificationCenter.default.removeObserver(observer)
            toggleHighlightObserver = nil
        }
        if let observer = spellcheckStateObserver {
            NotificationCenter.default.removeObserver(observer)
            spellcheckStateObserver = nil
        }
        if let observer = proofingModeObserver {
            NotificationCenter.default.removeObserver(observer)
            proofingModeObserver = nil
        }
        if let observer = proofingSettingsObserver {
            NotificationCenter.default.removeObserver(observer)
            proofingSettingsObserver = nil
        }
        webView = nil
    }

    func insertSectionBreak() {
        guard isEditorReady, let webView else { return }
        webView.evaluateJavaScript("window.FinalFinal.insertBreak()") { _, _ in }
    }

    func saveCursorPositionBeforeCleanup() {
        guard isEditorReady, let webView, !isCleanedUp else { return }
        webView.evaluateJavaScript("JSON.stringify(window.FinalFinal.getCursorPosition())") { [weak self] result, _ in
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let line = dict["line"] as? Int,
                  let column = dict["column"] as? Int else { return }
            self?.onCursorPositionSaved(CursorPosition(line: line, column: column))
        }
    }

    /// Save cursor and post notification for two-phase toggle
    /// IMPORTANT: Also syncs content to binding BEFORE cursor save to prevent content loss
    func saveAndNotify() {
        guard isEditorReady, let webView, !isCleanedUp else {
            // Editor not ready - post notification with start position
            NotificationCenter.default.post(
                name: .didSaveCursorPosition,
                object: nil,
                userInfo: ["position": CursorPosition.start]
            )
            return
        }

        // RACE CONDITION FIX: If we have a pending cursor restore that hasn't completed,
        // use that position instead of reading from the editor (which would return wrong value)
        if let pending = pendingCursorRestore {
            NotificationCenter.default.post(
                name: .didSaveCursorPosition,
                object: nil,
                userInfo: ["position": pending]
            )
            return
        }

        // CONTENT SYNC: Fetch and save content BEFORE cursor to prevent content loss during toggle
        webView.evaluateJavaScript("window.FinalFinal.getContent()") { [weak self] contentResult, _ in
            guard let self, !self.isCleanedUp else {
                self?.saveCursorAndNotify()
                return
            }

            if let content = contentResult as? String {
                // Update binding immediately to ensure content is preserved
                self.lastPushedContent = content
                self.contentBinding.wrappedValue = content
            }

            // Now save cursor position
            self.saveCursorAndNotify()
        }
    }

    /// Internal: save cursor position and post notification
    func saveCursorAndNotify() {
        guard let webView, !isCleanedUp else {
            NotificationCenter.default.post(
                name: .didSaveCursorPosition,
                object: nil,
                userInfo: ["position": CursorPosition.start]
            )
            return
        }

        webView.evaluateJavaScript("JSON.stringify(window.FinalFinal.getCursorPosition())") { result, _ in
            var position = CursorPosition.start
            if let json = result as? String,
               let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let line = dict["line"] as? Int,
               let column = dict["column"] as? Int {
                position = CursorPosition(line: line, column: column)
            }

            NotificationCenter.default.post(
                name: .didSaveCursorPosition,
                object: nil,
                userInfo: ["position": position]
            )
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        #if DEBUG
        print("[CodeMirrorEditor] WebView finished loading")

        webView.evaluateJavaScript("typeof window.__CODEMIRROR_SCRIPT_STARTED__") { result, _ in
            print("[CodeMirrorEditor] JS script check: \(result ?? "nil")")
        }

        webView.evaluateJavaScript("typeof window.FinalFinal") { result, _ in
            print("[CodeMirrorEditor] window.FinalFinal type: \(result ?? "nil")")
        }
        #endif

        isEditorReady = true
        batchInitialize()
        startPolling()

        // Notify parent that WebView is ready (for find operations)
        onWebViewReady?(webView)
    }

    /// Called when using a preloaded WebView (navigation already finished)
    func handlePreloadedView() {
        isEditorReady = true
        batchInitialize()
        startPolling()
        if let webView { onWebViewReady?(webView) }
    }

    /// Batch initialization - sends all setup data in a single JS call
    func batchInitialize() {
        guard let webView else { return }

        let content = contentBinding.wrappedValue

        let theme = ThemeManager.shared.cssVariables
        let cursor = cursorPositionToRestoreBinding.wrappedValue

        let cursorJS: String
        if let pos = cursor {
            cursorJS = "{line:\(pos.line),column:\(pos.column)}"
        } else {
            cursorJS = "null"
        }

        // Prevent updateNSView from calling setContent() after initialize().
        // Without this, shouldPushContent() returns true (lastPushedContent is ""),
        // and setContent() overwrites the cursor that initialize() just set.
        lastPushedContent = content
        lastPushTime = Date()
        #if DEBUG
        print("[DIAG-F2] batchInitialize: setting lastPushedContent preemptively (len=\(content.count))")
        #endif

        let escapedContent = content.escapedForJSTemplateLiteral

        let escapedTheme = theme
            .replacingOccurrences(of: "`", with: "\\`")

        let script = """
        window.FinalFinal.initialize({
            content: `\(escapedContent)`,
            theme: `\(escapedTheme)`,
            cursorPosition: \(cursorJS)
        })
        """

        webView.evaluateJavaScript(script) { [weak self] _, error in
            if let error {
                #if DEBUG
                print("[CodeMirrorEditor] Initialize error: \(error.localizedDescription)")
                #endif
                // Reset so updateNSView can retry content push
                self?.lastPushedContent = ""
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

    // Handle JS error messages and citation picker requests
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        #if DEBUG
        if message.name == "errorHandler", let body = message.body as? [String: Any] {
            let msgType = body["type"] as? String ?? "unknown"
            let errorMsg = body["message"] as? String ?? "unknown"
            print("[CodeMirrorEditor] JS \(msgType.uppercased()): \(errorMsg)")
        }
        #endif

        // Handle CAYW citation picker request from web editor
        if message.name == "openCitationPicker", let cmdStart = message.body as? Int {
            Task { @MainActor in
                await self.handleOpenCitationPicker(cmdStart: cmdStart)
            }
        }

        // Handle paint complete signal for zoom transitions
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
    @MainActor
    func handleOpenCitationPicker(cmdStart: Int) async {
        guard let webView else {
            print("[CodeMirrorEditor] handleOpenCitationPicker: webView is nil")
            return
        }

        print("[CodeMirrorEditor] Opening CAYW picker, cmdStart: \(cmdStart)")

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

            print("[CodeMirrorEditor] CAYW returned citekeys: \(parsed.citekeys)")

            // Encode CSL items as JSON for web
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let itemsData = try encoder.encode(items)
            guard let itemsJSON = String(data: itemsData, encoding: .utf8) else {
                print("[CodeMirrorEditor] Failed to encode CSL items")
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
                print("[CodeMirrorEditor] Failed to encode callback data")
                sendCitationPickerCancelled(webView: webView)
                return
            }

            // Send both parsed data and CSL items to web editor
            let escapedCallback = callbackStr.escapedForJSTemplateLiteral
            let escapedItems = itemsJSON.escapedForJSTemplateLiteral

            let script = "window.FinalFinal.citationPickerCallback(JSON.parse(`\(escapedCallback)`), JSON.parse(`\(escapedItems)`))"
            webView.evaluateJavaScript(script) { _, error in
                if let error {
                    print("[CodeMirrorEditor] citationPickerCallback error: \(error)")
                } else {
                    print("[CodeMirrorEditor] citationPickerCallback succeeded")
                }
            }
        } catch ZoteroError.userCancelled {
            NSApp.activate(ignoringOtherApps: true)
            print("[CodeMirrorEditor] CAYW cancelled by user")
            sendCitationPickerCancelled(webView: webView)
        } catch ZoteroError.notRunning {
            NSApp.activate(ignoringOtherApps: true)
            print("[CodeMirrorEditor] Zotero not running")
            showZoteroAlert(
                title: "Zotero Connection Lost",
                message: "Zotero is not running. Please open Zotero and try again."
            )
            sendCitationPickerCancelled(webView: webView)
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            print("[CodeMirrorEditor] CAYW error: \(error.localizedDescription)")
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

    /// Handle paint complete signal for zoom transitions
    /// Called after the JS double-RAF + micro-scroll pattern ensures paint is complete
    func handlePaintComplete() {
        // Show WebView now that paint is complete
        webView?.alphaValue = 1
    }

    // === Content push guard - prevent feedback loops ===
    func shouldPushContent(_ newContent: String) -> Bool {
        let timeSinceLastReceive = Date().timeIntervalSince(lastReceivedFromEditor)
        if timeSinceLastReceive < 0.6 && newContent == lastPushedContent { return false }
        return newContent != lastPushedContent
    }

    // === JavaScript API calls ===
    func setContent(_ markdown: String) {
        guard isEditorReady, let webView else { return }

        #if DEBUG
        print("[DIAG-F2] Swift setContent called (len=\(markdown.count))")
        #endif
        lastPushedContent = markdown
        lastPushTime = Date()  // Record push time to prevent poll feedback
        // Note: Escapes all $ (not just ${) for CodeMirror content
        let escaped = markdown.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        // Use the direct isZoomingContent flag instead of contentState check.
        // isZoomingContent is set in the same updateNSView cycle as the content change,
        // so it's guaranteed to be fresh (unlike contentState which may be stale due to
        // SwiftUI's reactive notification timing).
        let shouldScrollToStart = isZoomingContent
        let optionsArg = shouldScrollToStart ? ", {scrollToStart: true}" : ""

        // Hide WKWebView at compositor level during zoom transitions
        // This prevents visible scroll animation by hiding at the CALayer level
        // before any content changes, ensuring no intermediate frames are visible
        if shouldScrollToStart {
            webView.alphaValue = 0
        }

        webView.evaluateJavaScript("window.FinalFinal.setContent(`\(escaped)`\(optionsArg))") { _, _ in
            // For zoom transitions, DON'T show WebView here — wait for paintComplete message
            // The JS double-RAF + micro-scroll pattern will signal when paint is complete
            // For non-zoom content changes, WebView is already visible (no hiding was done)
        }
    }

    func setFocusMode(_ enabled: Bool) {
        guard isEditorReady, let webView else { return }
        webView.evaluateJavaScript("window.FinalFinal.setFocusMode(\(enabled))") { _, _ in }
    }

    func setSpellcheck(_ enabled: Bool) {
        guard isEditorReady, let webView else { return }
        let fn = enabled ? "enableSpellcheck" : "disableSpellcheck"
        webView.evaluateJavaScript("window.FinalFinal.\(fn)()") { _, _ in }
    }

    func triggerSpellcheck() {
        guard isEditorReady, let webView else { return }
        webView.evaluateJavaScript("window.FinalFinal.triggerSpellcheck()") { _, _ in }
    }

    func setTheme(_ cssVariables: String) {
        guard isEditorReady, let webView else { return }
        let escaped = cssVariables.replacingOccurrences(of: "`", with: "\\`")
        webView.evaluateJavaScript("window.FinalFinal.setTheme(`\(escaped)`)") { _, _ in }
    }

    func scrollToOffset(_ offset: Int) {
        guard isEditorReady, let webView else { return }
        webView.evaluateJavaScript("window.FinalFinal.scrollToOffset(\(offset))") { _, _ in }
    }

    func getCursorPosition(completion: @escaping (CursorPosition) -> Void) {
        guard isEditorReady, let webView else {
            completion(.start)
            return
        }
        webView.evaluateJavaScript("JSON.stringify(window.FinalFinal.getCursorPosition())") { result, _ in
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let line = dict["line"] as? Int,
                  let column = dict["column"] as? Int else {
                completion(.start)
                return
            }
            completion(CursorPosition(line: line, column: column))
        }
    }

    func setCursorPosition(_ position: CursorPosition, completion: (() -> Void)? = nil) {
        guard isEditorReady, let webView else {
            completion?()
            return
        }

        // Track pending cursor restore to handle race conditions with toggle
        pendingCursorRestore = position

        webView.evaluateJavaScript(
            "window.FinalFinal.setCursorPosition({line: \(position.line), column: \(position.column)})"
        ) { [weak self] _, _ in
            // Clear pending restore now that JS has executed
            self?.pendingCursorRestore = nil
            completion?()
        }
    }

    // === 500ms content polling ===
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

        // Skip polling during content transitions (zoom, hierarchy enforcement, drag)
        // This prevents stale content from overwriting newly rebuilt content
        guard contentState == .idle else { return }

        // Get raw content (including hidden anchors) for the binding
        // This preserves anchors so they travel with content during mode switches
        webView.evaluateJavaScript("window.FinalFinal.getContentRaw()") { [weak self] result, _ in
            guard let self, !self.isCleanedUp,
                  let rawContent = result as? String else { return }

            // Double-check reset flag in callback (may have changed)
            guard !self.isResettingContentBinding.wrappedValue else { return }

            // Double-check contentState in callback (may have changed during async)
            guard self.contentState == .idle else { return }

            // Grace period guard: don't overwrite recent pushes (race condition fix)
            let timeSincePush = Date().timeIntervalSince(self.lastPushTime)
            if timeSincePush < 0.3 && rawContent != self.lastPushedContent {
                return  // JS hasn't processed our push yet
            }

            guard rawContent != self.lastPushedContent else { return }

            self.lastReceivedFromEditor = Date()
            self.lastPushedContent = rawContent

            // Update binding with raw content (includes anchors)
            self.contentBinding.wrappedValue = rawContent

            // Call change handler with raw content
            // The ContentView callback will strip anchors for section sync
            self.onContentChange(rawContent)
        }

        webView.evaluateJavaScript("window.FinalFinal.getStats()") { [weak self] result, _ in
            guard let self, !self.isCleanedUp,
                  let dict = result as? [String: Any],
                  let words = dict["words"] as? Int, let chars = dict["characters"] as? Int else { return }
            self.onStatsChange(words, chars)
        }
    }

    // MARK: - Annotation API

    /// Set annotation display modes (no-op in source mode, but call for consistency)
    /// - Parameters:
    ///   - modes: Per-type display modes (inline/collapsed)
    ///   - isPanelOnly: Global toggle to hide all annotations from editor
    ///   - hideCompletedTasks: Filter to hide completed task annotations
    func setAnnotationDisplayModes(
        _ modes: [AnnotationType: AnnotationDisplayMode],
        isPanelOnly: Bool = false,
        hideCompletedTasks: Bool = false
    ) {
        guard isEditorReady, let webView else { return }

        var modeDict: [String: String] = [:]
        for (type, mode) in modes {
            modeDict[type.rawValue] = mode.rawValue
        }
        // Add special keys for global settings
        modeDict["__panelOnly"] = isPanelOnly ? "true" : "false"
        modeDict["__hideCompletedTasks"] = hideCompletedTasks ? "true" : "false"

        guard let jsonData = try? JSONSerialization.data(withJSONObject: modeDict),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        webView.evaluateJavaScript("window.FinalFinal.setAnnotationDisplayModes(\(jsonString))") { _, _ in }
    }

    /// Insert an annotation at the current cursor position
    func insertAnnotation(type: AnnotationType) {
        guard isEditorReady, let webView else { return }
        webView.evaluateJavaScript("window.FinalFinal.insertAnnotation('\(type.rawValue)')") { _, _ in }
    }

    /// Toggle highlight mark on selected text (Cmd+Shift+H)
    func toggleHighlight() {
        guard isEditorReady, let webView else { return }
        webView.evaluateJavaScript("window.FinalFinal.toggleHighlight()") { _, _ in }
    }
}
