//
//  BlockWriteStampGuardTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for the persisted (epoch, sequence) block-write stamp (t-19011ab6) that
//  replaced BlockSyncService's in-memory `lastWriterStampByBlockId`. That in-memory
//  map was wiped on `configure`/`reconfigure` and blind to native structural
//  rewrites, so an older editor batch's DB write — already dispatched when a newer
//  batch's in-memory guard passed — could commit last and silently overwrite newer
//  text on a shared block id (residual L11). The stamp now lives next to the rows it
//  protects (Database+BlockWriteStamp.swift) and is checked atomically inside the
//  same write transaction: comparison is lexicographic, epoch-major, so a batch
//  fetched before a wholesale rewrite is refused WHOLESALE (inserts included), and
//  within one epoch the guard degenerates to exactly the removed map's per-block
//  fetch-ordinal comparison.
//

import Testing
import Foundation
import GRDB
@testable import final_final

/// What `seedParagraphFixture()` hands back: a struct rather than a 4-member tuple, which
/// SwiftLint's `large_tuple` rule (error at 4 members) rejects.
private struct SeededParagraphFixture {
    let db: ProjectDatabase
    let pid: String
    let target: Block
    let epoch: Int64
}

@Suite("Block write stamp guard — Tier 1: Silent Killers")
struct BlockWriteStampGuardTests {

    // MARK: - Shared fixture helpers
    //
    // `TestFixtureFactory.createFixture` itself calls `replaceBlocks`, which bumps the
    // project's epoch (Database+BlocksReplace.swift's delete-and-reinsert site), so a
    // freshly created fixture is NEVER at epoch 0. Every stamp below is therefore built
    // from the epoch READ back out of the database, never a hard-coded literal that
    // depends on how the fixture happened to be created.
    //
    // The target is deliberately a PARAGRAPH found by content, not `.first` of the
    // default fixture (a heading): a paragraph is the block type an editor text diff
    // actually targets, and finding it by content keeps these tests independent of
    // fixture ordering.

