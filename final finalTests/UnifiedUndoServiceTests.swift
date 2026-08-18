//
//  UnifiedUndoServiceTests.swift
//  final finalTests
//
//  Phase 2 skeleton tests (docs/plans/patient-rewinding-clockwork.md): the stack/eviction/
//  barrier bookkeeping in UnifiedUndoService, exercised in isolation -- no editor, no
//  database, no real structural operation. Nothing in this suite depends on JS or a
//  WKWebView; the JS-side routing truth table lives in
//  web/{milkdown,codemirror}/src/__tests__/undo-coordinator.test.ts.
//

import Testing
import Foundation
@testable import final_final

@Suite("UnifiedUndoService — Phase 2 skeleton")
@MainActor
struct UnifiedUndoServiceTests {

    private func makeEntry(title: String = "Test entry", undoSnapshotId: String = "snap-1") -> StructuralEntry {
        StructuralEntry(kind: .restoreSectionReplace, title: title, undoSnapshotId: undoSnapshotId)
    }

    // MARK: - record()

    @Test("record appends to the undo stack and clears the redo stack")
    func recordAppendsAndClearsRedo() {
        let service = UnifiedUndoService()
        let first = makeEntry(title: "First")
        service.record(first)
        #expect(service.undoStack.map(\.id) == [first.id])

        // Simulate an undo having populated the redo stack, then a fresh op recorded --
        // the fresh op must invalidate the abandoned redo path.
        _ = service.performUndo(opId: first.id)
        #expect(!service.redoStack.isEmpty)

        let second = makeEntry(title: "Second")
        service.record(second)

        #expect(service.redoStack.isEmpty)
        #expect(service.undoStack.map(\.id) == [second.id])
    }

    @Test("record evicts the oldest entry once capacity is exceeded")
    func recordEvictsOldestAtCapacity() {
        let service = UnifiedUndoService()
        var recordedIds: [UUID] = []
        for i in 0..<(UnifiedUndoService.capacity + 1) {
            let entry = makeEntry(title: "Entry \(i)")
            recordedIds.append(entry.id)
            service.record(entry)
        }

        #expect(service.undoStack.count == UnifiedUndoService.capacity)
        // The very first entry recorded must be the one evicted.
        #expect(!service.undoStack.contains { $0.id == recordedIds[0] })
        // The most recently recorded entry must still be present, at the top.
        #expect(service.undoStack.last?.id == recordedIds.last)
    }

    @Test("record's eviction mini-barrier fires clearEditorHistories exactly once")
    func recordEvictionFiresClearEditorHistories() {
        let service = UnifiedUndoService()
        var clearCount = 0
        service.clearEditorHistories = { _ in clearCount += 1 }

        for i in 0..<UnifiedUndoService.capacity {
            service.record(makeEntry(title: "Entry \(i)"))
        }
        #expect(clearCount == 0) // not yet over capacity

        service.record(makeEntry(title: "Over capacity"))
        #expect(clearCount == 1)

        service.record(makeEntry(title: "Over capacity again"))
        #expect(clearCount == 2)
    }

    @Test("record does not fire clearEditorHistories while under capacity")
    func recordUnderCapacityDoesNotEvict() {
        let service = UnifiedUndoService()
        var clearCount = 0
        service.clearEditorHistories = { _ in clearCount += 1 }

        service.record(makeEntry())
        service.record(makeEntry())

        #expect(clearCount == 0)
        #expect(service.undoStack.count == 2)
    }

    // MARK: - performUndo() / performRedo()

    @Test("performUndo moves the matching top entry to the redo stack")
    func performUndoMovesTopEntry() {
        let service = UnifiedUndoService()
        let entry = makeEntry()
        service.record(entry)

        let outcome = service.performUndo(opId: entry.id)

        #expect(outcome == .performed(entry))
        #expect(service.undoStack.isEmpty)
        #expect(service.redoStack.map(\.id) == [entry.id])
    }

    @Test("performUndo reports mismatch when opId does not match the top entry")
    func performUndoMismatchWrongOpId() {
        let service = UnifiedUndoService()
        service.record(makeEntry())

        let outcome = service.performUndo(opId: UUID())

        #expect(outcome == .mismatch)
        #expect(service.undoStack.count == 1) // untouched
    }

