// swiftlint:disable type_body_length
//
//  OutlineSidebar.swift
//  final final
//

import SwiftUI
import UniformTypeIdentifiers

/// Main outline sidebar view
/// Displays sections as cards with filtering, zoom, and drag-drop support
struct OutlineSidebar: View {
    @Binding var sections: [SectionViewModel]
    @Binding var statusFilter: SectionStatus?
    @Binding var headerLevelFilter: Int?
    @Binding var zoomedSectionId: String?
    /// Zoomed section IDs from EditorViewState (includes root + descendants via document order)
    /// This is read-only because the sidebar never modifies the zoom state directly
    let zoomedSectionIds: Set<String>?
    /// Precomputed once per pass by the caller (`ContentView`) from this pass's `sections` plus
    /// the filter/zoom/goal `@Binding` values below -- see `OutlineSidebarRenderKey`'s doc
    /// comment (OutlineSidebar+Models.swift) for exactly what's folded in and the explicit
    /// invariant about future `@Binding`s. Declared here, immediately after `zoomedSectionIds`,
    /// purely so the memberwise-initializer argument order at every call site lines up with
    /// declaration order.
    let renderKey: OutlineSidebarRenderKey
    /// Document-level goal settings
    @Binding var documentGoal: Int?
    @Binding var documentGoalType: GoalType
    @Binding var excludeBibliography: Bool
    let onScrollToSection: (String) -> Void
    let onSectionUpdated: (SectionViewModel) -> Void
    let onSectionReorder: ((SectionReorderRequest) -> Void)?
    /// Called when user requests zoom into a section (double-click)
    /// Parameters: sectionId, zoomMode
    /// ID of the section the cursor is currently in (for active highlight)
    var currentSectionId: String?
    var onZoomToSection: ((String, ZoomMode) -> Void)?
    /// Called when user requests zoom out (double-click on already zoomed section)
    var onZoomOut: (() -> Void)?
    /// Called when drag operation starts - use to suppress sync
    var onDragStarted: (() -> Void)?
    /// Called when drag operation ends - use to resume sync
    var onDragEnded: (() -> Void)?
    /// MF-2 (Phase 7 review round, plan §7): bound through to both drop delegates
    /// (`OutlineSidebar+DropDelegates.swift`) as their `dropInFlight` binding -- see
    /// `EditorViewState.sectionDropInFlight`'s doc comment.
    @Binding var sectionDropInFlight: Bool
    /// Sidebar context-menu section operations: duplicate/delete a section's full subtree
    /// (see docs/architecture/unified-undo.md's unified-timeline-concept section for the
    /// `.sectionDelete`/`.sectionDuplicate` timeline entries this drives). Nil-defaulted so
    /// existing call sites are unaffected; see SectionCardView's context menu for the UI.
    var onDuplicateSection: ((String) -> Void)?
    var onDeleteSection: ((String) -> Void)?

    @Environment(ThemeManager.self) private var themeManager
    @State private var dropPosition: DropPosition?
    @State private var pendingDropId: UUID?  // Guards against race conditions in async drop handling
    @State private var lastDropLocation: CGPoint?  // Deduplicates simultaneous delegate fires
    @State private var sidebarWidth: CGFloat = 300  // Track actual width for zone calculations
    @State private var isDragging: Bool = false  // Track drag state for suppression
    @State private var hoveredCardId: String?
    @State private var cardFrames: [String: CGRect] = [:]  // Frames in scroll coordinate space for tooltip

    // Subtree drag state
    @State private var draggingSubtreeIds: Set<String> = []  // IDs being dragged (parent + children)
    @State private var isMouseOverSidebar = false
    @State private var showSubtreeDragHint: Bool = false
    @State private var subtreeDragHintTask: Task<Void, Never>?  // Replaces Timer for proper lifecycle
    private let hasSeenSubtreeDragHintKey = "hasSeenSubtreeDragHint"

