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
                DebugLog.log(.fileOps, "[FileCommands] Posting .closeProject notification")
                NotificationCenter.default.post(name: .closeProject, object: nil)
            }
            .keyboardShortcut("w", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                NotificationCenter.default.post(name: .saveProject, object: nil)
            }
            .keyboardShortcut("s", modifiers: .command)

            Button("Save As...") {
                NotificationCenter.default.post(name: .saveProjectAs, object: nil)
            }

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

            Menu("Export Markdown") {
                Button("Markdown with Images...") {
                    NotificationCenter.default.post(name: .exportMarkdownWithImages, object: nil)
                }

                Button("Markdown Only...") {
                    NotificationCenter.default.post(name: .exportMarkdownOnly, object: nil)
                }

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

            Button("Export as PDF...") {
                NotificationCenter.default.post(
                    name: .exportDocument,
                    object: nil,
                    userInfo: ["format": ExportFormat.pdf]
                )
            }

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

        CommandGroup(replacing: .printItem) {
            Menu("Print") {
                Button("Formatted...") {
                    NotificationCenter.default.post(name: .printFormatted, object: nil)
                }
                .keyboardShortcut("p", modifiers: .command)

                Button("Raw Markdown...") {
                    NotificationCenter.default.post(name: .printRawMarkdown, object: nil)
                }
            }
        }
    }
}

/// Submenu view for recent projects
struct RecentProjectsMenu: View {
    var body: some View {
        let entries = DocumentManager.shared.recentProjects
        Group {
            ForEach(entries) { entry in
                Button(entry.title) {
                    openRecentProject(entry)
                }
            }

            if !entries.isEmpty {
                Divider()
                Button("Clear Recent Projects") {
                    if FileOperations.confirmClearRecentProjects() {
                        DocumentManager.shared.clearRecentProjects()
                    }
                }
            }
        }
    }

