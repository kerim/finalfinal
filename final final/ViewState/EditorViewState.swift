//
//  EditorViewState.swift
//  final final
//

import SwiftUI

// MARK: - Editor Toggle Notifications
extension Notification.Name {
    /// Posted when editor mode toggle is requested - current editor should save cursor
    static let willToggleEditorMode = Notification.Name("willToggleEditorMode")
    /// Posted after cursor position is saved - toggle can proceed
    static let didSaveCursorPosition = Notification.Name("didSaveCursorPosition")
    /// Posted when sidebar requests scroll to a section
    static let scrollToSection = Notification.Name("scrollToSection")
    /// Posted when annotation display modes change - editors should update rendering
    static let annotationDisplayModesChanged = Notification.Name("annotationDisplayModesChanged")
    /// Posted to insert an annotation at the current cursor position (for keyboard shortcuts Cmd+Shift+T/C/R)
    static let insertAnnotation = Notification.Name("insertAnnotation")
    /// Posted to toggle highlight mark on selected text (Cmd+Shift+H)
    static let toggleHighlight = Notification.Name("toggleHighlight")
    /// Posted when citation library should be pushed to editor
    static let citationLibraryChanged = Notification.Name("citationLibraryChanged")
}

enum EditorMode: String, CaseIterable {
    case wysiwyg = "WYSIWYG"
    case source = "Source"
}

/// Content state machine - replaces multiple boolean flags for zoom/enforcement transitions
enum EditorContentState {
    case idle
    case zoomTransition
    case hierarchyEnforcement
}

@MainActor
@Observable
class EditorViewState {
    var editorMode: EditorMode = .wysiwyg
    var focusModeEnabled: Bool = false
    var zoomedSectionId: String?
    var wordCount: Int = 0
    var characterCount: Int = 0
    var currentSectionName: String = ""

    // MARK: - Content State Machine
    /// Tracks content transitions to prevent race conditions
    var contentState: EditorContentState = .idle

    /// When true, editor polling should skip updating the content binding.
    /// Used during project switch to prevent old editor content from bleeding into new projects.
    var isResettingContent = false

    /// Full document stored when zoomed (section-level backup)
    var fullDocumentBeforeZoom: String?

    /// IDs of sections included in the zoom (root + descendants)
    var zoomedSectionIds: Set<String>?

    // MARK: - Content
    var content: String = ""

    // MARK: - Scroll Request
    var scrollToOffset: Int?

    // MARK: - Sidebar State (Phase 1.6)
    var sections: [SectionViewModel] = []
    var statusFilter: SectionStatus?

    // MARK: - Annotation State (Phase 2)
    var annotations: [AnnotationViewModel] = []

    /// Display mode for each annotation type (inline or collapsed)
    var annotationDisplayModes: [AnnotationType: AnnotationDisplayMode] = [
        .task: .inline,
        .comment: .inline,
        .reference: .inline
    ]

    /// Type filters - which annotation types are visible in the panel
    var annotationTypeFilters: Set<AnnotationType> = Set(AnnotationType.allCases)

    /// Whether the annotation panel is visible
    var isAnnotationPanelVisible: Bool = true

    /// Whether the outline sidebar is visible
    var isOutlineSidebarVisible: Bool = true

    /// Global "panel only" mode - when true, ALL annotations are hidden from editor
    /// (regardless of per-type display mode settings)
    var isPanelOnlyMode: Bool = false

    /// Hide completed tasks from the annotation panel
    var hideCompletedTasks: Bool = false

    // MARK: - Zotero Integration (Phase 1.8)

    /// Zotero service reference (injected, not owned)
    weak var zoteroService: ZoteroService?

    /// Whether citation library has been pushed to the editor
    var isCitationLibraryPushed: Bool = false

    // MARK: - Database Observation
    private var observationTask: Task<Void, Never>?
    private var annotationObservationTask: Task<Void, Never>?

    /// When true, ValueObservation updates are ignored (used during drag-drop reorder)
    var isObservationSuppressed = false

    /// Callback invoked after sections are updated from database observation
    /// Used by ContentView to enforce hierarchy constraints after slash command changes
    var onSectionsUpdated: (() -> Void)?