    var body: some View {
        // Computed once per body pass and threaded through -- previously `filteredSections`
        // (filter+sort+allocate) and `sectionLevelInfos` (walks filteredSections) were each
        // reached from inside sectionCard(...), once per card, making per-update cost
        // O(N^2 log N) in section count. See EditorViewState.mergeSections for the companion
        // fix (Fix 2) that keeps card identity stable across updates.
        let visible = filteredSections
        let levelInfos = Self.levelInfos(for: visible)
        let structuralSignature = Self.structuralSignature(of: visible)
        #if DEBUG
        // swiftlint:disable:next redundant_discardable_let
        let _ = DebugLog.log(.viewUpdates, "[SidebarBody] visible=\(visible.count)")
        #endif
        VStack(spacing: 0) {
            OutlineFilterBar(
                selectedLevel: $headerLevelFilter,
                selectedFilter: $statusFilter,
                visibleSections: visible,
                documentGoal: $documentGoal,
                documentGoalType: $documentGoalType,
                excludeBibliography: $excludeBibliography
            )

            Divider()
                .foregroundColor(themeManager.currentTheme.dividerColor)

            if visible.isEmpty {
                emptyState
            } else {
                sectionsList(visible: visible, levelInfos: levelInfos, structuralSignature: structuralSignature)
            }
        }
        .frame(minWidth: 250, idealWidth: 300, maxWidth: 400)
        .background(themeManager.currentTheme.sidebarBackground)
    }

    private var filteredSections: [SectionViewModel] {
        var result = sections

        // Apply status filter
        if let filter = statusFilter {
            result = result.filter { $0.status == filter }
        }

        // Apply header level filter
        if let maxLevel = headerLevelFilter {
            result = result.filter { $0.headerLevel <= maxLevel }
        }

        // Apply zoom filter using zoomedSectionIds from EditorViewState
        // This uses the same document-order-based descendant calculation as the editor
        if let zoomedIds = zoomedSectionIds {
            result = result.filter { zoomedIds.contains($0.id) }
        }

        // Pin bibliography sections at the bottom
        // Sort by: isBibliography (false first), then sortOrder
        result.sort { a, b in
            if a.isBibliography != b.isBibliography {
                return !a.isBibliography  // Non-bibliography first
            }
            return a.sortOrder < b.sortOrder
        }

        return result
    }

    // MARK: - Subtree Drag Helpers

    /// Collect IDs of all descendants for subtree drag (level-based, not parent-based).
    /// Returns all sections after rootId until reaching one at same or shallower level.
    /// Delegates to the static `subtreeIds(rootId:in:)` -- the single implementation shared
    /// with `DraggableCardView`'s drag payload (via the closure `sectionCard` hands it) and
    /// pinned byte-identical by `ObservableListDiffTests.subtreeIdsMatchesLevelWalk`.
    private func collectSubtreeIds(rootId: String) -> [String] {
        Self.subtreeIds(rootId: rootId, in: filteredSections)
    }

    /// Check if section has children (for hint logic)
    private func sectionHasChildren(_ sectionId: String) -> Bool {
        return !collectSubtreeIds(rootId: sectionId).isEmpty
    }

    /// Collect IDs of all descendants of `rootId` for subtree drag (level-based, not
    /// parent-based): every section after the root until one at the same or shallower level.
    /// `internal static` so it can be called from a closure captured at `sectionCard` build
    /// time (see `DraggableCardView.collectSubtreeIds`) without re-deriving `filteredSections`,
    /// and from tests.
    static func subtreeIds(rootId: String, in sections: [SectionViewModel]) -> [String] {
        guard let rootIndex = sections.firstIndex(where: { $0.id == rootId }) else {
            return []
        }

        let rootLevel = sections[rootIndex].headerLevel
        var childIds: [String] = []

        // Iterate forward, collecting all sections deeper than root
        for i in (rootIndex + 1)..<sections.count {
            let section = sections[i]
            if section.headerLevel <= rootLevel {
                break  // Hit a section at same or shallower level
            }
            childIds.append(section.id)
        }

        return childIds
    }

