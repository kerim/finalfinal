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

// swiftlint:disable:next type_body_length
struct ContentView: View {
    @Environment(ThemeManager.self) private var themeManager
    @State private var editorState = EditorViewState()
    @State private var cursorPositionToRestore: CursorPosition?
    @State private var sectionSyncService = SectionSyncService()

    // swiftlint:disable:next line_length
    private let demoContent = """
# Welcome to final final

This is a **WYSIWYG** editor powered by [Milkdown](https://milkdown.dev). \
The editor supports rich text editing with full markdown compatibility.

You can write prose naturally and see it formatted in real-time. \
This paragraph demonstrates that the outline sidebar correctly calculates word counts \
even with *italic* and **bold** formatting mixed throughout the text.

## Getting Started

Start typing to edit this document. Your changes are automatically saved to the project database, so you never have to worry about losing your work.

The sidebar on the left shows an outline of your document structure. You can:

- Click a section to scroll to it
- Double-click to zoom into that section
- Drag sections to reorder them
- Set word goals and track progress

### Quick Tips

Here are some keyboard shortcuts to help you get started:

1. Toggle focus mode with **Cmd+Shift+F** to dim surrounding paragraphs
2. Switch themes with **Cmd+Opt+1** through **Cmd+Opt+5**
3. Toggle source view with **Cmd+/** to see raw markdown

> "The first draft is just you telling yourself the story." — Terry Pratchett

### Using Slash Commands

Type `/` followed by a command name to quickly insert content:

- `/break` - Insert a section break marker
- `/h1` through `/h6` - Insert heading markers
- Press space after the command to activate it

## Writing Features

The editor includes several features designed for long-form writing projects like novels, academic papers, and documentation.

### Focus Mode

Focus mode dims paragraphs you're not currently editing, helping you concentrate on the text at hand. This is especially useful when working on longer sections where distractions can break your flow.

Enable focus mode with **Cmd+Shift+F** or from the View menu.

### Section Management

Each heading in your document becomes a section in the outline sidebar. Sections can have:

- **Status**: Track progress (Next, Writing, Waiting, Review, Final)
- **Word Goals**: Set targets and see progress bars
- **Tags**: Organize with custom labels

### Drag and Drop

Reorganize your document by dragging sections in the sidebar. The editor automatically:

1. Updates heading levels to maintain hierarchy
2. Preserves section metadata like status and goals
3. Syncs changes back to the editor immediately

## Advanced Topics

This section covers more advanced features for power users.

### Code Blocks

The editor supports fenced code blocks with syntax highlighting:

```swift
struct ContentView: View {
    @State private var content = ""

    var body: some View {
        Text("Hello, World!")
    }
}
```

### Tables

You can create tables using markdown syntax:

| Feature | Status | Notes |
|---------|--------|-------|
| WYSIWYG | Done | Milkdown editor |
| Source | Done | CodeMirror editor |
| Outline | Done | Section sidebar |
| Focus | Done | Paragraph dimming |

### Links and References

The editor supports [inline links](https://example.com) as well as reference-style links for cleaner prose in source mode.

## Project Organization

final final uses a package format (`.ff` files) to store your projects. Each package contains:

- A SQLite database for content and metadata
- Section information with hierarchy
- Project settings and preferences

### Multiple Documents

While this demo shows a single document, the full application will support projects with multiple documents organized in a binder-style interface.

### Export Options

When your project is complete, you'll be able to export to various formats including:

- Markdown (`.md`)
- HTML
- PDF (via system print)
- Word documents (`.docx`)

## Conclusion

This demo content provides a comprehensive test of the outline sidebar functionality. It includes multiple heading levels (H1, H2, H3), various markdown formatting, lists, code blocks, and tables.

Use this content to verify that:

1. Scroll-to-section works correctly
2. Word counts exclude markdown syntax
3. Section hierarchy is properly detected
4. Drag-drop reordering maintains document integrity
"""
// Note: Demo content ends WITH content (no trailing newline)
// to test that reorderSection() properly normalizes section endings

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

