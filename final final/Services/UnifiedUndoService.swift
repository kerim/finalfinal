//
//  UnifiedUndoService.swift
//  final final
//
//  The unified chronological undo system's native timeline
//  (docs/architecture/unified-undo.md). Owns the
//  native structural-operation timeline -- undo/redo stacks of `StructuralEntry`, barriers,
//  eviction; the web editors keep owning text undo (JS undo-coordinator module, mirrored in
//  web/milkdown/src/undo-coordinator.ts and web/codemirror/src/undo-coordinator.ts).
//
//  All six structural operations (version-history restore in its three forms, section
//  delete, section duplicate, and section reorder) are wired end to end through
//  `StructuralUndoController`, the only caller of `record()`, `performUndo()`, and
//  `performRedo()` below. `invalidateAll()` (the barrier mechanism) is called separately, by
//  the view layer -- ContentView and its extensions, ViewNotificationModifiers -- at each of
//  the barrier events themselves (project switch, mode switch, zoom, hierarchy enforcement,
//  section-metadata edits, inline annotation edits); see the Barriers section of
//  docs/architecture/unified-undo.md.
//

import SwiftUI

/// One structural (non-text) operation on the unified undo timeline (see
/// docs/architecture/unified-undo.md's unified-timeline-concept section).
struct StructuralEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case restoreProject
        case restoreSectionReplace
        case restoreSectionDuplicate
        case sectionDelete
        case sectionDuplicate
        /// Sidebar drag-reorder (single-section or subtree), added Phase 7 -- promoted
        /// from a timeline-wiping barrier to a sixth tracked structural op. Title "Reorder
        /// Sections" (unused in the actual menu; kept for parity/diagnostics
        /// with the other five, matching their plain-noun-phrase convention).
        case sectionReorder
    }

    let id: UUID
    let kind: Kind
    let title: String
    /// Snapshot to restore FROM when this entry is undone (the pre-op state).
    let undoSnapshotId: String
    /// Snapshot to restore FROM when this entry is redone (the post-op state), captured at
    /// undo time (see docs/architecture/unified-undo.md's audited-sequences section) -- nil
    /// until this entry has actually been undone once.
    /// `var` because `attachRedoSnapshot(opId:redoSnapshotId:)` below writes it in place once
    /// `StructuralUndoController`'s audited undo sequence captures the redo snapshot.
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

/// Native timeline of structural operations (see docs/architecture/unified-undo.md's
/// unified-timeline-concept section). Per-project lifetime, in-memory only -- no persistence
/// across relaunch, matching editor-history lifetime (see the doc's "what this system
/// deliberately does not do" section).
///
/// `StructuralUndoController` calls `record()`, `performUndo()`, and `performRedo()` for all
/// six structural operations; the view layer calls `invalidateAll()` at every barrier event.
@MainActor
@Observable
final class UnifiedUndoService {
    /// Cap of 50 entries (see docs/architecture/unified-undo.md's unified-timeline-concept
    /// section). UI-test-only override (Phase D):
    /// `TestMode.undoEvictionCapOverride` lets a permanent e2e test exercise real eviction in a
    /// handful of operations instead of 51 -- see
    /// `UnifiedUndoE2ETests.testEvictionCapEvictsOldestEntryAndStaysConsistent`. Computed (not a
    /// stored `let`) so it reads the environment at call time; every existing caller --
    /// including `UnifiedUndoServiceTests`, which asserts exact eviction boundaries at the real
    /// value -- is unaffected in the normal case, since the override is `nil` unless a UI test
    /// explicitly launches with `FF_UNDO_EVICTION_CAP` set.
    static var capacity: Int {
        TestMode.undoEvictionCapOverride ?? 50
    }

    private(set) var undoStack: [StructuralEntry] = []
    private(set) var redoStack: [StructuralEntry] = []

