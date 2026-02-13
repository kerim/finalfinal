//
//  OutlineSidebar+DropDelegates.swift
//  final final
//
//  Drop delegates for section card drag-and-drop reordering.
//

import SwiftUI
import UniformTypeIdentifiers

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
