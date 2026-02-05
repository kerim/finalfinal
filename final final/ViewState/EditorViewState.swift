//
//  EditorViewState.swift
//  final final
//

import SwiftUI

// MARK: - Focus Mode Snapshot

/// Captures the pre-focus-mode state for restoration when exiting focus mode.
/// This is session-only storage (not persisted) - if user quits while in focus mode,
/// a fresh snapshot is captured on next launch before applying focus mode.
struct FocusModeSnapshot: Sendable {
    let wasInFullScreen: Bool
    let outlineSidebarVisible: Bool
    let annotationPanelVisible: Bool
    let annotationDisplayModes: [AnnotationType: AnnotationDisplayMode]
}

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
    /// Posted when bibliography section content changes in the database
    static let bibliographySectionChanged = Notification.Name("bibliographySectionChanged")
    /// Posted when editor appearance mode changes (WYSIWYG ↔ source) - Phase C dual-appearance
    static let editorAppearanceModeChanged = Notification.Name("editorAppearanceModeChanged")
    /// Posted when zoom-out completes and contentState is back to idle
    /// Used to trigger bibliography sync after zoom-out (citations added during zoom)
    static let didZoomOut = Notification.Name("didZoomOut")
}

enum EditorMode: String, CaseIterable {
    case wysiwyg = "WYSIWYG"
    case source = "Source"
}

/// Zoom mode for section navigation
/// - full: Shows section + all descendants (default behavior)
/// - shallow: Shows section + only direct pseudo-section children
enum ZoomMode {
    case full
    case shallow
}

/// Content state machine - replaces multiple boolean flags for zoom/enforcement transitions
enum EditorContentState {
    case idle
    case zoomTransition
    case hierarchyEnforcement
    case bibliographyUpdate
    case editorTransition  // During Milkdown ↔ CodeMirror switch
    case dragReorder       // During sidebar drag-drop reorder
}

@MainActor
@Observable
class EditorViewState {
    var editorMode: EditorMode = .wysiwyg

    /// Focus mode state - persists across app launches via UserDefaults
    var focusModeEnabled: Bool = UserDefaults.standard.bool(forKey: "focusModeEnabled") {
        didSet {
            UserDefaults.standard.set(focusModeEnabled, forKey: "focusModeEnabled")
        }
    }

    /// Snapshot of pre-focus-mode state for restoration on exit (session-only, not persisted)
    var preFocusModeState: FocusModeSnapshot?

    /// Controls visibility of the focus mode toast notification
    var showFocusModeToast: Bool = false

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

    /// Content with section anchors injected (for source mode)
    /// This is separate from `content` to avoid anchor pollution in WYSIWYG mode
    var sourceContent: String = ""

    /// Anchor mappings extracted from source content (for section ID restoration)
    var sourceAnchors: [SectionAnchorMapping] = []

    // MARK: - Content Acknowledgement
    /// Continuation for waiting on content acknowledgement from WebView
    /// Used during zoom transitions to prevent race conditions
    private var contentAckContinuation: CheckedContinuation<Void, Never>?

    /// Flag to prevent double-resume of continuation (fatal error if both timeout and ack fire)
    private var isAcknowledged = false

    /// Wait for content acknowledgement from the editor with timeout fallback
    /// Call this AFTER setting content to wait for WebView to confirm it was set
    /// Timeout of 1 second ensures contentState returns to .idle even if callback fails
    func waitForContentAcknowledgement() async {
        isAcknowledged = false

        // Race between acknowledgement and timeout
        // Use a simple timeout approach with Task.sleep and cancellation
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            // If we reach here without being cancelled, the acknowledgement timed out
            // Resume the continuation to prevent deadlock (only if not already acknowledged)
            guard !isAcknowledged else { return }
            isAcknowledged = true
            contentAckContinuation?.resume()
            contentAckContinuation = nil
        }

