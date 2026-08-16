//
//  MilkdownCoordinator+Content.swift
//  final final
//
//  Content management methods for MilkdownEditor.Coordinator.
//  Handles cleanup, content push/pull, cursor management, annotations, citations, and theming.
//

import SwiftUI
import WebKit

extension MilkdownEditor.Coordinator {

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
        clearObserver(&citationLibraryObserver)
        clearObserver(&citationStyleObserver)
        clearObserver(&refreshAllCitationsObserver)
        clearObserver(&editorModeObserver)
        clearObserver(&spellcheckStateObserver)
        clearObserver(&smartQuotesStateObserver)
        clearObserver(&proofingModeObserver)
        clearObserver(&proofingSettingsObserver)
        clearObserver(&insertFootnoteObserver)
        clearObserver(&renumberFootnotesObserver)
        clearObserver(&scrollToFootnoteDefObserver)
        clearObserver(&footnoteDefsObserver)
        clearObserver(&blockSyncPushObserver)
        clearObserver(&zoomFootnoteStateObserver)
        clearObserver(&insertImageObserver)
        clearObserver(&insertTableObserver)
        clearObserver(&insertEquationObserver)

        // Formatting command observers cleanup
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

        // Unregister all WKScriptMessageHandler channels registered in
        // registerMilkdownMessageHandlers(on:coordinator:) (MilkdownEditor.swift)
        // — without this, the WKUserContentController keeps a strong reference to this
        // Coordinator (via `controller.add(coordinator, name:)`) and it is never deallocated.
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

    /// Set editor appearance mode (WYSIWYG or source) - Phase C dual-appearance
    /// This toggles between rich text and markdown syntax view without swapping WebViews
    func setEditorAppearanceMode(_ mode: String) {
        guard isEditorReady, let webView else { return }
        let jsMode = mode.lowercased() == "source" ? "source" : "wysiwyg"
        webView.evaluateJavaScript("window.FinalFinal.setEditorMode('\(jsMode)')") { _, _ in }
    }

    /// Set annotation display modes in the editor
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

        // Convert to JSON-friendly format
        var modeDict: [String: String] = [:]
        for (type, mode) in modes {
            modeDict[type.rawValue] = mode.rawValue
        }
        // Add special keys for global settings
        modeDict["__panelOnly"] = isPanelOnly ? "true" : "false"
        modeDict["__hideCompletedTasks"] = hideCompletedTasks ? "true" : "false"