    private func openRecentProject(_ entry: DocumentManager.RecentProjectEntry) {
        // Guard against macOS state restoration replaying menu actions during launch
        guard DocumentManager.shared.hasCompletedInitialOpen else {
            DebugLog.log(.lifecycle, "[RecentProjectsMenu] Ignoring state-restoration replay during launch")
            return
        }
        Task { @MainActor in
            do {
                try DocumentManager.shared.openRecentProject(entry)
                NotificationCenter.default.post(name: .projectDidOpen, object: nil)
            } catch {
                DebugLog.log(.fileOps, "[FileCommands] Failed to open recent project: \(error)")
                // Prefer the actually-resolved URL, since it's now user-visible (the
                // sheet renders it) and Repair/Open Anyway would act on it -- only
                // fall back to the synthesized entry.path when resolution itself
                // failed, in which case there is no resolved URL to use anyway.
                let displayURL = DocumentManager.shared.resolveBookmark(entry.bookmarkData) ?? URL(fileURLWithPath: entry.path)
                ProjectOpenErrorState.shared.report(error, url: displayURL)
            }
        }
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
                    DebugLog.log(.fileOps, "[FileOperations] Project created, hasOpenProject: \(DocumentManager.shared.hasOpenProject)")
                    NotificationCenter.default.post(name: .projectDidCreate, object: nil)
                } catch {
                    DebugLog.log(.fileOps, "[FileOperations] Failed to create project: \(error)")
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
                    DebugLog.log(.fileOps, "[FileOperations] Project opened, hasOpenProject: \(DocumentManager.shared.hasOpenProject)")
                    NotificationCenter.default.post(name: .projectDidOpen, object: nil)
                } catch {
                    DebugLog.log(.fileOps, "[FileOperations] Failed to open project: \(error)")
                    ProjectOpenErrorState.shared.report(error, url: url)
                }
            }
        }
    }

    static func handleCloseProject() {
        DebugLog.log(.fileOps, "[FileOperations] handleCloseProject() called")
        let dm = DocumentManager.shared

        // Getting Started is an ephemeral playground with nothing to save -- always close
        // cleanly, no confirmation. (See t-fa000add: the previous "changes not saved" alert
        // fired inconsistently in both directions; edit awareness now surfaces as an
        // in-editor toast instead, via SectionSyncService's checkGettingStartedEdited.)
        if dm.isGettingStartedProject {
            dm.closeProject()
            DebugLog.log(.fileOps, "[FileOperations] Posting .projectDidClose notification (Getting Started)")
            NotificationCenter.default.post(name: .projectDidClose, object: nil)
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
                DebugLog.log(.fileOps, "[FileOperations] Posting .projectDidClose notification (saved)")
                NotificationCenter.default.post(name: .projectDidClose, object: nil)
            case .alertSecondButtonReturn:
                // Close without saving
                dm.closeProject()
                DebugLog.log(.fileOps, "[FileOperations] Posting .projectDidClose notification (no save)")
                NotificationCenter.default.post(name: .projectDidClose, object: nil)
            default:
                // Cancel - do nothing
                break
            }
        } else {
            dm.closeProject()
            DebugLog.log(.fileOps, "[FileOperations] Posting .projectDidClose notification (no changes)")
            NotificationCenter.default.post(name: .projectDidClose, object: nil)
        }
    }

    static func handleSaveProject() {
        // Note: Content is auto-saved by SectionSyncService
        // This explicit save is for any pending changes
        DocumentManager.shared.markClean()
        AppDelegate.shared?.autoBackupService?.contentDidSave()
        DebugLog.log(.fileOps, "[FileOperations] Project saved")
    }

    static func handleSaveProjectAs() {
        let dm = DocumentManager.shared

        // Guard: must have an open project that isn't Getting Started
        guard dm.hasOpenProject, let sourceURL = dm.projectURL else {
            DebugLog.log(.fileOps, "[FileOperations] Save As: no project open")
            return
        }
        if dm.isGettingStartedProject {
            DebugLog.log(.fileOps, "[FileOperations] Save As: cannot Save As from Getting Started")
            return
        }

        let defaultName = dm.projectTitle ?? sourceURL.deletingPathExtension().lastPathComponent

        let savePanel = NSSavePanel()
        savePanel.title = "Save As"
        savePanel.nameFieldLabel = "Project Name:"
        savePanel.nameFieldStringValue = defaultName
        savePanel.allowedContentTypes = [.init(exportedAs: "com.kerim.final-final.document")]
        savePanel.canCreateDirectories = true

        savePanel.begin { response in
            guard response == .OK, let destURL = savePanel.url else { return }

            // Explicitly close the panel before async work
            savePanel.orderOut(nil)

            Task { @MainActor in
                do {
                    // Flush pending editor content to database right before copy
                    AppDelegate.shared?.editorState?.flushContentToDatabase()

                    // PASSIVE checkpoint: merges as much WAL as possible without
                    // requiring exclusive access. copyItem copies the entire .ff
                    // package including -wal and -shm files, so SQLite replays
                    // any remaining WAL data when the copy is opened.
                    do {
                        try dm.projectDatabase?.dbWriter.writeWithoutTransaction { db in
                            try db.checkpoint(.passive)
                        }
                    } catch {
                        DebugLog.log(.fileOps, "[FileOperations] Save As: WAL checkpoint warning: \(error)")
                    }

                    let fm = FileManager.default

                    // Remove destination if it already exists
                    if fm.fileExists(atPath: destURL.path) {
                        try fm.removeItem(at: destURL)
                    }

                    // Copy the entire .ff package
                    try fm.copyItem(at: sourceURL, to: destURL)

                    // Open the copy (this internally closes the current project)
                    try dm.openProject(at: destURL)

                    // Update title in copied database to match new filename
                    let newTitle = destURL.deletingPathExtension().lastPathComponent
                    if let db = dm.projectDatabase, var project = try db.fetchProject() {
                        project.title = newTitle
                        try db.updateProject(project)
                        dm.projectTitle = newTitle
                    }

                    NotificationCenter.default.post(name: .projectDidOpen, object: nil)

                    DebugLog.log(.fileOps, "[FileOperations] Save As completed: \(destURL.path)")
                } catch {
                    DebugLog.log(.fileOps, "[FileOperations] Save As failed: \(error)")
                    showErrorAlert("Could Not Save Project", error: error)
                }
            }
        }
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
                                DebugLog.log(.fileOps, "[FileOperations] Failed to import: \(error)")
                                showErrorAlert("Could Not Import File", error: error)
                            }
                        }
                    }
                } catch {
                    DebugLog.log(.fileOps, "[FileOperations] Failed to read file: \(error)")
                    showErrorAlert("Could Not Read File", error: error)
                }
            }
        }
    }

    // Export handlers (handleExportMarkdownWithImages, handleExportTextBundle, and their
    // success/no-content helpers) live in FileCommands+Export.swift.

    static func showErrorAlert(_ title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Builds (but does not present) the Clear Recent Projects confirmation alert. Split out
    /// from `confirmClearRecentProjects()` so the button wiring below is unit-testable without
    /// ever calling `runModal()` (which would show a real, blocking modal window).
    ///
    /// "Clear Recent Projects" is a Commands-menu action, so SwiftUI cannot present a
    /// `.confirmationDialog` here (see `.claude/rules/ux-contract.md` §3 and the
    /// `.destructiveConfirmation` view modifier used by the SwiftUI sites) -- this uses
    /// `NSAlert` instead, reading its wording from the same `DestructiveConfirmationCopy` the
    /// SwiftUI sites use, so the two presentation mechanisms never drift.
    ///
    /// Button order matches every stock macOS destructive alert (review round finding):
    /// the ACTION button is added FIRST, which NSAlert renders rightmost -- the standard
    /// primary-button position -- and Cancel is added SECOND, rendering to its left. (The
    /// previous round had this backwards: Cancel first/rightmost, action second/left.)
    ///
    /// That standard position is exactly why the key-equivalent wiring below can't be the
    /// simple "first button -> Return" default: NSAlert auto-assigns Return to whichever
    /// button is added first (here, the destructive one) and Escape to a button literally
    /// titled "Cancel" -- but ONLY for a button whose `keyEquivalent` is still empty at
    /// `layout()` time, and each `NSButton` has exactly one `keyEquivalent` slot. Per
    /// ux-contract §3, Cancel -- never the destructive button -- must be the Return default,
    /// so:
    ///   1. `alert.layout()` forces NSAlert to wire each button's target/action now, while
    ///      both are still untouched (needed for step 3).
    ///   2. The destructive button's auto-assigned Return is explicitly cleared; Cancel's
    ///      slot is explicitly given Return. This alone would leave Cancel's own slot with
    ///      no room for Escape.
    ///   3. A second, invisible button (`NSButton.isTransparent`, in a zero-size accessory
    ///      view) carries the Escape key equivalent and shares Cancel's target/action/tag --
    ///      NSAlert dispatches every button through the same private handler keyed by tag,
    ///      so triggering the invisible button resolves `runModal()` with Cancel's own
    ///      response code. This is the standard AppKit workaround for "one logical action,
    ///      two key equivalents" (a single button object cannot hold both).
    ///
    /// This was verified against AppKit's documented auto-assignment behavior and the
    /// community-established relay-button pattern for it -- see the `alert.layout()`-based
    /// test in `DestructiveConfirmationCopyTests.swift`, which is a real assertion on runtime
    /// state rather than a readback of what this function just set. e2e (`E2EScratchTests`)
    /// has since confirmed this live: pressing Escape correctly dismisses the alert without
    /// clearing recents.
    static func makeClearRecentProjectsAlert() -> NSAlert {
        let copy = DestructiveConfirmationCopy.clearRecentProjects
        let alert = NSAlert()
        alert.messageText = copy.title
        alert.informativeText = copy.message
        alert.alertStyle = .warning

        let destructiveButton = alert.addButton(withTitle: copy.confirmTitle)
        let cancelButton = alert.addButton(withTitle: "Cancel")
        destructiveButton.hasDestructiveAction = true

        alert.layout()

        destructiveButton.keyEquivalent = ""
        cancelButton.keyEquivalent = "\r"

        let escapeRelay = NSButton(frame: .zero)
        escapeRelay.target = cancelButton.target
        escapeRelay.action = cancelButton.action
        escapeRelay.tag = cancelButton.tag
        escapeRelay.keyEquivalent = "\u{1b}"
        escapeRelay.isTransparent = true
        let accessory = NSView(frame: .zero)
        accessory.addSubview(escapeRelay)
        alert.accessoryView = accessory

        return alert
    }

    /// Shows the Clear Recent Projects confirmation alert. Returns `true` only if the user chose
    /// the destructive action.
    ///
    /// The destructive button is now added FIRST (review round: standard button order, see
    /// `makeClearRecentProjectsAlert()`), so its response is `.alertFirstButtonReturn` --
    /// this flipped from `.alertSecondButtonReturn` along with the button order and would
    /// otherwise have silently inverted this method's result (Cancel would read as "clear",
    /// and vice versa).
    static func confirmClearRecentProjects() -> Bool {
        let alert = makeClearRecentProjectsAlert()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
