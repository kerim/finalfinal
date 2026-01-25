//
//  ContentView.swift
//  final final
//

import SwiftUI

/// Line-based cursor position for cross-editor coordination.
/// Uses line/column instead of raw offsets because ProseMirror (tree-based)
/// and markdown (flat text) positions don't map 1:1.
struct CursorPosition: Equatable {
    let line: Int
    let column: Int

    static let start = CursorPosition(line: 1, column: 0)
}

struct ContentView: View {
    @Environment(ThemeManager.self) private var themeManager
    @State private var editorState = EditorViewState()
    @State private var cursorPositionToRestore: CursorPosition?
    @State private var sectionSyncService = SectionSyncService()

    private let demoContent = """
# Welcome to final final

This is a **WYSIWYG** editor powered by [Milkdown](https://milkdown.dev).

## Features

- Rich text editing
- Markdown support
- Focus mode (Cmd+Shift+F)
- Multiple themes

### Getting Started

Start typing to edit this document. Your changes are automatically saved.

> "The first draft is just you telling yourself the story." — Terry Pratchett

Try the following:

1. Toggle focus mode with **Cmd+Shift+F**
2. Switch themes with **Cmd+Opt+1** through **Cmd+Opt+5**
3. Toggle source view with **Cmd+/**
"""

    var body: some View {
        NavigationSplitView {
            sidebarView
        } detail: {
            detailView
        }
        .task {
            loadDemoContent()
            syncSections()
        }
        .onChange(of: editorState.content) { _, newValue in
            sectionSyncService.contentChanged(newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleFocusMode).receive(on: DispatchQueue.main)) { _ in
            editorState.toggleFocusMode()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleEditorMode).receive(on: DispatchQueue.main)) { _ in
            // Two-phase toggle: request cursor save first, then toggle after callback
            editorState.requestEditorModeToggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .didSaveCursorPosition).receive(on: DispatchQueue.main)) { notification in
            // Cursor saved - now complete the toggle
            if let position = notification.userInfo?["position"] as? CursorPosition {
                cursorPositionToRestore = position
            }
            editorState.toggleEditorMode()
        }
    }

    @ViewBuilder
    private var sidebarView: some View {
        VStack(spacing: 0) {
            // Zoom breadcrumb when zoomed into a section
            if let zoomedSection = editorState.zoomedSection {
                ZoomBreadcrumb(
                    zoomedSection: zoomedSection,
                    onZoomOut: {
                        editorState.zoomOut()
                    }
                )
                Divider()
            }

            OutlineSidebar(
                sections: $editorState.sections,
                statusFilter: $editorState.statusFilter,
                zoomedSectionId: $editorState.zoomedSectionId,
                onScrollToSection: { sectionId in
                    scrollToSection(sectionId)
                },
                onSectionUpdated: { section in
                    updateSection(section)
                },
                onSectionReorder: { request in
                    reorderSection(request)
                }
            )
        }
        .frame(minWidth: 250)
        .background(themeManager.currentTheme.sidebarBackground)
    }

    private func scrollToSection(_ sectionId: String) {
        // Find section and get its start offset
        guard let section = editorState.sections.first(where: { $0.id == sectionId }) else { return }

        // Request scroll to section's markdown content position
        // This will be handled by adding startOffset to Section model
        // For now, post a notification
        NotificationCenter.default.post(
            name: .scrollToSection,
            object: nil,
            userInfo: ["sectionId": sectionId]
        )
    }

    private func updateSection(_ section: SectionViewModel) {
        // TODO: Save section changes to database
        print("[ContentView] Section updated: \(section.title)")
    }

    private func reorderSection(_ request: SectionReorderRequest) {
        // Find the section to move
        guard let fromIndex = editorState.sections.firstIndex(where: { $0.id == request.sectionId }) else { return }

        // Remove from old position
        let section = editorState.sections.remove(at: fromIndex)

        // Calculate adjusted insertion index (account for removal shifting indices)
        let adjustedIndex = fromIndex < request.insertionIndex ? request.insertionIndex - 1 : request.insertionIndex
        let safeIndex = min(max(0, adjustedIndex), editorState.sections.count)

        // Update header level and parent
        section.headerLevel = request.newLevel
        section.parentId = request.newParentId

        // Insert at new position
        editorState.sections.insert(section, at: safeIndex)

        // Recalculate sort orders sequentially
        for (index, sectionVm) in editorState.sections.enumerated() {
            sectionVm.sortOrder = index
        }

        // TODO: Persist to database and update markdown
        print("[ContentView] Section reordered: \(request.sectionId) from index \(fromIndex) to \(safeIndex), level \(request.newLevel), parent: \(request.newParentId ?? "nil")")
    }

    @ViewBuilder
    private var detailView: some View {
        VStack(spacing: 0) {
            editorView
            StatusBar(editorState: editorState)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeManager.currentTheme.editorBackground)
    }

    @ViewBuilder
    private var editorView: some View {
        switch editorState.editorMode {
        case .wysiwyg:
            MilkdownEditor(
                content: $editorState.content,
                focusModeEnabled: $editorState.focusModeEnabled,
                cursorPositionToRestore: $cursorPositionToRestore,
                onContentChange: { _ in
                    // Content change handling - could trigger outline parsing here
                },
                onStatsChange: { words, characters in
                    editorState.updateStats(words: words, characters: characters)
                },
                onCursorPositionSaved: { position in
                    cursorPositionToRestore = position
                }
            )
        case .source:
            CodeMirrorEditor(
                content: $editorState.content,
                cursorPositionToRestore: $cursorPositionToRestore,
                onContentChange: { _ in
                    // Content change handling - could trigger outline parsing here
                },
                onStatsChange: { words, characters in
                    editorState.updateStats(words: words, characters: characters)
                },
                onCursorPositionSaved: { position in
                    cursorPositionToRestore = position
                }
            )
        }
    }

    private func loadDemoContent() {
        if editorState.content.isEmpty {
            editorState.content = demoContent
        }
    }

    private func syncSections() {
        Task {
            // For now, parse demo content into sections
            // In full implementation, this would load from ProjectDatabase
            let parser = SectionSyncService()
            editorState.sections = parseDemoSections()
        }
    }

    /// Temporary: Parse demo content into sections for testing
    private func parseDemoSections() -> [SectionViewModel] {
        var sections: [SectionViewModel] = []
        var currentOffset = 0
        var sortOrder = 0

        let lines = editorState.content.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let lineStr = String(line)
            let trimmed = lineStr.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("#") {
                if let (level, title) = parseHeader(trimmed) {
                    let section = Section(
                        projectId: "demo",
                        sortOrder: sortOrder,
                        headerLevel: level,
                        title: title,
                        markdownContent: "",
                        wordCount: 0
                    )
                    sections.append(SectionViewModel(from: section))
                    sortOrder += 1
                }
            }

            currentOffset += lineStr.count + 1
        }

        return sections
    }

    private func parseHeader(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }

        var level = 0
        var idx = line.startIndex

        while idx < line.endIndex && line[idx] == "#" && level < 6 {
            level += 1
            idx = line.index(after: idx)
        }

        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }

        let titleStart = line.index(after: idx)
        let title = String(line[titleStart...]).trimmingCharacters(in: .whitespaces)

        guard !title.isEmpty else { return nil }

        return (level, title)
    }
}

#Preview {
    ContentView()
        .environment(ThemeManager.shared)
}
