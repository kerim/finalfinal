//
//  ModeSwitchFlushSkipTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Step 2b of the book-length switch plan (plan-book-length-switch.md; the judge's must-fix 3 and the sync model's
//  "Phase 3b step T" section in docs/architecture/tla/README.md). The save that runs at every Markdown <-> Rich Text switch
//  (`EditorViewState.flushContentToDatabase`, called by `handleEditorModeToggle`) used to delete and reinsert every row, give
//  every non-heading block a new id and bump the write counter, even when nothing had changed. It now passes
//  `skipUnchangedWrite: true`, and `ProjectDatabase.replaceBlocksIfChanged` writes nothing when the rows already stored are the
//  rows the parse would store (the rule close and quit use: `LifecycleWholeDocumentWrite.matchingRowCount`).
//
//  WHY THESE TESTS AND NOT THE MODEL. The TLA+ model SEES the write counter (a skip does not bump it, and that is what the model
//  checked) but NOT row ids: its replace keeps every id, so "every switch gives non-heading blocks new ids" (before) and "an
//  unchanged switch keeps the ids" (after) are the same model. The ids are why this file exists. The Rich Text editor still holds
//  the ids it was given when the document was last loaded, and its next per-block update is addressed to one of them, so a skip
//  that changed an id (or a write that failed to) would silently send the user's next edit to a row that no longer exists.
//
//  What each test pins (the document is the shared fixture `ComplexDocumentFixture.article`, 138 rows, seeded the way the app
//  seeds a project, with the editor text assembled from the stored rows the way `editorState.content` is):
//   - an unchanged switch leaves every row, every row id and every row's write stamp, and the project's write counter, untouched;
//   - after such a skipped flush a per-block update addressed to a pre-switch NON-heading id lands on that row (and, as the
//     control, after a flush that does not skip that id is gone, so the test would notice if the skip stopped keeping ids);
//   - one changed character is written and stored; same text with a changed block type is written; a near tie among the stored
//     sort numbers is written (and renumbered);
//   - a zoomed flush never skips, whatever the flag says.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Mode-switch flush skips an unchanged write — Tier 1: Silent Killers", .serialized)
@MainActor
struct ModeSwitchFlushSkipTests {

    // MARK: - Fixture

    private struct Fixture {
        let db: ProjectDatabase
        let pid: String
        let state: EditorViewState
        let stored: [Block]
        /// What the Rich Text editor holds after a load: the stored rows assembled for the editor.
        let content: String
    }

    private func makeFixture() throws -> Fixture {
        let db = try TestFixtureFactory.createTemporary(content: ComplexDocumentFixture.article.editorMarkdown)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let stored = try db.fetchBlocks(projectId: pid)
        let state = EditorViewState()
        state.projectDatabase = db
        state.currentProjectId = pid
        return Fixture(db: db, pid: pid, state: state, stored: stored, content: BlockParser.assembleMarkdownForEditor(from: stored))
    }

    private struct Snapshot: Equatable {
        let rows: [Block]
        let stamps: [BlockWriteStamp?]
        let epoch: Int64
    }

    private func snapshot(_ db: ProjectDatabase, _ pid: String) throws -> Snapshot {
        let rows = try db.fetchBlocks(projectId: pid).sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
        let stamps = try db.dbWriter.read { database in
            try rows.map { try ProjectDatabase.storedStamp(db: database, blockId: $0.id) }
        }
        return Snapshot(rows: rows, stamps: stamps, epoch: try db.currentBlockWriteEpoch(projectId: pid))
    }

    /// The parse a flush of `text` makes, for the DB-level tests.
    private func parse(_ text: String, _ fixture: Fixture) -> [Block] {
        BlockParser.parse(markdown: text, projectId: fixture.pid)
    }