    /// Seeds a fixture with explicit content and returns its "first paragraph" block
    /// together with the project's current (fixture-creation-derived) epoch.
    private func seedParagraphFixture() throws -> SeededParagraphFixture {
        let db = try TestFixtureFactory.createTemporary(content: "# Alpha\n\nfirst paragraph.\n")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let target = try #require(
            blocks.first(where: { $0.blockType == .paragraph && $0.textContent.contains("first paragraph") }),
            "expected the Alpha paragraph in the fixture"
        )
        let epoch = try db.currentBlockWriteEpoch(projectId: pid)
        return SeededParagraphFixture(db: db, pid: pid, target: target, epoch: epoch)
    }

    /// Re-reads one block straight from the database.
    private func fetchRow(_ id: String, in db: ProjectDatabase) throws -> Block? {
        try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == id }
    }

    // MARK: - T1/T2: an older batch committing LAST must still lose (the core L11 fix)

    @Test("An older batch that commits LAST still loses to a newer batch already written")
    func olderBatchCommittingLastLoses() throws {
        let fixture = try seedParagraphFixture()
        let (db, pid, target, epoch) = (fixture.db, fixture.pid, fixture.target, fixture.epoch)

        let newerChanges = BlockChanges(updates: [
            BlockUpdate(id: target.id, textContent: "newer", markdownFragment: nil, headingLevel: nil)
        ])
        let newerResult = try db.applyBlockChangesFromEditor(
            newerChanges, for: pid, stamp: BlockWriteStamp(epoch: epoch, sequence: 5)
        )
        // The NEWER apply must genuinely land first, or the assertions below would pass
        // vacuously (a wholesale reject of this apply would also leave "older" unwritten).
        #expect(!newerResult.rejectedWholeBatchForStaleEpoch,
                "the newer batch carries the CURRENT epoch and must not be rejected wholesale")
        #expect(newerResult.writtenUpdateIds == [target.id],
                "the newer batch must be written — got \(newerResult.writtenUpdateIds)")
        let afterNewer = try #require(try fetchRow(target.id, in: db))
        #expect(afterNewer.textContent == "newer",
                "precondition: the newer batch's text must be on the row — got \(afterNewer.textContent)")

        // Dispatched EARLIER (lower sequence) but committing LAST — exactly the L11 shape.
        let olderChanges = BlockChanges(updates: [
            BlockUpdate(id: target.id, textContent: "older", markdownFragment: nil, headingLevel: nil)
        ])
        let result = try db.applyBlockChangesFromEditor(
            olderChanges, for: pid, stamp: BlockWriteStamp(epoch: epoch, sequence: 2)
        )

        #expect(!result.rejectedWholeBatchForStaleEpoch,
                "this must be PER-ROW supersession within the current epoch, not a wholesale epoch reject")
        let row = try #require(try fetchRow(target.id, in: db))
        #expect(row.textContent == "newer",
                "the chronologically older batch must not overwrite newer text just because it committed last")
        #expect(result.droppedUpdateIds == [target.id],
                "the superseded update must be reported as dropped — got \(result.droppedUpdateIds)")
        #expect(result.writtenUpdateIds.isEmpty,
                "the superseded update must not be reported as written — got \(result.writtenUpdateIds)")
    }

    @Test("A delete stamped OLDER than a row's last write is refused, not just an update")
    func olderDeleteOfNewerRowIsRefused() throws {
        let fixture = try seedParagraphFixture()
        let (db, pid, target, epoch) = (fixture.db, fixture.pid, fixture.target, fixture.epoch)

        let newerChanges = BlockChanges(updates: [
            BlockUpdate(id: target.id, textContent: "kept", markdownFragment: nil, headingLevel: nil)
        ])
        let newerResult = try db.applyBlockChangesFromEditor(
            newerChanges, for: pid, stamp: BlockWriteStamp(epoch: epoch, sequence: 5)
        )
        // As in T1: the newer write must genuinely land, or the survivor assertions
        // below could be satisfied by a wholesale reject of the DELETE batch alone.
        #expect(!newerResult.rejectedWholeBatchForStaleEpoch,
                "the newer batch carries the CURRENT epoch and must not be rejected wholesale")
        #expect(newerResult.writtenUpdateIds == [target.id],
                "the newer batch must be written — got \(newerResult.writtenUpdateIds)")
        let afterNewer = try #require(try fetchRow(target.id, in: db))
        #expect(afterNewer.textContent == "kept",
                "precondition: the newer batch's text must be on the row — got \(afterNewer.textContent)")

        let olderDelete = BlockChanges(deletes: [target.id])
        let result = try db.applyBlockChangesFromEditor(
            olderDelete, for: pid, stamp: BlockWriteStamp(epoch: epoch, sequence: 2)
        )

        #expect(!result.rejectedWholeBatchForStaleEpoch,
                "this must be PER-ROW supersession within the current epoch, not a wholesale epoch reject")
        let survivor = try fetchRow(target.id, in: db)
        #expect(survivor != nil, "a stale delete must not destroy a row a newer batch already wrote")
        #expect(survivor?.textContent == "kept",
                "the surviving row must still hold the newer text — got \(String(describing: survivor?.textContent))")
        #expect(result.droppedDeleteIds == [target.id],
                "the superseded delete must be reported as dropped — got \(result.droppedDeleteIds)")
        #expect(result.writtenDeleteIds.isEmpty,
                "the superseded delete must not be reported as written — got \(result.writtenDeleteIds)")
    }

    // MARK: - T3: epoch-major, not sequence-major

    @Test("A new epoch's low sequence beats the old epoch's high one — epoch-major, not sequence-major")
    func reopenedProjectFirstBatchApplies() throws {
        let fixture = try seedParagraphFixture()
        let (db, pid, target, fixtureEpoch) = (fixture.db, fixture.pid, fixture.target, fixture.epoch)

        // Start a fresh epoch on top of whatever the fixture creation left behind, and
        // read it back rather than assuming a number.
        let oldEpoch = try db.bumpBlockWriteEpoch(projectId: pid)
        #expect(oldEpoch == fixtureEpoch + 1, "bumping must advance the epoch by exactly one — got \(oldEpoch) from \(fixtureEpoch)")
        let readBack = try db.currentBlockWriteEpoch(projectId: pid)
        #expect(readBack == oldEpoch, "the epoch read back must equal the bump's return value — got \(readBack) vs \(oldEpoch)")

        let lateResult = try db.applyBlockChangesFromEditor(
            BlockChanges(updates: [
                BlockUpdate(id: target.id, textContent: "old-epoch-late", markdownFragment: nil, headingLevel: nil)
            ]),
            for: pid, stamp: BlockWriteStamp(epoch: oldEpoch, sequence: 900)
        )
        #expect(!lateResult.rejectedWholeBatchForStaleEpoch,
                "the old-epoch batch carries the epoch that is current AT THIS POINT and must not be rejected")
        #expect(lateResult.writtenUpdateIds == [target.id],
                "the old-epoch high-sequence batch must be written — got \(lateResult.writtenUpdateIds)")
        let afterLate = try #require(try fetchRow(target.id, in: db))
        #expect(afterLate.textContent == "old-epoch-late",
                "precondition: the old epoch's high-sequence text must be on the row — got \(afterLate.textContent)")

        // Project reopened / rewritten: the epoch bumps again (and restamps every row to
        // (newEpoch, 0)). The new epoch's very first, low-sequence batch must not be
        // measured against the OLD epoch's high sequence.
        let newEpoch = try db.bumpBlockWriteEpoch(projectId: pid)
        #expect(newEpoch == oldEpoch + 1, "bumping must advance the epoch by exactly one — got \(newEpoch) from \(oldEpoch)")
        let result = try db.applyBlockChangesFromEditor(
            BlockChanges(updates: [
                BlockUpdate(id: target.id, textContent: "new-epoch-first", markdownFragment: nil, headingLevel: nil)
            ]),
            for: pid, stamp: BlockWriteStamp(epoch: newEpoch, sequence: 1)
        )

        #expect(!result.rejectedWholeBatchForStaleEpoch,
                "a batch carrying the CURRENT epoch must not be rejected wholesale")
        let row = try #require(try fetchRow(target.id, in: db))
        #expect(row.textContent == "new-epoch-first",
                "a batch carrying the CURRENT epoch must win over a stale epoch's high sequence — got \(row.textContent)")
        #expect(result.droppedUpdateIds.isEmpty,
                "the new epoch's sequence 1 must not be dropped as superseded — got \(result.droppedUpdateIds)")
        #expect(result.writtenUpdateIds == [target.id],
                "the new epoch's first batch must be reported as written — got \(result.writtenUpdateIds)")
    }

    // MARK: - T4/T5: the rewrite barrier itself (replaceBlocks epoch bump)

    @Test("A batch fetched BEFORE a replaceBlocks() rewrite is rejected WHOLESALE, inserts included")
    func preRewriteBatchRejectedAfterReplaceBlocks() throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Alpha\n\none two three.\n")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let before = try TestFixtureFactory.fetchBlocks(from: db)
        let target = try #require(before.first { $0.textContent.contains("one two three") },
                                  "expected the Alpha paragraph in the fixture")

        let preRewriteEpoch = try db.currentBlockWriteEpoch(projectId: pid)

        // Wholesale rewrite -- bumps the epoch (Database+BlocksReplace.swift's
        // delete-and-reinsert epoch-bump site).
        let newBlocks = BlockParser.parse(markdown: "# Beta\n\nfour five six.\n", projectId: pid)
        try db.replaceBlocks(newBlocks, for: pid)
        let countAfterRewrite = try TestFixtureFactory.fetchBlocks(from: db).count
        let postRewriteEpoch = try db.currentBlockWriteEpoch(projectId: pid)
        #expect(preRewriteEpoch < postRewriteEpoch,
                "the rewrite must bump the epoch — got \(preRewriteEpoch) before, \(postRewriteEpoch) after")

        // The insert is deliberately ANCHOR-FREE (document start), so it is the outcome that
        // genuinely depends on the epoch barrier. `replaceBlocks` deleted every row, and an insert
        // ANCHORED to any of them would be skipped by `processEditorInserts`'s own stale-anchor
        // guard even with no barrier -- its absence would then prove nothing about the barrier.
        // An anchor-free doc-start insert needs no surviving row and is applied unconditionally
        // (`resolveInsertPlacement`'s doc-start branch), so WITHOUT the batch-level epoch reject
        // it would land; the positive control below applies this same insert and shows it does.
        let staleInsert = BlockInsert(tempId: "temp-stale-1", blockType: "paragraph", textContent: "stale insert",
                                      markdownFragment: "stale insert", headingLevel: nil,
                                      afterBlockId: nil, atDocumentStart: true)
        let staleChanges = BlockChanges(
            updates: [
                BlockUpdate(id: target.id, textContent: "stale update", markdownFragment: nil, headingLevel: nil)
            ],
            inserts: [staleInsert],
            deletes: []
        )
        let result = try db.applyBlockChangesFromEditor(
            staleChanges, for: pid, stamp: BlockWriteStamp(epoch: preRewriteEpoch, sequence: 5)
        )

        #expect(result.rejectedWholeBatchForStaleEpoch,
                "a batch stamped with an epoch below the current one must be rejected wholesale")
        #expect(result.idMapping.isEmpty, "no insert may land on the rejected path — got \(result.idMapping)")

        let afterStale = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(afterStale.count == countAfterRewrite,
                "the rejected batch must not change the row count — got \(afterStale.count), rewrite left \(countAfterRewrite)")
        #expect(!afterStale.contains { $0.textContent == "stale insert" },
                "the rejected batch's insert must never land")

        // Positive control: the very same anchor-free insert, stamped with the post-rewrite epoch,
        // must land -- so its absence above is attributable to the epoch barrier alone, not to an
        // insert that could never apply on this document.
        let control = try db.applyBlockChangesFromEditor(
            BlockChanges(inserts: [staleInsert]), for: pid, stamp: BlockWriteStamp(epoch: postRewriteEpoch, sequence: 6)
        )
        #expect(!control.rejectedWholeBatchForStaleEpoch,
                "the same insert stamped with the CURRENT epoch must not be rejected wholesale")
        #expect(control.idMapping.count == 1,
                "the same anchor-free insert stamped with the CURRENT epoch must land — got \(control.idMapping)")
        let afterControl = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(afterControl.contains { $0.textContent == "stale insert" },
                "the anchor-free insert must be present once the batch carries the current epoch")
    }

    @Test("A batch fetched AFTER a replaceBlocks() rewrite applies normally")
    func postRewriteBatchApplies() throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Alpha\n\none two three.\n")
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let newBlocks = BlockParser.parse(markdown: "# Beta\n\nfour five six.\n", projectId: pid)
        try db.replaceBlocks(newBlocks, for: pid)

        let postRewriteEpoch = try db.currentBlockWriteEpoch(projectId: pid)
        let target = try #require(
            try TestFixtureFactory.fetchBlocks(from: db).first { $0.textContent.contains("four five six") },
            "expected the rewrite's own paragraph"
        )

        let changes = BlockChanges(updates: [
            BlockUpdate(id: target.id, textContent: "fresh edit", markdownFragment: nil, headingLevel: nil)
        ])
        let result = try db.applyBlockChangesFromEditor(
            changes, for: pid, stamp: BlockWriteStamp(epoch: postRewriteEpoch, sequence: 1)
        )

        #expect(!result.rejectedWholeBatchForStaleEpoch,
                "a batch carrying the CURRENT epoch must not be rejected")
        let row = try #require(try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == target.id })
        #expect(row.textContent == "fresh edit", "a post-rewrite batch must apply normally — got \(row.textContent)")
    }
}

