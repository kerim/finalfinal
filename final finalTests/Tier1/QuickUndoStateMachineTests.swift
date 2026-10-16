//
//  QuickUndoStateMachineTests.swift
//  final finalTests
//
//  Tier 1 (t-94369a83 Phase 4b slice 2b; plan-v2-addendum 2.1-2.3 and 4.4, plan-v3-addendum D2, plan-v4-addendum 3.1): the small state
//  machines the quick undo of an editor-first section delete stands on, tested without a rig:
//    - the slot's states (`SectionDeleteSlotStore`: quickUndone, reinserted, back to reserved, fallback sticks);
//    - the payload holder (`SectionDeletePayloadHolder`: fill, fail, the hold token taken once);
//    - the per-entry epoch (`StructuralUndoController.bumpEpoch`) and what a discard forgets (`forgetQuickUndoState`);
//    - the stale-rebuild guard (`EditorViewState.stampRebuildRead`, `rebuildPushStillWanted`) and the sidebar overlay merge;
//    - the footnote checkpoint drop and hold (`FootnoteSyncService`, U-Q15b and its D2 sibling U-Q15c).
//
//  Snapshot ids here are made up (a pin is a string in a set), each test uses its own, so the shared static pin set cannot collide.
//

import Foundation
import Testing
@testable import final_final

@Suite("Quick undo — slot, holder, epoch, guard (Tier 1)")
@MainActor
struct QuickUndoStateMachineTests {

    private func pinned(_ id: String) -> Bool { SnapshotService.pinnedUndoPointSnapshotIdsForTesting.contains(id) }

    // MARK: - The slot's states

    @Test("The slot walks reserved, applied, quickUndone, reinserted, reserved (the redo's job), applied: each step by its own owner")
    func slotWalksTheWholeCycle() {
        let store = SectionDeleteSlotStore()
        let opId = UUID()
        defer { store.removeAll() }
        store.open(opId)
        #expect(store.slot(opId)?.state == .reserved)
        #expect(!store.markReinserted(opId), "a reinsert that was never queued marks nothing")
        #expect(!store.markReserved(opId), "only an undone slot can be reserved by a redo")

        #expect(store.recordApplied(opId, snapshotId: "snap-\(UUID())", removedSections: []))
        #expect(store.slot(opId)?.state == .applied)
        #expect(store.markQuickUndone(opId))
        #expect(store.slot(opId)?.state == .quickUndone)
        #expect(store.markReinserted(opId))
        #expect(store.slot(opId)?.state == .reinserted)
        #expect(!store.markReinserted(opId), "reinserted is reached once")
        #expect(store.markReserved(opId))
        #expect(store.slot(opId)?.state == .reserved)
        #expect(store.recordApplied(opId, snapshotId: "snap-\(UUID())", removedSections: []))
        #expect(store.slot(opId)?.state == .applied, "the redo's job commits and the slot is applied again")
    }

    // markQuickUndone also takes a slot whose delete job has not applied yet (reserved), and from reinserted (undo, redo before it
    // settled, undo)
    @Test("markQuickUndone also takes a slot whose delete job has not applied yet")
    func quickUndoneFromReservedAndReinserted() {
        let store = SectionDeleteSlotStore()
        let opId = UUID()
        defer { store.removeAll() }
        store.open(opId)
        #expect(store.markQuickUndone(opId), "reserved -> quickUndone: the press came before the job applied")
        store.markReinserted(opId)
        #expect(store.markQuickUndone(opId), "reinserted -> quickUndone")
    }

    @Test("A fallback slot stays fallback: a quick undo does not take it, and a redo cannot reserve it")
    func fallbackSlotIsLeftAlone() {
        let store = SectionDeleteSlotStore()
        let opId = UUID()
        defer { store.removeAll() }
        store.open(opId)
        store.markFallback(opId)

        #expect(!store.markQuickUndone(opId))
        #expect(!store.markReinserted(opId))
        #expect(!store.markReserved(opId))
        #expect(store.slot(opId)?.state == .fallback)
        #expect(!store.markQuickUndone(UUID()), "a slot that is gone changes nothing")
    }

    @Test("recordApplied over an earlier snapshot (a quick redo's new delete job) unpins the one it replaces and pins the new one")
    func recordAppliedUnpinsTheReplacedSnapshot() {
        let store = SectionDeleteSlotStore()
        let opId = UUID()
        let first = "snap-\(UUID().uuidString)"
        let second = "snap-\(UUID().uuidString)"
        defer { store.removeAll(); SnapshotService.unpinUndoPointSnapshot(first); SnapshotService.unpinUndoPointSnapshot(second) }
        store.open(opId)
        store.recordApplied(opId, snapshotId: first, removedSections: [])
        #expect(pinned(first))

        store.recordApplied(opId, snapshotId: second, removedSections: [])

        #expect(!pinned(first), "expected the pinned snapshot ids to equal the slot's live ids (the first job's snapshot is still pinned)")
        #expect(pinned(second))
        store.recordApplied(opId, snapshotId: second, removedSections: [])
        #expect(pinned(second), "recording the same id again must not unpin it")
    }