    /// Start observing sections from database for reactive UI updates
    /// Call this once during initialization after database is ready
    func startObserving(database: ProjectDatabase, projectId: String) {
        stopObserving()  // Cancel any existing observation

        observationTask = Task { [weak self] in
            do {
                for try await dbSections in database.observeSections(for: projectId) {
                    guard !Task.isCancelled, let self else { break }

                    print("[OBSERVE] Received \(dbSections.count) sections from database")
                    print("[OBSERVE] isObservationSuppressed: \(self.isObservationSuppressed)")
                    print("[OBSERVE] DB section order: \(dbSections.map { "\($0.sortOrder):\($0.title)[H\($0.headerLevel)]" })")

                    // Skip updates when observation is suppressed (during drag-drop reorder)
                    guard !self.isObservationSuppressed else {
                        print("[OBSERVE] SKIPPED due to suppression flag")
                        continue
                    }

                    // Skip updates during content transitions (zoom, hierarchy enforcement)
                    guard contentState == .idle else {
                        print("[OBSERVE] SKIPPED due to contentState: \(contentState)")
                        continue
                    }

                    // Convert to view models
                    let viewModels = dbSections.map { SectionViewModel(from: $0) }

                    print("[OBSERVE] Updating sections array with \(viewModels.count) view models")
                    // Update sections and recalculate parent relationships
                    self.sections = viewModels
                    self.recalculateParentRelationships()
                    print("[OBSERVE] Updated. Current order: \(self.sections.map { "\($0.sortOrder):\($0.title)[H\($0.headerLevel)]" })")

                    // Notify observers (e.g., for hierarchy enforcement)
                    self.onSectionsUpdated?()
                }
            } catch {
                print("[OBSERVE] ERROR: \(error)")
            }
        }
    }