        guard let jsonData = try? JSONSerialization.data(withJSONObject: modeDict),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }

        let script = "window.FinalFinal.setAnnotationDisplayModes(\(jsonString))"
        webView.evaluateJavaScript(script) { _, _ in }
    }

    /// Insert an annotation at the current cursor position
    func insertAnnotation(type: AnnotationType) {
        guard isEditorReady, let webView else { return }
        let script = "window.FinalFinal.insertAnnotation('\(type.rawValue)')"
        webView.evaluateJavaScript(script) { _, _ in }
    }

    /// Toggle highlight mark on selected text (Cmd+Shift+H)
    func toggleHighlight() {
        guard isEditorReady, let webView else { return }
        webView.evaluateJavaScript("window.FinalFinal.toggleHighlight()") { _, _ in }
    }

    /// Push citation library to the editor for search and formatting
    func setCitationLibrary(_ itemsJSON: String) {
        guard isEditorReady, let webView else { return }
        let escaped = itemsJSON.escapedForJSTemplateLiteral
        webView.evaluateJavaScript("window.FinalFinal.setCitationLibrary(JSON.parse(`\(escaped)`))") { _, _ in }
    }

    /// Insert a footnote reference at the current cursor position.
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
        ) { [weak webView] _, _ in
            // Ensure WKWebView is macOS first responder for caret rendering
            // (JS view.focus() sets DOM focus but not the NSWindow responder chain)
            if let webView, let window = webView.window {
                window.makeFirstResponder(webView)
            }
        }
    }

    /// Renumber footnote references in the editor using old→new label mapping
    func renumberFootnotes(mapping: [String: String]) {
        guard isEditorReady, let webView else { return }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: mapping),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.FinalFinal.renumberFootnotes(\(json))") { _, _ in }
    }

    func setZoomFootnoteState(zoomed: Bool, maxLabel: Int) {
        guard isEditorReady, let webView else { return }
        webView.evaluateJavaScript(
            "window.FinalFinal.setZoomFootnoteState(\(zoomed), \(maxLabel))"
        ) { _, _ in }
    }

    func setFootnoteDefinitions(_ defs: [String: String]) {
        guard isEditorReady, let webView else { return }
        // Convert to JSON and call the API
        guard let jsonData = try? JSONSerialization.data(withJSONObject: defs),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        let escaped = jsonString.escapedForJSTemplateLiteral
        webView.evaluateJavaScript("window.FinalFinal.setFootnoteDefinitions(JSON.parse(`\(escaped)`))") { _, _ in }
    }

    /// Set CSL style for citation formatting
    func setCitationStyle(_ styleXML: String) {
        guard isEditorReady, let webView else { return }
        // A hand-rolled backtick-only replace here used to let a `${...}` sequence inside the
        // style XML (or a stray backslash) break out of the JS template literal -- every
        // other bridge call in this file uses the shared escapedForJSTemplateLiteral helper
        // (see setCitationLibrary, setFootnoteDefinitions above) for exactly this reason.
        let escaped = styleXML.escapedForJSTemplateLiteral
        webView.evaluateJavaScript("window.FinalFinal.setCitationStyle(`\(escaped)`)") { _, _ in }
    }

    /// Get all citekeys used in the document (for bibliography generation)
    func getBibliographyCitekeys(completion: @escaping ([String]) -> Void) {
        guard isEditorReady, let webView else {
            completion([])
            return
        }
        webView.evaluateJavaScript("JSON.stringify(window.FinalFinal.getBibliographyCitekeys())") { result, _ in
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let keys = try? JSONDecoder().decode([String].self, from: data) else {
                completion([])
                return
            }
            completion(keys)
        }
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
                line: line,
                column: column,
                scrollFraction: scrollFraction,
                cursorIsVisible: cursorIsVisible,
                topLine: topLine
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
            NotificationCenter.default.post(
                name: .didSaveCursorPosition,
                object: nil,
                userInfo: ["position": pending]
            )
            return
        }

        // Skip content capture during Milkdown initialization (source→WYSIWYG transition).
        // Milkdown may return corrupted content (missing # from headers) during this window.
        // Still save cursor and fire the toggle notification so the toggle proceeds.
        if contentState == .editorTransition {
            DebugLog.log(.editor, "[CURSOR-SYNC] MW.saveAndNotify: SKIPPING content capture (editorTransition)")
            saveCursorAndNotify()
            return
        }

        // CONTENT SYNC: Fetch and save content BEFORE cursor to prevent content loss during toggle
        webView.evaluateJavaScript("window.FinalFinal.getContent()") { [weak self] contentResult, _ in
            guard let self, !self.isCleanedUp else {
                self?.saveCursorAndNotify()
                return
            }

            if let content = contentResult as? String {
                DebugLog.log(.editor, "[SAVE+NOTIFY] getContent returned length=\(content.count)")
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
                    line: line,
                    column: column,
                    scrollFraction: scrollFraction,
                    cursorIsVisible: cursorIsVisible,
                    topLine: topLine
                )
            }

            DebugLog.log(.editor,
                "[CURSOR-SYNC] MW.saveCursor: line=\(position.line) col=\(position.column) visible=\(position.cursorIsVisible)")

            NotificationCenter.default.post(
                name: .didSaveCursorPosition,
                object: nil,
                userInfo: ["position": position]
            )
        }
    }

    func shouldPushContent(_ newContent: String) -> Bool {
        let timeSinceLastReceive = Date().timeIntervalSince(lastReceivedFromEditor)
        if timeSinceLastReceive < 0.6 && newContent == lastPushedContent {
            return false
        }
        return newContent != lastPushedContent
    }

    func setContent(_ markdown: String) {
        guard isEditorReady, let webView else { return }

        lastPushedContent = markdown
        lastPushTime = Date()  // Record push time to prevent poll feedback

        // Use JSONEncoder to properly encode string with all special characters escaped
        // JSONEncoder handles strings directly (unlike JSONSerialization which needs Array/Dict)
        guard let jsonData = try? JSONEncoder().encode(markdown),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            DebugLog.log(.editor, "[MilkdownEditor] setContent: Failed to encode markdown as JSON")
            return
        }

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

        // Set content and then read it back to confirm (acknowledgement pattern)
        // This ensures WebView has processed the content before we continue
        webView.evaluateJavaScript("""
            window.FinalFinal.setContent(\(jsonString)\(optionsArg));
            window.FinalFinal.getContent();
        """) { [weak self] _, _ in
            // For zoom transitions, DON'T show WebView here - wait for paintComplete message
            // The JS double-RAF pattern will signal when paint is complete
            if !shouldScrollToStart {
                // For non-zoom content changes, call acknowledgement immediately
                if let callback = self?.onContentAcknowledged {
                    self?.onContentAcknowledged = nil  // One-shot callback
                    callback()
                }
            }
            // For zoom transitions, the paintComplete handler will show the WebView
            // and call the acknowledgement callback
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

    func triggerSpellcheck() {
        guard isEditorReady, let webView else { return }
        webView.evaluateJavaScript("window.FinalFinal.triggerSpellcheck()") { _, _ in }
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

    func setTheme(_ cssVariables: String) {
        guard isEditorReady, let webView else { return }
        let escaped = cssVariables.escapedForJSTemplateLiteral
        webView.evaluateJavaScript("window.FinalFinal.setTheme(`\(escaped)`)") { _, _ in }
    }

    func scrollToOffset(_ offset: Int) {
        guard isEditorReady, let webView else { return }
        webView.evaluateJavaScript("window.FinalFinal.scrollToOffset(\(offset))") { _, _ in }
    }

    /// Scroll to the nth annotation in the ProseMirror document (ordinal index matching)
    func scrollToAnnotation(index: Int) {
        guard isEditorReady, let webView else { return }
        webView.evaluateJavaScript("window.FinalFinal.scrollToAnnotation(\(index))") { _, _ in }
    }

    /// Scroll to a block by its ID (uses ProseMirror position lookup, avoids character offset issues with atom nodes)
    func scrollToBlock(_ blockId: String) {
        guard isEditorReady, let webView else { return }
        let escaped = blockId.escapedForJSTemplateLiteral
        webView.evaluateJavaScript("window.FinalFinal.scrollToBlock(`\(escaped)`)") { _, _ in }
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
}
