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
        if let observer = citationLibraryObserver {
            NotificationCenter.default.removeObserver(observer)
            citationLibraryObserver = nil
        }
        if let observer = refreshAllCitationsObserver {
            NotificationCenter.default.removeObserver(observer)
            refreshAllCitationsObserver = nil
        }
        if let observer = editorModeObserver {
            NotificationCenter.default.removeObserver(observer)
            editorModeObserver = nil
        }
        webView = nil
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

    /// Set CSL style for citation formatting
    func setCitationStyle(_ styleXML: String) {
        guard isEditorReady, let webView else { return }
        let escaped = styleXML.replacingOccurrences(of: "`", with: "\\`")
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
        webView.evaluateJavaScript("window.FinalFinal.getContent()") { [weak self] contentResult, contentError in
            guard let self, !self.isCleanedUp else {
                self?.saveCursorAndNotify()
                return
            }

            if let content = contentResult as? String {
                // DEFENSIVE: Don't overwrite non-empty content with empty content
                // This can happen when Milkdown fails to initialize (JS exception)
                let existingContent = self.contentBinding.wrappedValue
                if content.isEmpty && !existingContent.isEmpty {
                    // Skip - don't overwrite good content with empty
                } else {
                    // Update binding immediately to ensure content is preserved
                    self.lastPushedContent = content
                    self.contentBinding.wrappedValue = content
                }
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

    func shouldPushContent(_ newContent: String) -> Bool {
        let timeSinceLastReceive = Date().timeIntervalSince(lastReceivedFromEditor)
        if timeSinceLastReceive < 0.6 && newContent == lastPushedContent { return false }
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
            #if DEBUG
            print("[MilkdownEditor] setContent: Failed to encode markdown as JSON")
            #endif
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
        """) { [weak self] result, error in
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

    func setTheme(_ cssVariables: String) {
        guard isEditorReady, let webView else { return }
        let escaped = cssVariables.escapedForJSTemplateLiteral
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
}
