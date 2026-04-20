//
//  BlockSyncStaleGuardTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for BlockSyncService's stale-snapshot guard helpers.
//  Primary defense is the JS-side Phase 1 fix (see block-id-plugin.ts).
//  Swift helpers are defense-in-depth: a hard reject for the pre-existing
//  100%-delete-no-inserts pattern, plus a warning-only telemetry signal
//  for the "balanced massive churn" signature of the observed JS bug.
//

import Testing
import Foundation
@testable import final_final

@Suite("BlockSync stale-snapshot guard — Tier 1: Silent Killers")
struct BlockSyncStaleGuardTests {

    // MARK: - shouldRejectAsStale (hard reject — parity with pre-existing behavior)

    @Test("Rejects when all blocks deleted with no inserts on a large doc")
    func rejectsFullDeleteNoInsertsLargeDoc() {
        let changes = makeChanges(deletes: 135, inserts: 0, updates: 0)
        let reason = BlockSyncService.shouldRejectAsStale(changes: changes, blockCount: 135)
        #expect(reason == .allDeletedNoInserts)
    }

    @Test("Rejects full-delete on small doc above the >2 threshold")
    func rejectsFullDeleteSmallDoc() {
        let changes = makeChanges(deletes: 3, inserts: 0, updates: 0)
        let reason = BlockSyncService.shouldRejectAsStale(changes: changes, blockCount: 3)
        #expect(reason == .allDeletedNoInserts)
    }

    @Test("Does NOT reject when blockCount is at the threshold (blockCount=2)")
    func allowsFullDeleteAtThreshold() {
        let changes = makeChanges(deletes: 2, inserts: 0, updates: 0)
        let reason = BlockSyncService.shouldRejectAsStale(changes: changes, blockCount: 2)
        #expect(reason == nil)
    }

    @Test("Does NOT reject when inserts are present (not a pure delete)")
    func allowsFullDeleteWithInserts() {
        let changes = makeChanges(deletes: 135, inserts: 1, updates: 0)
        let reason = BlockSyncService.shouldRejectAsStale(changes: changes, blockCount: 135)
        #expect(reason == nil)
    }

    @Test("Does NOT reject the observed-bug signature (that's warning-only territory)")
    func allowsObservedChurnSignature() {
        // The figure-theft bug's exact live signature: u=15 i=85 d=85 on a 135-block doc.
        // This is NOT rejected here — the churn signal belongs to the warning helper.
        let changes = makeChanges(deletes: 85, inserts: 85, updates: 15)
        let reason = BlockSyncService.shouldRejectAsStale(changes: changes, blockCount: 135)
        #expect(reason == nil)
    }

    @Test("Does NOT reject normal keystroke edits")
    func allowsNormalEdit() {
        let changes = makeChanges(deletes: 0, inserts: 0, updates: 1)
        let reason = BlockSyncService.shouldRejectAsStale(changes: changes, blockCount: 135)
        #expect(reason == nil)
    }

    // MARK: - hasBalancedMassiveChurnSignature (warning-only telemetry)

    @Test("Fires on the observed bug signature (u=15 i=85 d=85, 135 blocks)")
    func fireOnObservedBugSignature() {
        let changes = makeChanges(deletes: 85, inserts: 85, updates: 15)
        #expect(BlockSyncService.hasBalancedMassiveChurnSignature(changes: changes, blockCount: 135))
    }

    @Test("Does NOT fire on paste-replace (matched churn but no updates)")
    func silentOnPasteReplace() {
        let changes = makeChanges(deletes: 50, inserts: 50, updates: 0)
        #expect(!BlockSyncService.hasBalancedMassiveChurnSignature(changes: changes, blockCount: 135))
    }

    @Test("Fires at the low threshold (u=6, balanced d+i above count/2)")
    func fireAtThreshold() {
        let changes = makeChanges(deletes: 30, inserts: 30, updates: 6)
        #expect(BlockSyncService.hasBalancedMassiveChurnSignature(changes: changes, blockCount: 100))
    }

    @Test("Does NOT fire at exactly u=5 (threshold is > 5)")
    func silentAtUpdateThreshold() {
        let changes = makeChanges(deletes: 30, inserts: 30, updates: 5)
        #expect(!BlockSyncService.hasBalancedMassiveChurnSignature(changes: changes, blockCount: 100))
    }

    @Test("Does NOT fire on asymmetric churn (select-range-delete with edits)")
    func silentOnAsymmetricChurn() {
        // 30 deletes + 10 inserts + 10 updates — churn=30, delta=20, 20 > 30/4=7 → not balanced
        let changes = makeChanges(deletes: 30, inserts: 10, updates: 10)
        #expect(!BlockSyncService.hasBalancedMassiveChurnSignature(changes: changes, blockCount: 100))
    }

    @Test("Does NOT fire on small documents (blockCount <= 10)")
    func silentOnSmallDoc() {
        let changes = makeChanges(deletes: 10, inserts: 10, updates: 10)
        #expect(!BlockSyncService.hasBalancedMassiveChurnSignature(changes: changes, blockCount: 5))
    }

    @Test("Does NOT fire on pure-insert scenario (no deletes)")
    func silentOnPureInsert() {
        // Pure insert: d=0, churn=i, balanceDelta=i, i <= i/4 only if i==0.
        let changes = makeChanges(deletes: 0, inserts: 50, updates: 10)
        #expect(!BlockSyncService.hasBalancedMassiveChurnSignature(changes: changes, blockCount: 100))
    }

    @Test("Does NOT fire on normal keystroke edits")
    func silentOnKeystroke() {
        let changes = makeChanges(deletes: 0, inserts: 0, updates: 1)
        #expect(!BlockSyncService.hasBalancedMassiveChurnSignature(changes: changes, blockCount: 135))
    }

    // MARK: - Helpers

    /// Minimal BlockChanges fixture. The helpers only read counts, so payload content doesn't matter.
    private func makeChanges(deletes: Int, inserts: Int, updates: Int) -> BlockChanges {
        return BlockChanges(
            updates: (0..<updates).map { i in
                BlockUpdate(
                    id: "u-\(i)",
                    textContent: "update \(i)",
                    markdownFragment: "update \(i)",
                    headingLevel: nil
                )
            },
            inserts: (0..<inserts).map { i in
                BlockInsert(
                    tempId: "temp-i-\(i)",
                    blockType: "paragraph",
                    textContent: "insert \(i)",
                    markdownFragment: "insert \(i)",
                    headingLevel: nil,
                    afterBlockId: nil
                )
            },
            deletes: (0..<deletes).map { "d-\($0)" }
        )
    }
}
