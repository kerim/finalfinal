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
struct DraggableCardView: NSViewRepresentable, Equatable {
    let section: SectionViewModel
    /// Computes the drag-payload subtree (descendant IDs) for a given root section id.
    /// Passed as a closure instead of the full section list -- the caller (`OutlineSidebar`)
    /// captures its per-body-pass `visible` snapshot directly, so this view doesn't need to
    /// hold (or re-derive) the whole array just to answer one query on option-drag start.
    /// Because it closes over a snapshot rather than reading through live state, this closure
    /// goes stale whenever `updateNSView` is skipped -- see `structuralSignature` below, which
    /// exists specifically to bound that staleness.
    let collectSubtreeIds: (String) -> [String]
    let isGhost: Bool
    var isActive: Bool = false
    /// `OutlineSidebar.structuralSignature(of:)` for the section order/levels this instance was
    /// built against. Not itself a render input -- folded into `==` purely to force
    /// `updateNSView` to re-run, for every card, whenever a reorder or promote/demote happens,
    /// even for a card whose own `section`/`isGhost`/`isActive` are unchanged. See `==`'s doc
    /// comment for why that matters.
    let structuralSignature: Int
    let onDragStarted: (Set<String>) -> Void
    let onDragEnded: () -> Void
    let onSingleClick: () -> Void
    let onDoubleClick: (ZoomMode) -> Void
    let onSectionUpdated: ((SectionViewModel) -> Void)?  // Called when word goal changes
    var onHoverChanged: ((Bool) -> Void)?  // Bubbles hover from SectionCardView to OutlineSidebar

    /// Manual `Equatable` conformance so SwiftUI can skip `updateNSView` when nothing that
    /// matters actually changed. The compiler can't synthesize this: closures aren't
    /// `Equatable`, and this struct carries several (`collectSubtreeIds`, `onDragStarted`,
    /// `onDragEnded`, `onSingleClick`, `onDoubleClick`, `onSectionUpdated`, `onHoverChanged`).
    ///
    /// What's compared:
    ///  - `section` by reference identity (`===`). `SectionViewModel` is an `@Observable`
    ///    class that callers update in place to preserve identity (see `apply(_:)`'s doc
    ///    comment in SectionCardView.swift) specifically so per-card Observable tracking
    ///    doesn't tear down and reinstall. As long as the reference is unchanged, content
    ///    edits (title, word count, status, etc.) still propagate to the already-hosted
    ///    `SectionCardView` via `@Observable`'s own tracking -- `updateNSView` doesn't need
    ///    to re-run for that. A different reference means a genuinely different section and
    ///    must re-wire the hosted view.
    ///  - `isGhost` / `isActive`: plain value flags that directly affect how
    ///    `SectionCardView` renders and aren't otherwise observable.
    ///  - `structuralSignature`: NOT a render input by itself. Closures are excluded from this
    ///    comparison because they can't be compared and none of them affects what THIS card
    ///    renders -- but excluding them only stays safe as long as a stale copy is never
    ///    actually invoked with a wrong answer. `updateNSView` is the only thing that copies a
    ///    fresh `self` (and its closures) into `context.coordinator.parent`; skip it and every
    ///    closure here keeps running against whatever it closed over last time it ran, forever
    ///    (in particular `collectSubtreeIds`, which closes over `OutlineSidebar`'s per-body-pass
    ///    `visible` snapshot). `structuralSignature` changes on any reorder or promote/demote,
    ///    which forces `updateNSView` -- and therefore a coordinator refresh -- on every card
    ///    exactly when that staleness would otherwise be observable, while leaving pure content
    ///    edits (which don't change any card's subtree computation) free to skip it. See
    ///    `OutlineSidebar.structuralSignature(of:)`.
    static func == (lhs: DraggableCardView, rhs: DraggableCardView) -> Bool {
        lhs.section === rhs.section && lhs.isGhost == rhs.isGhost && lhs.isActive == rhs.isActive
            && lhs.structuralSignature == rhs.structuralSignature
    }

    @Environment(ThemeManager.self) private var themeManager

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> DraggableNSView {
        let view = DraggableNSView()
        view.coordinator = context.coordinator
        view.section = section
        view.themeManager = themeManager

        // Embed SwiftUI content via NSHostingView
        let cardView = SectionCardView(
            section: section,
            onSingleClick: {},  // Handled by DraggableNSView
            onDoubleClick: { _ in },  // Handled by DraggableNSView
            onSectionUpdated: onSectionUpdated,
            isGhost: isGhost,
            isActive: isActive,
            onHoverChanged: onHoverChanged
        )
        .environment(themeManager)
        .environment(GoalColorSettingsManager.shared)

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
        nsView.themeManager = themeManager

        // Update hosted SwiftUI content
        let cardView = SectionCardView(
            section: section,
            onSingleClick: {},  // Handled by DraggableNSView
            onDoubleClick: { _ in },  // Handled by DraggableNSView
            onSectionUpdated: onSectionUpdated,
            isGhost: isGhost,
            isActive: isActive,
            onHoverChanged: onHoverChanged
        )
        .environment(themeManager)
        .environment(GoalColorSettingsManager.shared)

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

/// NSHostingView subclass that passes left-click events through to its superview for drag handling,
/// while allowing right-clicks to reach SwiftUI for context menus.
class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Allow right-clicks to reach SwiftUI for context menus
        if let event = NSApp.currentEvent {
            // Direct right-click
            if event.type == .rightMouseDown {
                return super.hitTest(point)
            }
            // Control+click (macOS alternative for right-click)
            if event.type == .leftMouseDown && event.modifierFlags.contains(.control) {
                return super.hitTest(point)
            }
        }
        // Pass regular left-clicks to superview (DraggableNSView handles drag events)
        return nil
    }
}

// MARK: - AppKit NSView with Drag and Click Handling

/// NSView subclass that handles mouse events to distinguish click vs drag,
/// implements NSDraggingSource for cursor offset control.
class DraggableNSView: NSView, NSDraggingSource {
    weak var coordinator: DraggableCardView.Coordinator?
    var section: SectionViewModel?
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
        let childIds = isOptionDrag ? (coordinator?.parent.collectSubtreeIds(section.id) ?? []) : []
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
                    .environment(GoalColorSettingsManager.shared)
            )
        } else {
            previewView = AnyView(
                SectionCardView(section: section, onSingleClick: {}, onDoubleClick: { _ in }, onSectionUpdated: nil)
                    .frame(width: 280)
                    .background(themeManager.currentTheme.sidebarBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(themeManager.currentTheme.accentColor, lineWidth: 2)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                    .environment(themeManager)
                    .environment(GoalColorSettingsManager.shared)
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