// MARK: - T4b/T4c: the two remaining epoch-barrier call sites
//
// Database+BlocksReplace.swift has THREE `stampWholeProjectForRewrite` calls, and each is the ONLY
// thing that bumps the epoch on its own path: `replaceBlocks`' default delete-and-reinsert branch,
// its `preservingMachineManagedBlocks: true` branch (which `return`s early, before the default
// branch's stamp call is ever reached), and `replaceBlocksInRange`. T4 above covers only the
// first, so deleting either other call would leave the whole suite green while the barrier was
// silently gone from that path.
//
// These tests live in an extension rather than the suite body purely to keep the struct under
// SwiftLint's `type_body_length` threshold; they share the suite's `private` helpers
// (same file).
//
// Shared recipe:
//   1. read the epoch immediately BEFORE the rewrite -- fixture creation and seeding already
//      bumped it, so no epoch literal is ever assumed;
//   2. run the rewrite, read the epoch again, and require it strictly greater;
//   3. replay a batch stamped with the PRE-rewrite epoch and require a WHOLESALE rejection;
//   4. replay the SAME batch stamped with the post-rewrite epoch and require it to land, so the
//      rejection in (3) is attributable to the epoch alone, not to a batch that could never apply.
//
// The batch carries an INSERT anchored to a row that STILL EXISTS after the rewrite. Both halves
// matter. An insert has no existing row to lose a per-row stamp comparison against, so only the
// batch-level epoch check can refuse it. And `processEditorInserts` independently skips an insert
// whose anchor no longer exists (the stale-snapshot guard), so an anchor deleted by the rewrite
// would keep the insert out for a reason that has nothing to do with the barrier.
extension BlockWriteStampGuardTests {

