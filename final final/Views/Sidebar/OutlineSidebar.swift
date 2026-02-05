// swiftlint:disable file_length type_body_length
//
//  OutlineSidebar.swift
//  final final
//

import SwiftUI
import UniformTypeIdentifiers

/// Transferable wrapper for drag-and-drop
struct SectionTransfer: Codable, Transferable {
    let id: String
    let sortOrder: Int
    let headerLevel: Int
    let isSubtreeDrag: Bool      // True when Option-drag includes descendants
    let childIds: [String]       // Ordered descendant IDs for subtree drag

    init(id: String, sortOrder: Int, headerLevel: Int, isSubtreeDrag: Bool = false, childIds: [String] = []) {
        self.id = id
        self.sortOrder = sortOrder
        self.headerLevel = headerLevel
        self.isSubtreeDrag = isSubtreeDrag
        self.childIds = childIds
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .sectionTransfer)
    }
}

extension UTType {
    static var sectionTransfer: UTType {
        UTType(exportedAs: "com.kerim.final-final.section")
    }
}

// MARK: - Drop Position Types

/// Represents where a drop will occur relative to a section card
/// Now includes level information for horizontal zone-based level selection
enum DropPosition: Equatable {
    case insertBefore(index: Int, level: Int)   // Insert before card at index with specified level
    case insertAfter(index: Int, level: Int)    // Insert after card at index with specified level

    var targetIndex: Int {
        switch self {
        case .insertBefore(let idx, _), .insertAfter(let idx, _):
            return idx
        }
    }

    var level: Int {
        switch self {
        case .insertBefore(_, let lvl), .insertAfter(_, let lvl):
            return lvl
        }
    }
}

// MARK: - Level Calculation

/// Calculate target header level from horizontal drop position using zone-based selection
/// Returns one of 2-3 valid level options based on x position relative to predecessor
/// - Parameters:
///   - x: Horizontal position of the drop
///   - sidebarWidth: Total width of the sidebar for zone calculation
///   - predecessorLevel: Header level of the section above the drop position (0 if dropping at top)
/// - Returns: Target header level (1+, no upper limit for deep headers)
func calculateZoneLevel(x: CGFloat, sidebarWidth: CGFloat, predecessorLevel: Int) -> Int {
    // Special case: first position (no predecessor) only allows level 1
    if predecessorLevel == 0 {
        return 1
    }

    // Allow levels beyond H6 (deep headers from subtree drags)
    let minLevel = max(1, predecessorLevel - 1)
    let maxLevel = predecessorLevel + 1  // No cap - allow H7+

    // Determine how many unique levels are available
    let uniqueLevels = Set([minLevel, predecessorLevel, maxLevel]).sorted()

    if uniqueLevels.count == 2 {
        // Only 2 options (e.g., predecessor at level 1 gives [1, 2])
        let zoneWidth = sidebarWidth / 2
        return x < zoneWidth ? uniqueLevels[0] : uniqueLevels[1]
    } else {
        // 3 options: minLevel, same level, maxLevel
        let zoneWidth = sidebarWidth / 3
        if x < zoneWidth {
            return minLevel
        } else if x < zoneWidth * 2 {
            return predecessorLevel
        } else {
            return maxLevel
        }
    }
}

/// Structured request for section reordering with full context
struct SectionReorderRequest {
    let sectionId: String
    let targetSectionId: String?  // Insert AFTER this section (nil = insert at beginning)
    let newLevel: Int
    let newParentId: String?
    let isSubtreeDrag: Bool       // True when Option-drag moves parent with children
    let childIds: [String]        // Ordered descendant IDs for subtree drag

    init(
        sectionId: String,
        targetSectionId: String?,
        newLevel: Int,
        newParentId: String?,
        isSubtreeDrag: Bool = false,
        childIds: [String] = []
    ) {
        self.sectionId = sectionId
        self.targetSectionId = targetSectionId
        self.newLevel = newLevel
        self.newParentId = newParentId
        self.isSubtreeDrag = isSubtreeDrag
        self.childIds = childIds
    }
}

/// Lightweight struct for level constraint calculation (thread-safe)
/// Used to pass section level info to drop delegates without @Observable
struct SectionLevelInfo: Sendable {
    let id: String
    let headerLevel: Int
    let index: Int
}