    /// Show hint for subtree drag (first-time only)
    /// Called when a single-card drag starts on a section with children
    /// Uses Task.sleep for proper async lifecycle management
    private func maybeShowSubtreeDragHint(for sectionId: String) {
        // Only show if hasn't seen hint before
        guard !AppDefaults.store.bool(forKey: hasSeenSubtreeDragHintKey) else {
            return
        }

        // Cancel any existing hint task
        subtreeDragHintTask?.cancel()

        // Show hint after 500ms delay using Task.sleep
        subtreeDragHintTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            showSubtreeDragHint = true

            // Auto-dismiss after 3 seconds
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            showSubtreeDragHint = false
            AppDefaults.store.set(true, forKey: hasSeenSubtreeDragHintKey)
        }
    }

    /// Cancel hint task when drag ends
    private func cancelSubtreeDragHint() {
        subtreeDragHintTask?.cancel()
        subtreeDragHintTask = nil
        showSubtreeDragHint = false
    }

    /// Clear drag state when drag ends
    private func clearDragState() {
        draggingSubtreeIds = []
        cancelSubtreeDragHint()
        dropPosition = nil  // Clear drop indicator
    }

    /// Section level info for drop delegates. `internal static` so it can be computed once per
    /// body pass (in `body`) and threaded into every card, instead of being re-derived from
    /// `filteredSections` inside each card as it was before.
    static func levelInfos(for sections: [SectionViewModel]) -> [SectionLevelInfo] {
        sections.enumerated().map { idx, sec in
            SectionLevelInfo(id: sec.id, headerLevel: sec.headerLevel, index: idx)
        }
    }

    /// Structural signature of an ordered section list -- the sequence of `(id, headerLevel)`
    /// pairs that `subtreeIds(rootId:in:)` walks to compute a drag payload. Computed once per
    /// body pass (like `levelInfos` above) and threaded into every `DraggableCardView` built
    /// from this list, where it's folded into `Equatable` (see that type's doc comment) so a
    /// reorder or promote/demote always forces `updateNSView` to re-run for every card, even
    /// ones whose own `section`/`isGhost`/`isActive` are unchanged -- because `updateNSView` is
    /// the only thing that refreshes `context.coordinator.parent`, and with it the
    /// `collectSubtreeIds` closure `sectionCard` builds by capturing this pass's `visible`
    /// snapshot.
    ///
    /// Deliberately excludes every other section property (title, word count, status, ...) --
    /// those already propagate to a hosted card via `@Observable` and don't change what any
    /// *other* card's subtree walk would compute, so a pure content edit should still let
    /// untouched cards skip `updateNSView`.
    ///
    /// See `renderSignature(of:)` below (bt t-ef411da3) for the sibling signature that gates
    /// whether `OutlineSidebar.body` re-runs AT ALL. That one's field set must remain a
    /// SUPERSET of this one's (currently `id` and `headerLevel`, both included there too) -- if
    /// this function ever grows a field `renderSignature` doesn't also hash, a structural change
    /// could leave `body` skipped while a per-card `DraggableCardView.updateNSView` still needed
    /// to run against stale data, which is exactly backwards. Keep the two lists in sync by
    /// hand; there is no compiler check for this.
    static func structuralSignature(of sections: [SectionViewModel]) -> Int {
        var hasher = Hasher()
        for section in sections {
            hasher.combine(section.id)
            hasher.combine(section.headerLevel)
        }
        return hasher.finalize()
    }

    /// Render-affecting signature of an ordered, UNFILTERED section list -- the fields
    /// `OutlineSidebar.body`'s own rendering logic actually depends on (the three leaves that
    /// read title/word count instead do so LIVE off the `@Observable` object -- see
    /// `OutlineSidebarRenderKey`'s doc comment). Folded into
    /// `OutlineSidebarRenderKey.sectionsSignature` (OutlineSidebar+Models.swift), which
    /// `ContentView` builds once per pass and `OutlineSidebar`'s `Equatable` conformance
    /// (also OutlineSidebar+Models.swift -- moved there to stay clear of this file's
    /// SwiftLint `file_length` warning threshold) compares, so SwiftUI can skip re-invoking
    /// `OutlineSidebar.body` entirely when nothing here changed -- the actual root-cause fix for
    /// bt t-ef411da3 (rounds 1-2 fixed leaf-level over-invalidation; this fixes body-level
    /// over-invalidation).
    ///
    /// Deliberately a SEPARATE function from `structuralSignature(of:)` above, not a call site
    /// built on top of it -- the two exist for different purposes (this one for whether `body`
    /// needs to re-run at all; `structuralSignature` for whether an already-rendered card's
    /// `DraggableCardView.updateNSView` needs to re-run) and are allowed to diverge. But this
    /// function's field set must remain a SUPERSET of whatever `structuralSignature` reads --
    /// see that function's own doc comment for the direction this must never be violated in.
    /// Called on the RAW, UNFILTERED `sections` array (not `filteredSections`): `body` reads
    /// `sections` before applying the status/level/zoom filters, and those filters are already
    /// covered by `OutlineSidebarRenderKey`'s own separate `statusFilter`/`headerLevelFilter`/
    /// `zoomedSectionId` fields, so hashing the raw array here avoids computing (and hashing) a
    /// filtered copy just to throw it away.
    ///
    /// Deliberately excludes `title`/`wordCount`/`aggregateWordCount`/`tags`/goal fields -- the
    /// exact per-keystroke-churning properties this whole fix exists to stop re-coupling `body`
    /// to. Including any of them here would silently reintroduce the original bug: every heading
    /// edit or word-count update would change this signature, invalidate
    /// `OutlineSidebarRenderKey`, and force `body` to re-run on every keystroke again, exactly as
    /// before this fix.
    static func renderSignature(of sections: [SectionViewModel]) -> Int {
        var hasher = Hasher()
        for section in sections {
            hasher.combine(ObjectIdentifier(section))
            hasher.combine(section.id)
            hasher.combine(section.headerLevel)
            hasher.combine(section.status)
            hasher.combine(section.isBibliography)
            hasher.combine(section.sortOrder)
        }
        return hasher.finalize()
    }

    private func sectionsList(
        visible: [SectionViewModel], levelInfos: [SectionLevelInfo], structuralSignature: Int
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, section in
                        sectionCard(
                            section: section, index: index, visible: visible, levelInfos: levelInfos,
                            structuralSignature: structuralSignature)

                        Divider()
                            .foregroundColor(themeManager.currentTheme.dividerColor)
                    }

                    // Drop zone after last card
                    Color.clear
                        .frame(height: 40)
                        .onDrop(of: [.sectionTransfer], delegate: EndDropDelegate(
                            sectionCount: visible.count,
                            sectionLevels: levelInfos,
                            sidebarWidth: sidebarWidth,  // Pass actual sidebar width for zone calculation
                            dropPosition: $dropPosition,
                            pendingDropId: $pendingDropId,
                            lastDropLocation: $lastDropLocation,
                            isDragging: $isDragging,
                            dropInFlight: $sectionDropInFlight,
                            onDrop: { transfer, position in
                                handleDropAtEnd(dropped: transfer, position: position)
                            },
                            onDragStarted: onDragStarted,
                            onDragEnded: {
                                // MF-2 point 6 (Phase 7 review round, plan §7): previously wired
                                // to the real `onDragEnded` closure directly, unlike
                                // SectionDropDelegate's own no-op below -- that asymmetry meant
                                // an end-of-list drop invoked ContentView's guarded onDragEnded
                                // TWICE per drag (once here, once via DraggableCardView's drag-
                                // source completion). Already handled by DraggableCardView --
                                // see ContentView.swift's onDragEnded doc comment (Path A) for
                                // why that's the single source of truth for both delegate types.
                            }
                        ))
                }
            }
            .coordinateSpace(.named("sidebarScroll"))
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                sidebarWidth = newWidth
            }
            // Tooltip overlay at ScrollView level (renders above all cards). `.overlay`'s content
            // closure -- unlike `.popover`/`.sheet` -- is evaluated EAGERLY as part of this
            // view's own body, so this closure must not itself read any `@Observable`
            // string-returning property (`section.title`, etc.): that would put OutlineSidebar's
            // body back on the hook for a per-keystroke invalidation whenever a hovered card's
            // title changes -- a narrower instance of the exact bug bt t-ef411da3 fixes. The whole
            // `section` object is passed into `SectionTitleTooltip` below (never `section.title`
            // as a string extracted here); the truncation check and the title `Text` both live in
            // that leaf's own body instead. `hoveredId`/`isDragging`/`cardFrames`/`section.id` are
            // all safe to read here: the first three are plain `@State`, and `id` is a `let` on
            // `SectionViewModel`, which `@Observable` never instruments.
            .overlay(alignment: .topLeading) {
                if let hoveredId = hoveredCardId,
                   !isDragging,
                   let frame = cardFrames[hoveredId],
                   let section = visible.first(where: { $0.id == hoveredId }) {
                    SectionTitleTooltip(section: section, frame: frame, sidebarWidth: sidebarWidth)
                }
            }
            // Subtree drag hint overlay
            .overlay(alignment: .bottom) {
                if showSubtreeDragHint {
                    SubtreeDragHint()
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .animation(.easeInOut(duration: 0.3), value: showSubtreeDragHint)
                }
            }
            .onHover { isMouseOverSidebar = $0 }
            .onChange(of: currentSectionId) { _, newId in
                guard let newId, draggingSubtreeIds.isEmpty, !isMouseOverSidebar else { return }
                if visible.contains(where: { $0.id == newId }) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(newId, anchor: .center)
                    }
                }
            }
        }
    }

    /// A single section card with drag, drop-indicator, and geometry tracking.
    /// Extracted from sectionsList to keep type-checking fast.
    /// `visible`/`levelInfos` are the snapshot computed once in `body` for this pass -- passed
    /// through rather than re-derived here, which previously made per-card cost O(N log N)
    /// (so O(N^2 log N) across all cards) in section count on every update.
    private func sectionCard(
        section: SectionViewModel, index: Int, visible: [SectionViewModel], levelInfos: [SectionLevelInfo],
        structuralSignature: Int
    ) -> some View {
        // Use DraggableCardView for cursor offset control via AppKit. The subtree walk is
        // handed over as a closure rather than the full `allSections` array so the closure can
        // capture this body pass's `visible` snapshot directly -- same childIds/pasteboard
        // payload a fresh `filteredSections` read would produce.
        //
        // That snapshot is only current as of the click if `updateNSView` actually ran for this
        // card since the last reorder. `DraggableCardView`'s `Equatable` conformance can skip
        // `updateNSView` for a card whose own `section`/`isGhost`/`isActive` are unchanged,
        // which would otherwise leave `context.coordinator.parent` (and this closure) pointing
        // at the pre-reorder list. `structuralSignature`, passed below, exists to prevent
        // exactly that: it changes on any reorder or promote/demote, which forces
        // `updateNSView` -- and a freshly-captured closure -- on every card, including ones
        // this snapshot alone wouldn't distinguish.
        DraggableCardView(
            section: section,
            collectSubtreeIds: { rootId in Self.subtreeIds(rootId: rootId, in: visible) },
            isGhost: draggingSubtreeIds.contains(section.id),
            isActive: section.id == currentSectionId,
            structuralSignature: structuralSignature,
            onDragStarted: { draggedIds in
                // Track subtree IDs for ghost state
                draggingSubtreeIds = draggedIds
                // Show hint for single-card drags on sections with children
                if draggedIds.count == 1 && sectionHasChildren(section.id) {
                    maybeShowSubtreeDragHint(for: section.id)
                }
                onDragStarted?()
            },
            onDragEnded: {
                clearDragState()
                onDragEnded?()
            },
            onSingleClick: {
                onScrollToSection(section.id)
            },
            onDoubleClick: { receivedMode in
                // Prevent zoom on managed sections — zoom filters these out,
                // producing empty content that destroys them on flush
                guard !section.isBibliography && !section.isNotes else { return }

                if zoomedSectionId == section.id {
                    // Zoom out if already zoomed to this section
                    onZoomOut?()
                } else {
                    // Pseudo-sections always use shallow zoom (show only the pseudo-section itself)
                    // Regular sections use the received mode (full or shallow based on Option key)
                    let mode = section.isPseudoSection ? .shallow : receivedMode
                    onZoomToSection?(section.id, mode)
                }
            },
            onSectionUpdated: onSectionUpdated,
            onHoverChanged: { isHovering in
                hoveredCardId = isHovering ? section.id : nil
            },
            onDuplicate: onDuplicateSection.map { callback in { callback(section.id) } },
            onDelete: onDeleteSection.map { callback in { callback(section.id) } },
            isZoomed: zoomedSectionId != nil
        )
        .id(section.id)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("sidebarScroll"))
        } action: { newFrame in
            cardFrames[section.id] = newFrame
        }
        // Elevate z-index for drop indicators
        .zIndex(
            shouldShowIndicatorBefore(index: index)
            || shouldShowIndicatorAfter(index: index) ? 1 : 0
        )
        // Drop indicator BEFORE - overlay doesn't affect layout, preventing flickering
        .overlay(alignment: .top) {
            if shouldShowIndicatorBefore(index: index) {
                DropIndicatorLine(level: levelForIndicatorBefore(index: index))
                    .offset(y: -(DropIndicatorLine.height / 2))  // Center in gap above card
                    .allowsHitTesting(false)
            }
        }
        // Drop indicator AFTER - overlay doesn't affect layout, preventing flickering
        .overlay(alignment: .bottom) {
            if shouldShowIndicatorAfter(index: index) {
                DropIndicatorLine(level: levelForIndicatorAfter(index: index))
                    .offset(y: DropIndicatorLine.height / 2)  // Center in gap below card
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.sectionTransfer], delegate: SectionDropDelegate(
            section: section,
            index: index,
            cardHeight: cardHeight(for: section),
            sectionLevels: levelInfos,
            sidebarWidth: sidebarWidth,  // Pass actual sidebar width for zone calculation
            dropPosition: $dropPosition,
            pendingDropId: $pendingDropId,
            lastDropLocation: $lastDropLocation,
            isDragging: $isDragging,
            dropInFlight: $sectionDropInFlight,
            onDrop: { transfer, position in
                handleDrop(dropped: transfer, position: position, targetSection: section)
            },
            onDragStarted: {
                // Ghost state already set by DraggableCardView.onDragStarted
                // This is called by drop delegate when drag enters a drop zone
            },
            onDragEnded: {
                // Drag ended callback already handled by DraggableCardView
            }
        ))
    }

    // MARK: - Drop Indicator Visibility Helpers

    /// Whether to show the drop indicator BEFORE the card at given index
    private func shouldShowIndicatorBefore(index: Int) -> Bool {
        if case .insertBefore(let idx, _) = dropPosition, idx == index {
            return true
        }
        return false
    }

    /// Whether to show the drop indicator AFTER the card at given index
    private func shouldShowIndicatorAfter(index: Int) -> Bool {
        if case .insertAfter(let idx, _) = dropPosition, idx == index {
            return true
        }
        return false
    }

    /// Get the level for the indicator before the card at given index
    private func levelForIndicatorBefore(index: Int) -> Int {
        if case .insertBefore(_, let level) = dropPosition {
            return level
        }
        return 1  // Default level when not visible
    }

    /// Get the level for the indicator after the card at given index
    private func levelForIndicatorAfter(index: Int) -> Int {
        if case .insertAfter(_, let level) = dropPosition {
            return level
        }
        return 1  // Default level when not visible
    }

    /// Fallback card height, used for any card `cardFrames` has no measurement for yet -- not just
    /// before first layout, but for any card the LazyVStack hasn't materialized (off-screen rows).
    static let estimatedCardHeight: CGFloat = 70

    static func cardHeight(measured: CGRect?) -> CGFloat {
        measured?.height ?? estimatedCardHeight
    }

    /// Calculate approximate card height for GeometryReader frame. Reads only the plain
    /// `cardFrames` `@State` dictionary (populated per-card via `.onGeometryChange`) -- not
    /// `section.title`, which previously made this reachable from `body`'s `@Observable` call
    /// graph (`body` -> `sectionCard` -> `cardHeight`) and invalidated the whole sidebar on
    /// every heading keystroke.
    private func cardHeight(for section: SectionViewModel) -> CGFloat {
        Self.cardHeight(measured: cardFrames[section.id])
    }

    /// Handle drop onto a section card with position awareness
    /// Uses the constrained level from drop position (determined by horizontal position)
    private func handleDrop(dropped: SectionTransfer, position: DropPosition, targetSection: SectionViewModel) {
        let newLevel = position.level

        // Self-drop: only proceed if level is changing
        if dropped.id == targetSection.id {
            guard dropped.headerLevel != newLevel else { return }
        }

        // Calculate target section ID (the section we insert AFTER)
        // This ID is stable across zoom/filter states, unlike index-based positioning
        let targetSectionId: String?
        let insertionIndexForParent: Int  // Only used for parent calculation within filteredSections

        switch position {
        case .insertBefore(let idx, _):
            // Insert BEFORE section at idx means insert AFTER section at idx-1
            targetSectionId = idx > 0 ? filteredSections[idx - 1].id : nil
            insertionIndexForParent = idx
        case .insertAfter(let idx, _):
            targetSectionId = filteredSections[idx].id
            insertionIndexForParent = idx + 1
        }

        // Find parent based on level - look backwards for a section with level < newLevel
        // Exclude the dragged section to prevent circular parent references
        let newParentId = findParentId(forLevel: newLevel, insertionIndex: insertionIndexForParent, excludingId: dropped.id)

        // Notify parent with structured request using stable section ID
        let request = SectionReorderRequest(
            sectionId: dropped.id,
            targetSectionId: targetSectionId,
            newLevel: newLevel,
            newParentId: newParentId,
            isSubtreeDrag: dropped.isSubtreeDrag,
            childIds: dropped.childIds
        )
        onSectionReorder?(request)
    }

    /// Handle drop at end of list
    private func handleDropAtEnd(dropped: SectionTransfer, position: DropPosition) {
        // Use level from drop position (constrained by predecessor)
        let newLevel = position.level
        let newParentId = findParentId(forLevel: newLevel, insertionIndex: filteredSections.count, excludingId: dropped.id)

        // Target is the last visible section (insert after it)
        let targetSectionId = filteredSections.last?.id

        let request = SectionReorderRequest(
            sectionId: dropped.id,
            targetSectionId: targetSectionId,
            newLevel: newLevel,
            newParentId: newParentId,
            isSubtreeDrag: dropped.isSubtreeDrag,
            childIds: dropped.childIds
        )
        onSectionReorder?(request)
    }

    /// Find the appropriate parent ID for a section at the given level and insertion point
    /// - Parameter excludingId: The ID of the section being moved (to prevent circular references)
    private func findParentId(forLevel level: Int, insertionIndex: Int, excludingId: String) -> String? {
        guard level > 1 else { return nil }

        // Look backwards from insertion point for a section with lower level
        for i in stride(from: insertionIndex - 1, through: 0, by: -1) {
            let section = filteredSections[i]
            // Prevent circular reference: exclude the section being moved
            if section.id != excludingId && section.headerLevel < level {
                return section.id
            }
        }
        return nil
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "doc.text")
                .font(.system(size: 40))
                .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.3))

            if statusFilter != nil || headerLevelFilter != nil {
                Text("No sections match the filter")
                    .font(.system(size: 13))
                    .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.6))

                Button("Clear Filter") {
                    statusFilter = nil
                    headerLevelFilter = nil
                }
                .buttonStyle(.borderless)
            } else if zoomedSectionId != nil {
                Text("Section not found")
                    .font(.system(size: 13))
                    .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.6))

                Button("Zoom Out") {
                    zoomedSectionId = nil
                }
                .buttonStyle(.borderless)
            } else {
                Text("No sections yet")
                    .font(.system(size: 13))
                    .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.6))

                Text("Add headers in your document\nto create sections")
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.4))
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
// swiftlint:enable type_body_length

