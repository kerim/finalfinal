//
//  MarkdownBibliographyFlushTests+Lifecycle.swift
//  final finalTests
//
//  t-94369a83 Phase 4a, plan v2 section 3, tests U3 (c) and U4 (bibliography update then close). Split out of
//  MarkdownBibliographyFlushTests.swift: the same serialized suite (these run the REAL bibliography update, which needs the
//  process-wide Zotero singleton, so every test that touches it lives in this one suite), in its own file for length.
//
//    - U3 (c): a lifecycle arms while the update's `writeNow` waits for the write in flight: nothing more is reserved, the newer
//      text is not written, and the bibliography update carries on
//    - U4: a bibliography update and then a close, in Markdown, both run through the writer (the typed text as a Markdown
//      sequence, the bibliography as ONE system write, the close as FB), and no barrier is left open
//

import Foundation
import Testing
@testable import final_final

extension MarkdownBibliographyFlushTests {

    private static let lifecycleBase = "# Alpha\n\nOne.\n\nTwo.\n\n# Beta\n\nFour."

    // MARK: - U3 (c)

    @Test("""
        (c) a lifecycle arms while `writeNow` waits for the write in flight: nothing more is reserved, the newer text is not \
        written, and the bibliography update that called it carries on and writes the bibliography
        """)
    func aLifecycleArmingWhileWriteNowWaitsReservesNothing() async throws {
        try await withZoteroItem {
            let typed = Self.lifecycleBase.replacingOccurrences(of: "One.", with: "One, typed.")
            let rig = try MarkdownWriterRig(content: Self.lifecycleBase)
            let service = BibliographySyncService()
            service.configure(database: rig.db, projectId: rig.pid)
            service.systemWriter = SystemWriter(blockSync: rig.sync)
            service.flushLiveEditorContentToBlocks = ContentView.makeBibliographyFlushHandler(for: rig.editorState)

            let parked = rig.parkedSignal()
            let held = rig.hold()
            #expect(rig.fire(typed) == .started)   // write 1 waits behind the held sequence
            await parked.wait()
            rig.editorState.content = typed + "\n\nCiting [@\(Self.key)] now."

            // The bibliography update starts: its flush hook (the real one) waits for write 1.
            let update = Task { @MainActor in
                await service.performBibliographyUpdate(citekeys: [Self.key], projectId: rig.pid, scheduledGeneration: 0)
            }
            await Task.yield()
            await Task.yield()
            // A close arms while it waits.
            guard case .armed(let token) = rig.editorState.armLifecycle(.close, wasGettingStarted: false) else {
                Issue.record("could not arm a close token")
                return
            }
            await rig.release(held)
            await update.value
            await rig.settle()

            #expect(try rig.storedText().contains("One, typed."), "write 1, reserved before the lifecycle armed, landed")
            #expect(try !rig.storedText().contains("Citing"), "the newer text was NOT written: `writeNow` found the lifecycle armed")
            #expect(rig.markdownWriter.lastTimingLine?.contains("u/i/d=1/0/0") == true, "the only Markdown write was write 1's")
            #expect(try rig.rows().contains { $0.isBibliography && $0.blockType == .heading }, "the bibliography update carried on")
            rig.editorState.clearLifecycle(token.id)
            service.reset()
        }
    }

    // MARK: - U4

    @Test("""
        a bibliography update and then a close in Markdown both run through the writer: the typed text is written as a Markdown \
        sequence, the bibliography as one system write, the close as FB, and no barrier is left open
        """)
    func bibliographyUpdateThenCloseRunThroughTheWriter() async throws {
        try await withZoteroItem {
            let rig = try LifecycleFlushHarness(content: Self.lifecycleBase)
            rig.editorState.editorMode = .source
            let text = "# Alpha\n\nciting [@\(Self.key)] here.\n\nTwo.\n\n# Beta\n\nFour."
            rig.editorState.content = text
            let bibliography = rig.attachBibliographyService()
            bibliography.flushLiveEditorContentToBlocks = ContentView.makeBibliographyFlushHandler(for: rig.editorState)
            let systemBefore = rig.sync.testWriterLedger.systemWritesApplied

            bibliography.checkAndUpdateBibliography(currentCitekeys: [Self.key], projectId: rig.pid)
            await bibliography.flushPendingSync()

            let line = rig.editorState.markdownWriter.lastTimingLine
            #expect(rig.sync.testWriterLedger.systemWritesApplied == systemBefore + 1, "the bibliography was ONE system write on the queue")
            #expect(line?.contains("mode=rows") == true && line?.contains("outcome=applied") == true, "the typed text went through the writer first")
            let blocks = try rig.blocks()
            #expect(blocks.contains { !$0.isBibliography && $0.markdownFragment == "citing [@\(Self.key)] here." })
            #expect(blocks.contains { $0.isBibliography && $0.blockType == .heading })

            rig.fetchAnswer = text + "\n\nLast words."
            let result = await rig.run(.close)

            #expect(result.outcome == .flushed)
            #expect(result.fbOutcome == .applied)
            #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentApplied == 1)
            #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentLost == 0)
            #expect(rig.sync.testWriterHandle?.testOpenBarrierSeq == nil, "no barrier left open")
            #expect(rig.editorState.lifecycleBarrier == nil)
            #expect(try rig.paragraphTexts().contains("Last words."))
            bibliography.reset()
        }
    }
}