        // Set the scroll offset - editors will react to this
        editorState.scrollTo(offset: section.startOffset)
    }

    private func updateSection(_ section: SectionViewModel) {
        // TODO: Save section changes to database
    }

    private func reorderSection(_ request: SectionReorderRequest) {
        // Validate: section cannot be its own parent (circular reference)
        if request.newParentId == request.sectionId { return }

        // Find the section to move
        guard let fromIndex = editorState.sections.firstIndex(where: { $0.id == request.sectionId }) else { return }

        let oldSection = editorState.sections[fromIndex]
        let oldLevel = oldSection.headerLevel

        // Calculate adjusted insertion index (account for removal shifting indices)
        let adjustedIndex = fromIndex < request.insertionIndex ? request.insertionIndex - 1 : request.insertionIndex
        let safeIndex = min(max(0, adjustedIndex), editorState.sections.count - 1)

        // BEFORE removing: promote any children that will become orphaned
        promoteOrphanedChildren(
            movedSectionId: request.sectionId,
            movedFromIndex: fromIndex,
            movingToIndex: safeIndex,
            oldLevel: oldLevel
        )

        // Re-find the section index (it may have shifted after promotions)
        guard let currentFromIndex = editorState.sections.firstIndex(where: { $0.id == request.sectionId }) else { return }

        // Remove from old position
        let sectionToMove = editorState.sections.remove(at: currentFromIndex)

        // Recalculate safe index after removal
        let finalIndex = min(max(0, currentFromIndex < safeIndex ? safeIndex : safeIndex), editorState.sections.count)

        // Update markdown content if level changed
        var newMarkdown = sectionToMove.markdownContent
        if sectionToMove.headerLevel != request.newLevel && request.newLevel > 0 {
            newMarkdown = sectionSyncService.updateHeaderLevel(
                in: sectionToMove.markdownContent,
                to: request.newLevel
            )
        }

        // CREATE NEW OBJECT - critical for SwiftUI to detect change!
        let newSection = sectionToMove.withUpdates(
            parentId: request.newParentId,
            sortOrder: finalIndex,
            headerLevel: request.newLevel,
            markdownContent: newMarkdown,
            startOffset: 0  // Will be recalculated below
        )

        // Insert at new position
        editorState.sections.insert(newSection, at: finalIndex)

        // Recalculate parent relationships for ALL sections based on final positions
        recalculateParentRelationships()

        // Recalculate sort orders and start offsets for ALL sections
        var currentOffset = 0
        for index in editorState.sections.indices {
            let section = editorState.sections[index]
            editorState.sections[index] = section.withUpdates(
                sortOrder: index,
                startOffset: currentOffset
            )
            currentOffset += editorState.sections[index].markdownContent.count
        }

        // Enforce hierarchy constraints - no section can be more than 1 level deeper than predecessor
        enforceHierarchyConstraints()

        // Rebuild document - ensure every section ends with newline for proper markdown separation
        let newContent = editorState.sections
            .map { section in
                var content = section.markdownContent
                // Ensure every section ends with newline for proper markdown separation
                if !content.hasSuffix("\n") {
                    content += "\n"
                }
                return content
            }
            .joined()

        editorState.content = newContent
    }

    /// Promote children that will become orphaned when their parent moves below them
    private func promoteOrphanedChildren(
        movedSectionId: String,
        movedFromIndex: Int,
        movingToIndex: Int,
        oldLevel: Int
    ) {
        // Find direct children of the section being moved
        let childIndices = editorState.sections.enumerated()
            .filter { $0.element.parentId == movedSectionId }
            .map { $0.offset }

        for childIndex in childIndices {
            let child = editorState.sections[childIndex]

            // After the parent is removed, child stays at childIndex (if after parent) or shifts
            let childFinalIndex = childIndex > movedFromIndex ? childIndex - 1 : childIndex
            // Parent will be at movingToIndex after insertion
            let parentFinalIndex = movingToIndex

            // Child is orphaned if it ends up BEFORE the parent
            if childFinalIndex < parentFinalIndex {
                // Promote to the parent's old level
                let newLevel = oldLevel
                let newMarkdown = sectionSyncService.updateHeaderLevel(
                    in: child.markdownContent,
                    to: newLevel
                )

                editorState.sections[childIndex] = child.withUpdates(
                    headerLevel: newLevel,
                    markdownContent: newMarkdown
                )
            }
        }
    }

    /// Recalculate parentId for all sections based on document order and header levels
    /// A section's parent is the nearest preceding section with a lower header level
    private func recalculateParentRelationships() {
        for index in editorState.sections.indices {
            let section = editorState.sections[index]
            let newParentId = findParentByLevel(at: index)

            // Only update if parentId changed
            if section.parentId != newParentId {
                editorState.sections[index] = section.withUpdates(parentId: newParentId)
            }
        }
    }

    /// Find the appropriate parent for a section at the given index
    /// Parent = nearest preceding section with a LOWER header level
    private func findParentByLevel(at index: Int) -> String? {
        let section = editorState.sections[index]

        // H1 sections have no parent
        guard section.headerLevel > 1 else { return nil }

        // Look backwards for a section with lower level
        for i in stride(from: index - 1, through: 0, by: -1) {
            let candidate = editorState.sections[i]
            if candidate.headerLevel < section.headerLevel {
                return candidate.id
            }
        }

        return nil  // No valid parent found
    }

    /// Ensure no section is more than 1 level deeper than its predecessor
    /// Uses iterative transformation with already-processed predecessors for correct constraint checking
    private func enforceHierarchyConstraints() {
        var sections = editorState.sections
        var changed = true
        var passes = 0
        let maxPasses = 10

        while changed && passes < maxPasses {
            changed = false
            passes += 1

            // CRITICAL: Create new array each pass so predecessors are up-to-date
            // Using map with sections[index-1] would check the ORIGINAL value, not the
            // already-processed value from earlier in THIS pass
            var newSections: [SectionViewModel] = []

            for (index, section) in sections.enumerated() {
                // Use newSections for predecessor (already processed in THIS pass)
                let predecessorLevel = index > 0 ? newSections[index - 1].headerLevel : 0

                // First section must be H1
                if index == 0 && section.headerLevel != 1 {
                    changed = true
                    let newMarkdown = sectionSyncService.updateHeaderLevel(in: section.markdownContent, to: 1)
                    newSections.append(section.withUpdates(headerLevel: 1, markdownContent: newMarkdown))
                    continue
                }

                // Max level is predecessor + 1
                let maxLevel = predecessorLevel == 0 ? 1 : min(6, predecessorLevel + 1)
                if section.headerLevel > maxLevel {
                    changed = true
                    let newMarkdown = sectionSyncService.updateHeaderLevel(in: section.markdownContent, to: maxLevel)
                    newSections.append(section.withUpdates(headerLevel: maxLevel, markdownContent: newMarkdown))
                } else {
                    newSections.append(section)
                }
            }

            sections = newSections
        }

        // Single atomic update
        editorState.sections = sections
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
                scrollToOffset: $editorState.scrollToOffset,
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
                scrollToOffset: $editorState.scrollToOffset,
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
        Task { @MainActor in
            // For now, parse demo content into sections
            // In full implementation, this would load from ProjectDatabase
            editorState.sections = parseDemoSections()
            // Initialize parent relationships based on header levels
            recalculateParentRelationships()
        }
    }

    /// Temporary: Parse demo content into sections for testing
    private func parseDemoSections() -> [SectionViewModel] {
        var sections: [SectionViewModel] = []
        let content = editorState.content

        // First pass: find all header positions
        var headerPositions: [(offset: Int, level: Int, title: String)] = []
        var currentOffset = 0

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let lineStr = String(line)
            let trimmed = lineStr.trimmingCharacters(in: .whitespaces)

            if let (level, title) = parseHeader(trimmed) {
                headerPositions.append((currentOffset, level, title))
            }
            currentOffset += lineStr.count + 1
        }

        // Second pass: extract markdown content between headers
        for (index, header) in headerPositions.enumerated() {
            let endOffset: Int
            if index < headerPositions.count - 1 {
                endOffset = headerPositions[index + 1].offset
            } else {
                endOffset = content.count
            }

            // Extract markdown content for this section
            let startIdx = content.index(content.startIndex, offsetBy: header.offset)
            let endIdx = content.index(content.startIndex, offsetBy: min(endOffset, content.count))
            let markdownContent = String(content[startIdx..<endIdx])

            let section = Section(
                projectId: "demo",
                sortOrder: index,
                headerLevel: header.level,
                title: header.title,
                markdownContent: markdownContent,
                wordCount: countWords(in: markdownContent),
                startOffset: header.offset
            )
            sections.append(SectionViewModel(from: section))
        }

        return sections
    }

    private func countWords(in text: String) -> Int {
        MarkdownUtils.wordCount(for: text)
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