    @Test("performUndo reports mismatch on an empty stack")
    func performUndoMismatchEmptyStack() {
        let service = UnifiedUndoService()
        #expect(service.performUndo(opId: UUID()) == .mismatch)
    }

    @Test("performRedo mirrors performUndo for the redo stack")
    func performRedoMovesTopEntry() {
        let service = UnifiedUndoService()
        let entry = makeEntry()
        service.record(entry)
        _ = service.performUndo(opId: entry.id)

        let outcome = service.performRedo(opId: entry.id)

        #expect(outcome == .performed(entry))
        #expect(service.redoStack.isEmpty)
        #expect(service.undoStack.map(\.id) == [entry.id])
    }

    @Test("performRedo reports mismatch when opId does not match the top entry")
    func performRedoMismatchWrongOpId() {
        let service = UnifiedUndoService()
        let entry = makeEntry()
        service.record(entry)
        _ = service.performUndo(opId: entry.id)

        let outcome = service.performRedo(opId: UUID())

        #expect(outcome == .mismatch)
        #expect(service.redoStack.count == 1) // untouched
    }

    // MARK: - invalidateAll()

    @Test("invalidateAll clears both stacks")
    func invalidateAllClearsBothStacks() {
        let service = UnifiedUndoService()
        let entry = makeEntry()
        service.record(entry)
        _ = service.performUndo(opId: entry.id)
        #expect(!service.redoStack.isEmpty)

        service.invalidateAll(reason: "test barrier")

        #expect(service.undoStack.isEmpty)
        #expect(service.redoStack.isEmpty)
    }

    @Test("invalidateAll on an already-empty timeline is a harmless no-op")
    func invalidateAllOnEmptyTimelineIsNoOp() {
        let service = UnifiedUndoService()
        service.invalidateAll(reason: "no-op barrier")
        #expect(service.undoStack.isEmpty)
        #expect(service.redoStack.isEmpty)
    }

    @Test("invalidateAll does not itself call clearEditorHistories -- barriers own that separately")
    func invalidateAllDoesNotCallClearEditorHistories() {
        let service = UnifiedUndoService()
        var clearCount = 0
        service.clearEditorHistories = { _ in clearCount += 1 }
        service.record(makeEntry())

        service.invalidateAll(reason: "test barrier")

        #expect(clearCount == 0)
    }

    // MARK: - clearEditorHistories eviction scoping (MF-1, Phase 5 review round)

    @Test("record's eviction mini-barrier fires clearEditorHistories with exactly the evicted entry's id, not the current entry's")
    func recordEvictionFiresClearEditorHistoriesWithEvictedId() {
        let service = UnifiedUndoService()
        var receivedIds: [UUID] = []
        service.clearEditorHistories = { receivedIds.append($0) }

        var recordedIds: [UUID] = []
        for i in 0..<(UnifiedUndoService.capacity + 1) {
            let entry = makeEntry(title: "Entry \(i)")
            recordedIds.append(entry.id)
            service.record(entry)
        }

        // 51 entries recorded (capacity 50 + 1): exactly one eviction, and it must carry the
        // FIRST entry's id (the oldest, evicted one) -- never the just-recorded 51st entry's own
        // id, which is what a whole-registry clear used to wipe by mistake (MF-1).
        #expect(receivedIds == [recordedIds[0]])
        #expect(!receivedIds.contains(recordedIds.last!))
        #expect(service.undoStack.contains { $0.id == recordedIds.last })
    }

    @Test("invalidateAll DOES call clearStructuralRegistry -- the lighter barrier-only JS clear (Phase 5)")
    func invalidateAllCallsClearStructuralRegistry() {
        let service = UnifiedUndoService()
        var clearCount = 0
        service.clearStructuralRegistry = { clearCount += 1 }
        service.record(makeEntry())

        service.invalidateAll(reason: "test barrier")

        #expect(clearCount == 1)
    }

