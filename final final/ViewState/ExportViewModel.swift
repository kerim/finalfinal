//
//  ExportViewModel.swift
//  final final
//
//  UI-facing state wrapper for export operations.
//  Provides @MainActor @Observable interface for SwiftUI views.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

/// State for export operations
@MainActor
@Observable
final class ExportViewModel {

    // MARK: - State

    /// Whether an export is currently in progress
    private(set) var isExporting = false

    /// Current export progress message
    private(set) var progressMessage: String?

    /// Last error from export operation
    private(set) var lastError: Error?

    /// Pandoc status (cached from last check)
    private(set) var pandocStatus: PandocStatus = .notFound

    /// Zotero status (cached from last check)
    private(set) var zoteroStatus: ZoteroStatus = .notRunning

    /// Whether Pandoc is available
    var isPandocAvailable: Bool {
        if case .found = pandocStatus { return true }
        return false
    }

    /// Whether Zotero is running
    var isZoteroRunning: Bool {
        zoteroStatus == .running
    }

    // MARK: - Services

    private let exportService = ExportService()

    // MARK: - Initialization

    init() {}

    // MARK: - Status Checks

    /// Check and update Pandoc status
    func checkPandoc() async {
        pandocStatus = await exportService.checkPandoc()
    }

    /// Check and update Zotero status
    func checkZotero() async {
        zoteroStatus = await exportService.checkZotero()
    }

    /// Refresh Pandoc status (clear cache)
    func refreshPandocStatus() async {
        pandocStatus = await exportService.refreshPandocStatus()
    }

    /// Configure export service with current settings
    func configure() async {
        let settings = ExportSettingsManager.shared.settings
        await exportService.configure(with: settings)
        await checkPandoc()
    }

    // MARK: - Export Operations

    /// Export content to the specified format
    /// - Parameters:
    ///   - content: Markdown content to export
    ///   - url: Destination URL
    ///   - format: Export format
    /// - Returns: ExportResult on success
    func export(content: String, to url: URL, format: ExportFormat) async throws -> ExportResult {
        isExporting = true
        progressMessage = "Exporting to \(format.displayName)..."
        lastError = nil

        defer {
            isExporting = false
            progressMessage = nil
        }

        do {
            let settings = ExportSettingsManager.shared.settings
            let result = try await exportService.export(
                content: content,
                to: url,
                format: format,
                settings: settings
            )

            // Update cached Zotero status
            zoteroStatus = result.zoteroStatus

            return result
        } catch {
            lastError = error
            throw error
        }
    }

    /// Show export save panel and perform export
    /// - Parameters:
    ///   - content: Markdown content to export
    ///   - format: Export format
    ///   - defaultName: Default file name (without extension)
    func showExportPanel(content: String, format: ExportFormat, defaultName: String) {
        // Check Pandoc first
        guard isPandocAvailable else {
            showPandocNotFoundAlert()
            return
        }

        let savePanel = NSSavePanel()
        savePanel.title = "Export as \(format.displayName)"
        savePanel.nameFieldLabel = "Export As:"
        savePanel.nameFieldStringValue = defaultName

        // Set allowed content type
        if let utType = UTType(format.contentTypeIdentifier) {
            savePanel.allowedContentTypes = [utType]
        }

        savePanel.canCreateDirectories = true

        savePanel.begin { [weak self] response in
            guard let self = self, response == .OK, let url = savePanel.url else { return }

            Task { @MainActor in
                do {
                    // Only check Zotero if content has citations
                    let hasCitations = self.hasPandocCitations(in: content)
                    if hasCitations {
                        await self.checkZotero()
                        if !self.isZoteroRunning && ExportSettingsManager.shared.showZoteroWarning {
                            let shouldContinue = await self.showZoteroWarningAlert()
                            if !shouldContinue { return }
                        }
                    }

                    let result = try await self.export(content: content, to: url, format: format)

                    // Show success with warnings
                    self.showExportSuccessAlert(result: result)

                } catch {
                    self.showExportErrorAlert(error: error)
                }
            }
        }
    }

    // MARK: - Citation Detection

    /// Detect Pandoc citations in content (e.g., [@Smith2020])
    private func hasPandocCitations(in content: String) -> Bool {
        content.range(
            of: #"\[[^\]]*@[\w:.-]+[^\]]*\]"#,
            options: .regularExpression
        ) != nil
    }

    // MARK: - Alerts

    private func showPandocNotFoundAlert() {
        let alert = NSAlert()
        alert.messageText = "Pandoc Not Found"
        alert.informativeText = PandocLocator.installInstructions
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Download Page")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(PandocLocator.downloadURL)
        }
    }

    private func showZoteroWarningAlert() async -> Bool {
        await withCheckedContinuation { continuation in
            let alert = NSAlert()
            alert.messageText = "Zotero Not Running"
            alert.informativeText = """
                Zotero with Better BibTeX is not running.

                Citations like [@Smith2020] will appear as-is in the exported document instead of being resolved to proper citations.

                Would you like to continue anyway?
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Continue Export")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't warn again"

            let response = alert.runModal()

            // Handle suppression
            if alert.suppressionButton?.state == .on {
                ExportSettingsManager.shared.showZoteroWarning = false
            }

            continuation.resume(returning: response == .alertFirstButtonReturn)
        }
    }

    private func showExportSuccessAlert(result: ExportResult) {
        let alert = NSAlert()

        if result.warnings.isEmpty {
            alert.messageText = "Export Complete"
            alert.informativeText = "Document exported successfully to \(result.format.displayName)."
            alert.alertStyle = .informational
        } else {
            alert.messageText = "Export Complete with Warnings"
            alert.informativeText = result.warnings.joined(separator: "\n\n")
            alert.alertStyle = .warning
        }

        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.selectFile(result.outputURL.path, inFileViewerRootedAtPath: "")
        }
    }

    private func showExportErrorAlert(error: Error) {
        let alert = NSAlert()
        alert.messageText = "Export Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
