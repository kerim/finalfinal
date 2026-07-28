//
//  FileCommands+Export.swift
//  final final
//
//  Export handlers for FileOperations: Markdown-with-images and TextBundle export.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension FileOperations {
    static func handleExportMarkdownWithImages() async {
        let dm = DocumentManager.shared
        guard dm.projectDatabase != nil, dm.projectId != nil else {
            showNoContentError()
            return
        }

        // Fetch blocks (flushing pending editor edits first), filter bibliography,
        // assemble standard markdown + extract image filenames
        let blocks: [Block]
        do {
            blocks = try await dm.exportBlocks()
        } catch {
            showErrorAlert("Could Not Load Content", error: error)
            return
        }

        let content = BlockParser.assembleStandardMarkdownForExport(from: blocks)
        guard !content.isEmpty else {
            showNoContentError()
            return
        }

        let imageFilenames = blocks.compactMap { block -> String? in
            guard block.blockType == .image, let src = block.imageSrc else { return nil }
            return URL(fileURLWithPath: src).lastPathComponent
        }
        let projectURL = dm.projectURL
        let defaultName = dm.projectTitle ?? "Untitled"

        let savePanel = NSSavePanel()
        savePanel.title = "Export Markdown with Images"
        savePanel.nameFieldLabel = "File Name:"
        savePanel.nameFieldStringValue = defaultName
        savePanel.allowedContentTypes = [.plainText]
        savePanel.canCreateDirectories = true

        savePanel.begin { response in
            guard response == .OK, var url = savePanel.url else { return }

            // Ensure .md extension
            if url.pathExtension != "md" {
                url = url.appendingPathExtension("md")
            }

            savePanel.orderOut(nil)

            Task { @MainActor in
                let exportService = ExportService()
                do {
                    let result = try await exportService.exportMarkdownWithImages(
                        content: content,
                        imageFilenames: imageFilenames,
                        projectURL: projectURL,
                        outputURL: url
                    )
                    showMarkdownExportSuccess(result: result)
                } catch {
                    showErrorAlert("Could Not Export File", error: error)
                }
            }
        }
    }

    static func handleExportTextBundle() async {
        let dm = DocumentManager.shared
        guard dm.projectDatabase != nil, dm.projectId != nil else {
            showNoContentError()
            return
        }

        // Fetch blocks (flushing pending editor edits first), filter bibliography,
        // assemble standard markdown + extract image filenames
        let blocks: [Block]
        do {
            blocks = try await dm.exportBlocks()
        } catch {
            showErrorAlert("Could Not Load Content", error: error)
            return
        }

        let content = BlockParser.assembleStandardMarkdownForExport(from: blocks)
        guard !content.isEmpty else {
            showNoContentError()
            return
        }

        let imageFilenames = blocks.compactMap { block -> String? in
            guard block.blockType == .image, let src = block.imageSrc else { return nil }
            return URL(fileURLWithPath: src).lastPathComponent
        }
        let projectURL = dm.projectURL
        let defaultName = dm.projectTitle ?? "Untitled"

        let savePanel = NSSavePanel()
        savePanel.title = "Export as TextBundle"
        savePanel.nameFieldLabel = "File Name:"
        savePanel.nameFieldStringValue = defaultName
        if let tbType = UTType("org.textbundle.package") {
            savePanel.allowedContentTypes = [tbType]
        }
        savePanel.canCreateDirectories = true

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            savePanel.orderOut(nil)

            Task { @MainActor in
                let exportService = ExportService()
                do {
                    let result = try await exportService.exportTextBundle(
                        content: content,
                        imageFilenames: imageFilenames,
                        projectURL: projectURL,
                        outputURL: url
                    )
                    showMarkdownExportSuccess(result: result)
                } catch {
                    showErrorAlert("Could Not Export File", error: error)
                }
            }
        }
    }

    private static func showMarkdownExportSuccess(result: ExportService.MarkdownExportResult) {
        let alert = NSAlert()

        if result.warnings.isEmpty {
            alert.messageText = "Export Complete"
            alert.informativeText = "Document exported successfully."
            alert.alertStyle = .informational
        } else {
            alert.messageText = "Export Complete with Warnings"
            alert.informativeText = result.warnings.joined(separator: "\n")
            alert.alertStyle = .warning
        }

        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.selectFile(result.outputURL.path, inFileViewerRootedAtPath: "")
        }
    }

    private static func showNoContentError() {
        let msg = "Open a project with content before exporting."
        let err = NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: msg])
        showErrorAlert("No Content to Export", error: err)
    }
}