    @Test("invalidateAll on an already-empty timeline STILL calls clearStructuralRegistry (MF-5, Phase 5 review round)")
    func invalidateAllOnEmptyTimelineStillCallsClearStructuralRegistry() {
        // MF-5: the registry-clear used to run AFTER the empty-stack early return, so it never
        // fired when both stacks were already empty -- stranding any JS-side registry entry
        // that got inserted (beginStructuralOp) before the Swift-side stacks caught up, with no
        // other path able to clear it. Moved to run unconditionally, before that guard.
        let service = UnifiedUndoService()
        var clearCount = 0
        service.clearStructuralRegistry = { clearCount += 1 }

        service.invalidateAll(reason: "no-op barrier")

        #expect(clearCount == 1)
    }

    // MARK: - generation (MF-2, Phase 5 review round)

    @Test("invalidateAll bumps generation even on an already-empty timeline (MF-5)")
    func invalidateAllBumpsGenerationEvenWhenEmpty() {
        let service = UnifiedUndoService()
        let before = service.generation

        service.invalidateAll(reason: "no-op barrier")

        #expect(service.generation == before + 1)
    }

    @Test("invalidateAll bumps generation once per call when the timeline is non-empty")
    func invalidateAllBumpsGenerationWhenNonEmpty() {
        let service = UnifiedUndoService()
        service.record(makeEntry())
        let before = service.generation

        service.invalidateAll(reason: "test barrier")

        #expect(service.generation == before + 1)
    }

    @Test("invalidateRedoBranch bumps generation when it actually clears the redo stack")
    func invalidateRedoBranchBumpsGeneration() {
        let service = UnifiedUndoService()
        let entry = makeEntry()
        service.record(entry)
        _ = service.performUndo(opId: entry.id)
        #expect(!service.redoStack.isEmpty)
        let before = service.generation

        service.invalidateRedoBranch(reason: "text edit after structural undo")

        #expect(service.generation == before + 1)
    }

    @Test("invalidateRedoBranch on an already-empty redo stack is a no-op and does not bump generation")
    func invalidateRedoBranchOnEmptyStackDoesNotBumpGeneration() {
        let service = UnifiedUndoService()
        let before = service.generation

        service.invalidateRedoBranch(reason: "no-op")

        #expect(service.generation == before)
    }

    @Test("invalidateRedoBranch unpins the discarded redo entries' snapshot ids (MF-3, Phase 5 review round)")
    func invalidateRedoBranchUnpinsSnapshots() {
        // MF-3: every other stack-discard path in this file unpins before clearing --
        // invalidateRedoBranch's redoStack.removeAll() didn't, leaking a permanent pin.
        let service = UnifiedUndoService()
        let undoSnapshotId = UUID().uuidString
        let redoSnapshotId = UUID().uuidString
        SnapshotService.pinUndoPointSnapshot(undoSnapshotId)
        SnapshotService.pinUndoPointSnapshot(redoSnapshotId)
        let entry = makeEntry(undoSnapshotId: undoSnapshotId)
        service.record(entry)
        _ = service.performUndo(opId: entry.id) // moves to redoStack
        service.attachRedoSnapshot(opId: entry.id, redoSnapshotId: redoSnapshotId)
        #expect(SnapshotService.pinnedUndoPointSnapshotIdsForTesting.contains(undoSnapshotId))
        #expect(SnapshotService.pinnedUndoPointSnapshotIdsForTesting.contains(redoSnapshotId))

        service.invalidateRedoBranch(reason: "text edit after structural undo")

        #expect(service.redoStack.isEmpty)
        #expect(!SnapshotService.pinnedUndoPointSnapshotIdsForTesting.contains(undoSnapshotId))
        #expect(!SnapshotService.pinnedUndoPointSnapshotIdsForTesting.contains(redoSnapshotId))
    }

    // MARK: - Snapshot pin/prune interplay (Phase 5, plan §4.4/§9)