    /// One UPDATE plus one INSERT, both anchored to `anchorId`, which the caller guarantees still
    /// exists after the rewrite under test.
    private func probeBatch(anchoredTo anchorId: String) -> BlockChanges {
        BlockChanges(
            updates: [
                BlockUpdate(id: anchorId, textContent: "probe update", markdownFragment: nil, headingLevel: nil)
            ],
            inserts: [
                BlockInsert(tempId: "temp-probe-1", blockType: "paragraph", textContent: "probe insert",
                            markdownFragment: "probe insert", headingLevel: nil, afterBlockId: anchorId)
            ],
            deletes: []
        )
    }

    /// Steps 3 and 4 of the recipe above, shared by both tests. `anchor` is the surviving block
    /// (as it stands right now) the probe batch is anchored to.
    private func expectPreRewriteBatchRejectedAndCurrentBatchApplied(
        db: ProjectDatabase,
        projectId pid: String,
        anchor: Block,
        preRewriteEpoch: Int64,
        postRewriteEpoch: Int64
    ) throws {
        let batch = probeBatch(anchoredTo: anchor.id)
        let countBefore = try TestFixtureFactory.fetchBlocks(from: db).count

        let stale = try db.applyBlockChangesFromEditor(
            batch, for: pid, stamp: BlockWriteStamp(epoch: preRewriteEpoch, sequence: 5)
        )
        #expect(stale.rejectedWholeBatchForStaleEpoch,
                "a batch stamped with the pre-rewrite epoch must be rejected wholesale")
        #expect(stale.idMapping.isEmpty, "no insert may land on the rejected path — got \(stale.idMapping)")

