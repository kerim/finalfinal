//
//  MarkdownBibliographyFlushTests.swift
//  final finalTests
//
//  t-94369a83 Phase 4a, plan v2 section 3, test U5: the bibliography update's flush of the live Markdown text, now saved
//  BLOCK BY BLOCK through the write queue (`MarkdownBlockWriter.writeNow`, reached through the REAL hook
//  `ContentView.makeBibliographyFlushHandler`) instead of a whole-document `replaceBlocks`.
//
//  The older Tier 1 files (`BibliographySourceModeFlushTests`, `BibliographySourceModeFlushOverrideTests`) keep their
//  scenarios and now wire the real hook; their editor states have no block-sync service, so they exercise the hook's
//  whole-document FALLBACK. This file runs the same hazard with a writer installed (the app's normal state):
//
//    - the typed citation reaches the database before the bibliography is written (queue order, shown by sequence numbers
//      and the writer's events), and the bibliography rows then appear;
//    - paragraphs the user did not touch keep their ids and stamps (the old whole-document flush re-created every one);
//    - the hook sends only the changed paragraph.
//
//  ZoteroService.shared is a process-wide singleton, so the suite is serialized and leaves the connection flag as it found it.
//

import Foundation
import Testing
@testable import final_final

@Suite("Markdown bibliography flush through the writer — Tier 2 (t-94369a83 Phase 4a, U5)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MarkdownBibliographyFlushTests {

    static let key = "writerflushkey2026"
    private static let stale = "# Test Document\n\nSee reference /cite here for details.\n\nUntouched paragraph one.\n\n"
        + "## Second Section\n\nUntouched paragraph two."
    private static let fresh = "# Test Document\n\nSee reference [@\(key)] here for details.\n\nUntouched paragraph one.\n\n"
        + "## Second Section\n\nUntouched paragraph two."

    /// Registers `key` with the Zotero singleton for the run of `body` and puts the connection flag back as it found it.
    /// Internal: `MarkdownBibliographyFlushTests+Lifecycle.swift` extends this suite and uses it too.
    func withZoteroItem(_ body: () async throws -> Void) async throws {
        let wasConnected = ZoteroService.shared.isConnected
        let itemJSON = """
        {"id":"\(Self.key)","type":"book","title":"Writer Flush Title",\
        "author":[{"family":"Flushfam","given":"Flora"}],"issued":{"date-parts":[[2026]]}}
        """
        ZoteroService.shared.isConnected = true
        ZoteroService.shared.loadItem(try JSONDecoder().decode(CSLItem.self, from: Data(itemJSON.utf8)))
        defer { ZoteroService.shared.isConnected = wasConnected }
        try await body()
    }

    @Test("""
        a citation typed in Markdown reaches the database through the writer BEFORE the bibliography is written, only the changed \
        paragraph is sent, and the paragraphs the user did not touch keep their ids and stamps
        """)
    func theTypedCitationLandsFirstAndUntouchedParagraphsKeepTheirIds() async throws {
        try await withZoteroItem {
            let rig = try MarkdownWriterRig(content: Self.stale)   // the stored rows still hold the stale /cite text
            rig.editorState.content = Self.fresh                   // the editor already shows the resolved citation
            let service = BibliographySyncService()
            service.configure(database: rig.db, projectId: rig.pid)
            service.systemWriter = SystemWriter(blockSync: rig.sync)
            service.flushLiveEditorContentToBlocks = ContentView.makeBibliographyFlushHandler(for: rig.editorState)
            let before = try rig.rows()
            let stampsBefore = try rig.stamps()
            let typedSequence = Int64(rig.writer.nextSequence)   // the Markdown write's turn is the next one reserved

            service.checkAndUpdateBibliography(currentCitekeys: [Self.key], projectId: rig.pid)
            await service.flushPendingSync()

            // The typed text is in the database, the stale /cite is gone, and the bibliography exists.
            let rows = try rig.rows()
            let body = rows.filter { !$0.isBibliography }
            #expect(body.contains { $0.markdownFragment == "See reference [@\(Self.key)] here for details." })
            #expect(!body.contains { $0.markdownFragment.contains("/cite") })
            #expect(rows.contains { $0.isBibliography && $0.blockType == .heading }, "the bibliography heading was written")
            #expect(rows.contains { $0.isBibliography && $0.markdownFragment.contains("Flushfam") }, "and the entry")

            // Through the writer, one changed paragraph, and nothing else of the document touched.
            let line = try #require(rig.markdownWriter.lastTimingLine)
            #expect(line.contains("mode=rows") && line.contains("u/i/d=1/0/0") && line.contains("outcome=applied"), "got \(line)")
            let stampsAfter = try rig.stamps()
            for block in before where block.markdownFragment.hasPrefix("Untouched") || block.blockType == .heading {
                #expect(rows.contains { $0.id == block.id }, "\(block.markdownFragment) kept its id")
                #expect(stampsAfter[block.id] == stampsBefore[block.id], "\(block.markdownFragment) was not restamped")
            }

            // Event order: the Markdown write held the earlier sequence, the bibliography write the later one, and the queue
            // applies in sequence order.
            let typedRow = try #require(body.first { $0.markdownFragment.contains("[@\(Self.key)]") })
            #expect(stampsAfter[typedRow.id]?.last == typedSequence, "the typed text was stamped by the first reserved turn")
            let systemApplied = rig.events.all.compactMap { event -> UInt64? in
                if case .systemApplied(let seq) = event { return seq }
                return nil
            }
            #expect(systemApplied.count == 1 && systemApplied.allSatisfy { Int64($0) > typedSequence }, "the bibliography was written behind it")
            #expect(rig.ledger.systemWritesApplied == 1 && rig.ledger.failedWrites == 0)
            service.reset()
        }
    }

    @Test("""
        with a writer installed `writeNow` writes the text the whole-document flush would have: an explicit override wins over a \
        stale editorState.content, and the staged `switchInProgressContent` wins when there is no override
        """, arguments: [true, false])
    func overrideAndStagedContentWinOverStaleEditorContent(explicitOverride: Bool) async throws {
        try await withZoteroItem {
            let staleContent = "# Test Document\n\nSTALE pre-switch text that must not survive."
            let freshContent = "# Test Document\n\nFRESH content citing [@\(Self.key)], staged just before this."
            let rig = try MarkdownWriterRig(content: staleContent)
            rig.editorState.content = staleContent   // deliberately stale, as during a project switch
            if !explicitOverride { rig.editorState.switchInProgressContent = freshContent }
            let service = BibliographySyncService()
            service.configure(database: rig.db, projectId: rig.pid)
            service.systemWriter = SystemWriter(blockSync: rig.sync)
            service.flushLiveEditorContentToBlocks = ContentView.makeBibliographyFlushHandler(for: rig.editorState)

            await service.performBibliographyUpdate(
                citekeys: [Self.key], projectId: rig.pid, scheduledGeneration: 0,
                overrideContent: explicitOverride ? freshContent : nil)

            let texts = try rig.rows().filter { !$0.isBibliography }.map(\.markdownFragment)
            #expect(texts.contains { $0.contains("FRESH content") }, "the fresh text was written through the writer")
            #expect(!texts.contains { $0.contains("STALE") }, "the stale editorState.content never replaced it")
            #expect(rig.markdownWriter.lastTimingLine?.contains("outcome=applied") == true, "through the writer, not the whole-document fallback")
            service.reset()
        }
    }

    @Test("the bibliography rows survive the flush: a flush that runs before the write cannot delete the fresh rows (the old whole-document hazard)")
    func theFlushCannotClobberTheFreshBibliographyRows() async throws {
        try await withZoteroItem {
            // Nothing in the editor text mentions a bibliography: the old whole-document flush, run AFTER the write, would delete it.
            let rig = try MarkdownWriterRig(content: "# Test Document\n\nBody paragraph, no bibliography section yet.")
            rig.editorState.content = "# Test Document\n\nBody paragraph, citing [@\(Self.key)] now."
            let service = BibliographySyncService()
            service.configure(database: rig.db, projectId: rig.pid)
            service.systemWriter = SystemWriter(blockSync: rig.sync)
            service.flushLiveEditorContentToBlocks = ContentView.makeBibliographyFlushHandler(for: rig.editorState)

            service.checkAndUpdateBibliography(currentCitekeys: [Self.key], projectId: rig.pid)
            await service.flushPendingSync()

            let rows = try rig.rows()
            #expect(rows.filter { $0.isBibliography && $0.blockType == .heading }.count == 1)
            #expect(rows.contains { $0.isBibliography && $0.markdownFragment.contains("Flushfam") })
            #expect(rows.contains { $0.markdownFragment == "Body paragraph, citing [@\(Self.key)] now." })
            service.reset()
        }
    }
}
