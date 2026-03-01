//
//  FileCommands.swift
//  final final
//
//  File menu commands for project management.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FileCommands: Commands {
    var body: some Commands {
        // Replace the default New/Open/Save commands
        CommandGroup(replacing: .newItem) {
            Button("New Project...") {
                NotificationCenter.default.post(name: .newProject, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Open Project...") {
                NotificationCenter.default.post(name: .openProject, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)

            // Recent Projects submenu
            Menu("Open Recent") {
                RecentProjectsMenu()
            }

            Divider()

            // Close Project (Cmd-W) - closes project and shows picker
            Button("Close Project") {
                print("[FileCommands] Posting .closeProject notification")
                NotificationCenter.default.post(name: .closeProject, object: nil)
            }
            .keyboardShortcut("w", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                NotificationCenter.default.post(name: .saveProject, object: nil)
            }
            .keyboardShortcut("s", modifiers: .command)

            Divider()

            Button("Save Version...") {
                NotificationCenter.default.post(name: .saveVersion, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button("Version History...") {
                NotificationCenter.default.post(name: .showVersionHistory, object: nil)
            }
            .keyboardShortcut("v", modifiers: [.command, .option])
        }

        CommandGroup(replacing: .importExport) {
            Button("Import Markdown...") {
                NotificationCenter.default.post(name: .importMarkdown, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])

            Menu("Export Markdown") {
                Button("Markdown with Images...") {
                    NotificationCenter.default.post(name: .exportMarkdownWithImages, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("TextBundle...") {
                    NotificationCenter.default.post(name: .exportTextBundle, object: nil)
                }
            }

            Divider()

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

            Button("Export Preferences...") {
                NotificationCenter.default.post(name: .showExportPreferences, object: nil)
            }
        }
    }
}

/// Submenu view for recent projects
struct RecentProjectsMenu: View {
    @State private var recentProjects: [DocumentManager.RecentProjectEntry] = []

    var body: some View {
        Group {
            ForEach(recentProjects) { entry in
                Button(entry.title) {
                    openRecentProject(entry)
                }
            }

            if !recentProjects.isEmpty {
                Divider()
                Button("Clear Recent Projects") {
                    Task { @MainActor in
                        DocumentManager.shared.clearRecentProjects()
                        recentProjects = []
                    }
                }
            }
        }
        .onAppear {
            recentProjects = DocumentManager.shared.recentProjects
        }
    }

    private func openRecentProject(_ entry: DocumentManager.RecentProjectEntry) {
        Task { @MainActor in
            do {
                try DocumentManager.shared.openRecentProject(entry)
                NotificationCenter.default.post(name: .projectDidOpen, object: nil)
            } catch {
                print("[FileCommands] Failed to open recent project: \(error)")
                showErrorAlert(error)
            }
        }
    }

    private func showErrorAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could Not Open Project"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Notification Names for File Operations

extension Notification.Name {
    /// Posted after a project has been opened (for UI updates)
    static let projectDidOpen = Notification.Name("projectDidOpen")
    /// Posted after a project has been closed (for UI updates)
    static let projectDidClose = Notification.Name("projectDidClose")
    /// Posted after a new project has been created (for UI updates)
    static let projectDidCreate = Notification.Name("projectDidCreate")
    /// Posted when a project fails integrity check (userInfo: "report" -> IntegrityReport, "url" -> URL)
    static let projectIntegrityError = Notification.Name("projectIntegrityError")

    // Version history notifications
    /// Posted when user wants to save a named version (Cmd+Shift+S)
    static let saveVersion = Notification.Name("saveVersion")
    /// Posted when user wants to show version history (Cmd+Option+V)
    static let showVersionHistory = Notification.Name("showVersionHistory")
}

// MARK: - File Operation Handlers

/// Handles file menu operations - called from ContentView
@MainActor
struct FileOperations {

    static func handleNewProject() {
        let savePanel = NSSavePanel()
        savePanel.title = "Create New Project"
        savePanel.nameFieldLabel = "Project Name:"
        savePanel.nameFieldStringValue = "Untitled"
        savePanel.allowedContentTypes = [.init(exportedAs: "com.kerim.final-final.document")]
        savePanel.canCreateDirectories = true

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            // Explicitly close the panel before async work
            savePanel.orderOut(nil)

            Task { @MainActor in
                do {
                    let title = url.deletingPathExtension().lastPathComponent
                    try DocumentManager.shared.newProject(at: url, title: title)
                    #if DEBUG
                    print("[FileOperations] Project created, hasOpenProject: \(DocumentManager.shared.hasOpenProject)")
                    #endif
                    NotificationCenter.default.post(name: .projectDidCreate, object: nil)
                } catch {
                    print("[FileOperations] Failed to create project: \(error)")
                    showErrorAlert("Could Not Create Project", error: error)
                }
            }
        }
    }

    static func handleOpenProject() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Open Project"
        openPanel.allowedContentTypes = [.init(exportedAs: "com.kerim.final-final.document")]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true

        openPanel.begin { response in
            guard response == .OK, let url = openPanel.url else { return }

            // Explicitly close the panel before async work
            openPanel.orderOut(nil)

            Task { @MainActor in
                do {
                    try DocumentManager.shared.openProject(at: url)
                    #if DEBUG
                    print("[FileOperations] Project opened, hasOpenProject: \(DocumentManager.shared.hasOpenProject)")
                    #endif
                    NotificationCenter.default.post(name: .projectDidOpen, object: nil)
                } catch let error as IntegrityError {
                    // Post notification for ContentView to show integrity alert
                    if let report = error.integrityReport {
                        print("[FileOperations] Integrity error, posting notification for: \(url.path)")
                        NotificationCenter.default.post(
                            name: .projectIntegrityError,
                            object: nil,
                            userInfo: ["report": report, "url": url]
                        )
                    } else {
                        print("[FileOperations] IntegrityError with nil report: \(error)")
                        showErrorAlert("Could Not Open Project", error: error)
                    }
                } catch {
                    print("[FileOperations] Failed to open project: \(error)")
                    showErrorAlert("Could Not Open Project", error: error)
                }
            }
        }
    }

    static func handleCloseProject() {
        print("[FileOperations] handleCloseProject() called")
        let dm = DocumentManager.shared

        // Check if this is the Getting Started project with modifications
        if dm.isGettingStartedProject && dm.isGettingStartedModified() {
            let alert = NSAlert()
            alert.messageText = "Changes Not Saved"
            alert.informativeText = "Changes to Getting Started aren't saved. Create a new project to keep your work."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Create New Project")

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                // Discard - just close
                dm.closeProject()
                print("[FileOperations] Posting .projectDidClose notification (Getting Started discard)")
                NotificationCenter.default.post(name: .projectDidClose, object: nil)
            case .alertSecondButtonReturn:
                // Create New Project - show save panel
                handleCreateFromGettingStarted()
            default:
                break
            }
            return
        }

        // Check for unsaved changes (regular projects)
        if dm.hasUnsavedChanges {
            let alert = NSAlert()
            alert.messageText = "Do you want to save changes before closing?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                // Save then close
                handleSaveProject()
                dm.closeProject()
                print("[FileOperations] Posting .projectDidClose notification (saved)")
                NotificationCenter.default.post(name: .projectDidClose, object: nil)
            case .alertSecondButtonReturn:
                // Close without saving
                dm.closeProject()
                print("[FileOperations] Posting .projectDidClose notification (no save)")
                NotificationCenter.default.post(name: .projectDidClose, object: nil)
            default:
                // Cancel - do nothing
                break
            }
        } else {
            dm.closeProject()
            print("[FileOperations] Posting .projectDidClose notification (no changes)")
            NotificationCenter.default.post(name: .projectDidClose, object: nil)
        }
    }

    /// Handle "Create New Project" from Getting Started
    private static func handleCreateFromGettingStarted() {
        let dm = DocumentManager.shared

        // Get current content before closing
        let currentContent = (try? dm.getCurrentContent()) ?? ""

        let savePanel = NSSavePanel()
        savePanel.title = "Save Your Work"
        savePanel.nameFieldLabel = "Project Name:"
        savePanel.nameFieldStringValue = "Untitled"
        savePanel.allowedContentTypes = [.init(exportedAs: "com.kerim.final-final.document")]
        savePanel.canCreateDirectories = true

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            // Explicitly close the panel before async work
            savePanel.orderOut(nil)

            Task { @MainActor in
                do {
                    let title = url.deletingPathExtension().lastPathComponent
                    try dm.newProject(at: url, title: title, initialContent: currentContent)
                    // Notify that a new project was created
                    NotificationCenter.default.post(name: .projectDidCreate, object: nil)
                } catch {
                    print("[FileOperations] Failed to create project from Getting Started: \(error)")
                }
            }
        }
    }

    static func handleSaveProject() {
        // Note: Content is auto-saved by SectionSyncService
        // This explicit save is for any pending changes
        DocumentManager.shared.markClean()
        print("[FileOperations] Project saved")
    }

    static func handleImportMarkdown() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Import Markdown"
        openPanel.allowedContentTypes = [.plainText]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true

        openPanel.begin { response in
            guard response == .OK, let url = openPanel.url else { return }

            // Explicitly close the panel before async work
            openPanel.orderOut(nil)

            Task { @MainActor in
                do {
                    // Read the markdown content
                    let content = try String(contentsOf: url, encoding: .utf8)

                    // Create a new project with the imported content
                    let savePanel = NSSavePanel()
                    savePanel.title = "Save Imported Project"
                    savePanel.nameFieldLabel = "Project Name:"
                    savePanel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent
                    savePanel.allowedContentTypes = [.init(exportedAs: "com.kerim.final-final.document")]
                    savePanel.canCreateDirectories = true

                    savePanel.begin { saveResponse in
                        guard saveResponse == .OK, let saveURL = savePanel.url else { return }

                        // Explicitly close the panel before async work
                        savePanel.orderOut(nil)

                        Task { @MainActor in
                            do {
                                let title = saveURL.deletingPathExtension().lastPathComponent
                                try DocumentManager.shared.newProject(at: saveURL, title: title)
                                try DocumentManager.shared.saveContent(content)
                                NotificationCenter.default.post(
                                    name: .projectDidCreate,
                                    object: nil,
                                    userInfo: ["content": content]
                                )
                            } catch {
                                print("[FileOperations] Failed to import: \(error)")
                                showErrorAlert("Could Not Import File", error: error)
                            }
                        }
                    }
                } catch {
                    print("[FileOperations] Failed to read file: \(error)")
                    showErrorAlert("Could Not Read File", error: error)
                }
            }
        }
    }

    static func handleExportMarkdownWithImages() {
        let dm = DocumentManager.shared
        guard let db = dm.projectDatabase, let pid = dm.projectId else {
            showNoContentError()
            return
        }

        // Fetch blocks, filter bibliography, assemble standard markdown + extract image filenames
        let blocks: [Block]
        do {
            blocks = try db.fetchBlocks(projectId: pid).filter { !$0.isBibliography }
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

    static func handleExportTextBundle() {
        let dm = DocumentManager.shared
        guard let db = dm.projectDatabase, let pid = dm.projectId else {
            showNoContentError()
            return
        }

        // Fetch blocks, filter bibliography, assemble standard markdown + extract image filenames
        let blocks: [Block]
        do {
            blocks = try db.fetchBlocks(projectId: pid).filter { !$0.isBibliography }
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

    private static func showErrorAlert(_ title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
