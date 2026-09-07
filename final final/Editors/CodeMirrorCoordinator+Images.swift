//
//  CodeMirrorCoordinator+Images.swift
//  final final
//
//  Image paste/picker/metadata handling for CodeMirrorEditor.Coordinator, split out
//  of CodeMirrorCoordinator+Handlers.swift to keep that file under SwiftLint's
//  file_length limit.
//

import SwiftUI
import WebKit

extension CodeMirrorEditor.Coordinator {

    // MARK: - Image Handling

    /// Handle pasted image data from JS (base64-encoded)
    @MainActor
    func handlePasteImage(_ body: [String: Any]) {
        guard let base64Data = body["data"] as? String,
              let data = Data(base64Encoded: base64Data) else {
            DebugLog.log(.editor, "[CodeMirrorEditor] Invalid paste image data")
            return
        }

        let mimeType = body["type"] as? String
        let suggestedName = body["name"] as? String

        guard let mediaDir = MediaSchemeHandler.shared.mediaDirectoryURL else {
            DebugLog.log(.editor, "[CodeMirrorEditor] No media directory — cannot paste image")
            return
        }

        do {
            let relativePath = try ImageImportService.importFromData(
                data, suggestedName: suggestedName, mimeType: mimeType, mediaDir: mediaDir
            )

            insertImageBlock(src: relativePath, alt: suggestedName ?? "")
        } catch {
            DebugLog.log(.editor, "[CodeMirrorEditor] Image paste failed: \(error.localizedDescription)")
            let window = webView?.window ?? NSApp.keyWindow
            if let window {
                let alert = NSAlert()
                alert.messageText = "Image Import Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window) { [weak self] _ in
                    EditorFocusRestoration.restoreFocus(to: self?.webView, context: "CodeMirrorEditor paste-image-error alert dismiss")
                }
            }
        }
    }

    /// Handle native file picker request
    @MainActor
    func handleImagePicker() {
        guard !isCleanedUp else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImageImportService.allowedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select an image to insert"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let mediaDir = MediaSchemeHandler.shared.mediaDirectoryURL else {
            DebugLog.log(.editor, "[CodeMirrorEditor] No media directory — cannot import image")
            return
        }

        do {
            let relativePath = try ImageImportService.importFromURL(url, mediaDir: mediaDir)
            let alt = (url.lastPathComponent as NSString).deletingPathExtension
            insertImageBlock(src: relativePath, alt: alt)
        } catch {
            DebugLog.log(.editor, "[CodeMirrorEditor] Image import failed: \(error.localizedDescription)")
            let window = webView?.window ?? NSApp.keyWindow
            if let window {
                let alert = NSAlert()
                alert.messageText = "Image Import Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window) { [weak self] _ in
                    EditorFocusRestoration.restoreFocus(to: self?.webView, context: "CodeMirrorEditor image-picker-error alert dismiss")
                }
            }
        }
    }

    /// Handle image metadata update from JS (caption, alt, width)
    @MainActor
    func handleUpdateImageMeta(_ body: [String: Any]) {
        guard let blockId = body["blockId"] as? String else {
            DebugLog.log(.editor, "[CodeMirrorEditor] updateImageMeta missing blockId")
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
            DebugLog.log(.editor, "[CodeMirrorEditor] Failed to update image meta: \(error)")
        }
    }

    /// Insert image markdown at cursor via JS
    @MainActor
    private func insertImageBlock(src: String, alt: String) {
        guard let webView else { return }
        let escapedSrc = src.replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        let escapedAlt = alt.replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        webView.evaluateJavaScript(
            "window.FinalFinal.insertImage({src: `\(escapedSrc)`, alt: `\(escapedAlt)`})"
        ) { _, error in
            if let error {
                DebugLog.log(.editor, "[CodeMirrorEditor] insertImage JS error: \(error)")
            }
        }
    }

}
