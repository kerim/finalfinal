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
                .disabled(ExportActivity.shared.isRunning)

                Button("Markdown Only...") {
                    NotificationCenter.default.post(name: .exportMarkdownOnly, object: nil)
                }
                .disabled(ExportActivity.shared.isRunning)

                Button("TextBundle...") {
                    NotificationCenter.default.post(name: .exportTextBundle, object: nil)
                }
                .disabled(ExportActivity.shared.isRunning)
            }

            Divider()

            Button("Export as Word...") {
                NotificationCenter.default.post(
                    name: .exportDocument,
                    object: nil,
                    userInfo: ["format": ExportFormat.word]
                )
            }
            .disabled(ExportActivity.shared.isRunning)

            Button("Export as PDF...") {
                NotificationCenter.default.post(
                    name: .exportDocument,
                    object: nil,
                    userInfo: ["format": ExportFormat.pdf]
                )
            }
            .disabled(ExportActivity.shared.isRunning)

            Button("Export as ODT...") {
                NotificationCenter.default.post(
                    name: .exportDocument,
                    object: nil,
                    userInfo: ["format": ExportFormat.odt]
                )
            }
            .disabled(ExportActivity.shared.isRunning)

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
                .disabled(ExportActivity.shared.isRunning)

                Button("Raw Markdown...") {
                    NotificationCenter.default.post(name: .printRawMarkdown, object: nil)
                }
                .disabled(ExportActivity.shared.isRunning)
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
        // E3 (t-94369a83 3a-1b, round C7a): the open runs inside the lifecycle entry (the old project is saved and
        // backed up first), and a failure is reported with the actually-resolved URL -- see `ProjectCommands`.
        Task { @MainActor in
            await ProjectCommands.openRecent(entry)
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

            // E7 (t-94369a83 3a-1b, round C8a): the creation runs inside the lifecycle entry (the old project is
            // saved and backed up first) -- see `ProjectCommands.newProject`, which also shows the failure alert.
            Task { @MainActor in
                let title = url.deletingPathExtension().lastPathComponent
                await ProjectCommands.newProject(at: url, title: title)
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

            // E2 (t-94369a83 3a-1b, round C7a): the open runs inside the lifecycle entry (the old project is saved
            // and backed up first) -- see `ProjectCommands`, which also reports a failure as it always was.
            Task { @MainActor in
                await ProjectCommands.open(url: url)
            }
        }
    }

    /// E1 (t-94369a83 3a-1b, round C7a): Cmd-W, the window's red button and File > Close Project. The work is in
    /// `ProjectCommands.close` (Getting Started closes directly; the unsaved-changes alert comes first; a regular
    /// project is saved through the write queue and then closed).
    static func handleCloseProject() {
        DebugLog.log(.fileOps, "[FileOperations] handleCloseProject() called")
        Task { @MainActor in
            await ProjectCommands.close()
        }
    }

    /// The "Do you want to save changes before closing?" alert, as the user answered it.
    static func confirmSaveBeforeClosing() -> UnsavedChangesChoice {
        let alert = NSAlert()
        alert.messageText = "Do you want to save changes before closing?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .dontSave
        default: return .cancel
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

        // The project the save panel names (t-eb07cd67): with no project open, or Getting Started open, the user is told why
        // (`ProjectCommands.saveAsSource` shows the alert) instead of the menu item silently doing nothing.
        guard let sourceURL = ProjectCommands.saveAsSource() else { return }

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

            // E4 (t-94369a83 3a-1b, round C8a): the copy is made inside the lifecycle entry, AFTER the save sequence
            // wrote the editor's fresh content through the ordered queue (the direct flush that used to sit here is
            // gone) -- see `ProjectCommands.saveAs` for the copy, the open, the non-fatal rename and the failure alert.
            // `sourceURL` is the project this save panel named, taken when the panel was shown (t-eb07cd67): the command copies THAT
            // project even if another one is opened while this waits for an earlier command.
            Task { @MainActor in
                await ProjectCommands.saveAs(from: sourceURL, to: destURL)
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

                        // E8 (t-94369a83 3a-1b, round C8a): the import runs inside the lifecycle entry (the old project
                        // is saved and backed up first) and the create tail seeds the new project with `content` -- see
                        // `ProjectCommands.importMarkdown`, which also shows the failure alert.
                        Task { @MainActor in
                            await ProjectCommands.importMarkdown(content, to: saveURL)
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