    @Test("record pins a new entry's undo snapshot and eviction unpins the evicted entry's snapshot")
    func evictionUnpinsSnapshot() {
        let service = UnifiedUndoService()
        let firstUndoSnapshotId = UUID().uuidString
        SnapshotService.pinUndoPointSnapshot(firstUndoSnapshotId) // mirrors createUndoPointSnapshot's own pin
        let first = makeEntry(title: "First", undoSnapshotId: firstUndoSnapshotId)
        service.record(first)
        #expect(SnapshotService.pinnedUndoPointSnapshotIdsForTesting.contains(firstUndoSnapshotId))

        for i in 0..<UnifiedUndoService.capacity {
            let snapshotId = UUID().uuidString
            SnapshotService.pinUndoPointSnapshot(snapshotId)
            service.record(makeEntry(title: "Entry \(i)", undoSnapshotId: snapshotId))
        }

        // `first` was evicted (capacity + 1 entries recorded total) -- its snapshot must be
        // unpinned so it rejoins the normal auto-backup population instead of leaking a
        // permanent pin.
        #expect(!service.undoStack.contains { $0.id == first.id })
        #expect(!SnapshotService.pinnedUndoPointSnapshotIdsForTesting.contains(firstUndoSnapshotId))
    }

    @Test("invalidateAll unpins every discarded entry's snapshot ids, on both stacks")
    func invalidateAllUnpinsSnapshots() {
        let service = UnifiedUndoService()
        let undoSnapshotId = UUID().uuidString
        let redoSnapshotId = UUID().uuidString
        SnapshotService.pinUndoPointSnapshot(undoSnapshotId)
        SnapshotService.pinUndoPointSnapshot(redoSnapshotId)
        let entry = StructuralEntry(
            kind: .restoreSectionReplace, title: "Test", undoSnapshotId: undoSnapshotId, redoSnapshotId: redoSnapshotId
        )
        service.record(entry)

        service.invalidateAll(reason: "test barrier")

        #expect(!SnapshotService.pinnedUndoPointSnapshotIdsForTesting.contains(undoSnapshotId))
        #expect(!SnapshotService.pinnedUndoPointSnapshotIdsForTesting.contains(redoSnapshotId))
    }

    @Test("record's redo-branch clear (a fresh op abandoning an undone entry) unpins the abandoned entry's snapshots")
    func freshRecordUnpinsAbandonedRedoBranch() {
        let service = UnifiedUndoService()
        let undoSnapshotId = UUID().uuidString
        SnapshotService.pinUndoPointSnapshot(undoSnapshotId)
        let entry = makeEntry(title: "First", undoSnapshotId: undoSnapshotId)
        service.record(entry)
        _ = service.performUndo(opId: entry.id) // moves to redoStack, still pinned
        #expect(SnapshotService.pinnedUndoPointSnapshotIdsForTesting.contains(undoSnapshotId))

        let freshSnapshotId = UUID().uuidString
        SnapshotService.pinUndoPointSnapshot(freshSnapshotId)
        service.record(makeEntry(title: "Second", undoSnapshotId: freshSnapshotId))

        #expect(service.redoStack.isEmpty)
        #expect(!SnapshotService.pinnedUndoPointSnapshotIdsForTesting.contains(undoSnapshotId))
    }

    @Test("replaceTopOfUndoStack unpins the discarded old undo/redo snapshot ids")
    func replaceTopOfUndoStackUnpinsDiscardedSnapshots() {
        let service = UnifiedUndoService()
        let originalUndoSnapshotId = UUID().uuidString
        let redoSnapshotId = UUID().uuidString
        SnapshotService.pinUndoPointSnapshot(originalUndoSnapshotId)
        SnapshotService.pinUndoPointSnapshot(redoSnapshotId)
        let entry = makeEntry(title: "Test", undoSnapshotId: originalUndoSnapshotId)
        service.record(entry)
        _ = service.performUndo(opId: entry.id)
        service.attachRedoSnapshot(opId: entry.id, redoSnapshotId: redoSnapshotId)
        _ = service.performRedo(opId: entry.id)

        let freshUndoSnapshotId = UUID().uuidString
        SnapshotService.pinUndoPointSnapshot(freshUndoSnapshotId)
        service.replaceTopOfUndoStack(opId: entry.id, freshUndoSnapshotId: freshUndoSnapshotId)

        #expect(!SnapshotService.pinnedUndoPointSnapshotIdsForTesting.contains(originalUndoSnapshotId))
        #expect(!SnapshotService.pinnedUndoPointSnapshotIdsForTesting.contains(redoSnapshotId))
        #expect(SnapshotService.pinnedUndoPointSnapshotIdsForTesting.contains(freshUndoSnapshotId))
    }
}
