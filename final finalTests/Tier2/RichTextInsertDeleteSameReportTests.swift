//
//  RichTextInsertDeleteSameReportTests.swift
//  final finalTests
//
//  t-80274c66: a paragraph made with Return and removed again before its insert was saved used to leave a row the editor no
//  longer had: the report carried the paragraph's insert AND its delete, the database applies a report's deletes before its
//  inserts, so the delete found nothing and the insert then made the row. The page no longer sends such a pair (report-outbox.ts
//  `applyOps`); these drive the Swift side directly, through the real Rich Text report entry, the real writer and database, so
//  they prove the second line of defence (`ProjectDatabase.cancellingInsertsDeletedInSameBatch`) on its own.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("A paragraph inserted and deleted in one report leaves no saved row (t-80274c66)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct RichTextInsertDeleteSameReportTests {
    static let threeBlocks = "# Chapter\n\nMiddle paragraph.\n\nLast paragraph."

    private func rig(_ content: String) throws -> TestStack {
        let stack = try makeStack(content: content)
        let js = ScriptedJSEvaluator()
        stack.sync.testJSEvaluator = { try await js.evaluate($0) }
        stack.editorState.projectDatabase = stack.db
        stack.editorState.currentProjectId = stack.pid
        return stack
    }

    /// Every row, empty ones included (the stray row an Enter leaves is EMPTY, which the assembly helpers skip).
    private func rowCount(_ db: ProjectDatabase) throws -> Int {
        try TestFixtureFactory.fetchBlocks(from: db).count
    }

    private func fragments(_ db: ProjectDatabase) throws -> [String] {
        MarkdownBlockDiff.assemblyOrderedNonEmpty(try TestFixtureFactory.fetchBlocks(from: db)).map(\.markdownFragment)
    }

    private func rowId(_ db: ProjectDatabase, startingWith prefix: String) throws -> String {
        try #require(try TestFixtureFactory.fetchBlocks(from: db).first { $0.markdownFragment.hasPrefix(prefix) }).id
    }

    private func paragraph(_ tempId: String, _ text: String, after anchorId: String?, atDocumentStart: Bool? = nil) -> BlockInsert {
        BlockInsert(tempId: tempId, blockType: "paragraph", textContent: text, markdownFragment: text,
                    headingLevel: nil, afterBlockId: anchorId, atDocumentStart: atDocumentStart)
    }

    private final class Minted { var ids: [String: String] = [:] }

    /// One report through the real Rich Text report path (applyReportBatch -> applyFetchedBatch -> applyAndConfirm -> the writer).
    private func applyReport(_ stack: TestStack, _ changes: BlockChanges) async throws -> [String: String] {
        let (ticket, stamp) = try #require(stack.sync.reserveWriterTurn(database: stack.db, projectId: stack.pid))
        ticket.noteFetched()
        let minted = Minted()
        await stack.sync.applyReportBatch(
            ticket: ticket, stamp: stamp, changes: changes, abandonAfterTurn: { false }, onApplied: { minted.ids = $0 })
        ticket.settleIfOpen(.noBatch)
        return minted.ids
    }

    @Test("S1: a report with the insert and the delete of one empty paragraph creates no row and confirms no id")
    func insertAndDeleteOfOneParagraphLeaveNoRow() async throws {
        let stack = try rig(Self.threeBlocks)
        let countBefore = try rowCount(stack.db)
        let textBefore = try fragments(stack.db)
        let middle = try rowId(stack.db, startingWith: "Middle paragraph.")
        let minted = try await applyReport(stack, BlockChanges(
            inserts: [paragraph("temp-stray-1", "", after: middle)], deletes: ["temp-stray-1"]))
        #expect(try rowCount(stack.db) == countBefore, "no row is created for a paragraph the same report deletes")
        #expect(try fragments(stack.db) == textBefore, "the document reads as before")
        #expect(minted["temp-stray-1"] == nil, "no id is confirmed for a paragraph that was never saved")
    }

    @Test("S2: a paragraph chained after the cancelled one is placed where the chain put it")
    func chainedInsertReanchorsPastTheCancelledOne() async throws {
        let stack = try rig(Self.threeBlocks)
        let countBefore = try rowCount(stack.db)
        let middle = try rowId(stack.db, startingWith: "Middle paragraph.")
        let minted = try await applyReport(stack, BlockChanges(
            inserts: [paragraph("temp-stray-2a", "", after: middle),
                      paragraph("temp-stray-2b", "Kept paragraph.", after: "temp-stray-2a")],
            deletes: ["temp-stray-2a"]))
        #expect(try rowCount(stack.db) == countBefore + 1, "only the kept paragraph gets a row")
        #expect(try fragments(stack.db) == ["# Chapter", "Middle paragraph.", "Kept paragraph.", "Last paragraph."],
                "the kept paragraph sits right after the middle one")
        #expect(minted["temp-stray-2b"] != nil, "the kept paragraph's id is confirmed")
        #expect(minted["temp-stray-2a"] == nil, "the cancelled paragraph's id is not")
    }

    @Test("S3: a chain at the document start keeps the start when its first paragraph is cancelled")
    func chainAtDocumentStartKeepsTheStart() async throws {
        let stack = try rig(Self.threeBlocks)
        let countBefore = try rowCount(stack.db)
        _ = try await applyReport(stack, BlockChanges(
            inserts: [paragraph("temp-stray-3a", "", after: nil, atDocumentStart: true),
                      paragraph("temp-stray-3b", "Opening paragraph.", after: "temp-stray-3a")],
            deletes: ["temp-stray-3a"]))
        #expect(try rowCount(stack.db) == countBefore + 1, "only the opening paragraph gets a row")
        #expect(try fragments(stack.db).first == "Opening paragraph.", "it is the first block of the document")
    }

    @Test("S4: the database entry reports the cancelled insert and writes nothing for it")
    func databaseEntryReportsTheCancelledInsert() throws {
        let db = try TestFixtureFactory.createTemporary(content: Self.threeBlocks)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let countBefore = try rowCount(db)
        let middle = try rowId(db, startingWith: "Middle paragraph.")
        let result = try db.applyBlockChangesFromEditor(
            BlockChanges(
                updates: [BlockUpdate(id: "temp-stray-4", textContent: "typed", markdownFragment: "typed",
                                      headingLevel: nil, blockType: "paragraph")],
                inserts: [paragraph("temp-stray-4", "", after: middle)],
                deletes: ["temp-stray-4"]),
            for: pid, stamp: .unguarded, renumberSortOrdersIfCrowded: true)
        #expect(result.cancelledInsertIds == ["temp-stray-4"], "the insert is cancelled by the delete in the same batch")
        #expect(result.idMapping.isEmpty, "nothing is minted")
        #expect(result.writtenDeleteIds.isEmpty && result.writtenUpdateIds.isEmpty, "nothing else is written for it")
        #expect(try rowCount(db) == countBefore, "no row was created")
    }

    @Test("S5: an insert and a delete of DIFFERENT blocks in one report both still apply")
    func differentBlocksStillApply() async throws {
        let stack = try rig(Self.threeBlocks)
        let middle = try rowId(stack.db, startingWith: "Middle paragraph.")
        let last = try rowId(stack.db, startingWith: "Last paragraph.")
        let minted = try await applyReport(stack, BlockChanges(
            inserts: [paragraph("temp-new-5", "New paragraph.", after: middle)], deletes: [last]))
        #expect(try fragments(stack.db) == ["# Chapter", "Middle paragraph.", "New paragraph."])
        #expect(minted["temp-new-5"] != nil)
    }
}