/// Main outline sidebar view
/// Displays sections as cards with filtering, zoom, and drag-drop support
struct OutlineSidebar: View {
    @Binding var sections: [SectionViewModel]
    @Binding var statusFilter: SectionStatus?
    @Binding var zoomedSectionId: String?
    /// Zoomed section IDs from EditorViewState (includes root + descendants via document order)
    /// This is read-only because the sidebar never modifies the zoom state directly
    let zoomedSectionIds: Set<String>?
    /// Document-level goal settings
    @Binding var documentGoal: Int?
    @Binding var documentGoalType: GoalType
    @Binding var excludeBibliography: Bool
    let onScrollToSection: (String) -> Void
    let onSectionUpdated: (SectionViewModel) -> Void
    let onSectionReorder: ((SectionReorderRequest) -> Void)?
    /// Called when user requests zoom into a section (double-click)
    /// Parameters: sectionId, zoomMode
    var onZoomToSection: ((String, ZoomMode) -> Void)?
    /// Called when user requests zoom out (double-click on already zoomed section)
    var onZoomOut: (() -> Void)?
    /// Called when drag operation starts - use to suppress sync
    var onDragStarted: (() -> Void)?
    /// Called when drag operation ends - use to resume sync
    var onDragEnded: (() -> Void)?

    @Environment(ThemeManager.self) private var themeManager
    @State private var dropPosition: DropPosition?
    @State private var pendingDropId: UUID?  // Guards against race conditions in async drop handling
    @State private var lastDropLocation: CGPoint?  // Deduplicates simultaneous delegate fires
    @State private var sidebarWidth: CGFloat = 300  // Track actual width for zone calculations
    @State private var isDragging: Bool = false  // Track drag state for suppression

    // Subtree drag state
    @State private var draggingSubtreeIds: Set<String> = []  // IDs being dragged (parent + children)
    @State private var showSubtreeDragHint: Bool = false
    @State private var subtreeDragHintTask: Task<Void, Never>?  // Replaces Timer for proper lifecycle
    private let hasSeenSubtreeDragHintKey = "hasSeenSubtreeDragHint"

    /// Total word count of currently visible sections (respects excludeBibliography)
    private var filteredWordCount: Int {
        filteredSections
            .filter { !excludeBibliography || !$0.isBibliography }
            .reduce(0) { $0 + $1.wordCount }
    }