        let afterStale = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(afterStale.count == countBefore,
                "the rejected batch must not change the row count — got \(afterStale.count), had \(countBefore)")
        #expect(!afterStale.contains { $0.textContent == "probe insert" },
                "the rejected batch's insert must never land")
        #expect(afterStale.first { $0.id == anchor.id }?.textContent == anchor.textContent,
                "the rejected batch's update must not land either")

        // Same batch, current epoch: it must apply, or the rejection above proves nothing.
        let control = try db.applyBlockChangesFromEditor(
            batch, for: pid, stamp: BlockWriteStamp(epoch: postRewriteEpoch, sequence: 6)
        )
        #expect(!control.rejectedWholeBatchForStaleEpoch,
                "the same batch stamped with the CURRENT epoch must not be rejected wholesale")
        #expect(control.writtenUpdateIds == [anchor.id],
                "the same batch stamped with the CURRENT epoch must write its update — got \(control.writtenUpdateIds)")
        #expect(control.idMapping.count == 1,
                "the same batch stamped with the CURRENT epoch must land its insert — got \(control.idMapping)")
        let afterControl = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(afterControl.contains { $0.textContent == "probe insert" },
                "the insert must be present once the batch carries the current epoch")
    }

    // Trigger for the early-return path: `preservingMachineManagedBlocks: true` and nothing else --
    // the `if preservingMachineManagedBlocks { ... return }` branch has no further condition, and
    // its `stampWholeProjectForRewrite` call is unconditional inside it. A fixture with
    // machine-managed rows is still required, but for the OTHER purpose: it is the observable that
    // distinguishes this branch from the default one. The default delete-and-reinsert path
    // replaces every row with `blocks`, which here carries no Notes content, so the Notes rows
    // surviving with their own ids can only have come from the preserving branch.
    @Test("A batch fetched BEFORE a replaceBlocks(preservingMachineManagedBlocks: true) rewrite is rejected WHOLESALE")
    func preRewriteBatchRejectedAfterPreservingReplaceBlocks() throws {
        let db = try TestFixtureFactory.createTemporary(content: "# Intro\n\nBody text.\n")
        let pid = try TestFixtureFactory.getProjectId(from: db)

        // A real Notes section (heading, labeled entry, unlabeled continuation) under an ordinary
        // body paragraph -- the shape a single-section restore preserves.
        let seedBlocks: [Block] = [
            Block(projectId: pid, sortOrder: 0, blockType: .heading,
                  textContent: "Intro", markdownFragment: "# Intro", headingLevel: 1),
            Block(projectId: pid, sortOrder: 1, blockType: .paragraph,
                  textContent: "Body text.", markdownFragment: "Body text."),
            Block(projectId: pid, sortOrder: 2, blockType: .heading,
                  textContent: "Notes", markdownFragment: "# Notes", headingLevel: 1, isNotes: true),
            Block(projectId: pid, sortOrder: 3, blockType: .paragraph,
                  textContent: "[^1]: Some footnote text.", markdownFragment: "[^1]: Some footnote text.",
                  isNotes: true),
            Block(projectId: pid, sortOrder: 4, blockType: .paragraph,
                  textContent: "Continuation with no footnote label.",
                  markdownFragment: "Continuation with no footnote label.", isNotes: true)
        ]
        try db.replaceBlocks(seedBlocks, for: pid)

        // Read back rather than trusting the seed's ids: the default path this seeding goes
        // through re-applies an existing same-titled heading's id over a seeded one.
        let seeded = try TestFixtureFactory.fetchBlocks(from: db)
        let notesBefore = seeded.filter { $0.isNotes }
        #expect(notesBefore.count == 3,
                "precondition: Notes heading + labeled entry + unlabeled continuation — got \(notesBefore.count)")
        let oldBody = try #require(seeded.first { $0.textContent == "Body text." },
                                   "expected the seeded body paragraph")

        let preRewriteEpoch = try db.currentBlockWriteEpoch(projectId: pid)

        // Production-shaped `blocks` for a section restore: NO Notes content at all, and body
        // text that differs from the seed so the rewrite itself is observable.
        let newBlocks: [Block] = [
            Block(projectId: pid, sortOrder: 0, blockType: .heading,
                  textContent: "Intro", markdownFragment: "# Intro", headingLevel: 1),
            Block(projectId: pid, sortOrder: 1, blockType: .paragraph,
                  textContent: "Body text, rewritten.", markdownFragment: "Body text, rewritten.")
        ]
        try db.replaceBlocks(newBlocks, for: pid, preservingMachineManagedBlocks: true)

        let postRewriteEpoch = try db.currentBlockWriteEpoch(projectId: pid)
        #expect(preRewriteEpoch < postRewriteEpoch,
                "the preserving rewrite must bump the epoch — got \(preRewriteEpoch) before, \(postRewriteEpoch) after")

        // Proof this really was the preserving branch, not the default delete-and-reinsert one.
        let afterRewrite = try TestFixtureFactory.fetchBlocks(from: db)
        let notesAfter = afterRewrite.filter { $0.isNotes }
        #expect(Set(notesAfter.map { $0.id }) == Set(notesBefore.map { $0.id }),
                "every Notes row must survive with its own id — the default path would have deleted all of them")
        #expect(notesAfter.contains { $0.textContent == "Continuation with no footnote label." },
                "the unlabeled continuation must survive untouched")
        // And that the rewrite itself ran: the non-machine-managed body was replaced.
        let rewrittenBody = try #require(afterRewrite.first { $0.textContent == "Body text, rewritten." },
                                         "the rewrite's own body paragraph must have been inserted")
        #expect(!afterRewrite.contains { $0.id == oldBody.id },
                "the seeded body paragraph is not machine-managed, so it must have been deleted and replaced")

        try expectPreRewriteBatchRejectedAndCurrentBatchApplied(
            db: db, projectId: pid, anchor: rewrittenBody,
            preRewriteEpoch: preRewriteEpoch, postRewriteEpoch: postRewriteEpoch
        )
    }

    // The range covers Beta's heading and body only. The observable that distinguishes this
    // branch from `replaceBlocks`' delete-and-reinsert one: the paragraphs OUTSIDE the range keep
    // their ids and text (the default path would have re-created every paragraph with a fresh id).
    @Test("A batch fetched BEFORE a replaceBlocksInRange() rewrite is rejected WHOLESALE")
    func preRewriteBatchRejectedAfterReplaceBlocksInRange() throws {
        let markdown = """
        # Alpha

        First alpha paragraph.

        # Beta

        Second beta paragraph.

        # Gamma

        Third gamma paragraph.
        """
        let db = try TestFixtureFactory.createTemporary(content: markdown)
        let pid = try TestFixtureFactory.getProjectId(from: db)

        let before = try TestFixtureFactory.fetchBlocks(from: db)
        func heading(_ title: String) throws -> Block {
            try #require(before.first { $0.blockType == .heading && $0.textContent == title },
                         "expected the \"\(title)\" heading in the fixture")
        }
        func paragraph(containing text: String) throws -> Block {
            try #require(before.first { $0.blockType == .paragraph && $0.textContent.contains(text) },
                         "expected the paragraph containing \"\(text)\" in the fixture")
        }
        let alphaHeading = try heading("Alpha")
        let alphaBody = try paragraph(containing: "alpha paragraph")
        let betaHeading = try heading("Beta")
        let betaBody = try paragraph(containing: "beta paragraph")
        let gammaHeading = try heading("Gamma")
        let gammaBody = try paragraph(containing: "gamma paragraph")
        #expect(betaHeading.sortOrder < betaBody.sortOrder && betaBody.sortOrder < gammaHeading.sortOrder,
                "precondition: Beta's heading and body must sit between the range's bounds")

        let preRewriteEpoch = try db.currentBlockWriteEpoch(projectId: pid)

        // Zoomed re-parse of the Beta section only: [Beta heading, Gamma heading).
        let newBlocks = BlockParser.parse(markdown: "# Beta\n\nSecond beta paragraph, rewritten.\n", projectId: pid)
        try db.replaceBlocksInRange(
            newBlocks, for: pid,
            startSortOrder: betaHeading.sortOrder, endSortOrder: gammaHeading.sortOrder
        )

        let postRewriteEpoch = try db.currentBlockWriteEpoch(projectId: pid)
        #expect(preRewriteEpoch < postRewriteEpoch,
                "the range rewrite must bump the epoch — got \(preRewriteEpoch) before, \(postRewriteEpoch) after")

        // Proof this really was the range branch, not the default delete-and-reinsert one.
        let afterRewrite = try TestFixtureFactory.fetchBlocks(from: db)
        for outside in [alphaHeading, alphaBody, gammaHeading, gammaBody] {
            let survivor = afterRewrite.first { $0.id == outside.id }
            #expect(survivor?.textContent == outside.textContent,
                    "\"\(outside.textContent)\" lies outside the range and must survive with its own id and text")
        }
        // And that the rewrite itself ran: the in-range body was replaced.
        #expect(!afterRewrite.contains { $0.id == betaBody.id },
                "the in-range body paragraph must have been deleted and replaced")
        #expect(afterRewrite.contains { $0.textContent.contains("beta paragraph, rewritten") },
                "the range rewrite's own paragraph must have been inserted")

        // Anchor on an OUTSIDE-the-range paragraph: it is guaranteed to exist after the rewrite.
        let anchor = try #require(afterRewrite.first { $0.id == alphaBody.id }, "the Alpha paragraph must survive")
        try expectPreRewriteBatchRejectedAndCurrentBatchApplied(
            db: db, projectId: pid, anchor: anchor,
            preRewriteEpoch: preRewriteEpoch, postRewriteEpoch: postRewriteEpoch
        )
    }
}

