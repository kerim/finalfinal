//
//  CodeMirrorCoordinator+Citations.swift
//  final final
//
//  Zotero CAYW citation picker handling for CodeMirrorEditor.Coordinator, split out
//  of CodeMirrorCoordinator+Handlers.swift to keep that file under SwiftLint's
//  file_length limit.
//

import SwiftUI
import WebKit

extension CodeMirrorEditor.Coordinator {

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
    func handleOpenCitationPicker(requestId: Int) async {
        guard let webView else {
            DebugLog.log(.zotero, "[CodeMirrorEditor] handleOpenCitationPicker: webView is nil")
            return
        }

        DebugLog.log(.zotero, "[CodeMirrorEditor] Opening CAYW picker, requestId: \(requestId)")

        // Pre-check: ping Zotero before opening the picker
        let isRunning = await ZoteroService.shared.ping()
        if !isRunning {
            showZoteroAlert(
                title: "Zotero Not Running",
                message: "Zotero is not running. Please open Zotero and try again."
            )
            sendCitationPickerCancelled(webView: webView, requestId: requestId)
            return
        }

        do {
            // Call CAYW picker - this blocks until user selects references
            let (parsed, items) = try await ZoteroService.shared.openCAYWPicker()

            // Bring app back to foreground after Zotero picker closes
            NSApp.activate(ignoringOtherApps: true)

            DebugLog.log(.zotero, "[CodeMirrorEditor] CAYW returned citekeys: \(parsed.citekeys)")

            // Encode CSL items as JSON for web
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let itemsData = try encoder.encode(items)
            guard let itemsJSON = String(data: itemsData, encoding: .utf8) else {
                DebugLog.log(.zotero, "[CodeMirrorEditor] Failed to encode CSL items")
                sendCitationPickerCancelled(webView: webView, requestId: requestId)
                return
            }

            // Build callback data object
            let callbackData: [String: Any] = [
                "rawSyntax": parsed.rawSyntax,
                "citekeys": parsed.citekeys,
                "locators": parsed.locatorsJSON,
                "prefix": parsed.entries.first?.prefix ?? "",
                "suppressAuthor": parsed.entries.first?.suppressAuthor ?? false,
                "requestId": requestId
            ]

            guard let callbackJSON = try? JSONSerialization.data(withJSONObject: callbackData),
                  let callbackStr = String(data: callbackJSON, encoding: .utf8) else {
                DebugLog.log(.zotero, "[CodeMirrorEditor] Failed to encode callback data")
                sendCitationPickerCancelled(webView: webView, requestId: requestId)
                return
            }

            // Send both parsed data and CSL items to web editor
            let escapedCallback = callbackStr.escapedForJSTemplateLiteral
            let escapedItems = itemsJSON.escapedForJSTemplateLiteral

            let script = "window.FinalFinal.citationPickerCallback(JSON.parse(`\(escapedCallback)`), JSON.parse(`\(escapedItems)`))"
            webView.evaluateJavaScript(script) { _, error in
                if let error {
                    DebugLog.log(.zotero, "[CodeMirrorEditor] citationPickerCallback error: \(error)")
                } else {
                    DebugLog.log(.zotero, "[CodeMirrorEditor] citationPickerCallback succeeded")
                }
            }
        } catch ZoteroError.userCancelled {
            NSApp.activate(ignoringOtherApps: true)
            DebugLog.log(.zotero, "[CodeMirrorEditor] CAYW cancelled by user")
            sendCitationPickerCancelled(webView: webView, requestId: requestId)
        } catch ZoteroError.notRunning {
            NSApp.activate(ignoringOtherApps: true)
            DebugLog.log(.zotero, "[CodeMirrorEditor] Zotero not running")
            showZoteroAlert(
                title: "Zotero Connection Lost",
                message: "Zotero is not running. Please open Zotero and try again."
            )
            sendCitationPickerCancelled(webView: webView, requestId: requestId)
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            DebugLog.log(.zotero, "[CodeMirrorEditor] CAYW error: \(error.localizedDescription)")
            showZoteroAlert(
                title: "Citation Error",
                message: error.localizedDescription
            )
            sendCitationPickerCancelled(webView: webView, requestId: requestId)
        }
    }

    /// Send citation picker cancelled to web editor
    @MainActor
    func sendCitationPickerCancelled(webView: WKWebView, requestId: Int) {
        webView.evaluateJavaScript("window.FinalFinal.citationPickerCancelled(\(requestId))") { _, _ in }
    }

}
