//
//  EditorViewState.swift
//  final final
//

import SwiftUI

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
    var contentAckContinuation: CheckedContinuation<Void, Never>?

    /// Flag to prevent double-resume of continuation (fatal error if both timeout and ack fire)
    var isAcknowledged = false

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
                }
            } catch {
                print("[EditorViewState] Block observation error: \(error)")
            }
        }
    }

    /// Re-fetch outline blocks from database and update sections.
    /// Called when ValueObservation may have been dropped during non-idle contentState.
    func refreshSections() {
        guard let db = projectDatabase, let pid = currentProjectId else { return }
        do {
            let outlineBlocks = try db.fetchOutlineBlocks(projectId: pid)
            var viewModels = outlineBlocks.map { SectionViewModel(from: $0) }
            for i in viewModels.indices {
                if let wc = try? db.wordCountForHeading(blockId: viewModels[i].id) {
                    viewModels[i].wordCount = wc
                }
            }
            self.sections = viewModels
            self.recalculateParentRelationships()
            self.onSectionsUpdated?()
        } catch {
            print("[EditorViewState] Section refresh error: \(error)")
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

    // MARK: - Project Switch Reset

    /// Reset all project-specific state for a clean project switch.
    /// Call from handleProjectOpened() and performProjectClose().
    func resetForProjectSwitch() {
        // Cancel in-flight tasks first
        blockReparseTask?.cancel()
        blockReparseTask = nil
        currentPersistTask?.cancel()
        currentPersistTask = nil

        // Reset content
        content = ""
        sourceContent = ""
        sourceAnchors = []

        // Reset sections and annotations
        sections = []
        annotations = []

        // Reset zoom state
        zoomedSectionId = nil
        zoomedSectionIds = nil
        zoomedBlockRange = nil
        isZoomingContent = false

        // Reset content state machine
        contentState = .idle
        isObservationSuppressed = false

        // Reset project-specific settings
        isCitationLibraryPushed = false
        documentGoal = nil
        documentGoalType = .approx
        excludeBibliography = false

        // Reset stats display
        wordCount = 0
        characterCount = 0
        currentSectionName = ""
        scrollToOffset = nil
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

}
