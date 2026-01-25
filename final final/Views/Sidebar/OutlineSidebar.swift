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
/// - Returns: Target header level (1-6)
func calculateZoneLevel(x: CGFloat, sidebarWidth: CGFloat, predecessorLevel: Int) -> Int {
    // Special case: first position (no predecessor) only allows level 1
    if predecessorLevel == 0 {
        return 1
    }

    let minLevel = max(1, predecessorLevel - 1)
    let maxLevel = min(6, predecessorLevel + 1)

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
    let insertionIndex: Int
    let newLevel: Int
    let newParentId: String?
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
    let onScrollToSection: (String) -> Void
    let onSectionUpdated: (SectionViewModel) -> Void
    let onSectionReorder: ((SectionReorderRequest) -> Void)?

    @Environment(ThemeManager.self) private var themeManager
    @State private var dropPosition: DropPosition?
    @State private var pendingDropId: UUID?  // Guards against race conditions in async drop handling
    @State private var lastDropLocation: CGPoint?  // Deduplicates simultaneous delegate fires
    @State private var sidebarWidth: CGFloat = 300  // Track actual width for zone calculations

    var body: some View {
        VStack(spacing: 0) {
            OutlineFilterBar(selectedFilter: $statusFilter)

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

        // Calculate aggregate word counts before filtering
        calculateAggregateWordCounts()

        // Apply status filter
        if let filter = statusFilter {
            result = result.filter { $0.status == filter }
        }

        // Apply zoom filter (show only subtree)
        if let zoomId = zoomedSectionId {
            result = filterToSubtree(sections: result, rootId: zoomId)
        }

        return result
    }

    /// Calculate aggregate word counts for all sections (section + descendants)
    private func calculateAggregateWordCounts() {
        // Recursive function to get aggregate for a section
        func aggregate(for sectionId: String, memo: inout [String: Int]) -> Int {
            if let cached = memo[sectionId] {
                return cached
            }

            guard let section = sections.first(where: { $0.id == sectionId }) else {
                return 0
            }

            // Get children of this section
            let children = sections.filter { $0.parentId == sectionId }

            // Sum: own word count + all children's aggregates
            let total = section.wordCount + children.reduce(0) { sum, child in
                sum + aggregate(for: child.id, memo: &memo)
            }

            memo[sectionId] = total
            return total
        }

        // Calculate for all sections
        var memo: [String: Int] = [:]
        for section in sections {
            section.aggregateWordCount = aggregate(for: section.id, memo: &memo)
        }
    }

    private func filterToSubtree(sections: [SectionViewModel], rootId: String) -> [SectionViewModel] {
        var result: [SectionViewModel] = []
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

        // Filter to only include matching sections
        for section in sections where idsToInclude.contains(section.id) {
            result.append(section)
        }

        return result
    }

    private var sectionsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredSections.enumerated()), id: \.element.id) { index, section in
                        SectionCardView(
                            section: section,
                            onSingleClick: {
                                onScrollToSection(section.id)
                            },
                            onDoubleClick: {
                                if zoomedSectionId == section.id {
                                    zoomedSectionId = nil
                                } else {
                                    zoomedSectionId = section.id
                                }
                            }
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
                            onDrop: { transfer, position in
                                handleDrop(dropped: transfer, position: position, targetSection: section)
                            }
                        ))
                        .draggable(SectionTransfer(
                            id: section.id,
                            sortOrder: section.sortOrder,
                            headerLevel: section.headerLevel
                        )) {
                            // NO STATE MODIFICATION - just return the drag preview
                            SectionCardView(
                                section: section,
                                onSingleClick: {},
                                onDoubleClick: {}
                            )
                            .frame(width: 280)
                            .background(themeManager.currentTheme.sidebarBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(themeManager.currentTheme.accentColor, lineWidth: 2)
                            )
                            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                        }

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
                            onDrop: { transfer, position in
                                handleDropAtEnd(dropped: transfer, position: position)
                            }
                        ))
                }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                sidebarWidth = newWidth
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
        let insertionIndex: Int
        let newLevel = position.level

        if dropped.id == targetSection.id {
            // Self-drop: only proceed if level is changing
            guard dropped.headerLevel != newLevel else { return }
            // Use guard let to safely unwrap (not ?? 0 which could corrupt data)
            guard let currentIndex = filteredSections.firstIndex(where: { $0.id == dropped.id }) else { return }
            insertionIndex = currentIndex
        } else {
            // Cross-section drop
            switch position {
            case .insertBefore(let idx, _):
                insertionIndex = idx
            case .insertAfter(let idx, _):
                insertionIndex = idx + 1
            }
        }

        // Common path for both self-drop and cross-section drop
        // Find parent based on level - look backwards for a section with level < newLevel
        // Exclude the dragged section to prevent circular parent references
        let newParentId = findParentId(forLevel: newLevel, insertionIndex: insertionIndex, excludingId: dropped.id)

        // Notify parent with structured request
        let request = SectionReorderRequest(
            sectionId: dropped.id,
            insertionIndex: insertionIndex,
            newLevel: newLevel,
            newParentId: newParentId
        )
        onSectionReorder?(request)
    }

    /// Handle drop at end of list
    private func handleDropAtEnd(dropped: SectionTransfer, position: DropPosition) {
        // Use level from drop position (constrained by predecessor)
        let newLevel = position.level
        let newParentId = findParentId(forLevel: newLevel, insertionIndex: filteredSections.count, excludingId: dropped.id)

        let request = SectionReorderRequest(
            sectionId: dropped.id,
            insertionIndex: filteredSections.count,
            newLevel: newLevel,
            newParentId: newParentId
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

/// Floating badge showing the target header level during drag
struct DragLevelBadge: View {
    let level: Int
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        Text(String(repeating: "#", count: level))
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
    let onDrop: (SectionTransfer, DropPosition) -> Void

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
    let onDrop: (SectionTransfer, DropPosition) -> Void

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
    @Previewable @State var filter: SectionStatus? = nil
    @Previewable @State var zoom: String? = nil

    OutlineSidebar(
        sections: $sections,
        statusFilter: $filter,
        zoomedSectionId: $zoom,
        onScrollToSection: { id in print("Scroll to: \(id)") },
        onSectionUpdated: { section in print("Updated: \(section.title)") },
        onSectionReorder: { request in
            print("Reorder: \(request.sectionId) to index \(request.insertionIndex), level \(request.newLevel), parent: \(request.newParentId ?? "nil")")
        }
    )
    .frame(width: 300, height: 500)
    .environment(ThemeManager.shared)
}