        // Wait for acknowledgement (or timeout to resume it)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            contentAckContinuation = continuation
        }

        // Cancel timeout if acknowledgement came first
        timeoutTask.cancel()
    }

    /// Called by the editor when content has been confirmed set
    /// Resumes the waiting continuation to allow zoom transition to complete
    func acknowledgeContent() {
        guard !isAcknowledged else { return }
        isAcknowledged = true
        contentAckContinuation?.resume()
        contentAckContinuation = nil
    }

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

    // MARK: - Section Sync Service (for zoom sourceContent updates)
    /// Section sync service reference (injected by ContentView)
    /// Used to inject section anchors when updating sourceContent during zoom
    weak var sectionSyncService: SectionSyncService?

    /// Whether citation library has been pushed to the editor
    var isCitationLibraryPushed: Bool = false

    // MARK: - Bibliography Change Detection
    /// Hash of the last bibliography section content, used to detect changes
    private var previousBibliographyHash: Int?

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

                    // Check for bibliography section changes
                    if let bibSection = viewModels.first(where: { $0.title == "Bibliography" }) {
                        let currentHash = bibSection.markdownContent.hashValue
                        // Post notification on FIRST creation (previousHash nil) or when hash changes
                        if self.previousBibliographyHash == nil ||
                           (self.previousBibliographyHash != nil && self.previousBibliographyHash != currentHash) {
                            print("[OBSERVE] Bibliography section changed (first creation or update), posting notification")
                            NotificationCenter.default.post(name: .bibliographySectionChanged, object: nil)
                        }
                        self.previousBibliographyHash = currentHash
                    } else {
                        // Bibliography was removed - post notification to rebuild content and reset hash
                        if self.previousBibliographyHash != nil {
                            print("[OBSERVE] Bibliography section removed, posting notification and resetting hash")
                            NotificationCenter.default.post(name: .bibliographySectionChanged, object: nil)
                            self.previousBibliographyHash = nil
                        }
                    }
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
                print("[PARENT] '\(section.title)' H\(section.headerLevel): \(section.parentId?.prefix(8) ?? "nil") -> \(newParentId?.prefix(8) ?? "nil")")
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

    // MARK: - Focus Mode

    /// Simple toggle for legacy callers (synchronous wrapper)
    func toggleFocusMode() {
        Task {
            if focusModeEnabled {
                await exitFocusMode()
            } else {
                await enterFocusMode()
            }
        }
    }

    /// Enter focus mode with full screen, hidden sidebars, and paragraph highlighting
    func enterFocusMode() async {
        guard !focusModeEnabled else { return }

        // 1. Capture pre-focus state for restoration on exit
        preFocusModeState = FocusModeSnapshot(
            wasInFullScreen: FullScreenManager.isInFullScreen(),
            outlineSidebarVisible: isOutlineSidebarVisible,
            annotationPanelVisible: isAnnotationPanelVisible,
            annotationDisplayModes: annotationDisplayModes
        )

        // 2. Enter full screen (if not already)
        if !FullScreenManager.isInFullScreen() {
            FullScreenManager.enterFullScreen()
            // Wait for full screen animation to complete (~500ms, use 600ms for safety)
            try? await Task.sleep(nanoseconds: 600_000_000)
        }

        // 3. Hide sidebars with animation
        withAnimation(.easeInOut(duration: 0.3)) {
            isOutlineSidebarVisible = false
            isAnnotationPanelVisible = false
        }

        // 4. Collapse all annotations
        for type in AnnotationType.allCases {
            annotationDisplayModes[type] = .collapsed
        }

        // 5. Enable focus mode (triggers paragraph highlighting in Milkdown)
        focusModeEnabled = true

        // 6. Show toast notification
        showFocusModeToast = true
    }

    /// Exit focus mode, restoring pre-focus state
    func exitFocusMode() async {
        guard focusModeEnabled else { return }

        guard let snapshot = preFocusModeState else {
            // No snapshot available - just disable focus mode
            focusModeEnabled = false
            return
        }

        // 1. Exit full screen ONLY if focus mode entered it (respect user's original state)
        if FullScreenManager.isInFullScreen() && !snapshot.wasInFullScreen {
            FullScreenManager.exitFullScreen()
            // Wait for full screen exit animation to complete
            try? await Task.sleep(nanoseconds: 600_000_000)
        }

        // 2. Restore sidebar visibility with animation
        withAnimation(.easeInOut(duration: 0.3)) {
            isOutlineSidebarVisible = snapshot.outlineSidebarVisible
            isAnnotationPanelVisible = snapshot.annotationPanelVisible
        }

        // 3. Restore annotation display modes
        annotationDisplayModes = snapshot.annotationDisplayModes

        // 4. Disable focus mode (disables paragraph highlighting in Milkdown)
        focusModeEnabled = false

        // 5. Clear snapshot
        preFocusModeState = nil
    }

    /// Zoom into a section, filtering the editor to show only that section and its descendants
    /// This is async because it needs to coordinate content transitions safely
    /// - Parameters:
    ///   - sectionId: The ID of the section to zoom into
    ///   - mode: Zoom mode (.full for all descendants, .shallow for direct pseudo-children only)
    func zoomToSection(_ sectionId: String, mode: ZoomMode = .full) async {
        // Guard against re-entry during transitions
        guard contentState == .idle else { return }

        // SET CONTENTSTATE FIRST - before any awaits to prevent race conditions
        contentState = .zoomTransition

        // If already zoomed to a different section, unzoom first
        // zoomOut() will detect contentState is already .zoomTransition and not reset it
        if zoomedSectionId != nil && zoomedSectionId != sectionId {
            await zoomOut()
        }

        guard sections.first(where: { $0.id == sectionId }) != nil else {
            contentState = .idle  // Reset on early return
            return
        }
        // NOTE: Do NOT use defer { contentState = .idle } here!
        // defer executes BEFORE SwiftUI's onChange fires, causing race conditions

        // Calculate zoomed section IDs based on mode
        let descendantIds = mode == .shallow
            ? getShallowDescendantIds(of: sectionId)
            : getDescendantIds(of: sectionId)
        zoomedSectionIds = descendantIds

        // ZOOM DEBUG LOGGING
        print("[ZOOM] Target section: \(sectionId)")
        print("[ZOOM] getDescendantIds returned \(descendantIds.count) IDs: \(descendantIds)")
        print("[ZOOM] All sections parentId state:")
        for s in sections {
            print("[ZOOM]   \(s.id.prefix(8))...: parent=\(s.parentId?.prefix(8) ?? "nil"), H\(s.headerLevel), '\(s.title)', bib=\(s.isBibliography)")
        }
        if let bibSection = sections.first(where: { $0.isBibliography }) {
            print("[ZOOM] Bibliography in descendants? \(descendantIds.contains(bibSection.id))")
        }

        // Store full document BEFORE modifying content
        // Only store if we don't have a backup (prevents overwriting with partial content during consecutive zooms)
        if fullDocumentBeforeZoom == nil {
            fullDocumentBeforeZoom = content
        }

        // Extract zoomed content by joining zoomed sections (EXCLUDE bibliography)
        let zoomedSections = sections.filter { descendantIds.contains($0.id) && !$0.isBibliography }
        print("[ZOOM] Filtered zoomedSections count (excl bib): \(zoomedSections.count)")
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

        // Update sourceContent for CodeMirror
        // If in source mode, inject anchors; otherwise plain content (anchors added on mode switch)
        if editorMode == .source, let syncService = sectionSyncService {
            let sortedZoomedSections = zoomedSections.sorted { $0.sortOrder < $1.sortOrder }
            // Adjust offsets for the zoomed content
            var adjustedSections: [SectionViewModel] = []
            var currentOffset = 0
            for section in sortedZoomedSections {
                adjustedSections.append(section.withUpdates(startOffset: currentOffset))
                currentOffset += section.markdownContent.count
            }
            sourceContent = syncService.injectSectionAnchors(
                markdown: zoomedContent,
                sections: adjustedSections
            )
        } else {
            sourceContent = zoomedContent
        }

        // Wait for editor to confirm content was set
        // This prevents race conditions where polling reads stale content
        // The acknowledgement comes from MilkdownEditor.setContent() callback
        await waitForContentAcknowledgement()

        // Now safe to mark transition as complete
        contentState = .idle
    }

    /// Zoom out from current section, merging any edits back into the full document
    func zoomOut() async {
        guard let fullDoc = fullDocumentBeforeZoom,
              let zoomedIds = zoomedSectionIds else {
            // Simple zoom out if no content backup (shouldn't happen, but safe fallback)
            zoomedSectionId = nil
            return
        }

        // Caller manages state if already in transition (called from zoomToSection)
        let callerManagedState = (contentState == .zoomTransition)
        if !callerManagedState {
            contentState = .zoomTransition
        }
        // NOTE: Do NOT use defer { contentState = .idle } here!
        // defer executes BEFORE SwiftUI's onChange fires, causing race conditions

        // Rebuild document directly from sections array
        // The database is the source of truth - sections have current content for everything:
        // - Zoomed sections: have edited content (synced via syncZoomedSections)
        // - Non-zoomed sections: have original content (unchanged)
        // This eliminates fragile title-matching logic that fails when titles change while zoomed.
        let sortedSections = sections
            .filter { !$0.isBibliography }
            .sorted { $0.sortOrder < $1.sortOrder }

        // ZOOMOUT DEBUG LOGGING
        print("[ZOOMOUT] Rebuilding from \(sortedSections.count) sections (excl bibliography)")
        for section in sortedSections {
            let inZoomed = zoomedIds.contains(section.id)
            print("[ZOOMOUT]   \(section.id.prefix(8))...: sortOrder=\(section.sortOrder), inZoomed=\(inZoomed), title='\(section.title)'")
        }

        var mergedContent = sortedSections
            .map { section in
                var sectionMd = section.markdownContent
                if !sectionMd.hasSuffix("\n") { sectionMd += "\n" }
                return sectionMd
            }
            .joined()

        // Append bibliography section at end (if exists)
        // This handles the case where bibliography was updated while zoomed
        if let bibSection = sections.first(where: { $0.isBibliography }) {
            var bibContent = bibSection.markdownContent
            if !bibContent.hasSuffix("\n") { bibContent += "\n" }
            mergedContent += bibContent
        }

        // Restore full document
        content = mergedContent

        // Update sourceContent for CodeMirror
        // If in source mode, inject anchors for all sections; otherwise plain content
        if editorMode == .source, let syncService = sectionSyncService {
            // Rebuild with anchors for all non-bibliography sections
            let allSectionsList = sections.filter { !$0.isBibliography }.sorted { $0.sortOrder < $1.sortOrder }
            // Adjust offsets for the full content
            var adjustedSections: [SectionViewModel] = []
            var currentOffset = 0
            for section in allSectionsList {
                adjustedSections.append(section.withUpdates(startOffset: currentOffset))
                currentOffset += section.markdownContent.count
            }
            let withAnchors = syncService.injectSectionAnchors(
                markdown: mergedContent,
                sections: adjustedSections
            )
            // Also inject bibliography marker for source mode
            sourceContent = syncService.injectBibliographyMarker(
                markdown: withAnchors,
                sections: sections
            )
        } else {
            sourceContent = mergedContent
        }

        fullDocumentBeforeZoom = nil
        zoomedSectionIds = nil
        zoomedSectionId = nil

        // Wait for editor to confirm content was set
        // This prevents race conditions where polling reads stale content
        await waitForContentAcknowledgement()

        // Only reset contentState if we set it ourselves (not if called from zoomToSection)
        if !callerManagedState {
            contentState = .idle
            // Post notification for bibliography sync catch-up
            // Citations added during zoom need to be processed now that we have full document
            NotificationCenter.default.post(name: .didZoomOut, object: nil)
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
    /// Uses document order to find pseudo-sections that belong to the zoomed section
    private func getDescendantIds(of sectionId: String) -> Set<String> {
        var ids = Set<String>([sectionId])

        // Ensure sections are sorted by document order
        let sortedSections = sections.sorted { $0.sortOrder < $1.sortOrder }

        // Find the zoomed section's index and level
        guard let rootIndex = sortedSections.firstIndex(where: { $0.id == sectionId }),
              let rootSection = sortedSections.first(where: { $0.id == sectionId }) else {
            return ids
        }
        let rootLevel = rootSection.headerLevel

        // First: Add pseudo-sections that follow in document order
        // Continue until we hit a regular (non-pseudo) section at same or shallower level
        for i in (rootIndex + 1)..<sortedSections.count {
            let section = sortedSections[i]

            // Stop at a regular (non-pseudo) section at same or shallower level
            if !section.isPseudoSection && section.headerLevel <= rootLevel {
                break
            }

            // Include pseudo-sections (they visually belong to the preceding section)
            if section.isPseudoSection {
                print("[DESC] Adding pseudo-section '\(section.title)' by document order")
                ids.insert(section.id)
            }
        }

        // Second: Add all transitive children by parentId
        // This loop handles both regular children AND children of pseudo-sections
        var changed = true
        while changed {
            changed = false
            for section in sortedSections where section.parentId != nil && ids.contains(section.parentId!) {
                if !ids.contains(section.id) {
                    print("[DESC] Adding '\(section.title)' (parent=\(section.parentId?.prefix(8) ?? "nil")) as descendant")
                    ids.insert(section.id)
                    changed = true
                }
            }
        }

        return ids
    }

    /// Get section ID plus only its direct pseudo-section children
    /// Used for shallow zoom (Option+double-click)
    /// Uses document order to find pseudo-sections that belong to the zoomed section
    private func getShallowDescendantIds(of sectionId: String) -> Set<String> {
        var ids = Set<String>([sectionId])

        // Ensure sections are sorted by document order
        let sortedSections = sections.sorted { $0.sortOrder < $1.sortOrder }

        // Find the section's index and level
        guard let rootIndex = sortedSections.firstIndex(where: { $0.id == sectionId }),
              let rootSection = sortedSections.first(where: { $0.id == sectionId }) else {
            return ids
        }
        let rootLevel = rootSection.headerLevel

        // Add only pseudo-sections that immediately follow in document order
        // Stop at any regular section at same or shallower level
        for i in (rootIndex + 1)..<sortedSections.count {
            let section = sortedSections[i]

            // Stop at a regular (non-pseudo) section at same or shallower level
            if !section.isPseudoSection && section.headerLevel <= rootLevel {
                break
            }

            // Include pseudo-sections only (shallow = no children, just pseudo-sections)
            if section.isPseudoSection {
                print("[SHALLOW] Adding pseudo-section '\(section.title)' as direct child")
                ids.insert(section.id)
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
    /// - Parameters:
    ///   - markdown: The markdown content to parse
    ///   - excludeBibliography: When true, excludes bibliography headers from the result (used during zoom out to prevent duplication)
    private func parseMarkdownToSectionOffsets(_ markdown: String, excludeBibliography: Bool = false) -> [ParsedSectionInfo] {
        var results: [ParsedSectionInfo] = []
        var currentOffset = 0
        var inCodeBlock = false

        struct HeaderInfo {
            let offset: Int
            let level: Int
            let title: String
        }

        var headers: [HeaderInfo] = []

        // Get bibliography header name for exclusion check
        let bibHeaderName = ExportSettingsManager.shared.bibliographyHeaderName

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
                        // Skip bibliography headers if exclusion is requested
                        if excludeBibliography && header.title == bibHeaderName {
                            print("[PARSE] Skipping bibliography header '\(header.title)' (excludeBibliography=true)")
                            currentOffset += lineStr.count + 1
                            continue
                        }
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
                print("[PARSE] '\(header.title)' H\(header.level) -> matched \(section.id.prefix(8))...")
                results.append(ParsedSectionInfo(id: section.id, content: sectionContent))
            } else {
                // No match found - use a placeholder ID
                print("[PARSE] '\(header.title)' H\(header.level) -> NO MATCH (unknown-\(index))")
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
