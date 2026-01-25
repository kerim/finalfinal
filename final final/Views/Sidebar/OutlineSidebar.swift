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
enum DropPosition: Equatable {
    case insertBefore(Int)   // Insert as sibling before card at index
    case insertAfter(Int)    // Insert as sibling after card at index
    case makeChild(String)   // Insert as child of section with given ID

    var targetIndex: Int? {
        switch self {
        case .insertBefore(let idx), .insertAfter(let idx):
            return idx
        case .makeChild:
            return nil
        }
    }

    var isChildDrop: Bool {
        if case .makeChild = self { return true }
        return false
    }
}

/// Structured request for section reordering with full context
struct SectionReorderRequest {
    let sectionId: String
    let insertionIndex: Int
    let newLevel: Int
    let newParentId: String?
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
    @State private var draggedSection: SectionViewModel?
    @State private var dropPosition: DropPosition?

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
                        // Show drop indicator BEFORE this card if insertBefore
                        if case .insertBefore(let idx) = dropPosition, idx == index {
                            DropIndicatorLine()
                        }

                        SectionCardView(
                            section: section,
                            isDropTarget: isChildDropTarget(for: section.id),
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
                        .onDrop(of: [.sectionTransfer], delegate: SectionDropDelegate(
                            section: section,
                            index: index,
                            cardHeight: cardHeight(for: section),
                            dropPosition: $dropPosition,
                            onDrop: { transfer, position in
                                handleDrop(dropped: transfer, position: position, targetSection: section)
                            }
                        ))
                        .draggable(SectionTransfer(
                            id: section.id,
                            sortOrder: section.sortOrder,
                            headerLevel: section.headerLevel
                        )) {
                            // Drag preview
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

                        // Show drop indicator AFTER this card if insertAfter
                        if case .insertAfter(let idx) = dropPosition, idx == index {
                            DropIndicatorLine()
                        }

                        Divider()
                            .foregroundColor(themeManager.currentTheme.dividerColor)
                    }

                    // Drop zone after last card
                    Color.clear
                        .frame(height: 40)
                        .onDrop(of: [.sectionTransfer], delegate: EndDropDelegate(
                            sectionCount: filteredSections.count,
                            dropPosition: $dropPosition,
                            onDrop: { transfer in
                                handleDropAtEnd(dropped: transfer)
                            }
                        ))

                    // Show indicator at very end if dropping there
                    if case .insertAfter(let idx) = dropPosition, idx == filteredSections.count - 1 {
                        // Already handled above
                    } else if dropPosition == .insertBefore(filteredSections.count) {
                        DropIndicatorLine()
                    }
                }
            }
        }
    }

    /// Calculate approximate card height for GeometryReader frame
    private func cardHeight(for section: SectionViewModel) -> CGFloat {
        // Base height + extra for longer titles
        let baseHeight: CGFloat = 70
        let titleLines = section.title.count > 30 ? 2 : 1
        return baseHeight + (titleLines > 1 ? 20 : 0)
    }

    /// Check if section is the target for a child drop
    private func isChildDropTarget(for sectionId: String) -> Bool {
        if case .makeChild(let id) = dropPosition {
            return id == sectionId
        }
        return false
    }

    /// Handle drop onto a section card with position awareness
    private func handleDrop(dropped: SectionTransfer, position: DropPosition, targetSection: SectionViewModel) {
        guard dropped.id != targetSection.id else { return }

        let insertionIndex: Int
        let newLevel: Int
        let newParentId: String?

        switch position {
        case .insertBefore(let idx):
            insertionIndex = idx
            newLevel = targetSection.headerLevel
            newParentId = targetSection.parentId
        case .insertAfter(let idx):
            insertionIndex = idx + 1
            newLevel = targetSection.headerLevel
            newParentId = targetSection.parentId
        case .makeChild(let parentId):
            // Insert after parent, as first child
            if let parentIdx = sections.firstIndex(where: { $0.id == parentId }) {
                insertionIndex = parentIdx + 1
            } else {
                insertionIndex = 0
            }
            newLevel = targetSection.headerLevel + 1
            newParentId = parentId
        }

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
    private func handleDropAtEnd(dropped: SectionTransfer) {
        let request = SectionReorderRequest(
            sectionId: dropped.id,
            insertionIndex: filteredSections.count,
            newLevel: 1,  // Top-level at end
            newParentId: nil
        )
        onSectionReorder?(request)
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

/// Visual indicator for drop insertion point between cards
struct DropIndicatorLine: View {
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        Rectangle()
            .fill(themeManager.currentTheme.accentColor)
            .frame(height: 3)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
    }
}

// MARK: - Drop Delegates

/// Drop delegate for section cards with zone-based positioning
/// Top 20% = insert before, Middle 60% = make child, Bottom 20% = insert after
struct SectionDropDelegate: DropDelegate {
    let section: SectionViewModel
    let index: Int
    let cardHeight: CGFloat
    @Binding var dropPosition: DropPosition?
    let onDrop: (SectionTransfer, DropPosition) -> Void  // Changed to Void - always succeeds

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let relativeY = info.location.y / max(cardHeight, 1)

        if relativeY < 0.20 {
            dropPosition = .insertBefore(index)
        } else if relativeY > 0.80 {
            dropPosition = .insertAfter(index)
        } else {
            dropPosition = .makeChild(section.id)
        }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let position = dropPosition else { return false }

        let providers = info.itemProviders(for: [.sectionTransfer])
        guard let provider = providers.first else { return false }

        // Clear indicator immediately for snappy feedback
        let capturedPosition = position
        dropPosition = nil

        // Load data async - UI updates immediately
        provider.loadDataRepresentation(forTypeIdentifier: UTType.sectionTransfer.identifier) { data, _ in
            guard let data = data,
                  let transfer = try? JSONDecoder().decode(SectionTransfer.self, from: data) else {
                return
            }
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    self.onDrop(transfer, capturedPosition)
                }
            }
        }

        return true  // Accept immediately, process async
    }

    func dropExited(info: DropInfo) {
        dropPosition = nil
    }

    func dropEntered(info: DropInfo) {
        _ = dropUpdated(info: info)
    }
}

/// Drop delegate for the zone after the last card
struct EndDropDelegate: DropDelegate {
    let sectionCount: Int
    @Binding var dropPosition: DropPosition?
    let onDrop: (SectionTransfer) -> Void  // Changed to Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropPosition = .insertAfter(sectionCount - 1)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.sectionTransfer])
        guard let provider = providers.first else { return false }

        dropPosition = nil

        provider.loadDataRepresentation(forTypeIdentifier: UTType.sectionTransfer.identifier) { data, _ in
            guard let data = data,
                  let transfer = try? JSONDecoder().decode(SectionTransfer.self, from: data) else {
                return
            }
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                    self.onDrop(transfer)
                }
            }
        }

        return true
    }

    func dropExited(info: DropInfo) {
        dropPosition = nil
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
