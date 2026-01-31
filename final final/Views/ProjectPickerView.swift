//
//  ProjectPickerView.swift
//  final final
//
//  Project picker shown on launch when no project is open.
//  Displays recent projects and options to create/open projects.
//

import SwiftUI
import AppKit

/// View shown when no project is open
struct ProjectPickerView: View {
    @Environment(ThemeManager.self) private var themeManager

    /// Callback when a project is selected or created
    var onProjectOpened: () -> Void

    /// Callback when Getting Started is requested
    var onGettingStartedRequested: () -> Void

    private var documentManager: DocumentManager { DocumentManager.shared }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // App icon or title area
            VStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("final final")
                    .font(.title)
                    .fontWeight(.medium)
            }
            .padding(.bottom, 16)

            // Recent projects section
            if !documentManager.recentProjects.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recent Projects")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    VStack(spacing: 4) {
                        ForEach(documentManager.recentProjects.prefix(5)) { entry in
                            RecentProjectRow(entry: entry) {
                                openRecentProject(entry)
                            }
                        }
                    }
                }
                .frame(maxWidth: 300)
            }

            // Action buttons
            HStack(spacing: 16) {
                Button("New Project") {
                    handleNewProject()
                }
                .buttonStyle(.borderedProminent)

                Button("Open Project...") {
                    handleOpenProject()
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 8)

            // Getting Started link
            Button {
                onGettingStartedRequested()
            } label: {
                Text("Getting Started")
                    .font(.callout)
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeManager.currentTheme.editorBackground)
    }

    private func openRecentProject(_ entry: DocumentManager.RecentProjectEntry) {
        Task { @MainActor in
            do {
                try documentManager.openRecentProject(entry)
                onProjectOpened()
            } catch {
                print("[ProjectPickerView] Failed to open recent project: \(error)")
                showErrorAlert(error)
            }
        }
    }

    private func handleNewProject() {
        let savePanel = NSSavePanel()
        savePanel.title = "Create New Project"
        savePanel.nameFieldLabel = "Project Name:"
        savePanel.nameFieldStringValue = "Untitled"
        savePanel.allowedContentTypes = [.init(exportedAs: "com.kerim.final-final.document")]
        savePanel.canCreateDirectories = true

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            Task { @MainActor in
                do {
                    let title = url.deletingPathExtension().lastPathComponent
                    try documentManager.newProject(at: url, title: title)
                    onProjectOpened()
                } catch {
                    print("[ProjectPickerView] Failed to create project: \(error)")
                    showErrorAlert(error)
                }
            }
        }
    }

    private func handleOpenProject() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Open Project"
        openPanel.allowedContentTypes = [.init(exportedAs: "com.kerim.final-final.document")]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true

        openPanel.begin { response in
            guard response == .OK, let url = openPanel.url else { return }

            Task { @MainActor in
                do {
                    try documentManager.openProject(at: url)
                    onProjectOpened()
                } catch {
                    print("[ProjectPickerView] Failed to open project: \(error)")
                    showErrorAlert(error)
                }
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

/// Row for a recent project entry
private struct RecentProjectRow: View {
    let entry: DocumentManager.RecentProjectEntry
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "doc.fill")
                    .foregroundColor(.secondary)
                Text(entry.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.05))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ProjectPickerView(
        onProjectOpened: {},
        onGettingStartedRequested: {}
    )
    .environment(ThemeManager.shared)
    .frame(width: 500, height: 400)
}
