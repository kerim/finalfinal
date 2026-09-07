//
//  CodeMirrorCoordinator+MessageDispatch.swift
//  final final
//
//  WKScriptMessageHandler entry point for CodeMirrorEditor.Coordinator, split out
//  of CodeMirrorCoordinator+Handlers.swift to keep that file under SwiftLint's
//  file_length limit and to keep userContentController's cyclomatic complexity
//  low. A flat `switch message.name` over all 15 message names scores far too
//  high because SwiftLint's cyclomatic_complexity rule counts conditionals inside
//  nested closures (the `Task { @MainActor in }` hop for every branch) — so
//  dispatch is split into two tiers: the delegate method fans out to one router
//  per message family, and each router's own switch/guard bodies stay small.
//

import SwiftUI
import WebKit

extension CodeMirrorEditor.Coordinator {

    // MARK: - Tier 1: WKScriptMessageHandler entry point

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if handleContentMessage(message) { return }
        if handleDiagnosticMessage(message) { return }
        if handleCitationMessage(message) { return }
        if handleNavigationMessage(message) { return }
        if handleMediaMessage(message) { return }
        if handleFootnoteMessage(message) { return }
        if handleUndoMessage(message) { return }
        _ = handleSpellcheckMessage(message)
    }

    /// Unified-undo bridge messages (docs/architecture/unified-undo.md's registry/descriptor
    /// bridge protocol section) -- Phase 3.
    nonisolated func handleUndoMessage(_ message: WKScriptMessage) -> Bool {
        switch message.name {
        case "structuralUndoRequested":
            guard let body = message.body as? [String: Any], let opId = body["opId"] as? String else { return true }
            let requestingWebView = message.webView
            Task { @MainActor in
                await routeStructuralRequest(opId: opId, direction: .undo, from: requestingWebView, editorLabel: "CodeMirrorEditor")
            }
            return true

        case "structuralRedoRequested":
            guard let body = message.body as? [String: Any], let opId = body["opId"] as? String else { return true }
            let requestingWebView = message.webView
            Task { @MainActor in
                await routeStructuralRequest(opId: opId, direction: .redo, from: requestingWebView, editorLabel: "CodeMirrorEditor")
            }
            return true

        case "historyEdited":
            // Redo-branch barrier (plan §4.6): a genuine text edit landed while a structural
            // redo entry exists. Doc-equality routing (§4.2) alone is NOT self-correcting here
            // -- a later text undo/redo can land the live doc back at byte-equality with a now-
            // stale redo entry's preOpDoc, letting an abandoned structural redo fire again. Tell
            // the controller to invalidate the redo branch, mirroring the sibling
            // structuralUndoRequested/structuralRedoRequested cases' webview-identity-guarded
            // routing above.
            DebugLog.log(.undo, "[CodeMirrorEditor] historyEdited: real edit while structural redo entry exists")
            let requestingWebView = message.webView
            Task { @MainActor in
                await routeHistoryEdited(from: requestingWebView, editorLabel: "CodeMirrorEditor")
            }
            return true

        case "structuralUndoRefused":
            guard let body = message.body as? [String: Any] else { return true }
            let direction = (body["direction"] as? String) ?? "undo"
            DebugLog.log(.undo, "[CodeMirrorEditor] structural undo refused (direction=\(direction)): beeping")
            Task { @MainActor in
                NSSound.beep()
            }
            return true

        default:
            return false
        }
    }

    // MARK: - Tier 2: family routers

    /// Hot-path content sync messages: section/content/selection push from JS.
    nonisolated func handleContentMessage(_ message: WKScriptMessage) -> Bool {
        switch message.name {
        case "sectionChanged":
            guard let data = message.body as? [String: Any] else { return true }
            let title = (data["title"] as? String) ?? ""
            let blockId = data["blockId"] as? String
            Task { @MainActor in
                self.applySectionChange(title: title, blockId: blockId)
            }
            return true

        case "contentChanged":
            // P3 (4c, undo-mode-switch-focus second timing gap): main.ts now posts an object
            // `{content, wasUndo}` instead of a bare string -- `wasUndo` is a sticky-OR over
            // the JS-side 50ms aggregating debounce window, true if any transaction folded
            // into this push was an undo replay. Bare-string fallback is UNSAFE-SILENT (it
            // means the web bundle wasn't rebuilt after this change -- `wasUndo` silently
            // reads as false, so the P3 §4d re-correction suppression this value is meant to
            // drive never engages), so it's logged once per occurrence rather than swallowed.
            let content: String?
            let wasUndo: Bool
            if let body = message.body as? [String: Any] {
                content = body["content"] as? String
                wasUndo = (body["wasUndo"] as? Bool) ?? false
            } else if let bareString = message.body as? String {
                content = bareString
                wasUndo = false
                DebugLog.log(.sync, "[CodeMirrorEditor] contentChanged arrived as a bare string -- stale web bundle? run: cd web && pnpm build")
            } else {
                content = nil
                wasUndo = false
            }
            guard let content else { return true }
            Task { @MainActor in
                // Set BEFORE handleContentPush's own early-return guards (mid-contentState
                // transition, the 150ms push grace window, mid-reset) -- all cases where a
                // local edit genuinely happened and must still count. Deliberately not
                // `lastReceivedFromEditor`, which IS skipped in those cases (undo-mode-
                // switch-focus fix: see `lastLocalEditAt`'s and `shouldPushContent`'s doc
                // comments in CodeMirrorCoordinator+Core.swift/+Handlers.swift).
                //
                // Must-fix F4 (judge review round): EXCEPT when `content` matches what Swift
                // itself just pushed -- main.ts posts `contentChanged` on any `docChanged`
                // update with no sync-origin filter, including the transaction `setContent`
                // itself dispatches, so ~50ms after every legitimate Swift->JS push this
                // message arrives again as a pure echo. Arming the settle window on that echo
                // widens the drop window from "user is actively typing" to "any burst of
                // derived refreshes within 0.6s of each other." Accepted residual: a user who
                // types then deletes back to the exact pushed content within the ~50ms debounce
                // won't arm the window either -- documented, not a new bug. Compares against
                // the EXTRACTED `content`, not the raw message body, now that the body is an
                // object rather than a bare string.
                if content != self.lastPushedContent {
                    self.lastLocalEditAt = Date()
                }
                // P3 (4d): `wasUndo` is captured onto the Coordinator here for visibility/
                // diagnostics, AND separately forwarded into `handleContentPush` below,
                // which passes it to `onContentChange` -- ContentView's closure there
                // constructs/invalidates `editorState.reconcileSuppression` (the token
                // SectionSyncService.contentChanged's `suppressReconcile` and
                // ContentView+ProjectLifecycle's onSectionsUpdated both consult). See
                // EditorViewState.ReconcileSuppression's doc comment for the full design.
                self.lastContentChangeWasUndo = wasUndo
                self.handleContentPush(content, wasUndo: wasUndo)
            }
            return true

        case "selectionChanged":
            guard let text = message.body as? String else { return true }
            Task { @MainActor in
                self.onSelectionChange?(text)
            }
            return true

        default:
            return false
        }
    }

    nonisolated func handleDiagnosticMessage(_ message: WKScriptMessage) -> Bool {
        guard message.name == "errorHandler" else { return false }
        guard let body = message.body as? [String: Any] else { return true }
        // errorHandler runs synchronously today — do not wrap this in a Task.
        logJSDiagnostic(body: body)
        return true
    }

    nonisolated func handleCitationMessage(_ message: WKScriptMessage) -> Bool {
        switch message.name {
        case "openCitationPicker":
            guard let requestId = message.body as? Int else { return true }
            Task { @MainActor in
                await self.handleOpenCitationPicker(requestId: requestId)
            }
            return true

        default:
            return false
        }
    }

    nonisolated func handleNavigationMessage(_ message: WKScriptMessage) -> Bool {
        switch message.name {
        case "paintComplete":
            // Mount-flash fix (doc-open-blank-regression follow-up): CodeMirror deliberately
            // does NOT get the token-based cloak system MilkdownEditor.Coordinator gained
            // (beginCloak/endCloak, MilkdownCoordinator+MessageHandlers.swift) -- the flash
            // this closes is specific to Milkdown's internal container-swap teardown/rebuild
            // dance during EditorView construction, which CodeMirror has no equivalent of.
            // CodeMirror's own zoom cloak stays on its existing bare `webView?.alphaValue`
            // pattern (CodeMirrorCoordinator+Handlers.swift), and no sender in
            // codemirror/src/api.ts posts a `reason`/`token` field, so this signature stays
            // unchanged -- do not add a `reason` parameter here to mirror Milkdown's dispatch.
            Task { @MainActor in
                self.handlePaintComplete()
            }
            return true

        case "openURL":
            guard let urlString = message.body as? String else { return true }
            Task { @MainActor in
                self.openExternalURL(urlString)
            }
            return true

        default:
            return false
        }
    }

    nonisolated func handleMediaMessage(_ message: WKScriptMessage) -> Bool {
        switch message.name {
        case "pasteImage":
            guard let body = message.body as? [String: Any] else { return true }
            Task { @MainActor in
                self.handlePasteImage(body)
            }
            return true

        case "requestImagePicker":
            Task { @MainActor in
                self.handleImagePicker()
            }
            return true

        case "updateImageMeta":
            guard let body = message.body as? [String: Any] else { return true }
            Task { @MainActor in
                self.handleUpdateImageMeta(body)
            }
            return true

        case "tableInsertTruncated":
            guard let body = message.body as? [String: Any] else { return true }
            Task { @MainActor in
                let rows = body["rows"] as? Int ?? 0
                let cols = body["cols"] as? Int ?? 0
                self.presentTableTruncatedAlert(rows: rows, cols: cols)
            }
            return true

        case "openEquationDialog":
            Task { @MainActor in
                EquationDialog.present(for: self.webView, logLabel: "CodeMirrorEditor")
            }
            return true

        default:
            return false
        }
    }

    nonisolated func handleFootnoteMessage(_ message: WKScriptMessage) -> Bool {
        switch message.name {
        case "footnoteInserted":
            // Sync editor content BEFORE posting notification to prevent stale DB body overwrite
            guard let body = message.body as? [String: Any],
                  let label = body["label"] as? String, !label.isEmpty else { return true }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncContentAfterFootnoteInsert(label: label)
            }
            return true

        case "navigateToFootnote":
            guard let body = message.body as? [String: Any] else { return true }
            Task { @MainActor in
                guard let label = body["label"] as? String,
                      let direction = body["direction"] as? String else { return }
                self.handleNavigateToFootnote(label: label, direction: direction)
            }
            return true

        default:
            return false
        }
    }

    /// Routing MUST stay inside the main-actor Task: the `guard let body … let action` AND
    /// the whole `switch action` run inside `Task { @MainActor in }`, which is what puts
    /// `SpellCheckService.shared.learnWord`/`.ignoreWord` and `ProofingSettings.shared.disableRule`
    /// on the main actor. Do not hoist the cast or the switch into this `nonisolated` router.
    nonisolated func handleSpellcheckMessage(_ message: WKScriptMessage) -> Bool {
        guard message.name == "spellcheck" else { return false }
        Task { @MainActor in
            guard let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }

            switch action {
            case "check":
                self.performSpellcheckCheck(body: body)

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
        return true
    }

    // MARK: - Extracted message bodies

    /// Applies a push-based section change from JS (instant sidebar highlight).
    @MainActor
    func applySectionChange(title: String, blockId: String?) {
        guard self.contentState == .idle else { return }
        guard !self.isResettingContentBinding.wrappedValue else { return }
        self.onSectionChange(title)
        self.onSectionIdChange?(blockId, title)
    }

    /// Logs a diagnostic/error message forwarded from the JS `window.onerror` /
    /// `unhandledrejection` handlers or explicit debug postMessage calls.
    nonisolated func logJSDiagnostic(body: [String: Any]) {
        let msgType = body["type"] as? String ?? "unknown"
        let msg = body["message"] as? String ?? "unknown"
        let prefix = "[CodeMirrorEditor]"

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

    /// Opens a URL from an editor `openURL` message (Cmd+click on links), restricted
    /// to a scheme allow-list.
    @MainActor
    func openExternalURL(_ urlString: String) {
        if let url = URL(string: urlString),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Shows the native "Table Truncated" alert for a paste that exceeded the
    /// 1000 row × 100 col limit.
    @MainActor
    func presentTableTruncatedAlert(rows: Int, cols: Int) {
        let window = self.webView?.window ?? NSApp.keyWindow
        if let window {
            let alert = NSAlert()
            alert.messageText = "Table Truncated"
            alert.informativeText = "The pasted table was truncated to \(rows) rows × \(cols) columns."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window) { [weak self] _ in
                EditorFocusRestoration.restoreFocus(to: self?.webView, context: "CodeMirrorEditor table-truncated alert dismiss")
            }
        }
    }

    /// Handle footnote inserted notification from JS (slash command or evaluateJavaScript path).
    /// CodeMirror deliberately reads the RAW content (with anchors) and also calls
    /// `onContentChange` here — Milkdown's counterpart does neither; that divergence is
    /// intentional (Milkdown has no anchor-stripping step), not a bug to unify.
    @MainActor
    func syncContentAfterFootnoteInsert(label: String) {
        guard let webView else { return }
        webView.evaluateJavaScript("window.FinalFinal.getContentRaw()") { [weak self] result, _ in
            guard let self, let rawContent = result as? String else { return }
            Task { @MainActor in
                self.lastPushedContent = rawContent
                self.lastReceivedFromEditor = Date()
                self.contentBinding.wrappedValue = rawContent  // Sets sourceContent (with anchors)
                self.onContentChange(rawContent, false)  // Strips anchors → updates editorState.content (never an undo -- Swift-triggered)
                NotificationCenter.default.post(
                    name: .footnoteInsertedImmediate, object: nil,
                    userInfo: ["label": label]
                )
            }
        }
    }

    // MARK: - Spellcheck

    @MainActor
    func performSpellcheckCheck(body: [String: Any]) {
        guard let segmentsData = body["segments"] as? [[String: Any]],
              let requestId = body["requestId"] as? Int else { return }
        let segments = parseSpellcheckSegments(segmentsData)
        self.spellcheckTask?.cancel()
        self.spellcheckTask = Task {
            let results = await SpellCheckService.shared.check(segments: segments)
            guard !Task.isCancelled else { return }
            self.deliverSpellcheckResults(results, requestId: requestId)
        }
    }

    func parseSpellcheckSegments(_ segmentsData: [[String: Any]]) -> [SpellCheckService.TextSegment] {
        segmentsData.compactMap { dict -> SpellCheckService.TextSegment? in
            guard let text = dict["text"] as? String,
                  let from = dict["from"] as? Int,
                  let toOffset = dict["to"] as? Int else { return nil }
            let blockId = dict["blockId"] as? Int
            return SpellCheckService.TextSegment(text: text, from: from, to: toOffset, blockId: blockId)
        }
    }

    @MainActor
    func deliverSpellcheckResults(_ results: [SpellCheckService.SpellCheckResult], requestId: Int) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(results),
              let json = String(data: data, encoding: .utf8) else {
            DebugLog.log(.proofing, "[LT] DIAG delivery(CM): JSON encode FAILED for \(results.count) results, requestId=\(requestId)")
            return
        }
        let escaped = json.escapedForJSTemplateLiteral
        DebugLog.log(.proofing, "[LT] DIAG delivery(CM): sending requestId=\(requestId) results=\(results.count) jsonBytes=\(data.count)")
        self.webView?.evaluateJavaScript(
            "window.FinalFinal.setSpellcheckResults(\(requestId), JSON.parse(`\(escaped)`))"
        ) { _, error in
            if let error {
                DebugLog.log(.proofing, "[LT] DIAG delivery(CM): evaluateJavaScript FAILED requestId=\(requestId) error=\(error)")
            } else {
                DebugLog.log(.proofing, "[LT] DIAG delivery(CM): evaluateJavaScript OK requestId=\(requestId)")
            }
        }
    }

}