    /// Timeline invalidation counter (MF-2, Phase 5 review round). Bumped by every barrier
    /// that can invalidate the timeline WHILE a `StructuralUndoController` audited sequence
    /// (`performStructuralOp`/`performUndo`/`performRedo`) is mid-flight -- `invalidateAll`
    /// and `invalidateRedoBranch` below -- deliberately independent of `undoStack`/
    /// `redoStack`'s own contents, so a sequence that captured this value at the start of its
    /// run can tell "the timeline was invalidated out from under me" apart from "the stack is
    /// just legitimately empty/different" even in the edge case where a barrier fires and the
    /// stacks end up looking the same as before (e.g. both already empty). The two new Phase 5
    /// barriers (project switch, mode switch) are deliberately NOT gated on
    /// `StructuralUndoController.isPerforming` -- skipping a barrier while an op is in flight
    /// would leave the OLD context's entries live against a NEW context, which is worse -- so
    /// this counter is what lets the in-flight sequence itself notice and abort instead,
    /// rather than blindly recording its own entry into a timeline that's no longer "its"
    /// timeline (see `StructuralUndoController.performStructuralOp`'s epoch check).
    private(set) var generation: Int = 0

    /// Set by ContentView (Phase 5, `ContentView.swift`'s `.task` block right after
    /// `structuralUndoController.configure(...)`) to actually clear the active editor's JS
    /// history for ONE evicted entry AND remove that entry from the undo-coordinator's
    /// registry (`window.FinalFinal.clearStructuralUndoState(opId)`; see
    /// docs/architecture/unified-undo.md's Eviction section, "mini-barrier"). Takes the
    /// evicted entry's id (MF-1, Phase 5 review round): the JS-side
    /// target used to be a whole-registry clear (`clearStructuralUndoRegistry`/`clearRegistry`),
    /// but `record()` below runs as the LAST step of `performStructuralOp` -- AFTER that same
    /// op's own registry entry has already been created and finalized -- so a whole-registry
    /// clear on eviction was wiping the current op's own just-recorded entry too, breaking
    /// structural undo/redo the moment the stack crossed capacity (op #51+). Scoped to the one
    /// evicted opId instead. A closure rather than a stored WKWebView reference -- this service
    /// has no business knowing about WebViews; ContentView/StructuralUndoController own those.
    /// The capturing closure holds `[weak controller]` (`StructuralUndoController`, not
    /// `self`/ContentView) -- `UnifiedUndoService` is a long-lived `@State` on ContentView, so a
    /// strong capture back into view-layer state here would be a retain cycle.
    var clearEditorHistories: ((UUID) -> Void)?

    /// Set alongside `clearEditorHistories` -- the lighter barrier-only counterpart
    /// (`window.FinalFinal.clearStructuralUndoRegistry()`): clears the JS registry/descriptor
    /// WITHOUT touching the editor's own text-undo history. Used by `invalidateAll()` below --
    /// a barrier (zoom, project/mode switch, hierarchy enforcement, section-metadata edits,
    /// inline annotation edits, ...) must not wipe legitimate in-flight text-undo steps, only
    /// the now-invalid structural checkpoints. Correctness was already backstopped without
    /// this (a stale opId request gets `.fallback` -- see docs/architecture/unified-undo.md's
    /// routing section); this closes the per-session `EditorState` leak (every checkpoint
    /// retains a full ProseMirror/CM doc) and lets the JS-side fast path skip a doomed
    /// equality check once cleared.
    var clearStructuralRegistry: (() -> Void)?