    /// A body paragraph (not Notes, not bibliography) with plain text at its start, from the stored rows.
    private func bodyParagraph(_ fixture: Fixture) throws -> Block {
        try #require(fixture.stored.first {
            $0.blockType == .paragraph && !$0.isBibliography && !$0.isNotes && $0.markdownFragment.first?.isLetter == true
        })
    }

    /// `fixture.content` with the first letter of `paragraph` changed to another letter: one changed character.
    private func contentWithOneChangedCharacter(_ fixture: Fixture, paragraph: Block) throws -> (content: String, altered: String) {
        let original = paragraph.markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement: Character = original.first == "Q" ? "X" : "Q"
        let altered = String(replacement) + original.dropFirst()
        let range = try #require(fixture.content.range(of: "\n\n" + original + "\n\n"), "the paragraph stands alone between blank lines")
        return (fixture.content.replacingCharacters(in: range, with: "\n\n" + altered + "\n\n"), altered)
    }

    // MARK: - (a) An unchanged switch leaves every id and the write stamp alone

    @Test("(a) an unchanged switch flush writes nothing: same rows, same ids, same row stamps, same write counter")
    func unchangedSwitchFlushLeavesEverythingUntouched() throws {
        let fixture = try makeFixture()
        let before = try snapshot(fixture.db, fixture.pid)
        #expect(before.rows.count == 138, "the shared x1 fixture parses to 138 rows")

        fixture.state.flushContentToDatabase(overrideContent: fixture.content, skipUnchangedWrite: true)

        let after = try snapshot(fixture.db, fixture.pid)
        let difference = LifecycleWholeDocumentWrite.firstDifference(
            stored: fixture.stored, wouldWrite: ProjectDatabase.preparedRowsForWholeReplace(
                existing: BlockParser.assemblySorted(fixture.stored), parsed: parse(fixture.content, fixture)))
        #expect(difference == nil, "precondition: the stored rows are what the editor text would store (\(difference ?? ""))")
        #expect(after.epoch == before.epoch, "no write: the write counter is not bumped")
        #expect(after.rows.map(\.id) == before.rows.map(\.id), "every row id is unchanged, headings and non-headings alike")
        #expect(after.stamps == before.stamps, "no row's write stamp moved")
        #expect(after == before, "nothing at all was written")
    }

    @Test("control: the same flush WITHOUT the flag rewrites every row, so the non-heading ids change and the counter moves")
    func flushWithoutTheFlagStillRewrites() throws {
        let fixture = try makeFixture()
        let before = try snapshot(fixture.db, fixture.pid)

        fixture.state.flushContentToDatabase(overrideContent: fixture.content)

        let after = try snapshot(fixture.db, fixture.pid)
        #expect(after.epoch == before.epoch + 1, "the whole-project rewrite bumped the write counter")
        let beforeNonHeadingIds = Set(before.rows.filter { $0.blockType != .heading }.map(\.id))
        let afterNonHeadingIds = Set(after.rows.filter { $0.blockType != .heading }.map(\.id))
        #expect(beforeNonHeadingIds.isDisjoint(with: afterNonHeadingIds),
                "non-heading blocks get new ids on a rewrite (this is what the skip avoids)")
    }

    // MARK: - (b) A per-block update to a pre-switch id still lands

    @Test("(b) after a skipped flush, a per-block update addressed to a pre-switch non-heading id lands on that row")
    func updateToAPreSwitchIdLandsAfterASkippedFlush() throws {
        let fixture = try makeFixture()
        let paragraph = try bodyParagraph(fixture)
        let rowCount = fixture.stored.count

        fixture.state.flushContentToDatabase(overrideContent: fixture.content, skipUnchangedWrite: true)

        let newText = "Edited after the switch."
        try fixture.db.applyBlockChangesFromEditor(
            BlockChanges(updates: [BlockUpdate(id: paragraph.id, textContent: newText, markdownFragment: newText, headingLevel: nil)]),
            for: fixture.pid)

        let landed = try #require(try fixture.db.fetchBlock(id: paragraph.id), "the row with the pre-switch id still exists")
        #expect(landed.markdownFragment == newText)
        #expect(landed.textContent == newText)
        #expect(try fixture.db.fetchBlocks(projectId: fixture.pid).count == rowCount, "the update replaced text, it did not add or drop a row")
    }

    @Test("control: after a flush that does not skip, the pre-switch non-heading id is gone, so the same update would land nowhere")
    func updateToAPreSwitchIdIsLostAfterARewrite() throws {
        let fixture = try makeFixture()
        let paragraph = try bodyParagraph(fixture)

        fixture.state.flushContentToDatabase(overrideContent: fixture.content)

        #expect(try fixture.db.fetchBlock(id: paragraph.id) == nil, "a rewrite gave the paragraph a new id; this is the hazard the skip removes")
    }

    // MARK: - Anything that differs is written

    @Test("one changed character is written and stored (flush)")
    func oneChangedCharacterIsWrittenByTheFlush() throws {
        let fixture = try makeFixture()
        let paragraph = try bodyParagraph(fixture)
        let changed = try contentWithOneChangedCharacter(fixture, paragraph: paragraph)
        let before = try snapshot(fixture.db, fixture.pid)

        fixture.state.flushContentToDatabase(overrideContent: changed.content, skipUnchangedWrite: true)

        let after = try snapshot(fixture.db, fixture.pid)
        #expect(after.epoch == before.epoch + 1, "the rows differed, so the write ran and stamped")
        #expect(after.rows.contains { $0.markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines) == changed.altered },
                "the edited paragraph is stored")
        let originalText = paragraph.markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!after.rows.contains { $0.markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines) == originalText },
                "the old text is gone")
    }

    @Test("replaceBlocksIfChanged: unchanged rows return false and write nothing")
    func unchangedRowsReturnFalse() throws {
        let fixture = try makeFixture()
        let before = try snapshot(fixture.db, fixture.pid)

        let wrote = try fixture.db.replaceBlocksIfChanged(parse(fixture.content, fixture), for: fixture.pid)

        #expect(!wrote)
        #expect(try snapshot(fixture.db, fixture.pid) == before)
    }

    @Test("replaceBlocksIfChanged: one changed character returns true and is stored")
    func oneChangedCharacterReturnsTrue() throws {
        let fixture = try makeFixture()
        let paragraph = try bodyParagraph(fixture)
        let changed = try contentWithOneChangedCharacter(fixture, paragraph: paragraph)
        let epochBefore = try fixture.db.currentBlockWriteEpoch(projectId: fixture.pid)

        let wrote = try fixture.db.replaceBlocksIfChanged(parse(changed.content, fixture), for: fixture.pid)

        #expect(wrote)
        #expect(try fixture.db.currentBlockWriteEpoch(projectId: fixture.pid) == epochBefore + 1)
        #expect(try fixture.db.fetchBlocks(projectId: fixture.pid).contains {
            $0.markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines) == changed.altered
        })
    }

    @Test("replaceBlocksIfChanged: the same text with a changed block type returns true and the type is stored")
    func changedBlockTypeReturnsTrue() throws {
        let fixture = try makeFixture()
        var blocks = parse(fixture.content, fixture)
        let index = try #require(blocks.firstIndex { $0.blockType == .paragraph && !$0.isBibliography && !$0.isNotes })
        let fragment = blocks[index].markdownFragment
        blocks[index].blockType = .blockquote
        let quotesBefore = fixture.stored.filter { $0.blockType == .blockquote }.count

        let wrote = try fixture.db.replaceBlocksIfChanged(blocks, for: fixture.pid)

        #expect(wrote, "only the block type differs (type, fragment text and flags are what the rows are compared on)")
        let after = try fixture.db.fetchBlocks(projectId: fixture.pid)
        #expect(after.filter { $0.blockType == .blockquote }.count == quotesBefore + 1)
        #expect(after.contains { $0.blockType == .blockquote && $0.markdownFragment == fragment })
    }

    @Test("replaceBlocksIfChanged: stored sort numbers that nearly tie return true even though the rows match, and the write renumbers them")
    func nearTieReturnsTrue() throws {
        let fixture = try makeFixture()
        let sorted = fixture.stored.sorted { $0.sortOrder < $1.sortOrder }
        let first = sorted[3]
        let second = sorted[4]
        try fixture.db.dbWriter.write { database in
            try database.execute(
                sql: "UPDATE block SET sortOrder = ? WHERE id = ?", arguments: [first.sortOrder + 1e-9, second.id])
        }
        #expect(LifecycleWholeDocumentWrite.hasNearTie(BlockParser.assemblySorted(try fixture.db.fetchBlocks(projectId: fixture.pid))),
                "precondition: the stored numbers now nearly tie")
        let epochBefore = try fixture.db.currentBlockWriteEpoch(projectId: fixture.pid)

        let wrote = try fixture.db.replaceBlocksIfChanged(parse(fixture.content, fixture), for: fixture.pid)

        #expect(wrote, "the near-tie rule forces a write: the write is the only thing that renumbers")
        #expect(try fixture.db.currentBlockWriteEpoch(projectId: fixture.pid) == epochBefore + 1)
        #expect(!LifecycleWholeDocumentWrite.hasNearTie(BlockParser.assemblySorted(try fixture.db.fetchBlocks(projectId: fixture.pid))),
                "after the write the numbers are apart again")
    }

    // MARK: - A zoomed flush never skips

    @Test("a zoomed flush never takes the skip path: the range replace runs and stamps, whatever the flag says")
    func zoomedFlushNeverSkips() throws {
        let markdown = "# Doc\n\n## Alpha\n\nBody.\n\n## Beta\n\nBeta body.\n"
        let db = try TestFixtureFactory.createTemporary(content: markdown)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
        let alpha = try #require(blocks.first { $0.textContent == "Alpha" })
        let beta = try #require(blocks.first { $0.textContent == "Beta" })

        let state = EditorViewState()
        state.projectDatabase = db
        state.currentProjectId = pid
        state.zoomedSectionId = alpha.id
        state.zoomedSectionIds = [alpha.id]
        state.zoomedBlockRange = (start: alpha.sortOrder, end: beta.sortOrder)
        let epochBefore = try db.currentBlockWriteEpoch(projectId: pid)

        // The zoomed text is exactly what the zoomed range already stores: a whole-document skip check would say "unchanged".
        state.flushContentToDatabase(overrideContent: "## Alpha\n\nBody.", skipUnchangedWrite: true)

        #expect(try db.currentBlockWriteEpoch(projectId: pid) == epochBefore + 1, "the zoomed replace ran and stamped; it was not skipped")
        let after = try TestFixtureFactory.fetchBlocks(from: db)
        #expect(after.contains { $0.textContent == "Beta" }, "the rest of the document is still there")
    }
}
