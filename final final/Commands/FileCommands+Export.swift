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

            // Ensure .md extension -- case-insensitive, so a user-typed "Notes.MD" is
            // recognized as already having the extension instead of becoming "Notes.MD.md".
            if url.pathExtension.lowercased() != "md" {
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

    static func handleExportMarkdownOnly() async {
        let dm = DocumentManager.shared
        guard dm.projectDatabase != nil, dm.projectId != nil else {
            showNoContentError()
            return
        }

        // Fetch blocks (flushing pending editor edits first), then assemble plain markdown
        // with no image markup left behind by stripping it.
        let blocks: [Block]
        do {
            blocks = try await dm.exportBlocks()
        } catch {
            showErrorAlert("Could Not Load Content", error: error)
            return
        }

        let content = BlockParser.assembleMarkdownOnlyForExport(from: blocks)
        guard !content.isEmpty else {
            // Empty here doesn't necessarily mean the document itself is empty -- it can also
            // mean every block was an image (or was image markup and nothing else), which
            // assembleMarkdownOnlyForExport correctly strips down to nothing. Distinguish the
            // two so the error reflects what's actually true. assembleStandardMarkdownForExport
            // (unfiltered -- it keeps image markup, unlike assembleMarkdownOnlyForExport) being
            // non-empty here means `blocks` DID carry real content; since the Markdown Only
            // assembly of that same content came back empty, that content can only have been
            // images -- text content would have survived unstripped and made `content` above
            // non-empty too.
            let documentHasContent = !BlockParser.assembleStandardMarkdownForExport(from: blocks).isEmpty
            if documentHasContent {
                showImagesOnlyError()
            } else {
                showNoContentError()
            }
            return
        }

        let defaultName = dm.projectTitle ?? "Untitled"

        let savePanel = NSSavePanel()
        savePanel.title = "Export Markdown Only"
        savePanel.nameFieldLabel = "File Name:"
        savePanel.nameFieldStringValue = defaultName
        savePanel.allowedContentTypes = [.plainText]
        savePanel.canCreateDirectories = true

        savePanel.begin { response in
            guard response == .OK, let panelURL = savePanel.url else { return }
            let url = markdownExportURL(for: panelURL)

            savePanel.orderOut(nil)

            Task { @MainActor in
                let exportService = ExportService()
                do {
                    let result = try await exportService.exportMarkdownOnly(
                        content: content,
                        outputURL: url
                    )
                    showMarkdownExportSuccess(result: result)
                } catch {
                    showErrorAlert("Could Not Export File", error: error)
                }
            }
        }
    }

    /// Ensures a markdown export URL ends in `.md` -- case-insensitively, so a user-typed
    /// "Notes.MD" is recognized as already having the extension instead of becoming
    /// "Notes.MD.md" -- and REPLACES any other extension rather than stacking `.md` on top
    /// of it. That replacement matters because `savePanel.allowedContentTypes = [.plainText]`
    /// makes NSSavePanel itself auto-append ".txt" (plain text's preferred extension) to any
    /// name typed without an extension -- e.g. a save panel opened with the default name
    /// "Notes" resolves to `savePanel.url` "Notes.txt" before this function ever runs. The
    /// previous logic only appended ".md" when the extension wasn't already "md", so that
    /// auto-appended ".txt" survived and became "Notes.txt.md" instead of "Notes.md".
    static func markdownExportURL(for url: URL) -> URL {
        if url.pathExtension.lowercased() == "md" {
            return url
        }
        return url.deletingPathExtension().appendingPathExtension("md")
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

    /// Distinct from `showNoContentError()`: this document is NOT empty -- it has content, but
    /// that content is entirely images, which "Markdown Only" deliberately excludes. Saying
    /// "open a project with content" here would be false and confusing.
    private static func showImagesOnlyError() {
        let msg = "This document only contains images, which \"Markdown Only\" export leaves out. "
            + "Use \"Markdown with Images...\" instead to include them."
        let err = NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: msg])
        showErrorAlert("No Text to Export", error: err)
    }
}
