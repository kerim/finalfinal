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
    @State private var demoProjectManager = DemoProjectManager()

    // swiftlint:disable line_length
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
// swiftlint:enable line_length
// Note: Demo content ends WITH content (no trailing newline)
// to test that reorderSection() properly normalizes section endings

    var body: some View {
        NavigationSplitView {
            sidebarView
        } detail: {
            detailView
        }
        .task {
            // Register editor state with AppDelegate for cleanup on quit
            AppDelegate.shared?.editorState = editorState
            await initializeProject()
        }
        .onChange(of: editorState.content) { _, newValue in
            // Skip sync during zoom transitions to prevent race conditions
            guard editorState.contentState == .idle else { return }
            // Pass zoomedIds when zoomed to enable in-place updates instead of replacing full array
            sectionSyncService.contentChanged(newValue, zoomedIds: editorState.zoomedSectionIds)
        }
        .onChange(of: editorState.zoomedSectionId) { _, newValue in
            // Track zoom state in sync service to prevent overwriting full document
            sectionSyncService.isContentZoomed = (newValue != nil)
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
                        editorState.zoomOutSync()
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
                },
                onZoomToSection: { sectionId in
                    Task {
                        await editorState.zoomToSection(sectionId)
                    }
                },
                onZoomOut: {
                    editorState.zoomOutSync()
                },
                onDragStarted: {
                    editorState.isObservationSuppressed = true
                    sectionSyncService.isSyncSuppressed = true
                    sectionSyncService.cancelPendingSync()
                },
                onDragEnded: {
                    editorState.isObservationSuppressed = false
                    sectionSyncService.isSyncSuppressed = false
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
        // Save section metadata changes to database
        Task {
            do {
                try demoProjectManager.saveSectionStatus(id: section.id, status: section.status)
                if let goal = section.wordGoal {
                    try demoProjectManager.saveSectionWordGoal(id: section.id, goal: goal)
                }
                if !section.tags.isEmpty {
                    try demoProjectManager.saveSectionTags(id: section.id, tags: section.tags)
                }
            } catch {
                print("[ContentView] Error saving section: \(error.localizedDescription)")
            }
        }
    }

    private func reorderSection(_ request: SectionReorderRequest) {
        print("[REORDER] === START ===")
        // swiftlint:disable:next line_length
        print("[REORDER] id=\(request.sectionId) target=\(request.targetSectionId ?? "nil") level=\(request.newLevel) parent=\(request.newParentId ?? "nil") subtree=\(request.isSubtreeDrag) children=\(request.childIds)")
        print("[REORDER] Current sections count: \(editorState.sections.count)")
        print("[REORDER] Section titles in order: \(editorState.sections.map { "\($0.title)[H\($0.headerLevel)]" })")

        sectionSyncService.cancelPendingSync()

        // Validate
        if request.newParentId == request.sectionId {
            print("[REORDER] ERROR: newParentId equals sectionId - circular reference prevented")
            return
        }
        guard let fromIndex = editorState.sections.firstIndex(where: { $0.id == request.sectionId }) else {
            print("[REORDER] ERROR: Section \(request.sectionId) not found in editorState.sections!")
            return
        }
        print("[REORDER] fromIndex=\(fromIndex)")

        // Use the target section ID passed from OutlineSidebar (stable across zoom/filtering)
        let targetSectionId = request.targetSectionId

        // Early return for self-drop at same position (no-op)
        if targetSectionId == request.sectionId {
            print("[REORDER] SKIP: Self-drop at same position")
            return
        }

        let sectionToMove = editorState.sections[fromIndex]
        let oldLevel = sectionToMove.headerLevel
        print("[REORDER] Moving section: '\(sectionToMove.title)' from index \(fromIndex), oldLevel=\(oldLevel)")

        if let targetId = targetSectionId,
           let targetSection = editorState.sections.first(where: { $0.id == targetId }) {
            print("[REORDER] Target section: '\(targetSection.title)' (insert AFTER this)")
        } else {
            print("[REORDER] Target section: nil (insert at beginning)")
        }

        // Branch: Subtree drag vs single-card drag
        if request.isSubtreeDrag && !request.childIds.isEmpty {
            reorderSubtree(request: request, fromIndex: fromIndex, oldLevel: oldLevel)
        } else {
            reorderSingleSection(request: request, fromIndex: fromIndex, oldLevel: oldLevel)
        }
    }

    /// Reorder a single section (original behavior, promotes orphaned children)
    private func reorderSingleSection(request: SectionReorderRequest, fromIndex: Int, oldLevel: Int) {
        let targetSectionId = request.targetSectionId

        // Work with a local copy to batch all SwiftUI updates
        var sections = editorState.sections
        print("[REORDER-SINGLE] Working with local copy of \(sections.count) sections")

        // 1. Promote orphaned children (on local copy)
        print("[REORDER-SINGLE] Step 1: Promoting orphaned children...")
        promoteOrphanedChildrenInPlace(
            sections: &sections,
            movedSectionId: request.sectionId,
            targetSectionId: targetSectionId,
            oldLevel: oldLevel
        )

        // 2. Re-find section after promotions
        guard let currentFromIndex = sections.firstIndex(where: { $0.id == request.sectionId }) else {
            print("[REORDER-SINGLE] ERROR: Section disappeared after promotions!")
            return
        }
        print("[REORDER-SINGLE] Step 2: currentFromIndex after promotions = \(currentFromIndex)")

        // 3. Remove the section
        var removed = sections.remove(at: currentFromIndex)
        print("[REORDER-SINGLE] Step 3: Removed section '\(removed.title)' from index \(currentFromIndex)")

        // 4. Find insertion point
        var finalIndex: Int
        if let targetId = targetSectionId,
           let targetIdx = sections.firstIndex(where: { $0.id == targetId }) {
            finalIndex = targetIdx + 1
            print("[REORDER-SINGLE] Step 4: Found target at idx \(targetIdx), finalIndex = \(finalIndex)")
        } else {
            finalIndex = 0
            print("[REORDER-SINGLE] Step 4: No target, finalIndex = 0")
        }
        finalIndex = min(max(0, finalIndex), sections.count)

        // 5. Update section properties
        if removed.headerLevel != request.newLevel && request.newLevel > 0 {
            let newMarkdown = sectionSyncService.updateHeaderLevel(
                in: removed.markdownContent,
                to: request.newLevel
            )
            removed = removed.withUpdates(
                parentId: request.newParentId,
                headerLevel: request.newLevel,
                markdownContent: newMarkdown
            )
            print("[REORDER-SINGLE] Step 5: Updated level from \(oldLevel) to \(request.newLevel)")
        } else {
            removed = removed.withUpdates(parentId: request.newParentId)
        }

        // 6. Insert at calculated position
        sections.insert(removed, at: finalIndex)
        print("[REORDER-SINGLE] Step 6: Inserted '\(removed.title)' at finalIndex \(finalIndex)")

        // 7. Finalize (shared logic)
        finalizeSectionReorder(sections: sections)
    }

    /// Reorder a subtree (parent + all children move together, levels adjusted relatively)
    private func reorderSubtree(request: SectionReorderRequest, fromIndex: Int, oldLevel: Int) {
        let targetSectionId = request.targetSectionId
        let levelDelta = request.newLevel - oldLevel  // How much to shift all levels

        print("[REORDER-SUBTREE] levelDelta=\(levelDelta) (newLevel=\(request.newLevel) - oldLevel=\(oldLevel))")
        print("[REORDER-SUBTREE] Moving \(request.childIds.count + 1) sections together")

        // Work with a local copy
        var sections = editorState.sections

        // 1. Collect all sections to move (parent + children) in order
        let allIdsToMove = [request.sectionId] + request.childIds
        var sectionsToMove: [SectionViewModel] = []

        for id in allIdsToMove {
            if let section = sections.first(where: { $0.id == id }) {
                sectionsToMove.append(section)
            }
        }
        print("[REORDER-SUBTREE] Step 1: Collected \(sectionsToMove.count) sections to move")

        // 2. Remove all sections being moved (in reverse order to maintain indices)
        let indicesToRemove = allIdsToMove.compactMap { id in
            sections.firstIndex(where: { $0.id == id })
        }.sorted().reversed()

        for idx in indicesToRemove {
            sections.remove(at: idx)
        }
        print("[REORDER-SUBTREE] Step 2: Removed \(allIdsToMove.count) sections from original positions")

        // 3. Find insertion point
        var insertionIndex: Int
        if let targetId = targetSectionId,
           let targetIdx = sections.firstIndex(where: { $0.id == targetId }) {
            insertionIndex = targetIdx + 1
            print("[REORDER-SUBTREE] Step 3: Found target at idx \(targetIdx), insertionIndex = \(insertionIndex)")
        } else {
            insertionIndex = 0
            print("[REORDER-SUBTREE] Step 3: No target, insertionIndex = 0")
        }
        insertionIndex = min(max(0, insertionIndex), sections.count)

        // 4. Apply level delta to all sections being moved
        var adjustedSections: [SectionViewModel] = []
        for (idx, section) in sectionsToMove.enumerated() {
            let newSectionLevel = section.headerLevel + levelDelta
            // Note: H7+ are allowed in data model (no clamping to 6)

            if idx == 0 {
                // Parent section - use the new parent from request
                let newMarkdown = sectionSyncService.updateHeaderLevel(
                    in: section.markdownContent,
                    to: newSectionLevel
                )
                let adjusted = section.withUpdates(
                    parentId: request.newParentId,
                    headerLevel: newSectionLevel,
                    markdownContent: newMarkdown
                )
                adjustedSections.append(adjusted)
                print("[REORDER-SUBTREE] Step 4: Parent '\(section.title)' H\(section.headerLevel) -> H\(newSectionLevel)")
            } else {
                // Child section - apply delta but parent will be recalculated later
                let newMarkdown = sectionSyncService.updateHeaderLevel(
                    in: section.markdownContent,
                    to: newSectionLevel
                )
                let adjusted = section.withUpdates(
                    headerLevel: newSectionLevel,
                    markdownContent: newMarkdown
                )
                adjustedSections.append(adjusted)
                print("[REORDER-SUBTREE] Step 4: Child '\(section.title)' H\(section.headerLevel) -> H\(newSectionLevel)")
            }
        }

        // 5. Insert all sections at the insertion point
        for (offset, section) in adjustedSections.enumerated() {
            sections.insert(section, at: insertionIndex + offset)
        }
        print("[REORDER-SUBTREE] Step 5: Inserted \(adjustedSections.count) sections at index \(insertionIndex)")

        // 6. Finalize (shared logic)
        finalizeSectionReorder(sections: sections)
    }

    /// Finalize section reorder - recalculate offsets, parent relationships, persist
    private func finalizeSectionReorder(sections: [SectionViewModel]) {
        var mutableSections = sections

        // Recalculate sort orders and offsets
        var currentOffset = 0
        for index in mutableSections.indices {
            mutableSections[index] = mutableSections[index].withUpdates(
                sortOrder: index,
                startOffset: currentOffset
            )
            currentOffset += mutableSections[index].markdownContent.count
        }
        print("[REORDER-FINALIZE] Recalculated sortOrders and offsets")

        // Single atomic update to trigger SwiftUI
        editorState.sections = mutableSections
        print("[REORDER-FINALIZE] Updated editorState.sections")
        print("[REORDER-FINALIZE] Final order: \(editorState.sections.map { "\($0.sortOrder):\($0.title)[H\($0.headerLevel)]" })")

        // Recalculate parent relationships and enforce hierarchy
        recalculateParentRelationships()
        enforceHierarchyConstraints()
        print("[REORDER-FINALIZE] Recalculated parent relationships and enforced hierarchy")

        // Rebuild document content (zoom-aware)
        rebuildDocumentContent()
        print("[REORDER-FINALIZE] Rebuilt document content")

        // Persist reordered sections to database
        print("[REORDER-FINALIZE] Dispatching persistReorderedSections()...")
        Task {
            await persistReorderedSections()
        }
        print("[REORDER] === END ===")
    }

    /// Persist current sections to database after reorder
    private func persistReorderedSections() async {
        print("[PERSIST] === START ===")
        print("[PERSIST] isObservationSuppressed: \(editorState.isObservationSuppressed)")

        guard let db = demoProjectManager.projectDatabase,
              let pid = demoProjectManager.projectId else {
            print("[PERSIST] ERROR: Database or projectId is nil!")
            return
        }

        print("[PERSIST] Building changes for \(editorState.sections.count) sections")

        // Build change set for all sections with updated sortOrder and potentially new levels
        var changes: [SectionChange] = []

        for (index, viewModel) in editorState.sections.enumerated() {
            let updates = SectionUpdates(
                title: viewModel.title,
                headerLevel: viewModel.headerLevel,
                sortOrder: index,
                markdownContent: viewModel.markdownContent,
                startOffset: viewModel.startOffset,
                parentId: .some(viewModel.parentId)  // Use .some to explicitly set (even if nil)
            )
            changes.append(.update(id: viewModel.id, updates: updates))
            print("[PERSIST] Change \(index): '\(viewModel.title)' sortOrder=\(index), level=\(viewModel.headerLevel)")
        }

        do {
            try db.applySectionChanges(changes, for: pid)
            print("[PERSIST] SUCCESS: \(changes.count) changes applied to database")
            // ValueObservation will automatically update the sidebar
        } catch {
            print("[PERSIST] ERROR: \(error)")
        }
        print("[PERSIST] === END ===")
    }

    /// Promote orphaned children in-place on a local array (avoids multiple SwiftUI updates)
    /// Uses target section ID for stable position comparison
    private func promoteOrphanedChildrenInPlace(
        sections: inout [SectionViewModel],
        movedSectionId: String,
        targetSectionId: String?,  // ID of section that will be BEFORE the moved section
        oldLevel: Int
    ) {
        guard let movedFromIndex = sections.firstIndex(where: { $0.id == movedSectionId }) else { return }

        // Find direct children of the section being moved
        let childIndices = sections.enumerated()
            .filter { $0.element.parentId == movedSectionId }
            .map { $0.offset }

        for childIndex in childIndices {
            let child = sections[childIndex]

            // After parent removal, where will the child be?
            let childFinalIndex = childIndex > movedFromIndex ? childIndex - 1 : childIndex

            // After parent removal, where will the target be? Parent inserts AFTER target.
            let parentFinalIndex: Int
            if let targetId = targetSectionId,
               let targetIdx = sections.firstIndex(where: { $0.id == targetId }) {
                // Target shifts down if it was after the removed section
                let targetFinalIndex = targetIdx > movedFromIndex ? targetIdx - 1 : targetIdx
                parentFinalIndex = targetFinalIndex + 1  // Parent goes AFTER target
            } else {
                parentFinalIndex = 0  // No target = insert at beginning
            }

            // Child is orphaned if it ends up BEFORE the parent in document order
            if childFinalIndex < parentFinalIndex {
                let newLevel = oldLevel
                let newMarkdown = sectionSyncService.updateHeaderLevel(
                    in: child.markdownContent,
                    to: newLevel
                )
                sections[childIndex] = child.withUpdates(
                    headerLevel: newLevel,
                    markdownContent: newMarkdown
                )
            }
        }
    }

    /// Rebuild document content based on zoom state (extracted for reuse)
    private func rebuildDocumentContent() {
        let sectionsToRebuild: [SectionViewModel]
        if let zoomedIds = editorState.zoomedSectionIds {
            sectionsToRebuild = editorState.sections
                .filter { zoomedIds.contains($0.id) }
                .sorted { $0.sortOrder < $1.sortOrder }
        } else {
            sectionsToRebuild = editorState.sections
        }

        editorState.content = sectionsToRebuild
            .map { section in
                var content = section.markdownContent
                if !content.hasSuffix("\n") { content += "\n" }
                return content
            }
            .joined()
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

    /// Initialize the project - load from database or create with demo content
    private func initializeProject() async {
        do {
            // Initialize demo project (creates if needed)
            try await demoProjectManager.ensureDemoProjectExists(demoContent: demoContent)

            // Configure sync service with database and start observation
            if let db = demoProjectManager.projectDatabase,
               let pid = demoProjectManager.projectId {
                sectionSyncService.configure(database: db, projectId: pid)

                // Start reactive observation (replaces callback-based updates)
                editorState.startObserving(database: db, projectId: pid)
            }

            // Try to load saved content from database
            if let savedContent = try demoProjectManager.loadContent(), !savedContent.isEmpty {
                editorState.content = savedContent
            } else {
                // Fall back to demo content for new projects
                editorState.content = demoContent
            }

            // Check if sections exist in database
            let existingSections = await sectionSyncService.loadSections()
            if existingSections.isEmpty {
                // No sections in database - trigger immediate sync to create them
                // ValueObservation will automatically update editorState.sections
                await sectionSyncService.syncNow(editorState.content)
            }
            // Note: editorState.sections is populated via ValueObservation in startObserving()

        } catch {
            print("[ContentView] Failed to initialize project: \(error.localizedDescription)")
            // Fall back to in-memory mode with demo content
            editorState.content = demoContent
            editorState.sections = parseDemoSections()
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
