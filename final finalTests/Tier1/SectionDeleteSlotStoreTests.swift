//
//  SectionDeleteSlotStoreTests.swift
//  final finalTests
//
//  Tier 1: `SectionDeleteSlotStore`, the in-memory slot a section delete's job leaves for undo, and the pin set it keeps right
//  (t-94369a83 Phase 4b, slice 2a; addenda A17 and A18, the slot-write and unpin part). Snapshot ids here are made up (a pin is just
//  a string in a set), and each test uses ids of its own, so the shared static pin set cannot make two tests collide.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Testing
import Foundation
@testable import final_final

@Suite("SectionDeleteSlotStore — Tier 1: slots and pins (A17, A18)")
struct SectionDeleteSlotStoreTests {

    private func pinned(_ id: String) -> Bool {
        SnapshotService.pinnedUndoPointSnapshotIdsForTesting.contains(id)
    }

    private func leader(_ title: String) -> Block {
        Block(projectId: "p", sortOrder: 1, blockType: .heading, textContent: title, markdownFragment: "# \(title)", headingLevel: 1)
    }

    @Test("recordApplied stores the snapshot id and the leaders, marks the slot applied and pins the snapshot")
    func recordAppliedStoresAndPins() {
        let store = SectionDeleteSlotStore()
        let opId = UUID()
        let snapshotId = "snap-\(UUID().uuidString)"
        defer { store.removeAll() }
        store.open(opId)
        #expect(store.slot(opId)?.state == .reserved)

        #expect(store.recordApplied(opId, snapshotId: snapshotId, removedSections: [leader("Chapter")]))

        let slot = store.slot(opId)
        #expect(slot?.state == .applied)
        #expect(slot?.snapshotId == snapshotId)
        #expect(slot?.removedSections.map(\.textContent) == ["Chapter"])
        #expect(pinned(snapshotId))
    }

    @Test("recordApplied on a slot that is gone stores nothing, pins nothing and says so")
    func recordAppliedWithSlotGone() {
        let store = SectionDeleteSlotStore()
        let opId = UUID()
        let snapshotId = "snap-\(UUID().uuidString)"
        store.open(opId)
        store.remove(opId)

        #expect(store.recordApplied(opId, snapshotId: snapshotId, removedSections: []) == false)

        #expect(store.count == 0 && store.slot(opId) == nil)
        #expect(!pinned(snapshotId))
    }

    @Test("remove unpins the snapshot the slot held; removeAll unpins every slot's snapshot")
    func removeUnpins() {
        let store = SectionDeleteSlotStore()
        let first = UUID(), second = UUID(), third = UUID()
        let snapshotIds = (0..<3).map { _ in "snap-\(UUID().uuidString)" }
        for (opId, snapshotId) in zip([first, second, third], snapshotIds) {
            store.open(opId)
            store.recordApplied(opId, snapshotId: snapshotId, removedSections: [])
        }
        #expect(snapshotIds.allSatisfy(pinned))

        let removed = store.remove(first)
        #expect(removed?.snapshotId == snapshotIds[0])
        #expect(!pinned(snapshotIds[0]) && pinned(snapshotIds[1]) && pinned(snapshotIds[2]))

        store.removeAll()
        #expect(snapshotIds.allSatisfy { !pinned($0) })
        #expect(store.count == 0)
    }

    @Test("snapshotIdWrite writes the new id on the slot and unpins the id it replaces, leaving the new id's pin alone")
    func snapshotIdWriteUnpinsReplacedId() {
        let store = SectionDeleteSlotStore()
        let opId = UUID()
        let original = "snap-\(UUID().uuidString)"
        let replacement = "snap-\(UUID().uuidString)"
        defer { store.removeAll(); SnapshotService.unpinUndoPointSnapshot(replacement) }
        store.open(opId)
        store.recordApplied(opId, snapshotId: original, removedSections: [])
        SnapshotService.pinUndoPointSnapshot(replacement)   // what createUndoPointSnapshot() does at creation

        let replaced = store.snapshotIdWrite(opId, replacement)

        #expect(replaced == original)
        #expect(store.slot(opId)?.snapshotId == replacement)
        #expect(!pinned(original), "the replaced id is no longer held by anything")
        #expect(pinned(replacement), "the new id stays pinned")

        #expect(store.snapshotIdWrite(opId, replacement) == nil, "writing the same id again replaces nothing")
        #expect(pinned(replacement))
    }

    @Test("snapshotIdWrite on a slot that is gone changes and unpins nothing")
    func snapshotIdWriteWithSlotGone() {
        let store = SectionDeleteSlotStore()
        let newId = "snap-\(UUID().uuidString)"
        defer { SnapshotService.unpinUndoPointSnapshot(newId) }
        SnapshotService.pinUndoPointSnapshot(newId)

        #expect(store.snapshotIdWrite(UUID(), newId) == nil)
        #expect(pinned(newId))
    }

    @Test("a slot marked fallback keeps that state when the job records afterwards, and markFallback on a gone slot is a no-op")
    func fallbackStateSticks() {
        let store = SectionDeleteSlotStore()
        let opId = UUID()
        defer { store.removeAll() }
        store.open(opId)
        store.markFallback(opId)

        store.recordApplied(opId, snapshotId: "snap-\(UUID().uuidString)", removedSections: [])

        #expect(store.slot(opId)?.state == .fallback)
        store.markFallback(UUID())
        #expect(store.count == 1)
    }
}
