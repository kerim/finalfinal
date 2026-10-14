//
//  DocumentWriterTests+BlockType.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-2, Step 1 (plan-v2 U-B1 case f): `BlockUpdate.blockType` must survive the two places
//  `DocumentWriter` REBUILDS a `BlockUpdate` field by field -- `resolveTempIds` (an update naming a temp id an earlier
//  sequence already minted) and `resolvedForRelease` (a held update released when its temp id is finally minted).
//  A rebuild that forgets the new field drops it silently: the row would then stay a paragraph with a list's text,
//  exactly the bug Step 1 fixes, but only on these two paths.
//
//  Same-suite context: an extension of `DocumentWriterTests` (Tier 2), sharing `makeWriterStack`/`stamp`, like
//  DocumentWriterLateBoundTests.swift. Models W6 (resolve) and W7 (hold, then release on a late apply).
//

import Foundation
import Testing
@testable import final_final

extension DocumentWriterTests {

    // WB1: the resolve rebuild
    @Test("An update naming an already-minted temp id keeps its blockType through the writer's rebuild")
    func tempIdResolvedUpdate_keepsBlockType() async throws {
        let (db, pid, writer, blockA, _) = try makeWriterStack()
        let result1 = await writer.applyEditorBatch(1, BlockChanges(inserts: [
            BlockInsert(tempId: "temp-wb1-1", blockType: "paragraph", textContent: "created",
                        markdownFragment: "created", headingLevel: nil, afterBlockId: blockA.id, atDocumentStart: nil)
        ]), stamp: try stamp(db, pid, 1))
        guard case .applied(let applied1) = result1, let permanentId = applied1.idMapping["temp-wb1-1"] else {
            Issue.record("expected seq 1 to mint temp-wb1-1, got \(result1)")
            return
        }

        let result2 = await writer.applyEditorBatch(2, BlockChanges(
            updates: [BlockUpdate(id: "temp-wb1-1", textContent: "created", markdownFragment: "- created",
                                  headingLevel: nil, blockType: "bullet_list")]
        ), stamp: try stamp(db, pid, 2))
        guard case .applied = result2 else {
            Issue.record("expected seq 2 to apply, got \(result2)")
            return
        }

        let row = try #require(try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == permanentId })
        #expect(row.blockType == .bulletList, "the rebuild in resolveTempIds dropped blockType; row is \(row.blockType)")
    }

    // WB2: the held-op release rebuild
    @Test("A held update keeps its blockType when it is released onto the newly minted row")
    func heldUpdate_keepsBlockTypeOnRelease() async throws {
        let (db, pid, writer, blockA, _) = try makeWriterStack()
        writer.testLateAfterSeconds = 0.2

        let expired1 = WriterEventSignal(matching: { if case .expired(1) = $0 { return true }; return false })
        let held2 = WriterEventSignal(matching: { if case .held(2, 1) = $0 { return true }; return false })
        writer.testEventHandler = { event in
            expired1.note(event)
            held2.note(event)
        }

        _ = writer.reserve()   // seq 1: never fetched -- stays .reserved until it expires

        let ticket2 = writer.reserve()
        ticket2.noteFetched()
        let stamp2 = try stamp(db, pid, 2)
        let cycle2 = Task { () -> WriterApplyOutcome in
            guard await ticket2.waitForTurn() == .go else { return .refused(.skipped) }
            return await writer.applyEditorBatch(2, BlockChanges(
                updates: [BlockUpdate(id: "temp-wb2-1", textContent: "seq2 edit", markdownFragment: "- seq2 edit",
                                      headingLevel: nil, blockType: "bullet_list")]
            ), stamp: stamp2)
        }
        await expired1.wait()
        await held2.wait()
        let result2 = await cycle2.value
        guard case .applied = result2 else {
            Issue.record("seq2 must apply once seq1 goes late, got \(result2)")
            return
        }

        let result1 = await writer.applyEditorBatch(1, BlockChanges(inserts: [
            BlockInsert(tempId: "temp-wb2-1", blockType: "paragraph", textContent: "created",
                        markdownFragment: "created", headingLevel: nil, afterBlockId: blockA.id, atDocumentStart: nil)
        ]), stamp: try stamp(db, pid, 1))
        guard case .applied(let applied1) = result1, let permanentId = applied1.idMapping["temp-wb2-1"] else {
            Issue.record("expected seq 1 to apply late and mint temp-wb2-1, got \(result1)")
            return
        }

        let row = try #require(try TestFixtureFactory.fetchBlocks(from: db).first { $0.id == permanentId })
        #expect(row.markdownFragment == "- seq2 edit", "the held update must cascade onto the minted row")
        #expect(row.blockType == .bulletList, "the rebuild in resolvedForRelease dropped blockType; row is \(row.blockType)")
        #expect(writer.ledger.heldOpsResolved == 1, "the held update must have been applied, not dropped: \(writer.ledger)")
    }
}
