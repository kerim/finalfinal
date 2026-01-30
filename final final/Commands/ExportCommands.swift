//
//  ExportCommands.swift
//  final final
//
//  Export submenu commands for Word, PDF, and ODT export.
//

import SwiftUI
import AppKit

struct ExportCommands: Commands {
    var body: some Commands {
        // Add Export submenu after the existing Import/Export group
        CommandMenu("Export") {
            Button("Export as Word...") {
                NotificationCenter.default.post(
                    name: .exportDocument,
                    object: nil,
                    userInfo: ["format": ExportFormat.word]
                )
            }
            .keyboardShortcut("e", modifiers: [.command, .option])

            Button("Export as PDF...") {
                NotificationCenter.default.post(
                    name: .exportDocument,
                    object: nil,
                    userInfo: ["format": ExportFormat.pdf]
                )
            }
            .keyboardShortcut("p", modifiers: [.command, .option])

            Button("Export as ODT...") {
                NotificationCenter.default.post(
                    name: .exportDocument,
                    object: nil,
                    userInfo: ["format": ExportFormat.odt]
                )
            }

            Divider()

            Button("Export Preferences...") {
                NotificationCenter.default.post(name: .showExportPreferences, object: nil)
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Request to export document (userInfo: "format" -> ExportFormat)
    static let exportDocument = Notification.Name("exportDocument")
    /// Request to show export preferences
    static let showExportPreferences = Notification.Name("showExportPreferences")
}

// MARK: - Export Operation Handlers

/// Handles export menu operations
@MainActor
struct ExportOperations {

    /// Shared export view model for tracking state
    static let exportViewModel = ExportViewModel()

    /// Handle export request with specified format
    static func handleExport(format: ExportFormat) {
        // Get current content from DocumentManager
        guard let content = try? DocumentManager.shared.loadContent(), !content.isEmpty else {
            showNoContentAlert()
            return
        }

        // Get project title for default filename
        let defaultName = DocumentManager.shared.projectTitle ?? "Untitled"

        // Configure and trigger export
        Task {
            await exportViewModel.configure()
            exportViewModel.showExportPanel(
                content: content,
                format: format,
                defaultName: defaultName
            )
        }
    }

    /// Check Pandoc status (for UI updates)
    static func checkPandocStatus() async -> Bool {
        await exportViewModel.configure()
        return exportViewModel.isPandocAvailable
    }

    private static func showNoContentAlert() {
        let alert = NSAlert()
        alert.messageText = "No Content to Export"
        alert.informativeText = "Open a project with content before exporting."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
