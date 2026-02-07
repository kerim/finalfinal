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
    var contentState: EditorContentState = .idle {
        didSet {
            contentStateWatchdog?.cancel()
            contentStateWatchdog = nil

            if contentState != .idle {
                contentStateWatchdog = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled, let self else { return }
                    if self.contentState != .idle {
                        print("[EditorViewState] WATCHDOG: contentState stuck at \(self.contentState), resetting to .idle")
                        if self.contentState == .zoomTransition {
                            self.isZoomingContent = false
                            self.zoomedSectionIds = nil
                            self.zoomedSectionId = nil
                            self.zoomedBlockRange = nil
                            self.contentAckContinuation?.resume()
                            self.contentAckContinuation = nil
                        }
                        self.contentState = .idle
                    }
                }
            }
        }
    }

    /// Watchdog task that resets contentState if stuck in non-idle state for >5 seconds
    private var contentStateWatchdog: Task<Void, Never>?

    /// Direct zoom flag passed through SwiftUI view hierarchy to bypass coordinator state race condition.
    /// Set to true IMMEDIATELY BEFORE content change, cleared AFTER acknowledgement.
    /// This flag is passed directly to editor views and read in the same updateNSView cycle as content.
    var isZoomingContent: Bool = false

    /// When true, editor polling should skip updating the content binding.
    /// Used during project switch to prevent old editor content from bleeding into new projects.
    var isResettingContent = false

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

    // MARK: - Document Goal Settings
    var documentGoal: Int?
    var documentGoalType: GoalType = .approx
    var excludeBibliography: Bool = false

    /// Filtered word count respecting excludeBibliography setting
    /// Used by both OutlineFilterBar and StatusBar for consistency
    var filteredTotalWordCount: Int {
        sections
            .filter { !excludeBibliography || !$0.isBibliography }
            .reduce(0) { $0 + $1.wordCount }
    }

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

    // MARK: - Database References
    /// Database and project references for block operations (zoom, scroll, etc.)
    var projectDatabase: ProjectDatabase?
    var currentProjectId: String?

    // MARK: - Block Zoom State
    /// Sort order boundaries for the zoomed block range
    var zoomedBlockRange: (start: Double, end: Double?)?

    /// Task for debounced block re-parse (source mode paste)
    var blockReparseTask: Task<Void, Never>?

    /// Current persist task for cancellation on rapid successive reorders
    var currentPersistTask: Task<Void, Never>?

    // MARK: - Database Observation
    private var observationTask: Task<Void, Never>?
    private var annotationObservationTask: Task<Void, Never>?

    /// When true, ValueObservation updates are ignored (used during drag-drop reorder)
    var isObservationSuppressed = false

    /// Callback invoked after sections are updated from database observation
    /// Used by ContentView to enforce hierarchy constraints after slash command changes
    var onSectionsUpdated: (() -> Void)?

    /// Start observing blocks from database for reactive UI updates
    /// Call this once during initialization after database is ready
    func startObserving(database: ProjectDatabase, projectId: String) {
        stopObserving()  // Cancel any existing observation
        self.projectDatabase = database
        self.currentProjectId = projectId

        observationTask = Task { [weak self] in
            do {
                for try await outlineBlocks in database.observeOutlineBlocks(for: projectId) {
                    guard !Task.isCancelled, let self else { break }

                    // Skip updates when observation is suppressed (during drag-drop reorder)
                    guard !self.isObservationSuppressed else { continue }

                    // Skip updates during content transitions (zoom, hierarchy enforcement)
                    guard contentState == .idle else { continue }

                    // Convert blocks to SectionViewModels
                    var viewModels = outlineBlocks.map { SectionViewModel(from: $0) }

                    // Aggregate word counts for each heading block
                    for i in viewModels.indices {
                        let vm = viewModels[i]
                        if let wc = try? database.wordCountForHeading(blockId: vm.id) {
                            viewModels[i].wordCount = wc
                        }
                    }

                    // Update sections and recalculate parent relationships
                    self.sections = viewModels
                    self.recalculateParentRelationships()

                    // Notify observers (e.g., for hierarchy enforcement)
                    self.onSectionsUpdated?()

                    // Check for bibliography section changes
                    if let bibSection = viewModels.first(where: { $0.title == "Bibliography" }) {
                        let currentHash = bibSection.markdownContent.hashValue
                        if self.previousBibliographyHash == nil ||
                           (self.previousBibliographyHash != nil && self.previousBibliographyHash != currentHash) {
                            NotificationCenter.default.post(name: .bibliographySectionChanged, object: nil)
                        }
                        self.previousBibliographyHash = currentHash
                    } else {
                        if self.previousBibliographyHash != nil {
                            NotificationCenter.default.post(name: .bibliographySectionChanged, object: nil)
                            self.previousBibliographyHash = nil
                        }
                    }
                }
            } catch {
                print("[EditorViewState] Block observation error: \(error)")
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
                print("[EditorViewState] Annotation observation error: \(error)")
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

        guard let db = projectDatabase, let pid = currentProjectId else { return }

        // SET CONTENTSTATE FIRST - before flush to prevent observation race conditions
        contentState = .zoomTransition

        // Flush any pending CodeMirror edits before zooming
        flushCodeMirrorSyncIfNeeded()

        // If already zoomed to a different section, unzoom first
        if zoomedSectionId != nil && zoomedSectionId != sectionId {
            await zoomOut()
        }

        guard sections.first(where: { $0.id == sectionId }) != nil else {
            zoomedSectionIds = nil
            zoomedSectionId = nil
            zoomedBlockRange = nil
            contentState = .idle
            return
        }

        do {
            // Find the heading block BEFORE computing descendant IDs
            guard let headingBlock = try db.fetchBlock(id: sectionId),
                  let headingLevel = headingBlock.headingLevel else {
                zoomedSectionIds = nil
                zoomedSectionId = nil
                zoomedBlockRange = nil
                contentState = .idle
                return
            }

            // Calculate zoomed section IDs AFTER confirming block exists
            let descendantIds = mode == .shallow
                ? getShallowDescendantIds(of: sectionId)
                : getDescendantIds(of: sectionId)
            zoomedSectionIds = descendantIds

            // Find next same-or-higher-level heading's sortOrder (range boundary)
            let allBlocks = try db.fetchBlocks(projectId: pid)
            let sorted = allBlocks.sorted { $0.sortOrder < $1.sortOrder }

            var endSortOrder: Double?
            for block in sorted where block.sortOrder > headingBlock.sortOrder {
                if block.blockType == .heading, let level = block.headingLevel, level <= headingLevel {
                    endSortOrder = block.sortOrder
                    break
                }
            }

            // Store range for later use
            zoomedBlockRange = (start: headingBlock.sortOrder, end: endSortOrder)

            // Fetch blocks in the range (including the heading itself)
            var zoomedBlocks = sorted.filter { block in
                block.sortOrder >= headingBlock.sortOrder &&
                !block.isBibliography &&
                (endSortOrder == nil || block.sortOrder < endSortOrder!)
            }

            #if DEBUG
            print("[Zoom] Heading: id=\(headingBlock.id), sort=\(headingBlock.sortOrder), level=\(headingLevel), fragment=\"\(String(headingBlock.markdownFragment.prefix(80)))\"")
            print("[Zoom] endSortOrder=\(String(describing: endSortOrder)), zoomedBlocks=\(zoomedBlocks.count)")
            if let first = zoomedBlocks.first {
                print("[Zoom] First block: id=\(first.id), sort=\(first.sortOrder), type=\(first.blockType)")
            }
            #endif

            let zoomedContent = BlockParser.assembleMarkdown(from: zoomedBlocks)

            #if DEBUG
            print("[Zoom] Content preview (\(zoomedContent.count) chars): \(String(zoomedContent.prefix(200)))")
            #endif

            // Set zoomed state
            zoomedSectionId = sectionId
            isZoomingContent = true
            content = zoomedContent

            // Update sourceContent for CodeMirror
            if editorMode == .source, let syncService = sectionSyncService {
                let zoomedSections = sections.filter { descendantIds.contains($0.id) && !$0.isBibliography }
                let sortedZoomedSections = zoomedSections.sorted { $0.sortOrder < $1.sortOrder }
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

            await waitForContentAcknowledgement()

            isZoomingContent = false
            contentState = .idle
        } catch {
            print("[EditorViewState] Zoom error: \(error)")
            zoomedSectionIds = nil
            zoomedSectionId = nil
            zoomedBlockRange = nil
            isZoomingContent = false
            contentState = .idle
        }
    }

    /// Zoom out from current section - fetch ALL blocks from DB and restore full document
    func zoomOut() async {
        guard zoomedSectionId != nil else { return }
        guard let db = projectDatabase, let pid = currentProjectId else {
            zoomedSectionId = nil
            return
        }

        // Caller manages state if already in transition (called from zoomToSection)
        let callerManagedState = (contentState == .zoomTransition)
        if !callerManagedState {
            contentState = .zoomTransition
        }

        // Flush any pending CodeMirror edits before reading from DB
        flushCodeMirrorSyncIfNeeded()

        do {
            // Fetch ALL blocks from DB - database is always complete
            let allBlocks = try db.fetchBlocks(projectId: pid)
            let mergedContent = BlockParser.assembleMarkdown(from: allBlocks)

            isZoomingContent = true
            content = mergedContent

            // Update sourceContent for CodeMirror
            if editorMode == .source, let syncService = sectionSyncService {
                let allSectionsList = sections.filter { !$0.isBibliography }.sorted { $0.sortOrder < $1.sortOrder }
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
                sourceContent = syncService.injectBibliographyMarker(
                    markdown: withAnchors,
                    sections: sections
                )
            } else {
                sourceContent = mergedContent
            }

            // Clear zoom state
            zoomedSectionIds = nil
            zoomedSectionId = nil
            zoomedBlockRange = nil

            await waitForContentAcknowledgement()

            isZoomingContent = false

            if !callerManagedState {
                contentState = .idle
                NotificationCenter.default.post(name: .didZoomOut, object: nil)
            }
        } catch {
            print("[EditorViewState] Zoom out error: \(error)")
            zoomedSectionId = nil
            zoomedSectionIds = nil
            zoomedBlockRange = nil
            isZoomingContent = false
            if !callerManagedState {
                contentState = .idle
            }
        }
    }

    /// Simple zoom out without async - for use in synchronous contexts like breadcrumb click
    func zoomOutSync() {
        Task {
            await zoomOut()
        }
    }

    // MARK: - CodeMirror Flush

    /// Immediately persist CodeMirror content to the block database (no debounce).
    /// Called before zoom-out, zoom-to, and editor switch to ensure CM edits are saved.
    /// Handles both zoomed (range replace) and non-zoomed (full replace) cases.
    func flushCodeMirrorSyncIfNeeded() {
        // Only flush when in source mode with actual content
        guard editorMode == .source, !content.isEmpty else { return }
        guard let db = projectDatabase, let pid = currentProjectId else { return }

        // Cancel any pending debounced re-parse
        blockReparseTask?.cancel()
        blockReparseTask = nil

        do {
            // Preserve existing heading metadata
            let existing = try db.fetchBlocks(projectId: pid)
            var metadata: [String: SectionMetadata] = [:]
            for block in existing where block.blockType == .heading {
                metadata[block.textContent] = SectionMetadata(
                    status: block.status,
                    tags: block.tags?.isEmpty == false ? block.tags : nil,
                    wordGoal: block.wordGoal
                )
            }

            let blocks = BlockParser.parse(
                markdown: content,
                projectId: pid,
                existingSectionMetadata: metadata.isEmpty ? nil : metadata
            )

            if let range = zoomedBlockRange {
                // Zoomed: only replace blocks within the zoom range
                try db.replaceBlocksInRange(
                    blocks,
                    for: pid,
                    startSortOrder: range.start,
                    endSortOrder: range.end
                )

                // Recalculate zoomedBlockRange after normalization shifted sort orders
                if let zoomedId = zoomedSectionId {
                    var headingBlock = try db.fetchBlock(id: zoomedId)

                    // Fallback: heading renamed → ID not preserved → find first heading in parsed blocks
                    if headingBlock == nil || headingBlock?.blockType != .heading {
                        if let fallback = blocks.first(where: { $0.blockType == .heading }) {
                            headingBlock = try db.fetchBlock(id: fallback.id)
                            zoomedSectionId = fallback.id
                        } else {
                            // Heading deleted entirely → clear zoom state
                            zoomedBlockRange = nil
                            zoomedSectionId = nil
                            zoomedSectionIds = nil
                            return
                        }
                    }

                    if let headingBlock = headingBlock,
                       let headingLevel = headingBlock.headingLevel {
                        let allBlocks = try db.fetchBlocks(projectId: pid)
                        var endSortOrder: Double?
                        for block in allBlocks where block.sortOrder > headingBlock.sortOrder {
                            if block.blockType == .heading, let level = block.headingLevel, level <= headingLevel {
                                endSortOrder = block.sortOrder
                                break
                            }
                        }
                        zoomedBlockRange = (start: headingBlock.sortOrder, end: endSortOrder)
                    }
                }
            } else {
                // Not zoomed: full document replace (existing behavior)
                try db.replaceBlocks(blocks, for: pid)
            }
        } catch {
            print("[EditorViewState] flushCodeMirrorSyncIfNeeded error: \(error)")
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
                ids.insert(section.id)
            }
        }

        return ids
    }

}
