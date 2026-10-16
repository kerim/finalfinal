//
//  CommittedDerivedStateTests.swift
//  final finalTests
//
//  Tier 1 (t-94369a83 Phase 4b slice 2b; the second real-app bug, VM test testRedoStraightAfterQuickUndo_book6): the two services that
//  write the document's derived parts remember what they last wrote and skip a resync that would write the same thing
//  (`FootnoteSyncService.lastRenumberedHash`, `BibliographySyncService.lastGeneratedHash`). A quick undo puts the pre-delete Notes and
//  Bibliography rows back without telling them, so the next resync (the redo's) looked "unchanged" and was skipped. The fix: the quick
//  undo and redo make them forget (`forgetCommittedNotesState`, `forgetCommittedBibliographyState`).
//    - U-Q47   (sw79)  the footnote service performs the same references again after it has forgotten what it committed
//    - U-Q47b  (sw80)  the same for the bibliography service
//  The whole flow (delete, quick undo, quick redo) is in Tier2/QuickUndoCommittedStateTests.swift.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Quick undo: the services forget what they last wrote (Tier 1)", .serialized)
@MainActor
struct CommittedDerivedStateTests {

    // MARK: - U-Q47: footnotes

    @Test("U-Q47 (VM bug): after forgetCommittedNotesState the same references perform again, with their renumber")
    func testForgetCommittedNotesStateLetsTheSameRefsPerformAgain() async throws {
        let text = """
        # Chapter

        Alpha[^1] beta[^41] gamma[^42].

        # Notes

        [^1]: One.

        [^41]: Forty-one.

        [^42]: Forty-two.
        """
        let db = try TestFixtureFactory.createTemporary(content: text)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let service = FootnoteSyncService()
        service.configure(database: db, projectId: pid)
        let posted = GateOrderLog()
        // The second reference was deleted: 1 and 42 remain, and 42 renumbers to 2. The mapping is the marker (labels nobody else uses).
        let observer = NotificationCenter.default.addObserver(forName: .renumberFootnotes, object: nil, queue: .main) { note in
            let mapping = (note.userInfo?["mapping"] as? [String: String]) ?? [:]
            MainActor.assumeIsolated { if mapping == ["42": "2"] { posted.note("renumber") } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await service.resyncNow(footnoteRefs: ["1", "42"], projectId: pid, fullContent: text)
        #expect(posted.items.count == 1, "precondition: the first resync is performed and renumbers 42 to 2")
        await service.resyncNow(footnoteRefs: ["1", "42"], projectId: pid, fullContent: text)
        #expect(posted.items.count == 1, "precondition: the same references again are skipped as already written")

        service.forgetCommittedNotesState()   // what the quick undo does: the table is not what this service last wrote
        await service.resyncNow(footnoteRefs: ["1", "42"], projectId: pid, fullContent: text)

        #expect(
            posted.items.count == 2,
            "expected the write applied and .renumberFootnotes posted after forgetCommittedNotesState, got \(posted.items.count) renumber(s) in all")
    }

    // MARK: - U-Q47b: bibliography

    private func bibliographyText(_ db: ProjectDatabase) throws -> String {
        try TestFixtureFactory.fetchBlocks(from: db).filter { $0.isBibliography && $0.blockType != .heading }
            .map(\.markdownFragment).joined(separator: "\n")
    }

    /// Replaces the text of every Bibliography entry row: the table changed behind the service's back (what a restored pre-delete
    /// table is to it). A plain (non-async) function on purpose: inside an `async` test `dbWriter.write` resolves to GRDB's async overload.
    private func overwriteBibliographyEntries(_ db: ProjectDatabase, with text: String) throws {
        _ = try db.dbWriter.write { database in
            let ids = try Block.filter(Block.Columns.isBibliography == true).fetchAll(database)
                .filter { $0.blockType != .heading }.map(\.id)
            try Block.filter(keys: ids).updateAll(
                database, Block.Columns.textContent.set(to: text), Block.Columns.markdownFragment.set(to: text))
        }
    }

    @Test("U-Q47b (VM bug): after forgetCommittedBibliographyState the same citekeys write the bibliography again")
    func testForgetCommittedBibliographyStateLetsTheSameCitekeysWriteAgain() async throws {
        let db = try TestFixtureFactory.createTemporary(content: "# One\n\nCiting [@forgetalpha2026].")
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let itemJSON = """
        {"id":"forgetalpha2026","type":"book","title":"Forget Alpha","author":[{"family":"Forgetquill","given":"Ann"}],\
        "issued":{"date-parts":[[2020]]}}
        """
        ZoteroService.shared.isConnected = true
        ZoteroService.shared.loadItem(try JSONDecoder().decode(CSLItem.self, from: Data(itemJSON.utf8)))
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }
        let service = BibliographySyncService()
        service.configure(database: db, projectId: pid)

        await service.resyncNow(citekeys: ["forgetalpha2026"], projectId: pid)
        #expect(try bibliographyText(db).contains("Forgetquill"), "precondition: the first resync writes the entry")
        try overwriteBibliographyEntries(db, with: "STALE-TABLE")
        await service.resyncNow(citekeys: ["forgetalpha2026"], projectId: pid)
        #expect(try bibliographyText(db).contains("STALE-TABLE"), "precondition: the same content again is skipped as already written")

        service.forgetCommittedBibliographyState()   // what the quick undo does: the table is not what this service last wrote
        await service.resyncNow(citekeys: ["forgetalpha2026"], projectId: pid)

        let text = try bibliographyText(db)
        #expect(
            text.contains("Forgetquill") && !text.contains("STALE-TABLE"),
            "expected the bibliography written again after forgetCommittedBibliographyState, got the table the service had skipped")
    }
}
