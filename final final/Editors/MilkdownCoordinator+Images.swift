//
//  MilkdownCoordinator+Images.swift
//  final final
//
//  Image paste/picker/metadata handling for MilkdownEditor.Coordinator, split out
//  of MilkdownCoordinator+MessageHandlers.swift to keep that file under SwiftLint's
//  file_length limit.
//

import SwiftUI
import WebKit

extension MilkdownEditor.Coordinator {

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
            // origin: "clipboard" — this handler is the single Swift entry point for both
            // clipboard paste and drag-and-drop, since the JS side posts both through the
            // same `pasteImage` message channel (see handlePaste/handleDrop in image-plugin.ts).
            insertImageBlock(src: relativePath, alt: suggestedName ?? "", origin: "clipboard")
        } catch {
            DebugLog.log(.editor, "[MilkdownEditor] Image paste failed: \(error.localizedDescription)")
            let window = webView?.window ?? NSApp.keyWindow
            if let window {
                let alert = NSAlert()
                alert.messageText = "Image Import Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window) { [weak self] _ in
                    EditorFocusRestoration.restoreFocus(to: self?.webView, context: "MilkdownEditor paste-image-error alert dismiss")
                }
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
            insertImageBlock(src: relativePath, alt: alt, origin: "picker")
        } catch {
            DebugLog.log(.editor, "[MilkdownEditor] Image import failed: \(error.localizedDescription)")
            let window = webView?.window ?? NSApp.keyWindow
            if let window {
                let alert = NSAlert()
                alert.messageText = "Image Import Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window) { [weak self] _ in
                    EditorFocusRestoration.restoreFocus(to: self?.webView, context: "MilkdownEditor image-picker-error alert dismiss")
                }
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
    ///
    /// `origin` is threaded through to JS's `insertImage()` so it can decide
    /// whether to consult a pending paste/drop caret position ("clipboard")
    /// or always fall back to inserting after the current selection's block
    /// ("picker" — the picker has no associated caret-capture event).
    @MainActor
    private func insertImageBlock(src: String, alt: String, origin: String) {
        let escapedAlt = alt.escapedForJSTemplateLiteral
        let script = "window.FinalFinal.insertImage && window.FinalFinal.insertImage(" +
            "{src: `\(src)`, alt: `\(escapedAlt)`, caption: '', width: null, blockId: '', origin: '\(origin)'})"
        webView?.evaluateJavaScript(script) { _, error in
            if let error {
                DebugLog.log(.editor, "[MilkdownEditor] insertImage JS error: \(error)")
            }
        }
    }

}
