//
//  SectionDeleteSlotStore.swift
//  final final
//
//  t-94369a83 Phase 4b, slice 2a (plan D2.2(d)(e)(f), addenda A17 and A18): the one in-memory place a section
//  delete's background job leaves what undo needs, keyed by the structural entry's operation id.
//
//  UNDER OPTION (b), THE BUILD THIS SERVES (instant delete first, quick undo later), a slot holds the Version History
//  snapshot the job wrote before it deleted the rows (today's undo restores it), the delete's leader rows (the sidebar
//  sections the click removed from the outline, kept for slice 2b's quick undo) and a state. The payload rows quick undo
//  re-inserts are slice 2b and are not here.
//
//  LIFETIME. The wiring opens a slot at the click (`open`), before the job is reserved; the job fills it
//  (`recordApplied`); the timeline's eviction and invalidation remove it (`remove`/`removeAll`), which also unpins the
//  snapshot. A slot that is already gone when the job runs means the timeline was cleared in between (a mode switch,
//  a zoom, an eviction): the job still writes the Version History snapshot (A17) but pins nothing and stores nothing,
//  so no pin outlives the entry it served.
//
//  LOCKING. The store is touched from the MainActor (click, undo, eviction) and from the writer's executor (the job's
//  after-commit hook), so every access goes through one unfair lock. The pin set has its own lock
//  (`SnapshotService.pinUndoPointSnapshot`); this file always takes the store lock first and the pin lock inside it,
//  and nothing takes them in the other order.
//

import Foundation
import os

final class SectionDeleteSlotStore: Sendable {

    /// Where the entry's undo stands. `reserved`: opened at the click, the job has not applied yet. `applied`: the job
    /// committed and recorded its snapshot. `fallback`: an undo or redo of this entry took today's snapshot path, so every
    /// later undo and redo of it does too (addendum A18, plan D5b).
    enum State: Sendable, Equatable {
        case reserved
        case applied
        case fallback
    }

    struct Slot: Sendable, Equatable {
        /// The Version History snapshot to restore when this entry is undone; nil until the job applies.
        var snapshotId: String?
        /// The delete's leader rows (headings and section breaks), as they were just before the job deleted them: what
        /// slice 2b's quick undo puts back into the sidebar. Empty until the job applies.
        var removedSections: [Block]
        var state: State
    }

    private let slots = OSAllocatedUnfairLock(initialState: [UUID: Slot]())

    init() {}

    /// Opens the slot for `opId` (state `reserved`). Called at the click, before the job is reserved. A second `open` for the
    /// same id leaves the existing slot as it is.
    func open(_ opId: UUID) {
        slots.withLock { table in
            if table[opId] == nil {
                table[opId] = Slot(snapshotId: nil, removedSections: [], state: .reserved)
            }
        }
    }

    func slot(_ opId: UUID) -> Slot? {
        slots.withLock { $0[opId] }
    }

    /// Whether the entry's slot still exists (it is removed by eviction and invalidation).
    func isLive(_ opId: UUID) -> Bool {
        slots.withLock { $0[opId] != nil }
    }

    var count: Int {
        slots.withLock { $0.count }
    }

    /// The job's after-commit record: stores the snapshot id and the removed leaders, sets the state to `applied`, and PINS
    /// the snapshot so Version History's pruning never deletes it. Atomic against `remove`/`removeAll`: when the slot is gone
    /// nothing is stored and nothing is pinned, and `false` is returned (addendum A17; the job's snapshot row stays, as an
    /// ordinary automatic version). A slot already marked `fallback` keeps that state.
    @discardableResult
    func recordApplied(_ opId: UUID, snapshotId: String, removedSections: [Block]) -> Bool {
        slots.withLock { table in
            guard var slot = table[opId] else { return false }
            slot.snapshotId = snapshotId
            slot.removedSections = removedSections
            if slot.state == .reserved { slot.state = .applied }
            table[opId] = slot
            SnapshotService.pinUndoPointSnapshot(snapshotId)
            return true
        }
    }

    /// Marks the slot `fallback` (plan D5b): every later undo and redo of this entry uses today's snapshot path.
    func markFallback(_ opId: UUID) {
        slots.withLock { table in
            table[opId]?.state = .fallback
        }
    }

    /// Writes `newId` onto the slot as its snapshot id and unpins the id it replaces (addendum A18): what a fallback undo or a
    /// redo does where today's `replaceTopOfUndoStack` would have swapped the entry's snapshot id. `newId` is already pinned by
    /// whoever created it (`createUndoPointSnapshot()` pins at creation); the replaced id's pin is the one that must go, or the
    /// pin set would grow by one snapshot per undo-redo cycle. Returns the replaced id, or nil when the slot is gone or had no
    /// snapshot id yet (then nothing is changed and nothing is unpinned).
    @discardableResult
    func snapshotIdWrite(_ opId: UUID, _ newId: String) -> String? {
        slots.withLock { table in
            guard var slot = table[opId] else { return nil }
            let replaced = slot.snapshotId
            slot.snapshotId = newId
            table[opId] = slot
            if let replaced, replaced != newId {
                SnapshotService.unpinUndoPointSnapshot(replaced)
                return replaced
            }
            return nil
        }
    }

    /// Removes the slot and unpins its snapshot (eviction of the entry, or invalidation of the timeline for it). Returns the
    /// removed slot, nil when there was none.
    @discardableResult
    func remove(_ opId: UUID) -> Slot? {
        slots.withLock { table in
            guard let removed = table.removeValue(forKey: opId) else { return nil }
            if let snapshotId = removed.snapshotId { SnapshotService.unpinUndoPointSnapshot(snapshotId) }
            return removed
        }
    }

    /// Removes every slot and unpins every snapshot they held (timeline invalidation: project switch, mode switch, zoom,
    /// close).
    func removeAll() {
        slots.withLock { table in
            for slot in table.values {
                if let snapshotId = slot.snapshotId { SnapshotService.unpinUndoPointSnapshot(snapshotId) }
            }
            table.removeAll()
        }
    }
}
