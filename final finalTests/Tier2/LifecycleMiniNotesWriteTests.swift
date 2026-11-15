//
//  LifecycleMiniNotesWriteTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C1 (slice-3a-1b-everyday.md §5.1 item 5, obligations 17 and N17 / N33):
//  the zoomed whole-document write ("FB") now carries the zoom panel's mini-Notes text. In the SAME
//  transaction, and BEFORE the range replace, `LifecycleWholeDocumentWrite.body` writes the mini-Notes
//  definitions back to the project's Notes rows when the write is zoomed and the text is non-empty.
//  A failure of that write is logged and NON-FATAL: it must not stop the range replace (N33), and its own
//  partial work must not survive (it runs in a savepoint).
//
//  Shares `makeStack` / `TestStack` (BlockSyncPollWatchdogTests.swift) with the other FB tests.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Lifecycle whole-document write: mini-Notes — Tier 2 (t-94369a83 3a-1b C1)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct LifecycleMiniNotesWriteTests {

    private static let seed = """
    # Alpha

    Alpha body[^1].

    # Beta

    Beta body.

    # Notes

    [^1]: Original note.
    """

    private static let zoomedContent = """
    # Alpha

    Alpha body edited[^1].

    <!-- ::zoom-notes:: -->

    [^1]: Edited note.
    """

    /// What a zoomed flush would carry for Alpha: the range from Alpha's heading up to Beta's heading.
    private struct Zoom {
        let alphaId: String
        let range: (start: Double, end: Double?)
        let betaId: String
        let notesHeadingId: String
    }

    private func zoomOnAlpha(_ db: ProjectDatabase) throws -> Zoom {
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let alpha = try #require(blocks.first { $0.blockType == .heading && $0.textContent == "Alpha" })
        let beta = try #require(blocks.first { $0.blockType == .heading && $0.textContent == "Beta" })
        let notesHeading = try #require(blocks.first { $0.isNotes && $0.blockType == .heading })
        try #require(blocks.contains { $0.isNotes && $0.markdownFragment == "[^1]: Original note." },
                     "precondition: the fixture must have a Notes definition row")
        return Zoom(alphaId: alpha.id, range: (start: alpha.sortOrder, end: beta.sortOrder),
                    betaId: beta.id, notesHeadingId: notesHeading.id)
    }

    private func applyZoomedFB(
        _ stack: TestStack, content: String, zoom: Zoom
    ) async throws -> SystemWriteResult<LifecycleWholeDocumentWriteValue> {
        let prepared = try #require(LifecycleWholeDocumentWrite.prepare(
            content: content, database: stack.db, projectId: stack.pid,
            zoomedRange: AnchoredSortOrderRange(unanchored: zoom.range), zoomedSectionId: zoom.alphaId))
        return await stack.sync.performLifecycleWholeDocumentWrite(
            identity: SystemWriteIdentity(projectId: stack.pid, database: stack.db), prepared: prepared)
    }

    // MARK: - Pre-parsed in prepare

    @Test("prepare pre-parses the zoom-notes text into definitions (so the write transaction does no parsing); not zoomed -> none")
    func prepare_preParsesMiniNoteDefinitions() throws {
        let stack = try makeStack(content: Self.seed)
        let zoom = try zoomOnAlpha(stack.db)

        let zoomed = try #require(LifecycleWholeDocumentWrite.prepare(
            content: Self.zoomedContent, database: stack.db, projectId: stack.pid,
            zoomedRange: AnchoredSortOrderRange(unanchored: zoom.range), zoomedSectionId: zoom.alphaId))
        #expect(zoomed.miniNotes == "[^1]: Edited note.")
        #expect(zoomed.miniNoteDefinitions == ["1": "Edited note."])

        let notZoomed = try #require(LifecycleWholeDocumentWrite.prepare(
            content: Self.zoomedContent, database: stack.db, projectId: stack.pid,
            zoomedRange: nil, zoomedSectionId: nil))
        #expect(notZoomed.miniNotes == nil, "mini-Notes are carried for a zoomed write only (as flushContentToDatabase does)")
        #expect(notZoomed.miniNoteDefinitions.isEmpty)
    }

    // MARK: - The write

    @Test("""
        A zoomed FB writes the mini-Notes definitions into the Notes rows AND replaces the range, in ONE \
        transaction: the edited note and the edited body are both in the database, one epoch bump, outside the range untouched
        """)
    func zoomedFB_writesMiniNotesAndRange_inOneTransaction() async throws {
        let stack = try makeStack(content: Self.seed)
        let zoom = try zoomOnAlpha(stack.db)
        let epochBefore = try stack.db.currentBlockWriteEpoch(projectId: stack.pid)

        let result = try await applyZoomedFB(stack, content: Self.zoomedContent, zoom: zoom)

        guard case .applied = result.outcome else {
            Issue.record("expected the zoomed FB to apply, got \(result.outcome)")
            return
        }
        let after = try TestFixtureFactory.fetchBlocks(from: stack.db)
        #expect(after.contains { $0.textContent.contains("Alpha body edited") }, "the range replace must have landed")
        #expect(after.contains { $0.isNotes && $0.markdownFragment == "[^1]: Edited note." },
                "the mini-Notes definition must have been written to the Notes rows")
        #expect(!after.contains { $0.markdownFragment == "[^1]: Original note." })
        #expect(after.first { $0.isNotes && $0.blockType == .heading }?.id == zoom.notesHeadingId,
                "the Notes heading keeps its id (scroll stability, as the mini-Notes sync always did)")
        #expect(after.first { $0.id == zoom.betaId }?.textContent == "Beta", "rows outside the range are untouched")
        #expect(after.contains { $0.textContent == "Beta body." })
        #expect(try stack.db.currentBlockWriteEpoch(projectId: stack.pid) == epochBefore + 1,
                "the mini-Notes write adds no epoch bump of its own: FB's replace is the one bump")
        #expect(stack.sync.testWriterLedger.lifecycleWholeDocumentApplied == 1)
        #expect(stack.sync.testWriterLedger.lifecycleWholeDocumentLost == 0)
    }

    @Test("""
        N33: a mini-Notes write that THROWS is non-fatal -- the range replace still persists, FB is applied (not lost), \
        and the failed write left the Notes rows exactly as they were (its own work rolled back, not half done)
        """)
    func zoomedFB_miniNotesWriteThrows_rangeReplaceStillPersists() async throws {
        let stack = try makeStack(content: Self.seed)
        let zoom = try zoomOnAlpha(stack.db)
        let before = try TestFixtureFactory.fetchBlocks(from: stack.db).filter(\.isNotes).map(\.id)

        // Every insert of a Notes row aborts. The mini-Notes write deletes the Notes rows first and
        // inserts afterwards, so without its savepoint the delete would already have happened.
        try stack.db.write { db in
            try db.execute(sql: """
                CREATE TRIGGER failMiniNotesInsert BEFORE INSERT ON block WHEN NEW.isNotes = 1
                BEGIN SELECT RAISE(ABORT, 'mini-notes insert refused (test)'); END
                """)
        }

        let result = try await applyZoomedFB(stack, content: Self.zoomedContent, zoom: zoom)

        guard case .applied = result.outcome else {
            Issue.record("a failing mini-Notes write must not fail FB; got \(result.outcome)")
            return
        }
        let after = try TestFixtureFactory.fetchBlocks(from: stack.db)
        #expect(after.contains { $0.textContent.contains("Alpha body edited") },
                "the range replace must persist although the mini-Notes write threw")
        #expect(after.filter(\.isNotes).map(\.id) == before, "the failed mini-Notes write must leave the Notes rows untouched")
        #expect(after.contains { $0.isNotes && $0.markdownFragment == "[^1]: Original note." })
        let ledger = stack.sync.testWriterLedger
        #expect(ledger.lifecycleWholeDocumentApplied == 1)
        #expect(ledger.lifecycleWholeDocumentLost == 0, "N33: a mini-Notes failure is not a lost FB")
    }

    @Test("""
        N17: an empty miniNotes string is handled explicitly and matches flushContentToDatabase (skip when empty): \
        nothing is written to the Notes rows, and the range replace still lands
        """)
    func zoomedFB_emptyMiniNotes_skipsTheNotesWrite() async throws {
        let stack = try makeStack(content: Self.seed)
        let zoom = try zoomOnAlpha(stack.db)
        let notesBefore = try TestFixtureFactory.fetchBlocks(from: stack.db).filter(\.isNotes).map { "\($0.id)|\($0.markdownFragment)" }

        let prepared = LifecycleWholeDocumentPrepared(
            blocks: BlockParser.parse(markdown: "# Alpha\n\nAlpha body edited[^1].\n", projectId: stack.pid),
            projectId: stack.pid, range: AnchoredSortOrderRange(unanchored: zoom.range), anchorHeadingId: zoom.alphaId, miniNotes: "")
        #expect(prepared.miniNoteDefinitions.isEmpty)
        let result = await stack.sync.performLifecycleWholeDocumentWrite(
            identity: SystemWriteIdentity(projectId: stack.pid, database: stack.db), prepared: prepared)

        guard case .applied = result.outcome else {
            Issue.record("expected the zoomed FB to apply, got \(result.outcome)")
            return
        }
        let after = try TestFixtureFactory.fetchBlocks(from: stack.db)
        #expect(after.filter(\.isNotes).map { "\($0.id)|\($0.markdownFragment)" } == notesBefore,
                "an empty mini-Notes text must not touch the Notes rows")
        #expect(after.contains { $0.textContent.contains("Alpha body edited") })
    }

    @Test("A whole-document (not zoomed) FB never writes mini-Notes, even when the content carries the zoom-notes marker")
    func wholeDocumentFB_neverWritesMiniNotes() async throws {
        let stack = try makeStack(content: Self.seed)
        let prepared = try #require(LifecycleWholeDocumentWrite.prepare(
            content: Self.zoomedContent, database: stack.db, projectId: stack.pid, zoomedRange: nil, zoomedSectionId: nil))

        let result = await stack.sync.performLifecycleWholeDocumentWrite(
            identity: SystemWriteIdentity(projectId: stack.pid, database: stack.db), prepared: prepared)

        guard case .applied = result.outcome else {
            Issue.record("expected the whole-document FB to apply, got \(result.outcome)")
            return
        }
        let after = try TestFixtureFactory.fetchBlocks(from: stack.db)
        #expect(!after.contains { $0.markdownFragment == "[^1]: Edited note." }, "mini-Notes are written for a zoomed write only")
    }
}
