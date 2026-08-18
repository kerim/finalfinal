//
//  EditorViewState.swift
//  final final
//

import SwiftUI

@MainActor
@Observable
class EditorViewState {
    var editorMode: EditorMode = .wysiwyg

    /// Timestamp of last editor mode toggle request — used for debounce
    var lastToggleRequestTime: Date = .distantPast

    /// Minimum interval between editor mode toggle requests (prevents rapid double-toggle)
    private static let toggleDebounceInterval: TimeInterval = 0.5

    /// Whether enough time has passed since last toggle request to allow another
    var canToggleEditorMode: Bool {
        Date().timeIntervalSince(lastToggleRequestTime) >= Self.toggleDebounceInterval
    }

    /// Focus mode state - persists across app launches via UserDefaults
    var focusModeEnabled: Bool = AppDefaults.store.bool(forKey: "focusModeEnabled") {
        didSet {
            AppDefaults.store.set(focusModeEnabled, forKey: "focusModeEnabled")
        }
    }

    /// LanguageTool connection status (only visible when LT mode is active)
    var proofingConnectionStatus: LTConnectionStatus = .disconnected

    /// Spelling check state - persists across app launches via UserDefaults (defaults to true)
    var isSpellingEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "isSpellingEnabled") == nil { return true }
        return UserDefaults.standard.bool(forKey: "isSpellingEnabled")
    }() {
        didSet { UserDefaults.standard.set(isSpellingEnabled, forKey: "isSpellingEnabled") }
    }

    /// Grammar check state - persists across app launches via UserDefaults (defaults to true)
    var isGrammarEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "isGrammarEnabled") == nil { return true }
        return UserDefaults.standard.bool(forKey: "isGrammarEnabled")
    }() {
        didSet { UserDefaults.standard.set(isGrammarEnabled, forKey: "isGrammarEnabled") }
    }

    /// Snapshot of pre-focus-mode state for restoration on exit (session-only, not persisted)
    var preFocusModeState: FocusModeSnapshot?

    /// Active focus mode effects (set in enterFocusMode, cleared in exitFocusMode)
    /// Pre-initialized from settings when focusModeEnabled is persisted to prevent
    /// toolbar/status bar flash on app relaunch (~500ms gap before enterFocusMode runs)
    var focusModeHidesToolbar: Bool = {
        guard AppDefaults.store.bool(forKey: "focusModeEnabled") else { return false }
        return FocusModeSettingsManager.shared.hideToolbar
    }()
    var focusModeHidesStatusBar: Bool = {
        guard AppDefaults.store.bool(forKey: "focusModeEnabled") else { return false }
        return FocusModeSettingsManager.shared.hideStatusBar
    }()

    /// Controls visibility of the focus mode toast notification
    var showFocusModeToast: Bool = false

    /// Controls visibility of the Getting Started first-edit toast notification.
    /// Set true on the .gettingStartedEdited notification (see EditorViewState+Types.swift),
    /// posted by SectionSyncService rather than set directly through its existing weak
    /// `editorState` back-reference -- keeping this UI-layer concern out of the sync service.
    var showGettingStartedToast: Bool = false

    var zoomedSectionId: String?
    var wordCount: Int = 0
    var characterCount: Int = 0
    var currentSectionName: String = ""
    var currentSectionId: String?

    // MARK: - Content State Machine
    /// Tracks content transitions to prevent race conditions
    var contentState: EditorContentState = .idle {
        didSet {
            // Increment generation on every non-idle transition
            if oldValue == .idle && contentState != .idle {
                contentGeneration += 1
            }

            // Editor content is being replaced (zoom, mode switch, project switch):
            // any reported selection is stale, so drop the selection word count.
            if contentState != .idle {
                selectedWordCount = nil
            }

            contentStateWatchdog?.cancel()
            contentStateWatchdog = nil

            if contentState != .idle {
                contentStateWatchdog = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled, let self else { return }
                    // Exempt .structuralUndo (docs/plans/patient-rewinding-clockwork.md §4.4,
                    // review round CRIT fix): a unified-undo op/undo/redo sequence
                    // (StructuralUndoController) can legitimately run longer than 5s --
                    // multiple JS round trips, two synchronous DB writes, up to two 1s/3s
                    // bibliography/footnote flushes. The controller itself already guarantees
                    // contentState returns to .idle on every one of its own exit paths
                    // (success or failure, via `defer { isPerforming = false }` alongside
                    // explicit `contentState = .idle` on each return). A force-reset HERE,
                    // mid-sequence, would let BlockSyncService's poll -- gated only on
                    // contentState == .idle -- resume and read block state mid-restore: the
                    // exact content-laundering hazard (H1) this whole design exists to
                    // prevent. If the sequence is genuinely stuck (a real bug), staying stuck
                    // and visible is safer than silently resuming sync over a half-restored
                    // document.
                    guard self.contentState != .structuralUndo else { return }
                    if self.contentState != .idle {
                        if self.contentState == .zoomTransition {
                            self.isZoomingContent = false
                            self.zoomedSectionIds = nil
                            self.zoomedSectionId = nil
                            self.zoomedBlockRange = nil
                            self.resumeAckContinuationOnce()
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

    /// Incremented on every content state transition away from idle.
    /// Polling captures this before JS calls and discards results if it changed.
    var contentGeneration: Int = 0

    /// Incremented every time `resetForProjectSwitch()` runs (project switch or close).
    /// `MilkdownEditor`/`CodeMirrorEditor`'s Coordinator compares this against the value
    /// it last saw in `updateNSView` and, on change, clears its `lastPolled*`
    /// equality-guard caches (word/character counts, section title/id). Without this,
    /// those caches -- which the Coordinator keeps across project switches because the
    /// editor view stays mounted -- would still hold the old project's values after
    /// `wordCount`/`characterCount`/`currentSectionName`/`currentSectionId` reset to
    /// zero/empty below, so a poll tick after reopening the same project would see the
    /// same numbers it cached before and wrongly suppress the change callbacks.
    var pollCacheResetGeneration: Int = 0

    /// Whether any content transition is in progress.
    /// Services check this instead of maintaining their own suppression flags.
    var isBusy: Bool { contentState != .idle }

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

    // MARK: - Scroll Request
    var scrollToOffset: Int?
    /// Block-ID-based scroll for Milkdown (avoids character-offset mismatch with atom nodes)
    var scrollToBlockId: String?
    /// Index into `annotations` array — triggers scroll to nth annotation in editor
    var scrollToAnnotationIndex: Int?

    // MARK: - Sidebar State (Phase 1.6)
    var sections: [SectionViewModel] = [] {
        didSet { invalidateOutlineCache() }
    }
    var statusFilter: SectionStatus?
    var headerLevelFilter: Int?

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

    /// Word count of the zoomed subtree (root section + descendants), or nil when not zoomed.
    /// Applies the same bibliography filter as filteredTotalWordCount so the
    /// "X of Y words" status-bar display compares like with like.
    var zoomedFilteredWordCount: Int? {
        guard let zoomedIds = zoomedSectionIds else { return nil }
        return sections
            .filter { zoomedIds.contains($0.id) }
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

    /// Whether the Document Notes section is collapsed in the annotation panel
    var isDocumentNotesCollapsed: Bool = UserDefaults.standard.bool(forKey: "isDocumentNotesCollapsed") {
        didSet { UserDefaults.standard.set(isDocumentNotesCollapsed, forKey: "isDocumentNotesCollapsed") }
    }

    /// ID of a newly created document annotation that should auto-enter edit mode (session-only)
    var pendingEditAnnotationId: String?

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

    /// Block sync service reference (injected by ContentView)
    /// Used for atomic content+blockID pushes during hierarchy enforcement
    weak var blockSyncService: BlockSyncService?

    /// Annotation sync service reference (injected by ContentView)
    weak var annotationSyncService: AnnotationSyncService?

    /// Bibliography sync service reference (injected by ContentView)
    weak var bibliographySyncService: BibliographySyncService?

    /// Footnote sync service reference (injected by ContentView)
    weak var footnoteSyncService: FootnoteSyncService?

    /// Pending image metadata for CodeMirror to pick up during zoom/rebuild transitions
    var pendingImageMeta: [ContentView.ImageBlockMeta]?

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
    /// Generation counter for blockReparseTask cooperative cancellation guard
    var blockReparseGeneration: Int = 0

    /// Current persist task for cancellation on rapid successive reorders
    var currentPersistTask: Task<Void, Never>?

    // MARK: - Database Observation
    private var observationTask: Task<Void, Never>?
    private var annotationObservationTask: Task<Void, Never>?

    /// Callback invoked after sections are updated from database observation
    /// Used by ContentView to enforce hierarchy constraints after slash command changes
    var onSectionsUpdated: (() -> Void)?

    // MARK: - Outline Cache (equality guard for the merge, Fix 1)
    //
    // Caches the last blocks/counts an observation tick actually applied, so an unchanged
    // re-emission from ValueObservation can be skipped before it ever reaches
    // `mergeSections`. This is the guard from Fix 1; Fix 2 is the merge itself. Comparing
    // blocks alone (without counts) would reintroduce a bug this codebase has fixed and
    // re-broken four times before -- see the "DO NOT ADD .removeDuplicates()" banner near
    // `observeOutlineBlocks` in `Database+BlocksObservation.swift` and
    // `OutlineObservationTests.swift`.
    //
    // Annotations don't need an equivalent cache: `observeAnnotations` applies
    // `.removeDuplicates()` at the GRDB layer (unlike `observeOutlineBlocks`, which
    // deliberately can't), so an unchanged re-emission is already filtered out before this
    // class ever sees it.
    //
    // Mechanism: invalidation is automatic, via `sections`'s `didSet` above -- any wholesale
    // write to `sections` (reassignment, subscript assignment, `inout` access) clears the
    // cache on its own. `applySectionsUpdate` is the sole re-arming point, and it re-arms
    // *after* its own assignment to `sections` runs (so the `didSet` it just triggered doesn't
    // wipe what it's about to set). `invalidateOutlineCache()` itself is `private`, which
    // narrows its blast radius to this file -- no caller outside `EditorViewState.swift` can
    // hand-manage the cache. Two manual, file-local calls remain and are both audited as
    // genuinely needed: `startObserving` and `stopObserving` neither one writes `sections`, so
    // the automatic `didSet` path never fires there -- these are the only two places that must
    // still clear the cache by hand.
    //
    // Boundary: the guard is automatic for *array-level* writes only. It cannot catch in-place
    // mutation of a `SectionViewModel` element -- e.g. `recalculateParentRelationships()`
    // mutating `vm.parentId` below, or the equality-guarded `apply()` mutations in
    // `EditorViewState+ObservableListDiff.swift`. Most of these element mutations happen inside
    // the cache-consistent merge path (`applySectionsUpdate` re-arms right after them), but
    // `finalizeSectionReorder` (`ContentView+SectionManagement.swift`) is a second, real caller
    // of `recalculateParentRelationships()` that sits outside that path. It's still safe
    // there: `editorState.sections = mutableSections`, an unconditional whole-array
    // reassignment immediately before the call, clears the cache via `sections`'s `didSet`,
    // and nothing between that write and the call re-arms it -- `applySectionsUpdate` is the
    // sole re-arming point in this file -- so the cache is guaranteed nil for the entire
    // mutation. `enforceHierarchyConstraints()`'s own reassignment immediately after also
    // clears the cache, but that's incidental to this invariant: the cache is already nil by
    // then, so removing that trailing write wouldn't reopen anything. The preceding write is
    // what's load-bearing here, not something this type structurally enforces on its own: a
    // future edit to `finalizeSectionReorder` that removes the preceding `editorState.sections
    // = mutableSections` write could silently reopen a stale-cache window without anything
    // here catching it. Any future code that needs the cache to notice an element mutation
    // must route it through `applySectionsUpdate`'s merge path rather than mutating a
    // `SectionViewModel` directly -- there is deliberately no escape hatch for that case.
    //
    // `@ObservationIgnored`: this is a private merge-skip cache, not UI state -- nothing should
    // ever observe it. Without the annotation, `@Observable` tracks these like any other stored
    // property, so `invalidateOutlineCache()`'s writes to them run *inside* the `withMutation`
    // that `sections`'s own write already opened, adding two redundant nested registrar
    // mutations to every array-level `sections` write for no observable benefit.
    @ObservationIgnored
    private var lastOutlineBlocks: [Block]?
    @ObservationIgnored
    private var lastOutlineCounts: [String: ProjectDatabase.HeadingWordCounts] = [:]

    /// Clear the outline equality-guard cache. Fires automatically from `sections`'s `didSet`;
    /// private so nothing outside this file can hand-manage it.
    private func invalidateOutlineCache() {
        lastOutlineBlocks = nil
        lastOutlineCounts = [:]
    }

    /// True when `blocks`/`counts` are exactly what the last applied tick produced, i.e. the
    /// merge can be skipped. Cleared automatically by `sections`'s `didSet`.
    func isOutlineUnchanged(
        blocks: [Block],
        counts: [String: ProjectDatabase.HeadingWordCounts]
    ) -> Bool {
        lastOutlineBlocks == blocks && lastOutlineCounts == counts
    }

    /// Start observing blocks from database for reactive UI updates
    /// Call this once during initialization after database is ready
    func startObserving(database: ProjectDatabase, projectId: String) {
        stopObserving()  // Cancel any existing observation
        invalidateOutlineCache()
        self.projectDatabase = database
        self.currentProjectId = projectId

        observationTask = Task { [weak self] in
            do {
                for try await outlineBlocks in database.observeOutlineBlocks(for: projectId) {
                    guard !Task.isCancelled, let self else { break }

                    // Skip updates during content transitions (drag, zoom, hierarchy enforcement, etc.)
                    guard contentState == .idle else {
                        DebugLog.log(.outline, "[EditorViewState:observe] SKIPPED: contentState=\(contentState), blocks=\(outlineBlocks.count)")
                        continue
                    }

                    // Batch word counts in a single DB read off the main thread.
                    let blockIds = outlineBlocks.map(\.id)
                    let needsAggregate = Set(outlineBlocks.filter { $0.aggregateGoal != nil }.map(\.id))
                    let counts = await Self.fetchBatchWordCounts(
                        database: database,
                        blockIds: blockIds,
                        needsAggregate: needsAggregate
                    )

                    // Fix 1: skip the merge entirely when nothing actually changed since the
                    // last applied tick -- both blocks AND counts, never blocks alone.
                    if self.isOutlineUnchanged(blocks: outlineBlocks, counts: counts) {
                        self.onSectionsUpdated?()
                        continue
                    }

                    // Fix 2: merge in place -- reuse existing view models by id instead of
                    // replacing the array wholesale, then recalculate parent relationships.
                    // `applySectionsUpdate` merges into a local copy and only assigns back when
                    // something actually changed: `inout` access to a tracked `@Observable`
                    // property fires that property's array-level notification unconditionally
                    // on exit (its synthesized `_modify` accessor's `didSet` call sits in an
                    // unconditional `defer`, unlike the plain `set`), so passing `&self.sections`
                    // directly here would defeat the point of this merge on every single tick.
                    self.applySectionsUpdate(from: outlineBlocks, counts: counts)

                    // Notify observers (e.g., for hierarchy enforcement)
                    self.onSectionsUpdated?()
                }
            } catch {
                DebugLog.log(.outline, "[EditorViewState] Block observation error: \(error)")
            }
        }
    }

    /// Re-fetch outline blocks from database and update sections.
    /// Called when ValueObservation may have been dropped during non-idle contentState.
    /// Heavy DB work runs off the main actor; the section assignment lands back on @MainActor.
    func refreshSections() {
        guard let db = projectDatabase, let pid = currentProjectId else {
            DebugLog.log(.outline, "[EditorViewState:refresh] BAIL: no db/pid")
            return
        }
        Task { [weak self] in
            do {
                let outlineBlocks = try await Task.detached(priority: .userInitiated) {
                    try db.fetchOutlineBlocks(projectId: pid)
                }.value

                let blockIds = outlineBlocks.map(\.id)
                let needsAggregate = Set(outlineBlocks.filter { $0.aggregateGoal != nil }.map(\.id))
                let counts = await Self.fetchBatchWordCounts(
                    database: db,
                    blockIds: blockIds,
                    needsAggregate: needsAggregate
                )

                guard let self else { return }
                DebugLog.log(.outline, "[EditorViewState:refresh] \(outlineBlocks.count) sections (contentState=\(self.contentState))")

                if self.isOutlineUnchanged(blocks: outlineBlocks, counts: counts) {
                    self.onSectionsUpdated?()
                    return
                }

                // See the observation-loop call site above for why `applySectionsUpdate` merges
                // into a local copy rather than passing `&self.sections` directly.
                self.applySectionsUpdate(from: outlineBlocks, counts: counts)
                self.onSectionsUpdated?()
            } catch {
                DebugLog.log(.outline, "[EditorViewState] refreshSections error: \(error)")
            }
        }
    }

    /// Merge freshly-fetched blocks/counts into `sections` and recalculate parent
    /// relationships in one step -- the exact sequence both `startObserving`'s live loop and
    /// `refreshSections`'s explicit re-fetch run on every tick. Extracted so both call sites
    /// (and tests) go through one call rather than duplicating the "merge into a local copy,
    /// assign back only if changed, then recalculate parents" sequence -- see `mergeSections`'s
    /// doc comment (EditorViewState+ObservableListDiff.swift) for why the local-copy step matters.
    ///
    /// - Returns: `true` if `mergeSections` structurally changed `sections` (see that method's
    ///   doc comment for what counts as a structural change).
    @discardableResult
    func applySectionsUpdate(
        from blocks: [Block],
        counts: [String: ProjectDatabase.HeadingWordCounts]
    ) -> Bool {
        var updatedSections = sections
        let sectionsChanged = Self.mergeSections(into: &updatedSections, from: blocks, counts: counts)
        if sectionsChanged { sections = updatedSections }   // fires didSet -> clears cache
        recalculateParentRelationships()
        // Re-arm AFTER the assignment above: `sections`'s didSet would otherwise wipe it.
        lastOutlineBlocks = blocks
        lastOutlineCounts = counts
        return sectionsChanged
    }

    /// Fetch heading word counts off the main thread, logging (rather than swallowing)
    /// any error so a silently-zeroed sidebar gets attention in the debug log.
    private static func fetchBatchWordCounts(
        database: ProjectDatabase,
        blockIds: [String],
        needsAggregate: Set<String>
    ) async -> [String: ProjectDatabase.HeadingWordCounts] {
        await Task.detached(priority: .userInitiated) {
            do {
                return try database.batchWordCounts(blockIds: blockIds, needsAggregate: needsAggregate)
            } catch {
                DebugLog.log(.outline, "[EditorViewState] batchWordCounts failed: \(error)")
                return [:]
            }
        }.value
    }

    /// Stop observing sections from database
    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
        annotationObservationTask?.cancel()
        annotationObservationTask = nil
        invalidateOutlineCache()
    }

    /// Start observing annotations from database for reactive UI updates
    func startObservingAnnotations(database: ProjectDatabase, contentId: String) {
        annotationObservationTask?.cancel()

        annotationObservationTask = Task { [weak self] in
            do {
                for try await dbAnnotations in database.observeAnnotations(for: contentId) {
                    guard !Task.isCancelled, let self else { break }

                    // Merge in place -- reuse existing view models by id. Merge into a
                    // local copy and only assign back when something actually changed -- see
                    // the sections observation loop above for why `&self.annotations` can't be
                    // passed directly here. No equality guard is needed before this: unlike
                    // `observeOutlineBlocks`, `observeAnnotations` applies `.removeDuplicates()`
                    // at the GRDB layer, so an unchanged re-emission never reaches here.
                    var updatedAnnotations = self.annotations
                    let annotationsChanged = Self.mergeAnnotations(into: &updatedAnnotations, from: dbAnnotations)
                    if annotationsChanged { self.annotations = updatedAnnotations }
                }
            } catch {
                DebugLog.log(.outline, "[EditorViewState] Annotation observation error: \(error)")
            }
        }
    }

    /// Recalculate parentId for all sections based on document order and header levels
    /// A section's parent is the nearest preceding section with a lower header level.
    ///
    /// Mutates `parentId` on the existing view model in place (equality-guarded) rather than
    /// calling `withUpdates`, which returns a new object instance. This method is shared by two
    /// callers with different cadences. The real per-tick caller is `applySectionsUpdate`
    /// (above, in this file, at the `recalculateParentRelationships()` call inside it) -- it
    /// runs on every database observation tick, which can fire every keystroke, so replacing
    /// identities here would undo Fix 2 on the very next line. The drag-reorder path
    /// (`ContentView+SectionManagement.swift`'s `finalizeSectionReorder`) is the other caller,
    /// invoked once per user action via `editorState.recalculateParentRelationships()`, instead
    /// of duplicating the parent-recalculation logic locally the way it used to. Either way,
    /// in-place mutation is the right choice for this method; `withUpdates` still exists and
    /// remains in use elsewhere on the drag path (e.g. `recalculateSortOrders`/
    /// `applyComputedOffsets`) for identity-replacing updates that are unaffected by this
    /// method's approach.
    func recalculateParentRelationships() {
        for index in sections.indices {
            let vm = sections[index]
            let newParentId = findParentByLevel(at: index)
            if vm.parentId != newParentId { vm.parentId = newParentId }
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

    // MARK: - Selection State

    /// Word count of the current editor text selection, or nil when nothing is selected.
    /// Fed by the selectionChanged push from both editors; counted with the same
    /// MarkdownUtils rules as the document total so the two numbers agree.
    var selectedWordCount: Int?

}

extension EditorViewState {
    /// Whether a resetting-content window (e.g. version-history restore) just closed
    /// in a state where it's safe and worthwhile to force an immediate block-sync poll,
    /// recovering any content push `handleContentPush` silently dropped while the
    /// window was open. Gated on `contentState == .idle` because `pollBlockChangesNow()`
    /// deliberately bypasses that guard for its own other callers — firing it while a
    /// different transition (zoom, hierarchy enforcement, etc.) is still in flight could
    /// read a half-updated document tree. A drop that closes while non-idle is an
    /// accepted narrowing: it still falls back to the ~2s periodic poll.
    static func shouldForcePollAfterResettingContent(
        wasResetting: Bool, isResetting: Bool, contentState: EditorContentState
    ) -> Bool {
        wasResetting && !isResetting && contentState == .idle
    }
}