// MARK: - T6/T7: safety-net stamping and migration safety
//
// In an extension, not the suite body, to keep the struct under SwiftLint's `type_body_length`
// threshold; shares the suite's `private` helpers (same file).

/// One migrated `block` row read back with raw SQL (a struct: `large_tuple` rejects 4-member tuples).
private struct MigratedBlockRow {
    let id: String
    let epoch: Int64
    let sequence: Int64
    let text: String
}

/// Schema facts checked before/after the v17 replay (a struct: `large_tuple` flags 3-member tuples).
private struct MigrationSchemaSnapshot {
    let blockColumns: [String]
    let projectColumns: [String]
    let v17Rows: Int   // `grdb_migrations` rows recording `v17_block_write_stamp`
}

extension BlockWriteStampGuardTests {

    /// Raw-SQL schema snapshot: `Block`/`Project` deliberately do not declare the stamp columns
    /// (Database+BlockWriteStamp.swift), so decoding through them could not observe them.
    private func readSchemaSnapshot(of db: ProjectDatabase) throws -> MigrationSchemaSnapshot {
        try db.dbWriter.read { database in
            let blockColumns = try Row.fetchAll(database, sql: "PRAGMA table_info(block)").map { $0["name"] as String }
            let projectColumns = try Row.fetchAll(database, sql: "PRAGMA table_info(project)").map { $0["name"] as String }
            let v17Rows = try Int.fetchOne(
                database, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                arguments: ["v17_block_write_stamp"]
            ) ?? -1
            return MigrationSchemaSnapshot(blockColumns: blockColumns, projectColumns: projectColumns, v17Rows: v17Rows)
        }
    }

    // MARK: - T6: a refused safety-net write must not be stamped

    @Test("A row a safety net refuses is not stamped, so a later lower-sequence legitimate write still applies")
    func rejectedNotesWriteIsNotStamped() throws {
        let seed = """
        Body[^2].

        # Notes

        [^2]: First real text.
        """
        let db = try TestFixtureFactory.createTemporary(content: seed)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        // The CURRENT epoch, read back -- fixture creation already bumped it (see the
        // "Shared fixture helpers" note), so a hard-coded literal would be stale and
        // the guard would reject both batches below wholesale.
        let epoch = try db.currentBlockWriteEpoch(projectId: pid)

        let notesBlock = try #require(
            try TestFixtureFactory.fetchBlocks(from: db).first { $0.isNotes && $0.markdownFragment.hasPrefix("[^2]:") }
        )