    /// Record a completed structural operation. Clears the redo stack (a fresh operation
    /// invalidates any previously-undone-then-abandoned redo path) and evicts the oldest
    /// undo entry once the cap is exceeded.
    ///
    /// Eviction is a MINI-BARRIER (see docs/architecture/unified-undo.md's Eviction
    /// section): it also clears both editors' JS histories via `clearEditorHistories`.
    /// Skipping that would leave pre-boundary text steps reachable past a boundary the
    /// timeline no longer guards against -- reopening the laundering (H1) and rebase-collapse
    /// (H2) hazards. Wired for real in Phase 5: every discarded entry's undo/redo-point
    /// snapshot ids are also unpinned (`SnapshotService`'s in-memory pin set -- see the doc's
    /// Snapshot pin/prune interplay section), so they rejoin the normal auto-backup
    /// population and prune on the usual Time-Machine schedule.
    func record(_ entry: StructuralEntry) {
        // A fresh op abandons any previously-undone redo path -- unpin every discarded
        // entry's snapshots before the stack itself is cleared.
        for discarded in redoStack { unpinSnapshots(of: discarded) }
        undoStack.append(entry)
        redoStack.removeAll()
        if undoStack.count > Self.capacity {
            let evicted = undoStack.removeFirst()
            unpinSnapshots(of: evicted)
            DebugLog.log(.undo, "[UnifiedUndoService] evicted oldest entry at capacity \(Self.capacity) -- clearing editor history for \(evicted.id)")
            clearEditorHistories?(evicted.id)
        }
    }

    /// Unpins both of an entry's snapshot ids (see docs/architecture/unified-undo.md's
    /// Snapshot pin/prune interplay section) -- shared by
    /// every path that permanently discards a `StructuralEntry` (eviction, a fresh op
    /// abandoning the redo branch, `invalidateAll`, `replaceTopOfUndoStack`'s stale undo
    /// snapshot). See `SnapshotService.pinUndoPointSnapshot`'s doc comment for why this is an
    /// in-memory set rather than a DB column.
    private func unpinSnapshots(of entry: StructuralEntry) {
        SnapshotService.unpinUndoPointSnapshot(entry.undoSnapshotId)
        if let redoSnapshotId = entry.redoSnapshotId {
            SnapshotService.unpinUndoPointSnapshot(redoSnapshotId)
        }
    }

    enum UndoOutcome: Equatable {
        /// `opId` matched the top of the stack; it has moved to the opposite stack.
        /// Bookkeeping only -- Phase 3+ wraps this with the actual snapshot restore /
        /// checkpoint swap (see docs/architecture/unified-undo.md's audited-sequences
        /// section).
        case performed(StructuralEntry)
        /// `opId` did not match the top of the stack (or the stack was empty) -- the JS
        /// side must reply "fall back" and perform the text undo/redo it suppressed
        /// (see docs/architecture/unified-undo.md's routing section).
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

    /// Attaches a freshly-captured redo snapshot id to the entry now on top of the redo
    /// stack (Phase 3 -- see docs/architecture/unified-undo.md's audited-sequences section --
    /// called right after `performUndo` moves the entry there). No-op if the top entry's id
    /// doesn't match `opId` (defense in depth
    /// against a barrier racing the caller between `performUndo` and this call).
    func attachRedoSnapshot(opId: UUID, redoSnapshotId: String) {
        guard var top = redoStack.last, top.id == opId else { return }
        top.redoSnapshotId = redoSnapshotId
        redoStack[redoStack.count - 1] = top
    }

    /// Replaces the entry now on top of the undo stack with a version carrying a
    /// freshly-captured undo snapshot id and no redo snapshot (Phase 3 -- see
    /// docs/architecture/unified-undo.md's audited-sequences section -- called
    /// right after `performRedo` moves the entry there; that entry hasn't been undone again
    /// yet, so its previous `redoSnapshotId` no longer applies). No-op if the top entry's id
    /// doesn't match `opId`.
    func replaceTopOfUndoStack(opId: UUID, freshUndoSnapshotId: String) {
        guard let top = undoStack.last, top.id == opId else { return }
        // The old undoSnapshotId and redoSnapshotId are both being discarded here (the fresh
        // entry starts with `redoSnapshotId: nil`) -- unpin them so they rejoin the normal
        // auto-backup population instead of leaking a permanent pin.
        unpinSnapshots(of: top)
        undoStack[undoStack.count - 1] = StructuralEntry(
            id: top.id, kind: top.kind, title: top.title,
            undoSnapshotId: freshUndoSnapshotId, redoSnapshotId: nil, createdAt: top.createdAt
        )
    }

