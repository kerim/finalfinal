//
//  DraggableCardView.swift
//  final final
//
//  AppKit-based drag wrapper that provides cursor offset control for drag previews.
//  Positions the drag preview to the RIGHT of the cursor (cursor at left edge of card).
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - SwiftUI Wrapper with Coordinator Pattern

/// Wraps a SwiftUI view with AppKit drag handling for cursor offset control.
/// Handles both click (single/double) and drag gestures with threshold-based distinction.
struct DraggableCardView: NSViewRepresentable {
    let section: SectionViewModel
    let allSections: [SectionViewModel]
    let isGhost: Bool
    let onDragStarted: (Set<String>) -> Void
    let onDragEnded: () -> Void
    let onSingleClick: () -> Void
    let onDoubleClick: (ZoomMode) -> Void

    @Environment(ThemeManager.self) private var themeManager

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> DraggableNSView {
        let view = DraggableNSView()
        view.coordinator = context.coordinator
        view.section = section
        view.allSections = allSections
        view.themeManager = themeManager

        // Embed SwiftUI content via NSHostingView
        let cardView = SectionCardView(
            section: section,
            onSingleClick: {},  // Handled by DraggableNSView
            onDoubleClick: { _ in },  // Handled by DraggableNSView
            isGhost: isGhost
        )
        .environment(themeManager)

        let hostingView = PassthroughHostingView(rootView: AnyView(cardView))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingView)
        view.hostingView = hostingView

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        return view
    }

    func updateNSView(_ nsView: DraggableNSView, context: Context) {
        context.coordinator.parent = self
        nsView.section = section
        nsView.allSections = allSections
        nsView.themeManager = themeManager

        // Update hosted SwiftUI content
        let cardView = SectionCardView(
            section: section,
            onSingleClick: {},  // Handled by DraggableNSView
            onDoubleClick: { _ in },  // Handled by DraggableNSView
            isGhost: isGhost
        )
        .environment(themeManager)

        nsView.hostingView?.rootView = AnyView(cardView)
    }

    class Coordinator {
        var parent: DraggableCardView

        init(_ parent: DraggableCardView) {
            self.parent = parent
        }
    }
}

// MARK: - Passthrough Hosting View

/// NSHostingView subclass that passes all mouse events through to its superview.
/// Used to display SwiftUI content while letting the parent NSView handle mouse events.
class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Pass all events to superview (DraggableNSView handles mouse events)
        return nil
    }
}

// MARK: - AppKit NSView with Drag and Click Handling

/// NSView subclass that handles mouse events to distinguish click vs drag,
/// implements NSDraggingSource for cursor offset control.
class DraggableNSView: NSView, NSDraggingSource {
    weak var coordinator: DraggableCardView.Coordinator?
    var section: SectionViewModel?
    var allSections: [SectionViewModel] = []
    var themeManager: ThemeManager?
    var hostingView: PassthroughHostingView<AnyView>?

    // Click vs Drag threshold
    private let dragThreshold: CGFloat = 5.0
    private var mouseDownLocation: CGPoint?
    private var mouseDownTime: Date?
    private var didStartDrag = false
    private var isOptionDrag = false

    // Track if we're currently in a drag session
    private var isInDragSession = false

    override var isFlipped: Bool { true }  // Match SwiftUI coordinate system

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        mouseDownTime = Date()
        isOptionDrag = event.modifierFlags.contains(.option)
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag, let startLocation = mouseDownLocation else { return }

        let currentLocation = convert(event.locationInWindow, from: nil)
        let distance = hypot(currentLocation.x - startLocation.x,
                             currentLocation.y - startLocation.y)

        // Only start drag if moved beyond threshold
        guard distance > dragThreshold else { return }
        didStartDrag = true
        isInDragSession = true

        guard let section = section else { return }

        // Disable drag for bibliography sections
        if section.isBibliography {
            didStartDrag = false
            isInDragSession = false
            return
        }

        // 1. Compute subtree
        let childIds = isOptionDrag ? collectSubtreeIds(rootId: section.id) : []
        let isSubtreeDrag = isOptionDrag && !childIds.isEmpty
        let draggedIds = Set([section.id] + childIds)