    var body: some View {
        VStack(spacing: 0) {
            OutlineFilterBar(
                selectedFilter: $statusFilter,
                filteredWordCount: filteredWordCount,
                documentGoal: $documentGoal,
                documentGoalType: $documentGoalType,
                excludeBibliography: $excludeBibliography
            )

            Divider()
                .foregroundColor(themeManager.currentTheme.dividerColor)

            if filteredSections.isEmpty {
                emptyState
            } else {
                sectionsList
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

    /// Collect IDs of all descendants for subtree drag (level-based, not parent-based)
    /// Returns all sections after rootId until reaching one at same or shallower level
    private func collectSubtreeIds(rootId: String) -> [String] {
        guard let rootIndex = filteredSections.firstIndex(where: { $0.id == rootId }) else {
            return []
        }

        let rootLevel = filteredSections[rootIndex].headerLevel
        var childIds: [String] = []

        // Iterate forward, collecting all sections deeper than root
        for i in (rootIndex + 1)..<filteredSections.count {
            let section = filteredSections[i]
            if section.headerLevel <= rootLevel {
                break  // Hit a section at same or shallower level
            }
            childIds.append(section.id)
        }

        return childIds
    }

    /// Check if section has children (for hint logic)
    private func sectionHasChildren(_ sectionId: String) -> Bool {
        return !collectSubtreeIds(rootId: sectionId).isEmpty
    }

    /// Show hint for subtree drag (first-time only)
    /// Called when a single-card drag starts on a section with children
    /// Uses Task.sleep for proper async lifecycle management
    private func maybeShowSubtreeDragHint(for sectionId: String) {
        // Only show if hasn't seen hint before
        guard !UserDefaults.standard.bool(forKey: hasSeenSubtreeDragHintKey) else {
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
            UserDefaults.standard.set(true, forKey: hasSeenSubtreeDragHintKey)
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

    private var sectionsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredSections.enumerated()), id: \.element.id) { index, section in
                        // Use DraggableCardView for cursor offset control via AppKit
                        DraggableCardView(
                            section: section,
                            allSections: filteredSections,
                            isGhost: draggingSubtreeIds.contains(section.id),
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
                            onSectionUpdated: onSectionUpdated
                        )
                        .id(section.id)
                        // Elevate z-index when showing indicator to prevent adjacent cards from rendering on top
                        .zIndex(shouldShowIndicatorBefore(index: index) || shouldShowIndicatorAfter(index: index) ? 1 : 0)
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
                            // Compute section levels inline - no state modification
                            sectionLevels: filteredSections.enumerated().map { idx, sec in
                                SectionLevelInfo(id: sec.id, headerLevel: sec.headerLevel, index: idx)
                            },
                            sidebarWidth: sidebarWidth,  // Pass actual sidebar width for zone calculation
                            dropPosition: $dropPosition,
                            pendingDropId: $pendingDropId,
                            lastDropLocation: $lastDropLocation,
                            isDragging: $isDragging,
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

                        Divider()
                            .foregroundColor(themeManager.currentTheme.dividerColor)
                    }

                    // Drop zone after last card
                    Color.clear
                        .frame(height: 40)
                        .onDrop(of: [.sectionTransfer], delegate: EndDropDelegate(
                            sectionCount: filteredSections.count,
                            // Compute section levels inline - no state modification
                            sectionLevels: filteredSections.enumerated().map { idx, sec in
                                SectionLevelInfo(id: sec.id, headerLevel: sec.headerLevel, index: idx)
                            },
                            sidebarWidth: sidebarWidth,  // Pass actual sidebar width for zone calculation
                            dropPosition: $dropPosition,
                            pendingDropId: $pendingDropId,
                            lastDropLocation: $lastDropLocation,
                            isDragging: $isDragging,
                            onDrop: { transfer, position in
                                handleDropAtEnd(dropped: transfer, position: position)
                            },
                            onDragStarted: onDragStarted,
                            onDragEnded: onDragEnded
                        ))
                }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                sidebarWidth = newWidth
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
        }
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

    /// Calculate approximate card height for GeometryReader frame
    private func cardHeight(for section: SectionViewModel) -> CGFloat {
        // Base height + extra for longer titles
        let baseHeight: CGFloat = 70
        let titleLines = section.title.count > 30 ? 2 : 1
        return baseHeight + (titleLines > 1 ? 20 : 0)
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

            if statusFilter != nil {
                Text("No sections match the filter")
                    .font(.system(size: 13))
                    .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.6))

                Button("Clear Filter") {
                    statusFilter = nil
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

/// Floating badge showing the target header level during drag
/// Supports deep headers (H7+) with ######+N notation
struct DragLevelBadge: View {
    let level: Int
    @Environment(ThemeManager.self) private var themeManager

    /// Display text for the level badge
    private var levelText: String {
        if level <= 6 {
            return String(repeating: "#", count: level)
        } else {
            // Deep header: ######+N
            return String(repeating: "#", count: 6) + "+\(level - 6)"
        }
    }

    var body: some View {
        Text(levelText)
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(themeManager.currentTheme.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(radius: 4)
    }
}

/// Visual indicator for drop insertion point between cards
/// Shows a prominent badge on the left side so it's visible above dragged cards
/// Uses fixed height for predictable overlay positioning
struct DropIndicatorLine: View {
    let level: Int

    @Environment(ThemeManager.self) private var themeManager

    /// Fixed height for predictable offset calculation in overlay positioning
    static let height: CGFloat = 24

    var body: some View {
        HStack(spacing: 8) {
            // Prominent badge on LEFT side (visible above card overlay)
            DragLevelBadge(level: level)

            Rectangle()
                .fill(themeManager.currentTheme.accentColor)
                .frame(height: 3)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
    }
}

/// Drag preview for subtree drag operations
/// Shows parent card with stacked shadow effect and "+N" badge
struct SubtreeDragPreview: View {
    let section: SectionViewModel
    let childCount: Int

    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Stacked shadow effect - two layers behind
            if childCount > 1 {
                RoundedRectangle(cornerRadius: 8)
                    .fill(themeManager.currentTheme.sidebarBackground)
                    .frame(width: 280)
                    .offset(x: 6, y: 6)
                    .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
            }

            if childCount > 0 {
                RoundedRectangle(cornerRadius: 8)
                    .fill(themeManager.currentTheme.sidebarBackground)
                    .frame(width: 280)
                    .offset(x: 3, y: 3)
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
            }

            // Main card
            SectionCardView(
                section: section,
                onSingleClick: {},
                onDoubleClick: { _ in },
                onSectionUpdated: nil
            )
            .frame(width: 280)
            .background(themeManager.currentTheme.sidebarBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(themeManager.currentTheme.accentColor, lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)

            // Badge showing "+N" children count
            if childCount > 0 {
                Text("+\(childCount)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(themeManager.currentTheme.accentColor)
                    .clipShape(Capsule())
                    .padding(.top, 8)
                    .padding(.trailing, 8)
            }
        }
    }
}

/// Hint popup for first-time subtree drag discoverability
struct SubtreeDragHint: View {
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "option")
                .font(.system(size: 14, weight: .medium))
            Text("Hold ⌥ while dragging to include child sections")
                .font(.system(size: 12))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(themeManager.currentTheme.sidebarSelectedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
    }
}

// MARK: - Drop Delegates

/// Drop delegate for section cards with zone-based positioning
/// Vertical: Top 30% = insert before, Bottom 70% = insert after
/// Horizontal: X position determines target header level (zone-based, 2-3 options)
struct SectionDropDelegate: DropDelegate {
    let section: SectionViewModel
    let index: Int
    let cardHeight: CGFloat
    let sectionLevels: [SectionLevelInfo]  // Section levels for predecessor lookup
    let sidebarWidth: CGFloat  // Actual sidebar width for zone calculation
    @Binding var dropPosition: DropPosition?
    @Binding var pendingDropId: UUID?  // Guards against race conditions in async drop handling
    @Binding var lastDropLocation: CGPoint?  // Deduplicates simultaneous delegate fires
    @Binding var isDragging: Bool  // Track drag state for sync suppression
    let onDrop: (SectionTransfer, DropPosition) -> Void
    var onDragStarted: (() -> Void)?
    var onDragEnded: (() -> Void)?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Skip updates if a drop is pending (prevents race condition)
        guard pendingDropId == nil else {
            return DropProposal(operation: .move)
        }

        let relativeY = info.location.y / max(cardHeight, 1)
        let insertionIndex = relativeY < 0.30 ? index : index + 1

        // Find predecessor level for zone-based calculation
        let predecessorLevel = predecessorLevel(at: insertionIndex)

        // Calculate level from horizontal zone position (2-3 options relative to predecessor)
        let constrainedLevel = calculateZoneLevel(
            x: info.location.x,
            sidebarWidth: sidebarWidth,
            predecessorLevel: predecessorLevel
        )

        if relativeY < 0.30 {
            dropPosition = .insertBefore(index: index, level: constrainedLevel)
        } else {
            dropPosition = .insertAfter(index: index, level: constrainedLevel)
        }
        return DropProposal(operation: .move)
    }

    /// Get the header level of the predecessor at the given insertion index
    private func predecessorLevel(at insertionIndex: Int) -> Int {
        if insertionIndex == 0 { return 0 }  // No predecessor at top
        guard insertionIndex <= sectionLevels.count, insertionIndex > 0 else { return 1 }
        return sectionLevels[insertionIndex - 1].headerLevel
    }

    // swiftlint:disable:next cyclomatic_complexity
    func performDrop(info: DropInfo) -> Bool {
        // Dedupe by exact location (same drop event has same location)
        if lastDropLocation == info.location { return false }
        lastDropLocation = info.location

        // CRITICAL: Reject if a drop is already in progress
        guard pendingDropId == nil else { return false }
        guard let position = dropPosition else { return false }

        // Guard: Ensure this delegate's index matches the drop position
        switch position {
        case .insertBefore(let idx, _):
            guard idx == index else { return false }
        case .insertAfter(let idx, _):
            guard idx == index else { return false }
        }

        let providers = info.itemProviders(for: [.sectionTransfer])
        guard let provider = providers.first else { return false }

        // Generate unique ID for this drop to prevent race conditions
        let dropId = UUID()
        pendingDropId = dropId

        // Capture position and clear indicator immediately
        let capturedPosition = position
        dropPosition = nil

        // Timeout to prevent permanently stuck drops
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if self.pendingDropId == dropId {
                self.pendingDropId = nil
            }
        }

        // Use loadTransferable with completion handler (macOS 13+)
        _ = provider.loadTransferable(type: SectionTransfer.self) { result in
            Task { @MainActor in
                // Only execute if this is still the pending drop
                guard self.pendingDropId == dropId else { return }

                if case .success(let transfer) = result {
                    self.onDrop(transfer, capturedPosition)
                }
                self.pendingDropId = nil

                // Signal drag ended
                self.isDragging = false
                self.onDragEnded?()
            }
        }

        return true  // Accept immediately, process async
    }

    func dropExited(info: DropInfo) {
        // Only clear if no drop is pending
        if pendingDropId == nil {
            dropPosition = nil
        }
    }

    func dropEntered(info: DropInfo) {
        // Signal drag started (only once per drag session)
        if !isDragging {
            isDragging = true
            onDragStarted?()
        }
        _ = dropUpdated(info: info)
    }
}

/// Drop delegate for the zone after the last card
struct EndDropDelegate: DropDelegate {
    let sectionCount: Int
    let sectionLevels: [SectionLevelInfo]  // Section levels for predecessor lookup
    let sidebarWidth: CGFloat  // Actual sidebar width for zone calculation
    @Binding var dropPosition: DropPosition?
    @Binding var pendingDropId: UUID?  // Guards against race conditions in async drop handling
    @Binding var lastDropLocation: CGPoint?  // Deduplicates simultaneous delegate fires
    @Binding var isDragging: Bool  // Track drag state for sync suppression
    let onDrop: (SectionTransfer, DropPosition) -> Void
    var onDragStarted: (() -> Void)?
    var onDragEnded: (() -> Void)?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Skip updates if a drop is pending (prevents race condition)
        guard pendingDropId == nil else {
            return DropProposal(operation: .move)
        }

        // Find predecessor level (last section in list)
        let predecessorLevel = sectionLevels.isEmpty ? 0 : sectionLevels[sectionCount - 1].headerLevel

        // Calculate level from horizontal zone position (2-3 options relative to predecessor)
        let constrainedLevel = calculateZoneLevel(
            x: info.location.x,
            sidebarWidth: sidebarWidth,
            predecessorLevel: predecessorLevel
        )

        dropPosition = .insertAfter(index: sectionCount - 1, level: constrainedLevel)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        // Dedupe by exact location (same drop event has same location)
        if lastDropLocation == info.location { return false }
        lastDropLocation = info.location

        // CRITICAL: Reject if a drop is already in progress
        guard pendingDropId == nil else { return false }
        guard let position = dropPosition else { return false }

        // Guard: EndDropDelegate only handles insertAfter(sectionCount-1)
        switch position {
        case .insertBefore:
            return false
        case .insertAfter(let idx, _):
            guard idx == sectionCount - 1 else { return false }
        }

        let providers = info.itemProviders(for: [.sectionTransfer])
        guard let provider = providers.first else { return false }

        // Generate unique ID for this drop to prevent race conditions
        let dropId = UUID()
        pendingDropId = dropId

        let capturedPosition = position
        dropPosition = nil

        // Timeout to prevent permanently stuck drops
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if self.pendingDropId == dropId {
                self.pendingDropId = nil
            }
        }

        // Use loadTransferable with completion handler (macOS 13+)
        _ = provider.loadTransferable(type: SectionTransfer.self) { result in
            Task { @MainActor in
                // Only execute if this is still the pending drop
                guard self.pendingDropId == dropId else { return }

                if case .success(let transfer) = result {
                    self.onDrop(transfer, capturedPosition)
                }
                self.pendingDropId = nil

                // Signal drag ended
                self.isDragging = false
                self.onDragEnded?()
            }
        }

        return true
    }