/// Leaf view for the sidebar's hover tooltip (bt t-ef411da3, sidebar re-render investigation).
/// Extracted from `OutlineSidebar.sectionsList`'s `.overlay` closure so that the truncation check
/// (`TypeScale.sectionTitleIsTruncated`, a real Core Text measurement) and the title `Text` --
/// both of which read `section.title`, an `@Observable` property -- invalidate only this small
/// leaf when the hovered section's title changes, not the whole sidebar body. Takes the whole
/// `SectionViewModel`, not a pre-extracted `String`: passing a string would just move the read to
/// wherever that string gets pulled out of `section`, defeating the extraction.
struct SectionTitleTooltip: View {
    let section: SectionViewModel
    let frame: CGRect
    let sidebarWidth: CGFloat
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        if TypeScale.sectionTitleIsTruncated(
            section.title,
            level: section.headerLevel,
            isItalic: section.isPseudoSection,
            availableWidth: sidebarWidth - 24
        ) {
            Text(section.title)
                .font(.system(size: TypeScale.smallUI))
                .foregroundColor(themeManager.currentTheme.tooltipText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(themeManager.currentTheme.tooltipBackground)
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280)
                .offset(x: frame.minX + 12, y: frame.maxY)
                .allowsHitTesting(false)
        }
    }
}