    /// Stop observing sections from database
    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
        annotationObservationTask?.cancel()
        annotationObservationTask = nil
    }

    /// Start observing annotations from database for reactive UI updates
    func startObservingAnnotations(database: ProjectDatabase, contentId: String) {
        annotationObservationTask?.cancel()

        annotationObservationTask = Task { [weak self] in
            do {
                for try await dbAnnotations in database.observeAnnotations(for: contentId) {
                    guard !Task.isCancelled, let self else { break }

                    // Convert to view models
                    let viewModels = dbAnnotations.map { AnnotationViewModel(from: $0) }
                    self.annotations = viewModels
                }
            } catch {
                print("[OBSERVE] Annotation observation error: \(error)")
            }
        }
    }

    /// Recalculate parentId for all sections based on document order and header levels
    /// A section's parent is the nearest preceding section with a lower header level
    private func recalculateParentRelationships() {
        for index in sections.indices {
            let section = sections[index]
            let newParentId = findParentByLevel(at: index)

            if section.parentId != newParentId {
                sections[index] = section.withUpdates(parentId: newParentId)
            }
        }
    }

    /// Find the appropriate parent for a section at the given index
    /// Parent = nearest preceding section with a LOWER header level
    private func findParentByLevel(at index: Int) -> String? {
        let section = sections[index]

        // H1 sections have no parent
        guard section.headerLevel > 1 else { return nil }

        // Look backwards for a section with lower level
        for i in stride(from: index - 1, through: 0, by: -1) {
            let candidate = sections[i]
            if candidate.headerLevel < section.headerLevel {
                return candidate.id
            }
        }

        return nil
    }

    /// Sections to display (filtered by status and zoom)
    var displaySections: [SectionViewModel] {
        var result = sections

        // Apply status filter
        if let filter = statusFilter {
            result = result.filter { $0.status == filter }
        }

        // Apply zoom (show subtree only)
        if let zoomId = zoomedSectionId {
            result = filterToSubtree(sections: result, rootId: zoomId)
        }

        return result
    }

    private func filterToSubtree(sections: [SectionViewModel], rootId: String) -> [SectionViewModel] {
        var idsToInclude = Set<String>([rootId])

        // Build set of all descendants
        var changed = true
        while changed {
            changed = false
            for section in sections where section.parentId != nil && idsToInclude.contains(section.parentId!) {
                if !idsToInclude.contains(section.id) {
                    idsToInclude.insert(section.id)
                    changed = true
                }
            }
        }

        return sections.filter { idsToInclude.contains($0.id) }
    }

    /// Find zoomed section for breadcrumb display
    var zoomedSection: SectionViewModel? {
        guard let zoomId = zoomedSectionId else { return nil }
        return sections.first { $0.id == zoomId }
    }

    // MARK: - Annotation Filtering

    /// Annotations to display in panel (filtered by type and completion status)
    var displayAnnotations: [AnnotationViewModel] {
        annotations.filter { annotation in
            // Must match type filter
            guard annotationTypeFilters.contains(annotation.type) else { return false }

            // Hide completed tasks if filter is on
            if hideCompletedTasks && annotation.type == .task && annotation.isCompleted {
                return false
            }

            return true
        }
    }

    /// Toggle visibility of an annotation type in the panel
    func toggleAnnotationTypeFilter(_ type: AnnotationType) {
        if annotationTypeFilters.contains(type) {
            annotationTypeFilters.remove(type)
        } else {
            annotationTypeFilters.insert(type)
        }
    }

    /// Set display mode for an annotation type
    func setAnnotationDisplayMode(_ mode: AnnotationDisplayMode, for type: AnnotationType) {
        annotationDisplayModes[type] = mode
    }

    /// Get display mode for an annotation type
    func displayMode(for type: AnnotationType) -> AnnotationDisplayMode {
        annotationDisplayModes[type] ?? .inline
    }

    /// Toggle annotation panel visibility
    func toggleAnnotationPanel() {
        isAnnotationPanelVisible.toggle()
    }

    /// Toggle outline sidebar visibility
    func toggleOutlineSidebar() {
        isOutlineSidebarVisible.toggle()
    }

    /// Get annotation counts by type (single-pass)
    var annotationCounts: [AnnotationType: Int] {
        annotations.reduce(into: [:]) { counts, annotation in
            counts[annotation.type, default: 0] += 1
        }
    }

    /// Get incomplete task count
    var incompleteTaskCount: Int {
        annotations.filter { $0.type == .task && !$0.isCompleted }.count
    }

    // MARK: - Stats Update
    func updateStats(words: Int, characters: Int) {
        wordCount = words
        characterCount = characters
    }

    func scrollTo(offset: Int) {
        scrollToOffset = offset
    }

    func clearScrollRequest() {
        scrollToOffset = nil
    }

    func toggleEditorMode() {
        editorMode = editorMode == .wysiwyg ? .source : .wysiwyg
    }

    /// Request editor mode toggle - posts notification for current editor to save cursor first
    func requestEditorModeToggle() {
        NotificationCenter.default.post(name: .willToggleEditorMode, object: nil)
    }

    func toggleFocusMode() {
        focusModeEnabled.toggle()
    }

    /// Zoom into a section, filtering the editor to show only that section and its descendants
    /// This is async because it needs to coordinate content transitions safely
    func zoomToSection(_ sectionId: String) async {
        // Guard against re-entry during transitions
        guard contentState == .idle else { return }

        // If already zoomed to a different section, unzoom first
        if zoomedSectionId != nil && zoomedSectionId != sectionId {
            await zoomOut()
        }

        guard sections.first(where: { $0.id == sectionId }) != nil else { return }

        contentState = .zoomTransition
        // NOTE: Do NOT use defer { contentState = .idle } here!
        // defer executes BEFORE SwiftUI's onChange fires, causing race conditions

        // Calculate zoomed section IDs (section + all descendants)
        let descendantIds = getDescendantIds(of: sectionId)
        zoomedSectionIds = descendantIds

        // Store full document BEFORE modifying content
        fullDocumentBeforeZoom = content

        // Extract zoomed content by joining zoomed sections
        let zoomedSections = sections.filter { descendantIds.contains($0.id) }
        let zoomedContent = zoomedSections
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { section in
                var md = section.markdownContent
                // Ensure proper markdown separation
                if !md.hasSuffix("\n") { md += "\n" }
                return md
            }
            .joined()

        // Set zoomed state
        zoomedSectionId = sectionId
        content = zoomedContent

        // Use MainActor.run to ensure state is set AFTER SwiftUI processes the content change
        // This runs in the next runloop iteration after content assignment
        await MainActor.run {
            contentState = .idle
        }
    }

    /// Zoom out from current section, merging any edits back into the full document
    func zoomOut() async {
        guard let fullDoc = fullDocumentBeforeZoom,
              let zoomedIds = zoomedSectionIds else {
            // Simple zoom out if no content backup (shouldn't happen, but safe fallback)
            zoomedSectionId = nil
            return
        }

        contentState = .zoomTransition
        // NOTE: Do NOT use defer { contentState = .idle } here!
        // defer executes BEFORE SwiftUI's onChange fires, causing race conditions

        // Rebuild document: use current sections array which has been synced with edits
        // Non-zoomed sections retain their original content from the backup
        // Zoomed sections have their current edited content

        // Parse the full backup to get original non-zoomed section content
        let originalSections = parseMarkdownToSectionOffsets(fullDoc)

        // Build merged content: for zoomed sections use current content, for others use original
        var mergedContent = ""
        var currentIdx = 0

        for original in originalSections {
            if zoomedIds.contains(original.id) {
                // Find the current edited version of this section
                if let editedSection = sections.first(where: { $0.id == original.id }) {
                    var md = editedSection.markdownContent
                    if !md.hasSuffix("\n") { md += "\n" }
                    mergedContent += md
                } else {
                    // Section was deleted while zoomed - skip it
                }
            } else {
                // Use original content for non-zoomed sections
                mergedContent += original.content
            }
            currentIdx += 1
        }

        // Handle any new sections created while zoomed (not in original)
        for section in sections where !originalSections.contains(where: { $0.id == section.id }) {
            if zoomedIds.contains(section.id) {
                var md = section.markdownContent
                if !md.hasSuffix("\n") { md += "\n" }
                mergedContent += md
            }
        }

        // Restore full document
        content = mergedContent
        fullDocumentBeforeZoom = nil
        zoomedSectionIds = nil
        zoomedSectionId = nil

        // Use MainActor.run to ensure state is set AFTER SwiftUI processes the content change
        await MainActor.run {
            contentState = .idle
        }
    }

    /// Simple zoom out without async - for use in synchronous contexts like breadcrumb click
    func zoomOutSync() {
        Task {
            await zoomOut()
        }
    }

    // MARK: - Private Helpers

    /// Get all descendant section IDs for a given section
    private func getDescendantIds(of sectionId: String) -> Set<String> {
        var ids = Set<String>([sectionId])
        var changed = true
        while changed {
            changed = false
            for section in sections where section.parentId != nil && ids.contains(section.parentId!) {
                if !ids.contains(section.id) {
                    ids.insert(section.id)
                    changed = true
                }
            }
        }
        return ids
    }

    /// Simple struct to hold parsed section info for merge operations
    private struct ParsedSectionInfo {
        let id: String
        let content: String
    }

    /// Parse markdown to extract section boundaries for merge operations
    /// This is a simplified version that matches sections by title/level to their IDs
    private func parseMarkdownToSectionOffsets(_ markdown: String) -> [ParsedSectionInfo] {
        var results: [ParsedSectionInfo] = []
        var currentOffset = 0
        var inCodeBlock = false

        struct HeaderInfo {
            let offset: Int
            let level: Int
            let title: String
        }

        var headers: [HeaderInfo] = []

        // First pass: find all headers
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let lineStr = String(line)
            let trimmed = lineStr.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                inCodeBlock = !inCodeBlock
            }

            if !inCodeBlock {
                if trimmed.hasPrefix("#") {
                    if let header = parseHeader(trimmed) {
                        headers.append(HeaderInfo(offset: currentOffset, level: header.level, title: header.title))
                    }
                }
            }

            currentOffset += lineStr.count + 1
        }

        // Second pass: extract content and match to section IDs
        let contentLength = markdown.count
        for (index, header) in headers.enumerated() {
            let endOffset = index < headers.count - 1 ? headers[index + 1].offset : contentLength

            let startIdx = markdown.index(markdown.startIndex, offsetBy: min(header.offset, markdown.count))
            let endIdx = markdown.index(markdown.startIndex, offsetBy: min(endOffset, markdown.count))
            let sectionContent = String(markdown[startIdx..<endIdx])

            // Find matching section by title and level
            let matchingSection = sections.first { section in
                section.headerLevel == header.level && section.title == header.title
            }

            if let section = matchingSection {
                results.append(ParsedSectionInfo(id: section.id, content: sectionContent))
            } else {
                // No match found - use a placeholder ID
                results.append(ParsedSectionInfo(id: "unknown-\(index)", content: sectionContent))
            }
        }

        return results
    }

    private struct ParsedHeader {
        let level: Int
        let title: String
    }

    private func parseHeader(_ line: String) -> ParsedHeader? {
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

        return ParsedHeader(level: level, title: title)
    }
}
