//
//  UnifiedUndoService.swift
//  final final
//
//  Phase 2 skeleton for the unified chronological undo system
//  (docs/plans/patient-rewinding-clockwork.md). Owns the native structural-operation
//  timeline; the web editors keep owning text undo (JS undo-coordinator module, mirrored in
//  web/milkdown/src/undo-coordinator.ts and web/codemirror/src/undo-coordinator.ts).
//
//  Phase 2 wires ZERO real structural operations. record()/performUndo()/performRedo()/
//  invalidateAll() are all correct and unit-tested, but nothing calls them yet -- Phase 3+
//  adds the version-restore/section-delete/section-duplicate call sites (plan §7).
//

import SwiftUI

/// One structural (non-text) operation on the unified undo timeline (plan §4.1). Defined
/// now even though nothing constructs one until Phase 3.
struct StructuralEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case restoreProject
        case restoreSectionReplace
        case restoreSectionDuplicate
        case sectionDelete
        case sectionDuplicate
    }

    let id: UUID
    let kind: Kind
    let title: String
    /// Snapshot to restore FROM when this entry is undone (the pre-op state).
    let undoSnapshotId: String
    /// Snapshot to restore FROM when this entry is redone (the post-op state), captured at
    /// undo time (plan §4.4 step 2) -- nil until this entry has actually been undone once.
    /// DEFERRED (Phase 3, do not fix now): `var` so it's technically settable, but nothing
    /// in `UnifiedUndoService` has a setter path for it yet -- `performUndo`/`performRedo`
    /// are pure bookkeeping today and never populate it. Phase 3's audited undo sequence
    /// (plan §4.4 step 2, "capture the redo checkpoint/snapshot") owns writing this.
    var redoSnapshotId: String?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        undoSnapshotId: String,
        redoSnapshotId: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.undoSnapshotId = undoSnapshotId
        self.redoSnapshotId = redoSnapshotId
        self.createdAt = createdAt
    }
}

/// Native timeline of structural operations (plan §4.1). Per-project lifetime, in-memory
/// only -- no persistence across relaunch, matching editor-history lifetime (plan §4.8).
///
/// Phase 2: fully built and unit-tested, but nothing calls `record()`, `performUndo()`,
/// `performRedo()`, or `invalidateAll()` yet.
@MainActor
@Observable
final class UnifiedUndoService {
    /// Cap per plan §4.1.
    static let capacity = 50

    private(set) var undoStack: [StructuralEntry] = []
    private(set) var redoStack: [StructuralEntry] = []

    /// Set by ContentView (Phase 3+) to actually clear both editors' JS undo/redo
    /// histories. A closure rather than a stored WKWebView reference -- this service has no
    /// business knowing about WebViews; ContentView owns those. nil in Phase 2: nothing
    /// ever exceeds `capacity`, so the eviction path that would invoke this never runs.
    /// DEFERRED (Phase 3, do not fix now): whoever wires this closure from ContentView must
    /// capture `self`/`findBarState`/webviews as `[weak ...]` -- `UnifiedUndoService` is a
    /// long-lived `@State` on ContentView, so a strong capture back into view-layer state
    /// here would be a retain cycle. Not a real leak yet since nothing sets this closure.
    var clearEditorHistories: (() -> Void)?

    /// Record a completed structural operation. Clears the redo stack (a fresh operation
    /// invalidates any previously-undone-then-abandoned redo path) and evicts the oldest
    /// undo entry once the cap is exceeded.
    ///
    /// Eviction is a MINI-BARRIER (plan §4.1/§4.5): it also clears both editors' JS
    /// histories via `clearEditorHistories`. Skipping that would leave pre-boundary text
    /// steps reachable past a boundary the timeline no longer guards against -- reopening
    /// the laundering (H1) and rebase-collapse (H2) hazards. Built correctly now even
    /// though nothing evicts in practice until Phase 3+ starts recording real entries.
    func record(_ entry: StructuralEntry) {
        undoStack.append(entry)
        redoStack.removeAll()
        if undoStack.count > Self.capacity {
            undoStack.removeFirst()
            DebugLog.log(.undo, "[UnifiedUndoService] evicted oldest entry at capacity \(Self.capacity) -- clearing editor histories")
            clearEditorHistories?()
        }
    }

    enum UndoOutcome: Equatable {
        /// `opId` matched the top of the stack; it has moved to the opposite stack.
        /// Bookkeeping only -- Phase 3+ wraps this with the actual snapshot restore /
        /// checkpoint swap (plan §4.4's audited undo/redo sequences).
        case performed(StructuralEntry)
        /// `opId` did not match the top of the stack (or the stack was empty) -- the JS
        /// side must reply "fall back" and perform the text undo/redo it suppressed
        /// (plan §4.2).
        case mismatch
    }

    /// Move the top undo entry to the redo stack, if `opId` matches it.
    func performUndo(opId: UUID) -> UndoOutcome {
        guard let top = undoStack.last, top.id == opId else { return .mismatch }
        undoStack.removeLast()
        redoStack.append(top)
        return .performed(top)
    }

    /// Mirror of `performUndo` for the redo stack.
    func performRedo(opId: UUID) -> UndoOutcome {
        guard let top = redoStack.last, top.id == opId else { return .mismatch }
        redoStack.removeLast()
        undoStack.append(top)
        return .performed(top)
    }

    /// Barrier: wipes the timeline (plan §4.5). Does NOT itself clear editor histories --
    /// every real barrier call site (project switch, mode switch, zoom, drag reorder, ...)
    /// already has its own existing mechanism for that; unlike eviction (above), a full
    /// barrier doesn't need a second one here. No call site exists yet -- Phase 3+ wires
    /// project switch, zoom, etc. -- this method is deliberately inert today.
    func invalidateAll(reason: String) {
        guard !undoStack.isEmpty || !redoStack.isEmpty else { return }
        DebugLog.log(.undo, "[UnifiedUndoService] invalidateAll: \(reason) (undo=\(undoStack.count) redo=\(redoStack.count))")
        undoStack.removeAll()
        redoStack.removeAll()
    }
}

// MARK: - FocusedValue (menu enablement, plan §4.7 -- ViewCommands.swift:9 convention)

private struct UnifiedUndoServiceFocusedKey: FocusedValueKey {
    typealias Value = UnifiedUndoService
}

extension FocusedValues {
    var unifiedUndoService: UnifiedUndoService? {
        get { self[UnifiedUndoServiceFocusedKey.self] }
        set { self[UnifiedUndoServiceFocusedKey.self] = newValue }
    }
}
