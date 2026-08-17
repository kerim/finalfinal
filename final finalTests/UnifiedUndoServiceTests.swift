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
        service.clearEditorHistories = { clearCount += 1 }

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
        service.clearEditorHistories = { clearCount += 1 }

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
        service.clearEditorHistories = { clearCount += 1 }
        service.record(makeEntry())

        service.invalidateAll(reason: "test barrier")

        #expect(clearCount == 0)
    }
}