    // MARK: - The payload holder

    private func row(_ title: String) -> Block {
        Block(projectId: "p", sortOrder: 1, blockType: .heading, textContent: title, markdownFragment: "# \(title)", headingLevel: 1)
    }

    @Test("The holder starts pending, fill makes it applied and counts each delete job, and what was filled is what a snapshot reads")
    func holderFillAndSerial() {
        let holder = SectionDeletePayloadHolder(opId: UUID(), rootId: "root", projectId: "p")
        #expect(holder.outcome == .pending)
        #expect(holder.snapshot().preDeleteRows.isEmpty && holder.snapshot().jobSerial == 0)

        holder.fill(rows: [row("A"), row("B")], leaders: [row("A")], resolvedRootId: "root-db")
        var state = holder.snapshot()
        #expect(holder.outcome == .applied)
        #expect(state.preDeleteRows.map(\.textContent) == ["A", "B"] && state.leaders.map(\.textContent) == ["A"])
        #expect(state.resolvedRootId == "root-db" && state.jobSerial == 1)

        holder.fill(rows: [row("C")], leaders: [], resolvedRootId: "root-db")   // a redo's job fills it again
        state = holder.snapshot()
        #expect(state.preDeleteRows.map(\.textContent) == ["C"] && state.jobSerial == 2, "the redo's job overwrites the rows and counts")
    }

    @Test("markFailed fails only a pending holder: a redo's failed job leaves the earlier job's rows for a reinsert already queued behind it")
    func holderFailsOnlyWhilePending() {
        let pending = SectionDeletePayloadHolder(opId: UUID(), rootId: "root", projectId: "p")
        pending.markFailed()
        #expect(pending.outcome == .failed)

        let applied = SectionDeletePayloadHolder(opId: UUID(), rootId: "root", projectId: "p")
        applied.fill(rows: [row("A")], leaders: [], resolvedRootId: "root")
        applied.markFailed()
        #expect(applied.outcome == .applied, "an applied holder is never turned into a failed one")
    }

    @Test("A snapshot is a copy: filling the holder afterwards does not change what an earlier reader holds")
    func holderSnapshotIsACopy() {
        let holder = SectionDeletePayloadHolder(opId: UUID(), rootId: "root", projectId: "p")
        holder.fill(rows: [row("A")], leaders: [], resolvedRootId: "root")
        let earlier = holder.snapshot()
        holder.fill(rows: [row("B")], leaders: [], resolvedRootId: "root")
        #expect(earlier.preDeleteRows.map(\.textContent) == ["A"])
        #expect(holder.snapshot().preDeleteRows.map(\.textContent) == ["B"])
    }

    @Test("The checkpoint hold token is handed out once: the release that follows cannot happen twice")
    func holderHandsOutTheHoldTokenOnce() {
        let holder = SectionDeletePayloadHolder(opId: UUID(), rootId: "root", projectId: "p")
        let token = UUID()
        holder.setCheckpointHoldToken(token)
        #expect(holder.takeCheckpointHoldToken() == token)
        #expect(holder.takeCheckpointHoldToken() == nil)
    }

    // MARK: - The epoch

    // The epoch is per entry and goes up by one at each bump; a discard forgets the holder and the keys but NOT the epoch (a settle still
    // running must find its own epoch unchanged)
    @Test("The epoch is per entry and goes up by one at each bump")
    func epochSurvivesADiscard() {
        let controller = StructuralUndoController()
        let one = UUID()
        let other = UUID()
        #expect(controller.bumpEpoch(one) == 1 && controller.bumpEpoch(one) == 2 && controller.bumpEpoch(other) == 1, "per entry, +1 each")

        controller.efHolders[one] = SectionDeletePayloadHolder(opId: one, rootId: "r", projectId: "p")
        controller.efLatestJobKey[one] = UUID()
        controller.efRecordedStructGeneration[one] = 4
        controller.forgetQuickUndoState(one)

        #expect(controller.efHolders[one] == nil && controller.efLatestJobKey[one] == nil && controller.efRecordedStructGeneration[one] == nil)
        #expect(controller.efOpEpoch[one] == 2, "the epoch is left alone")
        #expect(controller.efOpEpoch[other] == 1)
    }

    // MARK: - The stale-rebuild guard

    @Test("A rebuild's stamp is current until a quick undo or redo starts, and a rebuild that read while a reinsert was pending is never current")
    func rebuildStampRules() {
        let state = EditorViewState()
        let fresh = state.stampRebuildRead()
        #expect(state.rebuildPushStillWanted(fresh), "no quick undo since the read: push")

        state.editorRestoreGeneration += 1   // the quick undo's first stretch
        state.pendingReinsertCount += 1
        #expect(!state.rebuildPushStillWanted(fresh), "a rebuild that read before the restore is stale")
        let duringReinsert = state.stampRebuildRead()
        #expect(duringReinsert.readWhileReinsertPending && !state.rebuildPushStillWanted(duringReinsert),
                "a rebuild that read while the reinsert was pending read the post-delete table")