    func dropExited(info: DropInfo) {
        // Only clear if no drop is pending
        if pendingDropId == nil {
            dropPosition = nil
        }
    }

    func dropEntered(info: DropInfo) {
        // Signal drag started (only once per drag session)
        if !isDragging {
            isDragging = true
            onDragStarted?()
        }
        _ = dropUpdated(info: info)
    }
}

/// Zoom navigation breadcrumb bar
struct ZoomBreadcrumb: View {
    let zoomedSection: SectionViewModel?
    let onZoomOut: () -> Void
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        if let section = zoomedSection {
            HStack {
                Button {
                    onZoomOut()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("All Sections")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.accentColor)
                }
                .buttonStyle(.plain)

                Text("›")
                    .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.4))

                Text(section.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.sidebarText)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(themeManager.currentTheme.sidebarBackground.opacity(0.95))
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
    @Previewable @State var zoom: String?
    @Previewable @State var docGoal: Int? = 1000
    @Previewable @State var docGoalType: GoalType = .approx
    @Previewable @State var excludeBib: Bool = false

    OutlineSidebar(
        sections: $sections,
        statusFilter: $filter,
        zoomedSectionId: $zoom,
        zoomedSectionIds: nil,
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
        onDragEnded: { print("Drag ended") }
    )
    .frame(width: 300, height: 500)
    .environment(ThemeManager.shared)
}
