//
//  CodeMirrorCoordinator+Handlers.swift
//  final final
//
//  Content sync, polling, cursor/scroll management, and the annotation/footnote/
//  formatting command API for CodeMirrorEditor.Coordinator. WKScriptMessageHandler
//  dispatch lives in CodeMirrorCoordinator+MessageDispatch.swift.
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
        clearObserver(&toggleObserver)
        clearObserver(&insertBreakObserver)
        clearObserver(&annotationDisplayModesObserver)
        clearObserver(&insertAnnotationObserver)
        clearObserver(&toggleHighlightObserver)
        clearObserver(&spellcheckStateObserver)
        clearObserver(&proofingModeObserver)
        clearObserver(&proofingSettingsObserver)
        clearObserver(&insertFootnoteObserver)
        clearObserver(&renumberFootnotesObserver)
        clearObserver(&scrollToFootnoteDefObserver)
        clearObserver(&insertImageObserver)
        clearObserver(&insertTableObserver)
        clearObserver(&insertEquationObserver)
        // Formatting command observers cleanup (also covers smartQuotesStateObserver and
        // zoomFootnoteStateObserver, previously missed here despite being removed in deinit)
        clearObserver(&toggleBoldObserver)
        clearObserver(&toggleItalicObserver)
        clearObserver(&toggleStrikethroughObserver)
        clearObserver(&setHeadingObserver)
        clearObserver(&toggleBulletListObserver)
        clearObserver(&toggleNumberListObserver)
        clearObserver(&toggleBlockquoteObserver)
        clearObserver(&toggleCodeBlockObserver)
        clearObserver(&toggleInlineCodeObserver)
        clearObserver(&insertLinkObserver)
        clearObserver(&insertCitationObserver)
        clearObserver(&smartQuotesStateObserver)
        clearObserver(&zoomFootnoteStateObserver)
        // Unregister all WKScriptMessageHandler channels registered in registerMessageHandlers(on:includeTableInsertTruncated:)
        // — without this, the WKUserContentController keeps a strong reference to this
        // Coordinator (via `controller.add(self, name:)`) and it is never deallocated.
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView = nil
    }

    /// Remove `observer` from NotificationCenter (if still registered) and nil out the
    /// stored token. Used by `cleanup()`, which — unlike `deinit` — can run while the
    /// instance is still alive, so the tokens must be cleared to avoid double-removal.
    private func clearObserver(_ observer: inout NSObjectProtocol?) {
        if let unwrapped = observer {
            NotificationCenter.default.removeObserver(unwrapped)
        }
        observer = nil
    }

    /// Execute a formatting command via window.FinalFinal API
    func executeFormatting(_ method: String, argument: String? = nil) {
        guard isEditorReady, let webView else { return }
        let script: String
        if let arg = argument {
            script = "window.FinalFinal.\(method)(\(arg))"
        } else {
            script = "window.FinalFinal.\(method)()"
        }
        webView.evaluateJavaScript(script) { _, _ in }
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
            let scrollFraction = dict["scrollFraction"] as? Double ?? 0
            let cursorIsVisible = dict["cursorIsVisible"] as? Bool ?? true
            let topLine = dict["topLine"] as? Double ?? 1.0
            self?.onCursorPositionSaved(CursorPosition(
                line: line, column: column, scrollFraction: scrollFraction,
                cursorIsVisible: cursorIsVisible, topLine: topLine
            ))
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
            DebugLog.log(.editor,
                "[CURSOR-SYNC] CM.saveAndNotify: pendingRestore line=\(pending.line) col=\(pending.column)")
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
                DebugLog.log(.sync, "[CM-SAVE+NOTIFY] getContent returned length=\(content.count)")
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
                let scrollFraction = dict["scrollFraction"] as? Double ?? 0
                let cursorIsVisible = dict["cursorIsVisible"] as? Bool ?? true
                let topLine = dict["topLine"] as? Double ?? 1.0
                position = CursorPosition(
                    line: line, column: column, scrollFraction: scrollFraction,
                    cursorIsVisible: cursorIsVisible, topLine: topLine
                )
            }

            DebugLog.log(.editor,
                "[CURSOR-SYNC] CM.saveCursor: line=\(position.line) col=\(position.column) visible=\(position.cursorIsVisible)")

            NotificationCenter.default.post(
                name: .didSaveCursorPosition,
                object: nil,
                userInfo: ["position": position]
            )
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DebugLog.log(.editor, "[CodeMirrorEditor] WebView finished loading")

        webView.evaluateJavaScript("typeof window.__CODEMIRROR_SCRIPT_STARTED__") { result, _ in
            DebugLog.log(.editor, "[CodeMirrorEditor] JS script check: \(result ?? "nil")")
        }

        webView.evaluateJavaScript("typeof window.FinalFinal") { result, _ in
            DebugLog.log(.editor, "[CodeMirrorEditor] window.FinalFinal type: \(result ?? "nil")")
        }

        isEditorReady = true
        applyPersistedToggleStates()
        onWebViewReady?(webView)    // Push image meta first (FIFO guarantees execution order)
        batchInitialize()            // Then push content (decorations build with metadata present)
        startPolling()
    }

    /// Called when using a preloaded WebView (navigation already finished)
    func handlePreloadedView() {
        isEditorReady = true
        applyPersistedToggleStates()
        if let webView { onWebViewReady?(webView) }    // Push image meta first
        batchInitialize()                                // Then push content
        startPolling()
    }

    /// Batch initialization - sends all setup data in a single JS call
    func batchInitialize() {
        guard let webView else { return }

        let content = contentBinding.wrappedValue

        let theme = ThemeManager.shared.cssVariables
        let cursor = cursorPositionToRestoreBinding.wrappedValue

        // Use cursorIsVisible to decide restore strategy:
        // - Cursor NOT visible (scrolled away or never clicked) + has topLine → restore scroll position
        // - Cursor IS visible → restore cursor + center on it
        let useScrollRestore = cursor.map { !$0.cursorIsVisible && $0.topLine > 1.0 } ?? false

        let cursorJS: String
        if let pos = cursor, !useScrollRestore {
            cursorJS = "{line:\(pos.line),column:\(pos.column)}"
        } else {
            // Don't pass cursor — prevents setCursorPosition(1,0) + scrollCursorToCenter
            cursorJS = "null"
        }

        // Prevent updateNSView from calling setContent() after initialize().
        // Without this, shouldPushContent() returns true (lastPushedContent is ""),
        // and setContent() overwrites the cursor that initialize() just set.
        lastPushedContent = content
        lastPushTime = Date()
        DebugLog.log(.sync, "[DIAG-F2] batchInitialize: setting lastPushedContent preemptively (len=\(content.count))")

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
                let nsError = error as NSError
                DebugLog.log(.editor, "[CodeMirrorEditor] Initialize error: \(nsError.localizedDescription)")
                if let message = nsError.userInfo["WKJavaScriptExceptionMessage"] {
                    DebugLog.log(.editor, "[CodeMirrorEditor] JS Exception: \(message)")
                }
                if let line = nsError.userInfo["WKJavaScriptExceptionLineNumber"] {
                    DebugLog.log(.editor, "[CodeMirrorEditor] JS Line: \(line)")
                }
                if let column = nsError.userInfo["WKJavaScriptExceptionColumnNumber"] {
                    DebugLog.log(.editor, "[CodeMirrorEditor] JS Column: \(column)")
                }
                if let sourceURL = nsError.userInfo["WKJavaScriptExceptionSourceURL"] {
                    DebugLog.log(.editor, "[CodeMirrorEditor] JS Source: \(sourceURL)")
                }
                // Reset so updateNSView can retry content push
                self?.lastPushedContent = ""
            }

            // Restore scroll position when cursor is not visible
            if useScrollRestore, let topLine = cursor?.topLine, topLine > 1.0 {
                self?.scrollToLine(topLine)
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

    /// Handle paint complete signal for zoom transitions
    /// Called after the JS double-RAF + micro-scroll pattern ensures paint is complete
    func handlePaintComplete() {
        // Show WebView now that paint is complete
        webView?.alphaValue = 1

        // Call acknowledgement callback if registered (for zoom sync)
        if let callback = onContentAcknowledged {
            onContentAcknowledged = nil  // One-shot callback
            callback()
        }
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

        DebugLog.log(.sync, "[DIAG-F2] Swift setContent called (len=\(markdown.count))")
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

        webView.evaluateJavaScript("window.FinalFinal.setContent(`\(escaped)`\(optionsArg))") { [weak self] _, _ in
            // For zoom transitions, DON'T show WebView here — wait for paintComplete message
            // The JS double-RAF + micro-scroll pattern will signal when paint is complete
            if !shouldScrollToStart {
                // For non-zoom content changes, call acknowledgement immediately
                if let callback = self?.onContentAcknowledged {
                    self?.onContentAcknowledged = nil  // One-shot callback
                    callback()
                }
            }
        }
    }

    func setFocusMode(_ enabled: Bool) {
        guard isEditorReady, let webView else { return }
        webView.evaluateJavaScript("window.FinalFinal.setFocusMode(\(enabled))") { _, _ in }
    }

    func setSpellcheck(_ enabled: Bool) {
        guard isEditorReady, let webView else { return }
        let jsFunctionName = enabled ? "enableSpellcheck" : "disableSpellcheck"
        webView.evaluateJavaScript("window.FinalFinal.\(jsFunctionName)()") { _, _ in }
    }

    func setSmartQuotes(_ enabled: Bool) {
        guard isEditorReady, let webView else { return }
        let jsFunctionName = enabled ? "enableSmartQuotes" : "disableSmartQuotes"
        webView.evaluateJavaScript("window.FinalFinal.\(jsFunctionName)()") { _, _ in }
    }

    /// Applies the persisted spellcheck/smart-quotes toggle state to this editor instance.
    /// Each fresh WKWebView (new load, or a preloaded instance just claimed from
    /// EditorPreloader) starts its JS module state at the default (enabled), independent
    /// of whatever the Edit menu currently shows. The one-shot app-launch notification only
    /// reaches whichever coordinator happens to exist at that moment — every editor created
    /// later (e.g. every WYSIWYG/Source mode switch creates a fresh Coordinator+WKWebView)
    /// never received it. Call this whenever isEditorReady flips true, not just on launch.
    func applyPersistedToggleStates() {
        let spellingOn = UserDefaults.standard.bool(forKey: "isSpellingEnabled", defaultingTo: true)
        let grammarOn = UserDefaults.standard.bool(forKey: "isGrammarEnabled", defaultingTo: true)
        setSpellcheck(spellingOn || grammarOn)
        setSmartQuotes(UserDefaults.standard.bool(forKey: "isSmartQuotesEnabled", defaultingTo: true))
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

    func scrollToAnnotation(index: Int) {
        guard isEditorReady, let webView else { return }
        webView.evaluateJavaScript("window.FinalFinal.scrollToAnnotation(\(index))") { _, _ in }
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
            let scrollFraction = dict["scrollFraction"] as? Double ?? 0
            let cursorIsVisible = dict["cursorIsVisible"] as? Bool ?? true
            let topLine = dict["topLine"] as? Double ?? 1.0
            completion(CursorPosition(line: line, column: column, scrollFraction: scrollFraction, cursorIsVisible: cursorIsVisible, topLine: topLine))
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

    // MARK: - Push-based content messaging

    /// Handle content pushed from JS via window.webkit.messageHandlers.contentChanged
    func handleContentPush(_ content: String) {
        guard !self.isCleanedUp, self.isEditorReady else { return }
        guard !self.isResettingContentBinding.wrappedValue else { return }
        guard self.contentState == .idle else { return }

        // Grace period: 150ms for push-based flow (reduced from 300ms polling)
        let timeSincePush = Date().timeIntervalSince(self.lastPushTime)
        if timeSincePush < 0.15 && content != self.lastPushedContent { return }
        guard content != self.lastPushedContent else { return }

        self.lastReceivedFromEditor = Date()
        self.lastPushedContent = content

        // Update binding with raw content (includes anchors)
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

        // Skip polling during content transitions (zoom, hierarchy enforcement, drag)
        guard contentState == .idle else { return }

        let generationAtPoll = contentGeneration  // Capture BEFORE async call

        // Batched poll: stats + section title in a single JS call
        webView.evaluateJavaScript("window.FinalFinal.getPollData()") { [weak self] result, _ in
            guard let self, !self.isCleanedUp else { return }
            // Discard stale result if a state transition happened during the JS roundtrip
            guard self.contentGeneration == generationAtPoll else {
                DebugLog.log(.sync, "[CodeMirrorPoll] Discarded stale result (gen \(generationAtPoll) != \(self.contentGeneration))")
                return
            }
            guard let jsonString = result as? String,
                  let data = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            if let stats = json["stats"] as? [String: Any],
               let words = stats["words"] as? Int,
               let chars = stats["characters"] as? Int,
               words != self.lastPolledWordCount || chars != self.lastPolledCharacterCount {
                self.lastPolledWordCount = words
                self.lastPolledCharacterCount = chars
                self.onStatsChange(words, chars)
            }

            let sectionTitle = (json["sectionTitle"] as? String) ?? ""
            let sectionBlockId = json["sectionBlockId"] as? String
            if sectionTitle != self.lastPolledSectionTitle || sectionBlockId != self.lastPolledSectionBlockId {
                self.lastPolledSectionTitle = sectionTitle
                self.lastPolledSectionBlockId = sectionBlockId
                self.onSectionChange(sectionTitle)
                self.onSectionIdChange?(sectionBlockId, sectionTitle)
            }
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

    /// Handle footnote navigation — find offset of target and scroll to it
    @MainActor
    func handleNavigateToFootnote(label: String, direction: String) {
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
            let pattern = "\\[\\^\(label)\\](?!:)"
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) {
                let offset = match.range.location
                scrollToOffset(offset)
            }
        }
    }

    /// Insert a footnote reference at the current cursor position (Cmd+Shift+N).
    /// Captures the returned label via completion handler and posts notification
    /// for immediate Notes section creation (bypasses 3s debounce).
    func insertFootnoteAtCursor() {
        guard isEditorReady, let webView else { return }
        // JS insertFootnote() sends postMessage({label}) which triggers .footnoteInsertedImmediate
        // via the footnoteInserted message handler — no need to post from completion handler
        webView.evaluateJavaScript("window.FinalFinal.insertFootnote()") { _, error in
            if let error {
                DebugLog.log(.editor, "[FootnoteSyncService] insertFootnote evaluateJavaScript error: \(error)")
            }
        }
    }

    /// Scroll to the footnote definition [^N]: in the Notes section
    func scrollToFootnoteDefinition(label: String) {
        guard isEditorReady, let webView else { return }
        guard label.allSatisfy(\.isNumber) else { return }
        webView.evaluateJavaScript(
            "window.FinalFinal.scrollToFootnoteDefinition('\(label)')"
        ) { _, _ in }
    }

    func setZoomFootnoteState(zoomed: Bool, maxLabel: Int) {
        guard isEditorReady, let webView else { return }
        webView.evaluateJavaScript(
            "window.FinalFinal.setZoomFootnoteState(\(zoomed), \(maxLabel))"
        ) { _, _ in }
    }

    /// Renumber footnote references in the editor using old→new label mapping
    func renumberFootnotes(mapping: [String: String]) {
        guard isEditorReady, let webView else { return }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: mapping),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.FinalFinal.renumberFootnotes(\(json))") { _, _ in }
    }

    /// Toggle highlight mark on selected text (Cmd+Shift+H)
    func toggleHighlight() {
        guard isEditorReady, let webView else { return }
        webView.evaluateJavaScript("window.FinalFinal.toggleHighlight()") { _, _ in }
    }

}