        state.pendingReinsertCount -= 1   // the reinsert's job future resolved
        let afterReinsert = state.stampRebuildRead()
        #expect(
            state.rebuildPushStillWanted(afterReinsert),
            "expected 1 push, got 0: a rebuild that read after the reinsert applied is not over-skipped")
        #expect(!state.rebuildPushStillWanted(duringReinsert), "the stamp taken during the reinsert stays stale for good")

        state.editorRestoreGeneration += 1   // a quick redo
        #expect(!state.rebuildPushStillWanted(afterReinsert), "a later quick undo or redo makes an earlier stamp stale again")
    }

    @Test("The sidebar overlay: a restored leader the outline lacks is merged in at its sort position, before the bibliography, and never twice")
    func overlayMerge() {
        let state = EditorViewState()
        func heading(_ title: String, order: Double, bibliography: Bool = false) -> Block {
            var block = Block(
                projectId: "p", sortOrder: order, blockType: .heading, textContent: title, markdownFragment: "# \(title)",
                headingLevel: 1)
            block.isBibliography = bibliography
            return block
        }
        let outline = [heading("One", order: 1), heading("Three", order: 3), heading("Bibliography", order: 9, bibliography: true)]
        #expect(state.mergingPendingRestores(into: outline).map(\.textContent) == ["One", "Three", "Bibliography"], "no overlay: unchanged")

        let restored = heading("Two", order: 2)
        let opId = UUID()
        state.pendingRestoreSections[opId] = [restored]
        #expect(state.mergingPendingRestores(into: outline).map(\.textContent) == ["One", "Two", "Three", "Bibliography"])

        let lastChapter = heading("Four", order: 4)
        state.pendingRestoreSections[opId] = [lastChapter]
        #expect(state.mergingPendingRestores(into: outline).map(\.textContent) == ["One", "Three", "Four", "Bibliography"], "before the bibliography")

        state.pendingRestoreSections[opId] = [outline[1]]
        #expect(state.mergingPendingRestores(into: outline).count == 3, "a leader the outline already has is not added twice")
    }

    // MARK: - Footnote checkpoints (U-Q15b, D2)

    private func deletingCheckpoint() -> FootnoteUndoCheckpoint {
        FootnoteUndoCheckpoint(
            bodyBefore: "Text [^1] and [^2].", refsBefore: ["1", "2"], deletedDefinitions: ["2": "Second note"], appliedRenameMap: [:])
    }

    @Test("U-Q15b: dropUndoCheckpoints removes what was recorded since the delete's click and keeps the older ones")
    func dropCheckpointsKeepsTheMarked() {
        let service = FootnoteSyncService()
        let older = deletingCheckpoint()
        service.undoCheckpoints = [older]
        let marker = Set(service.undoCheckpoints.map(\.id))
        service.undoCheckpoints.append(deletingCheckpoint())
        service.undoCheckpoints.append(deletingCheckpoint())

        service.dropUndoCheckpoints(notIn: marker)

        #expect(service.undoCheckpoints.map(\.id) == [older.id])
    }

    // U-Q15b: while the quick undo's hold is active, a write scheduled before the undo records no checkpoint; a write scheduled after it
    // does (U-Q15c); a different token's release leaves the hold
    @Test("U-Q15b: while the quick undo's hold is active")
    func checkpointHoldCoversOnlyEarlierWrites() {
        let service = FootnoteSyncService()
        service.syncGeneration = 5
        let token = UUID()
        service.holdUndoCheckpoints(token: token)

        service.committedNotesWrite(undoCheckpoint: deletingCheckpoint(), scheduledGeneration: 5)
        #expect(service.undoCheckpoints.isEmpty, "expected no undo checkpoint recorded by a write scheduled before the quick undo")
        service.committedNotesWrite(undoCheckpoint: deletingCheckpoint(), scheduledGeneration: 4)
        #expect(service.undoCheckpoints.isEmpty)

        service.committedNotesWrite(undoCheckpoint: deletingCheckpoint(), scheduledGeneration: 6)
        #expect(service.undoCheckpoints.count == 1, "a write scheduled after the quick undo records its checkpoint as always (U-Q15c)")

        service.releaseUndoCheckpointHold(token: UUID())
        service.committedNotesWrite(undoCheckpoint: deletingCheckpoint(), scheduledGeneration: 3)
        #expect(service.undoCheckpoints.count == 1, "another token's release leaves the hold in place")

        service.releaseUndoCheckpointHold(token: token)
        service.committedNotesWrite(undoCheckpoint: deletingCheckpoint(), scheduledGeneration: 3)
        #expect(service.undoCheckpoints.count == 2, "once the hold is released an old write records again")
    }

    @Test("A write with no generation (the no-writer direct fallbacks) is never withheld, hold or not")
    func writeWithoutGenerationIsNeverWithheld() {
        let service = FootnoteSyncService()
        service.holdUndoCheckpoints(token: UUID())
        service.committedNotesWrite(undoCheckpoint: deletingCheckpoint())
        #expect(service.undoCheckpoints.count == 1)
    }
}