#Preview {
    @Previewable @State var sections = [
        SectionViewModel(from: Section(
            projectId: "test",
            sortOrder: 0,
            headerLevel: 1,
            title: "Chapter One",
            status: .writing,
            wordCount: 450
        )),
        SectionViewModel(from: Section(
            projectId: "test",
            parentId: nil,
            sortOrder: 1,
            headerLevel: 2,
            title: "Introduction",
            status: .next,
            tags: ["draft"],
            wordGoal: 500,
            goalType: .approx,
            wordCount: 320
        )),
        SectionViewModel(from: Section(
            projectId: "test",
            sortOrder: 2,
            headerLevel: 2,
            title: "Background",
            status: .review,
            wordCount: 180
        ))
    ]
    @Previewable @State var filter: SectionStatus?
    @Previewable @State var levelFilter: Int?
    @Previewable @State var zoom: String?
    @Previewable @State var docGoal: Int? = 1000
    @Previewable @State var docGoalType: GoalType = .approx
    @Previewable @State var excludeBib: Bool = false
    @Previewable @State var dropInFlight: Bool = false

    OutlineSidebar(
        sections: $sections,
        statusFilter: $filter,
        headerLevelFilter: $levelFilter,
        zoomedSectionId: $zoom,
        zoomedSectionIds: nil,
        renderKey: OutlineSidebarRenderKey(
            sections: sections,
            statusFilter: filter,
            headerLevelFilter: levelFilter,
            zoomedSectionId: zoom,
            documentGoal: docGoal,
            documentGoalType: docGoalType,
            excludeBibliography: excludeBib
        ),
        documentGoal: $docGoal,
        documentGoalType: $docGoalType,
        excludeBibliography: $excludeBib,
        onScrollToSection: { id in print("Scroll to: \(id)") },
        onSectionUpdated: { section in print("Updated: \(section.title)") },
        onSectionReorder: { request in
            // swiftlint:disable:next line_length
            print("Reorder: \(request.sectionId) after \(request.targetSectionId ?? "nil"), level \(request.newLevel), parent: \(request.newParentId ?? "nil")")
        },
        onZoomToSection: { id, mode in
            zoom = id
            print("Zoom to: \(id) with mode: \(mode)")
        },
        onZoomOut: {
            zoom = nil
            print("Zoom out")
        },
        onDragStarted: { print("Drag started") },
        onDragEnded: { print("Drag ended") },
        sectionDropInFlight: $dropInFlight
    )
    .frame(width: 300, height: 500)
    .environment(ThemeManager.shared)
    .environment(GoalColorSettingsManager.shared)
}