        // 2. Notify ghost state
        DispatchQueue.main.async {
            self.coordinator?.parent.onDragStarted(draggedIds)
        }

        // 3. Create transfer data (NSPasteboardWriting wrapper)
        let transfer = SectionTransfer(
            id: section.id,
            sortOrder: section.sortOrder,
            headerLevel: section.headerLevel,
            isSubtreeDrag: isSubtreeDrag,
            childIds: childIds
        )
        let pasteboardItem = SectionTransferPasteboardItem(transfer)

        // 4. Render preview to NSImage
        let previewImage = renderPreview(isSubtreeDrag: isSubtreeDrag, childCount: childIds.count)

        // 5. Create drag item with cursor offset
        let dragItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        dragItem.setDraggingFrame(
            CGRect(x: 0, y: -previewImage.size.height / 2,
                   width: previewImage.size.width, height: previewImage.size.height),
            contents: previewImage
        )

        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownLocation = nil
            mouseDownTime = nil
            didStartDrag = false
        }

        // If drag didn't start, forward click to SwiftUI
        guard !didStartDrag else { return }

        let clickDuration = Date().timeIntervalSince(mouseDownTime ?? Date())
        if event.clickCount == 2 {
            // Option+double-click triggers shallow zoom
            let mode: ZoomMode = event.modifierFlags.contains(.option) ? .shallow : .full
            coordinator?.parent.onDoubleClick(mode)
        } else if clickDuration < 0.3 {
            coordinator?.parent.onSingleClick()
        }
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        isInDragSession = false
        DispatchQueue.main.async {
            self.coordinator?.parent.onDragEnded()
        }
    }

    // MARK: - Helpers

    /// Collect IDs of all descendants for subtree drag (level-based, not parent-based)
    /// Returns all sections after rootId until reaching one at same or shallower level
    private func collectSubtreeIds(rootId: String) -> [String] {
        guard let rootIndex = allSections.firstIndex(where: { $0.id == rootId }) else {
            return []
        }

        let rootLevel = allSections[rootIndex].headerLevel
        var childIds: [String] = []

        // Iterate forward, collecting all sections deeper than root
        for i in (rootIndex + 1)..<allSections.count {
            let section = allSections[i]
            if section.headerLevel <= rootLevel {
                break  // Hit a section at same or shallower level
            }
            childIds.append(section.id)
        }

        return childIds
    }

    /// Render the appropriate drag preview to NSImage
    private func renderPreview(isSubtreeDrag: Bool, childCount: Int) -> NSImage {
        guard let section = section, let themeManager = themeManager else {
            return NSImage(size: NSSize(width: 280, height: 80))
        }

        let previewView: AnyView
        if isSubtreeDrag {
            previewView = AnyView(
                SubtreeDragPreview(section: section, childCount: childCount)
                    .environment(themeManager)
            )
        } else {
            previewView = AnyView(
                SectionCardView(section: section, onSingleClick: {}, onDoubleClick: { _ in })
                    .frame(width: 280)
                    .background(themeManager.currentTheme.sidebarBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(themeManager.currentTheme.accentColor, lineWidth: 2)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                    .environment(themeManager)
            )
        }

        let hostingView = NSHostingView(rootView: previewView)
        let fittingSize = hostingView.fittingSize
        hostingView.frame = CGRect(origin: .zero, size: fittingSize)
        hostingView.layoutSubtreeIfNeeded()

        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return NSImage(size: NSSize(width: 280, height: 80))
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)

        let image = NSImage(size: fittingSize)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: - NSPasteboardWriting Bridge

/// Bridges SectionTransfer (Codable) to NSPasteboardWriting for AppKit drag sessions
class SectionTransferPasteboardItem: NSObject, NSPasteboardWriting {
    let transfer: SectionTransfer

    init(_ transfer: SectionTransfer) {
        self.transfer = transfer
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.init(UTType.sectionTransfer.identifier)]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        try? JSONEncoder().encode(transfer)
    }
}