    /// Redo-branch barrier (see docs/architecture/unified-undo.md's registry/descriptor
    /// bridge protocol section, `historyEdited`): a genuine new text edit landed in the live
    /// editor while
    /// a structural redo entry still exists. Clears ONLY the redo stack -- the undo stack is
    /// left untouched -- exactly mirroring how `record()` (above) clears the redo stack, not
    /// the undo stack, when a fresh structural op is recorded. Without this, a structural undo
    /// followed by a genuine new text edit (then an undo of THAT edit) can land the live
    /// document back at byte-equality with a now-stale redo entry's `preOpDoc`, letting the
    /// abandoned structural redo fire again instead of correctly falling back to a plain text
    /// redo (confirmed live: a redo producing a word count matching an old, already-superseded
    /// entry's snapshot).
    func invalidateRedoBranch(reason: String) {
        guard !redoStack.isEmpty else { return }
        DebugLog.log(.undo, "[UnifiedUndoService] invalidateRedoBranch: \(reason) (redo=\(redoStack.count))")
        // MF-3 (Phase 5 review round): every other stack-discard path in this file unpins
        // before clearing -- this one didn't, leaking every abandoned redo entry's snapshot
        // ids as a permanent pin.
        for entry in redoStack { unpinSnapshots(of: entry) }
        redoStack.removeAll()
        generation += 1
    }

    /// Barrier: wipes the timeline (see docs/architecture/unified-undo.md's Barriers
    /// section). Does NOT clear the editor's own text-undo history -- every real barrier call
    /// site (project switch, mode switch, zoom, hierarchy enforcement, section metadata edit,
    /// inline annotation ops) already has its own existing mechanism for that where needed
    /// (e.g. `resetForProjectSwitch()`'s history clear), and a barrier must not wipe
    /// legitimate in-flight text-undo steps that have nothing to do with the invalidated
    /// structural timeline. It DOES (Phase 5) unpin every discarded entry's snapshot ids and
    /// clear the JS registry/descriptor via `clearStructuralRegistry` -- see that closure's
    /// doc comment.
    func invalidateAll(reason: String) {
        // MF-5 (Phase 5 review round): the generation bump and the JS registry clear both run
        // UNCONDITIONALLY, before the empty-stack early return below -- moved here from after
        // it. `StructuralUndoController`'s in-flight epoch check (MF-2) depends on every
        // `invalidateAll` call bumping `generation`, including one that lands while both
        // stacks happen to already be empty (e.g. a project-switch barrier firing against a
        // freshly-opened project with nothing recorded yet) -- an early return that skipped
        // the bump would let a stale in-flight sequence's epoch check pass by coincidence. The
        // registry clear has the same orphan-entry hazard on its own: `beginStructuralOp` can
        // insert a JS-side registry entry (and the descriptor can point at it) before this
        // barrier fires and the Swift-side stacks are still empty at that exact moment -- an
        // early return used to strand that JS-side entry forever, un-clearable by anything
        // else. The unpin loops and stack clears below are still skipped when both stacks are
        // genuinely empty -- nothing to unpin or clear there.
        generation += 1
        clearStructuralRegistry?()
        guard !undoStack.isEmpty || !redoStack.isEmpty else { return }
        DebugLog.log(.undo, "[UnifiedUndoService] invalidateAll: \(reason) (undo=\(undoStack.count) redo=\(redoStack.count))")
        for entry in undoStack { unpinSnapshots(of: entry) }
        for entry in redoStack { unpinSnapshots(of: entry) }
        undoStack.removeAll()
        redoStack.removeAll()
    }
}

// MARK: - FocusedValue (menu enablement -- ViewCommands.swift:9 convention)

private struct UnifiedUndoServiceFocusedKey: FocusedValueKey {
    typealias Value = UnifiedUndoService
}

extension FocusedValues {
    var unifiedUndoService: UnifiedUndoService? {
        get { self[UnifiedUndoServiceFocusedKey.self] }
        set { self[UnifiedUndoServiceFocusedKey.self] = newValue }
    }
}