        // Label-changing update -- refused by the Notes safety net in
        // applyUpdateToExistingBlock -- stamped at a HIGH sequence.
        let refused = BlockChanges(updates: [
            BlockUpdate(id: notesBlock.id, textContent: "First real text.",
                        markdownFragment: "[^1]: First real text.", headingLevel: nil)
        ])
        let refusedResult = try db.applyBlockChangesFromEditor(refused, for: pid, stamp: BlockWriteStamp(epoch: epoch, sequence: 9))
        #expect(!refusedResult.rejectedWholeBatchForStaleEpoch,
                "the refused batch carries the CURRENT epoch -- it must reach the safety net, not be rejected wholesale")
        #expect(refusedResult.writtenUpdateIds.isEmpty,
                "the safety net must have refused the label-changing update — got \(refusedResult.writtenUpdateIds)")
        #expect(refusedResult.droppedUpdateIds.isEmpty,
                "the safety net's refusal is not a write-stamp supersede — got \(refusedResult.droppedUpdateIds)")

        // A later LEGITIMATE (label-preserving) update at a LOWER sequence must still
        // apply -- proving the refused write above was never stamped.
        let legit = BlockChanges(updates: [
            BlockUpdate(id: notesBlock.id, textContent: "new text.",
                        markdownFragment: "[^2]: new text.", headingLevel: nil)
        ])
        let legitResult = try db.applyBlockChangesFromEditor(legit, for: pid, stamp: BlockWriteStamp(epoch: epoch, sequence: 3))

        #expect(!legitResult.rejectedWholeBatchForStaleEpoch,
                "the legitimate batch carries the CURRENT epoch and must not be rejected wholesale")
        #expect(legitResult.droppedUpdateIds.isEmpty,
                "the refused write was never stamped, so this write must not be superseded — got \(legitResult.droppedUpdateIds)")
        let after = try #require(try fetchRow(notesBlock.id, in: db))
        #expect(after.markdownFragment == "[^2]: new text.",
                "a later, lower-sequence legitimate update must still apply — the refused write must never have been stamped")
        #expect(legitResult.writtenUpdateIds == [notesBlock.id],
                "the legitimate update must be reported as written — got \(legitResult.writtenUpdateIds)")
    }

    // MARK: - T7: migration safety

    // Replays the REAL v17 migration against a genuinely v16-shaped database that already
    // holds rows. This deliberately does NOT open the committed `Fixtures/test-fixture.ff`:
    // that file is regenerated at the current schema (mandatory after any migration), so it
    // is already v17-shaped -- and because fixture creation goes through `replaceBlocks`
    // (which bumps the epoch), it carries a non-zero epoch and non-zero row stamps. A test
    // built on it would neither observe defaulted (0, 0) stamps nor exercise an upgrade.
    //
    // Same downgrade-then-reopen recipe as SectionParentPersistenceTests'
    // `migrationBackfillComputesCorrectParentIds`: drop the new columns AND delete the
    // migration's own `grdb_migrations` bookkeeping row (without the row deletion GRDB's
    // migrator would see v17 as already applied and skip it even with the columns gone),
    // then reopen through the normal `ProjectDatabase` init -- production's exact path --
    // so the migrator replays v17 against pre-existing rows.
    @Test("Migrating a v16-shaped database to v17 defaults every row's stamp to (0, 0) and preserves content")
    func migrationFromV16PreservesRowsAndDefaultsStamps() throws {
        let url = URL(fileURLWithPath: "/tmp/claude/v17-migration-\(UUID().uuidString).ff")
        defer { try? FileManager.default.removeItem(at: url) }

        let projectId: String
        let textByIdBefore: [String: String]

        // Scoped so the first ProjectDatabase (and its DatabasePool connections) is
        // released before the file is reopened below, rather than relying on Swift's
        // last-use release timing.
        do {
            let db = try TestFixtureFactory.createFixture(
                at: url,
                content: "# Alpha\n\nfirst paragraph.\n\n## Beta\n\nsecond paragraph.\n"
            )
            projectId = try TestFixtureFactory.getProjectId(from: db)

            // Ground truth for content preservation, recorded BEFORE the downgrade. Raw SQL
            // so it does not depend on `Block` decoding either side of the migration.
            textByIdBefore = try db.dbWriter.read { database -> [String: String] in
                var texts: [String: String] = [:]
                for row in try Row.fetchAll(
                    database, sql: "SELECT id, textContent FROM block WHERE projectId = ?",
                    arguments: [projectId]
                ) {
                    let id: String = row["id"]
                    let text: String = row["textContent"]
                    texts[id] = text
                }
                return texts
            }
            #expect(textByIdBefore.count >= 4,
                    "expected the fixture to hold real rows (2 headings + 2 paragraphs) before the downgrade — got \(textByIdBefore.count)")

            // Downgrade to a GENUINELY v16-shaped database. Legal: v17 is the only thing that
            // adds these columns, and nothing indexes, references, or triggers on them
            // (the v17 migration -- registered in ProjectDatabase.swift, body in
            // Database+BlockWriteStamp.swift -- adds them as plain NOT NULL DEFAULT 0).
            try db.dbWriter.write { database in
                try database.execute(sql: "ALTER TABLE block DROP COLUMN lastWriteEpoch")
                try database.execute(sql: "ALTER TABLE block DROP COLUMN lastWriteSequence")
                try database.execute(sql: "ALTER TABLE project DROP COLUMN blockWriteEpoch")
                try database.execute(
                    sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                    arguments: ["v17_block_write_stamp"]
                )
            }

            // Precondition: the downgrade really happened. Without this, a silently failed
            // drop would leave the columns in place and the assertions below would pass
            // without ever exercising the migration.
            let schemaBefore = try readSchemaSnapshot(of: db)
            #expect(!schemaBefore.blockColumns.contains("lastWriteEpoch"), "precondition: block.lastWriteEpoch must be gone before reopening")
            #expect(!schemaBefore.blockColumns.contains("lastWriteSequence"), "precondition: block.lastWriteSequence must be gone before reopening")
            #expect(!schemaBefore.projectColumns.contains("blockWriteEpoch"), "precondition: project.blockWriteEpoch must be gone before reopening")
            #expect(schemaBefore.v17Rows == 0, "precondition: v17's bookkeeping row must be gone before reopening — got \(schemaBefore.v17Rows)")
        }

        // Reopen through the normal ProjectDatabase init -- production's exact path -- which
        // runs every pending migration. This is where v17 actually executes, against the
        // pre-existing rows above, which have no stamp columns at all until it re-adds them.
        let package = try ProjectPackage.open(at: url)
        let migratedDb = try ProjectDatabase(package: package)

        // Raw SQL throughout -- `Block`/`Project` deliberately do not declare these
        // columns (Database+BlockWriteStamp.swift), so this is the only way to read them.
        let schemaAfter = try readSchemaSnapshot(of: migratedDb)
        let projectEpoch = try migratedDb.dbWriter.read { database in
            try Int64.fetchOne(
                database, sql: "SELECT blockWriteEpoch FROM project WHERE id = ?",
                arguments: [projectId]
            )
        }

        #expect(
            schemaAfter.v17Rows == 1,
            """
            the v17 migration must have actually RUN again (bookkeeping row re-recorded), \
            not merely left the columns alone — got \(schemaAfter.v17Rows)
            """
        )
        #expect(schemaAfter.blockColumns.contains("lastWriteEpoch"), "block.lastWriteEpoch must exist again after the migration replays")
        #expect(schemaAfter.blockColumns.contains("lastWriteSequence"), "block.lastWriteSequence must exist again after the migration replays")
        #expect(schemaAfter.projectColumns.contains("blockWriteEpoch"), "project.blockWriteEpoch must exist again after the migration replays")
        #expect(projectEpoch == 0, "a migrated project's epoch must default to 0 — got \(String(describing: projectEpoch))")

        let stampRows = try migratedDb.dbWriter.read { database -> [MigratedBlockRow] in
            var rows: [MigratedBlockRow] = []
            for row in try Row.fetchAll(
                database,
                sql: "SELECT id, lastWriteEpoch, lastWriteSequence, textContent FROM block WHERE projectId = ?",
                arguments: [projectId]
            ) {
                let id: String = row["id"]
                let epoch: Int64 = row["lastWriteEpoch"]
                let sequence: Int64 = row["lastWriteSequence"]
                let text: String = row["textContent"]
                rows.append(MigratedBlockRow(id: id, epoch: epoch, sequence: sequence, text: text))
            }
            return rows
        }

        #expect(!stampRows.isEmpty, "expected the pre-existing block rows to survive the migration")
        for row in stampRows {
            #expect(row.epoch == 0, "every pre-existing row must default to epoch 0 — block \(row.id) got \(row.epoch)")
            #expect(row.sequence == 0, "every pre-existing row must default to sequence 0 — block \(row.id) got \(row.sequence)")
        }

        // Content/count preserved: not a single row lost, added, or altered.
        #expect(stampRows.count == textByIdBefore.count,
                "block count must be unchanged by the migration — got \(stampRows.count), had \(textByIdBefore.count)")
        let textByIdAfter = Dictionary(stampRows.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        #expect(Set(textByIdAfter.keys) == Set(textByIdBefore.keys),
                "the migration must neither lose nor invent block ids")
        for (id, textBefore) in textByIdBefore {
            #expect(
                textByIdAfter[id] == textBefore,
                """
                block \(id) must survive the migration with its text unchanged — \
                before \"\(textBefore)\", after \(String(describing: textByIdAfter[id]))
                """
            )
        }

        // Reopening through the normal record-decoding path must also still work.
        let blocksViaRecord = try TestFixtureFactory.fetchBlocks(from: migratedDb)
        #expect(blocksViaRecord.count == stampRows.count,
                "record-decoded block count must match the raw row count — got \(blocksViaRecord.count) vs \(stampRows.count)")

        // The upgraded database must be immediately usable by the guard. The stamp's epoch is
        // read back from the database, never hard-coded.
        let epoch = try migratedDb.currentBlockWriteEpoch(projectId: projectId)
        let target = try #require(
            blocksViaRecord.first { $0.blockType == .paragraph && $0.textContent.contains("first paragraph") },
            "expected the Alpha paragraph to survive the migration"
        )
        let result = try migratedDb.applyBlockChangesFromEditor(
            BlockChanges(updates: [
                BlockUpdate(id: target.id, textContent: "edited after migration", markdownFragment: nil, headingLevel: nil)
            ]),
            for: projectId, stamp: BlockWriteStamp(epoch: epoch, sequence: 1)
        )

        #expect(!result.rejectedWholeBatchForStaleEpoch,
                "a batch carrying the migrated project's CURRENT epoch must not be rejected wholesale")
        #expect(result.writtenUpdateIds == [target.id],
                "the first batch after migration must be written — got \(result.writtenUpdateIds)")
        #expect(result.droppedUpdateIds.isEmpty,
                "a (epoch, 1) batch must not be superseded by a migrated (0, 0) row — got \(result.droppedUpdateIds)")
        let edited = try #require(try fetchRow(target.id, in: migratedDb))
        #expect(edited.textContent == "edited after migration",
                "the update must actually land on the migrated row — got \(edited.textContent)")
        let storedStamp = try migratedDb.dbWriter.read { database -> BlockWriteStamp? in
            guard let row = try Row.fetchOne(
                database, sql: "SELECT lastWriteEpoch, lastWriteSequence FROM block WHERE id = ?",
                arguments: [target.id]
            ) else { return nil }
            let storedEpoch: Int64 = row["lastWriteEpoch"]
            let storedSequence: Int64 = row["lastWriteSequence"]
            return BlockWriteStamp(epoch: storedEpoch, sequence: storedSequence)
        }
        #expect(storedStamp == BlockWriteStamp(epoch: epoch, sequence: 1),
                "the written row must carry the batch's stamp — got \(String(describing: storedStamp))")
    }
}
