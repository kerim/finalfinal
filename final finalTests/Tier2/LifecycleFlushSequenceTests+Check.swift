//
//  LifecycleFlushSequenceTests+Check.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-2, Step 3 (plan-v2 U-C3, U-C4, U-C5; "checked FB", Option A per the user's decision): the
//  lifecycle save sequence's FB now compares the rows it would write with the stored rows inside its own queued
//  transaction and writes nothing when they match (`LifecycleFBOutcome.unchanged`, no epoch bump). These tests drive
//  the whole sequence (`EditorViewState.runLifecycleFlush`) over the scripted harness:
//
//    - positive control: Rich Text, F clean, a real fetch identical to the stored document -> `.unchanged`; the FB job
//      is still counted as having run (`lifecycleWholeDocumentApplied`), it is not a loss
//    - U-C3 (STOP RULE): a document with a heading, a footnote and a bibliography written by the REAL
//      `BibliographySyncService` system write closes `.unchanged`. If it does not, the failure message names the
//      compared fields that differ; the comparison is NOT to be loosened to make it pass (judge's choice, D5)
//    - U-C4: about 50 paragraphs appended before the Notes heading squeeze their `sortOrder`s into a near tie, which
//      forces the rebuild, which renumbers (D2); a handful of appended paragraphs (no tie) is `.unchanged`
//    - U-C5: every condition of the gate, one at a time: Markdown, zoomed with a range, zoom in flight, a fallback
//      fetch, a wedged / timed-out F, and the no-writer direct path each do NOT give `.unchanged`
//
//  The editor's whole-document serializer (remark) is not in this harness: the "fetched" text is what the editor was
//  loaded with (`assembleMarkdownForEditor`), so the scripted U-C3 proves the comparison over the real bibliography
//  rows, while remark's own re-serialization is only exercised by the real-WebView tests (ListConversionRoundTripTests).
//

import Foundation
import GRDB
import Testing
import WebKit
@testable import final_final

extension LifecycleFlushSequenceTests {

    private func primeCheck(_ rig: LifecycleFlushHarness, fetch: String?) {
        rig.js.answer("flushPendingBlockChanges", true)
        rig.fetchAnswer = fetch
    }

    private func epoch(_ rig: LifecycleFlushHarness) throws -> Int64 {
        try rig.db.currentBlockWriteEpoch(projectId: rig.pid)
    }

    /// What the stored rows would have to look like for FB to skip: the compared-fields difference between the stored
    /// rows and the rows FB would write for `content`, or "none". Used only in failure messages.
    private func differenceReport(_ rig: LifecycleFlushHarness, content: String) -> String {
        let stored = BlockParser.assemblySorted((try? rig.blocks()) ?? [])
        let parsed = BlockParser.parse(
            markdown: content, projectId: rig.pid, existingSectionMetadata: nil,
            notesHeaderName: try? rig.db.fetchNotesHeadingTitle(projectId: rig.pid))
        let wouldWrite = ProjectDatabase.preparedRowsForWholeReplace(existing: stored, parsed: parsed)
        let near = LifecycleWholeDocumentWrite.hasNearTie(stored)
        return "nearTie=\(near); " + (LifecycleWholeDocumentWrite.firstDifference(stored: stored, wouldWrite: wouldWrite) ?? "no field differs")
    }

    // MARK: - Positive control

    @Test("""
        checked FB, positive control: Rich Text, a clean F and a real fetch identical to the stored document -> FB is \
        `.unchanged`: no row touched, no epoch bump, the job still counted as run, not a loss
        """)
    func cleanFetchOfAnUnchangedDocument_fbIsUnchanged() async throws {
        let rig = try LifecycleFlushHarness()
        primeCheck(rig, fetch: LifecycleFlushHarness.seed)
        let before = try rig.blocks()
        let epochBefore = try epoch(rig)

        let result = await rig.run()

        #expect(result.outcome == .flushed)
        #expect(result.fetchedContent == LifecycleFlushHarness.seed)
        #expect(!result.usedFallback)
        #expect(result.fbOutcome == .unchanged, "the check ran inside FB's job and found the rows identical")
        #expect(result.fbSettledOutcome == .unchanged)
        #expect(try rig.blocks() == before, "nothing was written: same rows, same ids, same sortOrders")
        #expect(try epoch(rig) == epochBefore, "an unchanged FB bumps no epoch")
        let ledger = rig.sync.testWriterLedger
        #expect(ledger.lifecycleWholeDocumentApplied == 1, "`applied` means the FB job ran in the queue, whether or not it wrote")
        #expect(ledger.lifecycleWholeDocumentLost == 0, "an unchanged FB is not a loss")
    }

    // MARK: - U-C3 (STOP RULE)

    @Test("""
        U-C3 (STOP RULE, D5): an untouched document with a heading, a footnote and a bibliography written by the REAL \
        BibliographySyncService system write (citeproc output for an item with a title in italics and an `&`) closes \
        `.unchanged`. If this fails, report which compared fields differ; do not loosen the comparison
        """)
    func untouchedDocumentWithRealBibliography_closesUnchanged() async throws {
        let key = "fbcheckkey2026"
        let seed = "# Alpha\n\nBody text[^1] citing [@\(key)] here.\n\n# Notes\n\n[^1]: Kept definition.\n"
        let rig = try LifecycleFlushHarness(content: seed)
        let bibliography = rig.attachBibliographyService()
        let itemJSON = """
        {"id":"\(key)","type":"book","title":"Salt & Pepper: A Study","publisher":"Press & Sons","publisher-place":"Leeds",\
        "author":[{"family":"Quietfam","given":"Quinn"},{"family":"Otherfam","given":"Olive"}],\
        "issued":{"date-parts":[[2020]]}}
        """
        let item = try JSONDecoder().decode(CSLItem.self, from: Data(itemJSON.utf8))
        // `ZoteroService.shared` is process-global: leave it as found, and do not clear the shared cache.
        let wasConnected = ZoteroService.shared.isConnected
        ZoteroService.shared.isConnected = true
        ZoteroService.shared.loadItem(item)
        defer { ZoteroService.shared.isConnected = wasConnected }

        bibliography.checkAndUpdateBibliography(currentCitekeys: [key], projectId: rig.pid)
        await bibliography.flushPendingSync()
        let bibliographyRows = try rig.blocks().filter(\.isBibliography)
        try #require(!bibliographyRows.isEmpty, "precondition: the real system write produced bibliography rows")
        // Isolate the check from step 7: the bibliography service is not part of this close.
        rig.editorState.bibliographySyncService = nil

        // The document as the editor was loaded with it: the stored rows assembled back into Markdown.
        let content = BlockParser.assembleMarkdownForEditor(from: try rig.blocks())
        primeCheck(rig, fetch: content)
        rig.editorState.content = content
        let before = try rig.blocks()
        let epochBefore = try epoch(rig)

        let result = await rig.run()

        let stopRuleMessage = "U-C3 STOP RULE: the check did not skip a document with a real bibliography. "
            + "Differing compared fields: \(differenceReport(rig, content: content)). "
            + "Bibliography entries as stored: \(bibliographyRows.map(\.markdownFragment))"
        #expect(result.fbSettledOutcome == .unchanged, Comment(rawValue: stopRuleMessage))
        if result.fbSettledOutcome == .unchanged {
            #expect(try rig.blocks() == before)
            #expect(try epoch(rig) == epochBefore)
        }
        withExtendedLifetime(bibliography) {}
    }

    // MARK: - X1 (code review): textContent is part of the comparison

    @Test("""
        X1 (code review): a paragraph holding a citation and a footnote reference, whose stored textContent is the editor's \
        own (ProseMirror's textContent: inline atoms contribute no text; since t-4eb7bfa9 the per-edit path no longer stores \
        it, so the row is set up directly), does NOT close `.unchanged`. The stored text differs from the text FB \
        re-derives, so skipping FB would leave a different stored textContent; FB runs instead and the stored textContent \
        becomes what FB derives (the citation kept). Since t-0b70d1e9 the per-edit update counts its words from its markdown \
        fragment, so the word count is already the full one before FB runs and FB keeps it
        """)
    func editedParagraphWithCitationAndFootnoteRef_rebuildsAndKeepsTheFullWordCount() async throws {
        let key = "fbtextkey2026"
        let seed = "# Alpha\n\nBody text[^1] citing [@\(key)] here.\n\n# Notes\n\n[^1]: Kept definition.\n"
        let rig = try LifecycleFlushHarness(content: seed)
        let paragraph = try #require(try rig.blocks().first { $0.markdownFragment.hasPrefix("Body text") })

        // The user types "edited" after the footnote reference. The editor sends the new fragment and ITS text: ProseMirror's
        // `node.textContent`, in which the footnote reference and the citation (inline atoms) contribute nothing.
        let editedFragment = "Body text[^1] edited citing [@\(key)] here."
        let perEditText = "Body text edited citing  here."
        let update = BlockUpdate(
            id: paragraph.id, textContent: perEditText, markdownFragment: editedFragment, headingLevel: nil, blockType: "paragraph")
        _ = try rig.db.applyBlockChangesFromEditor(BlockChanges(updates: [update]), for: rig.pid)
        // t-4eb7bfa9 (S14): the per-edit path now stores what FB derives from the fragment, not the editor's own text, so the update
        // alone leaves FB nothing to rebuild. X1 is about a stored text that DIFFERS (a row from an older version, or from a path that
        // sent no fragment, holds the editor's own text), so the editor's text is put into the row directly to build that premise.
        let afterUpdate = try #require(try rig.blocks().first { $0.id == paragraph.id })
        #expect(
            afterUpdate.textContent == BlockParser.extractTextContent(from: editedFragment, blockType: .paragraph),
            "the per-edit text is the text a close derives from the fragment")
        try rig.db.write { db in
            guard var row = try Block.fetchOne(db, key: paragraph.id) else { return }
            row.textContent = perEditText
            try row.update(db)
        }
        let stored = try #require(try rig.blocks().first { $0.id == paragraph.id })
        #expect(stored.textContent == perEditText, "precondition: the table holds the editor's own text")

        // The editor's whole document (what the fresh fetch carries), and the row FB derives from it.
        let content = BlockParser.assembleMarkdownForEditor(from: try rig.blocks())
        let derived = try #require(
            BlockParser.parse(markdown: content, projectId: rig.pid).first { $0.markdownFragment == editedFragment },
            "precondition: FB's parse has the edited paragraph")
        #expect(derived.textContent != stored.textContent, "precondition: FB's text keeps the citation, the editor's does not")
        // t-0b70d1e9: the per-edit update carries its fragment and is counted from it, so its count already equals FB's (it used to be
        // LOWER, two words per citation). What still forces FB to write is the differing textContent, asserted just above.
        #expect(
            derived.wordCount == stored.wordCount,
            "precondition: the per-edit count comes from the fragment, citation included (\(stored.wordCount) vs \(derived.wordCount))")
        primeCheck(rig, fetch: content)
        rig.editorState.content = content
        let epochBefore = try epoch(rig)

        let result = await rig.run()

        #expect(result.fbSettledOutcome == .applied, "the text differs, so FB must run, not skip: \(differenceReport(rig, content: content))")
        #expect(try epoch(rig) == epochBefore + 1)
        let after = try #require(try rig.blocks().first { $0.markdownFragment == editedFragment })
        #expect(after.textContent == derived.textContent, "the stored text is what FB derives, citation included")
        #expect(after.wordCount == derived.wordCount, "so the word count is the full one, FB's write kept it")
    }

    // MARK: - U-C4: the near-tie rule

    /// Appends `count` paragraphs one at a time, each after the previous one and so just before the Notes heading
    /// (what typing at the end of the body text does), through the editor-insert path. Returns the editor text.
    private func appendParagraphsBeforeNotes(_ rig: LifecycleFlushHarness, count: Int) throws -> String {
        var lastId = try #require(try rig.blocks().first { $0.markdownFragment.hasPrefix("First body paragraph") }).id
        var added: [String] = []
        for index in 1...count {
            let text = "appended paragraph number \(index)."
            let temp = "temp-fbcheck-\(index)"
            let changes = BlockChanges(inserts: [
                BlockInsert(tempId: temp, blockType: "paragraph", textContent: text, markdownFragment: text,
                            headingLevel: nil, afterBlockId: lastId, atDocumentStart: nil)
            ])
            let mapping = try rig.db.applyBlockChangesFromEditor(changes, for: rig.pid)
            lastId = try #require(mapping[temp], "the insert \(index) must have been given a permanent id")
            added.append(text)
        }
        return "# Alpha\n\nFirst body paragraph[^1].\n\n" + added.joined(separator: "\n\n")
            + "\n\n# Notes\n\n[^1]: Kept definition.\n"
    }

    private static let nearTieSeed = "# Alpha\n\nFirst body paragraph[^1].\n\n# Notes\n\n[^1]: Kept definition.\n"

    @Test("""
        U-C4 control: three paragraphs appended before the Notes heading leave no near tie, and the document closes \
        `.unchanged`: the near-tie rule is what the next test turns on, not the appended paragraphs
        """)
    func fewAppendedParagraphs_closeUnchanged() async throws {
        let rig = try LifecycleFlushHarness(content: Self.nearTieSeed)
        let content = try appendParagraphsBeforeNotes(rig, count: 3)
        primeCheck(rig, fetch: content)
        rig.editorState.content = content
        #expect(!LifecycleWholeDocumentWrite.hasNearTie(BlockParser.assemblySorted(try rig.blocks())), "precondition: no near tie yet")

        let result = await rig.run()

        #expect(result.fbSettledOutcome == .unchanged, "\(differenceReport(rig, content: content))")
    }

    @Test("""
        U-C4 (D2): about 50 paragraphs appended one at a time before the Notes heading squeeze their sortOrders into a \
        near tie. The close then runs the rebuild (`.applied`), which renumbers (strictly increasing, gaps of at least \
        1, no near tie left), and every appended paragraph sorts before `# Notes` with isNotes == false
        """)
    func manyAppendedParagraphs_nearTieForcesRebuildAndRenumber() async throws {
        let rig = try LifecycleFlushHarness(content: Self.nearTieSeed)
        let content = try appendParagraphsBeforeNotes(rig, count: 50)
        primeCheck(rig, fetch: content)
        rig.editorState.content = content
        let squeezed = BlockParser.assemblySorted(try rig.blocks())
        #expect(LifecycleWholeDocumentWrite.hasNearTie(squeezed), "precondition: 50 midpoint inserts leave a near tie")
        let epochBefore = try epoch(rig)

        let result = await rig.run()

        #expect(result.fbSettledOutcome == .applied, "a near tie must send FB to renumber, never skip")
        #expect(try epoch(rig) == epochBefore + 1)
        let after = BlockParser.assemblySorted(try rig.blocks())
        #expect(!LifecycleWholeDocumentWrite.hasNearTie(after), "the rebuild renumbered the rows")
        #expect(zip(after, after.dropFirst()).allSatisfy { $1.sortOrder - $0.sortOrder >= 1 }, "strictly increasing, gaps of at least 1")
        let notesHeading = try #require(after.firstIndex { $0.blockType == .heading && $0.textContent == "Notes" })
        let appendedIndexes = after.indices.filter { after[$0].markdownFragment.hasPrefix("appended paragraph number") }
        #expect(appendedIndexes.count == 50)
        #expect(appendedIndexes.allSatisfy { $0 < notesHeading }, "every appended paragraph sorts before the Notes heading")
        #expect(appendedIndexes.allSatisfy { !after[$0].isNotes }, "and none became a footnote row")
    }

    // MARK: - U-C5: the gate, one condition at a time

    @Test("""
        U-C5 gate table: only Rich Text, not zoomed (BOTH the range and the section id nil), a clean F and a real \
        (non-fallback) fetch open the gate; each other condition alone closes it
        """)
    func gateTable() {
        func capture(
            mode: EditorMode = .wysiwyg, range: (start: Double, end: Double?)? = nil, section: String? = nil
        ) -> LifecycleCapture {
            LifecycleCapture(
                webView: nil, editorMode: mode, blockSync: nil, database: nil, projectId: nil,
                zoomedRange: range, zoomedSectionId: section, fetch: nil)
        }
        func result(
            watchdog: Bool = false, forced: Bool = false, fetched: String? = "x", fallback: Bool = false
        ) -> LifecycleFlushResult {
            var value = LifecycleFlushResult()
            value.watchdogHit = watchdog
            value.forcedPollTimedOut = forced
            value.fetchedContent = fetched
            value.usedFallback = fallback
            return value
        }
        func open(_ capture: LifecycleCapture, _ result: LifecycleFlushResult) -> Bool {
            EditorViewState.fbMaySkipWhenUnchanged(capture: capture, result: result)
        }

        #expect(open(capture(), result()), "everything holds")
        #expect(open(capture(), result(fetched: "")), "an empty fetch is still a real answer (N28)")
        #expect(!open(capture(mode: .source), result()), "Markdown")
        #expect(!open(capture(range: (start: 1, end: 5)), result()), "zoomed with a block range")
        #expect(!open(capture(section: "some-heading"), result()), "zoom in flight: the section id alone closes the gate (N15)")
        #expect(!open(capture(range: (start: 1, end: nil), section: "some-heading"), result()), "zoomed, both set")
        #expect(!open(capture(), result(watchdog: true)), "the page did not answer flushAndAck")
        #expect(!open(capture(), result(forced: true)), "flushAndAck's writer wait timed out")
        #expect(!open(capture(), result(fetched: nil)), "no fetch answer")
        #expect(!open(capture(), result(fallback: true)), "the content on hand stood in for the fetch")
    }

    @Test("U-C5: a Markdown close never skips, even when the fetch equals the stored document: FB writes and bumps the epoch")
    func markdownClose_neverSkips() async throws {
        let rig = try LifecycleFlushHarness()
        rig.editorState.editorMode = .source
        primeCheck(rig, fetch: LifecycleFlushHarness.seed)
        let epochBefore = try epoch(rig)

        let result = await rig.run(.close)

        #expect(result.capturedEditorMode == .source, "precondition: the Markdown branch ran")
        #expect(result.fbOutcome == .applied)
        #expect(try epoch(rig) == epochBefore + 1)
    }

    @Test("U-C5: a zoomed close (block range set) never skips, even when the zoomed text equals the stored section")
    func zoomedClose_neverSkips() async throws {
        let rig = try LifecycleFlushHarness()
        let alpha = try #require(try rig.blocks().first { $0.blockType == .heading && $0.textContent == "Alpha" })
        let beta = try #require(try rig.blocks().first { $0.blockType == .heading && $0.textContent == "Beta" })
        rig.editorState.zoomedSectionId = alpha.id
        rig.editorState.zoomedBlockRange = (start: alpha.sortOrder, end: beta.sortOrder)
        primeCheck(rig, fetch: "# Alpha\n\none two three.\n")
        let epochBefore = try epoch(rig)

        let result = await rig.run()

        #expect(result.fbOutcome == .applied)
        #expect(try epoch(rig) == epochBefore + 1, "the zoomed replace ran")
    }

    @Test("""
        U-C5: the zoom-in-flight shape (section id set, no range yet) stays the counted `.refused(.notWanted)` loss, \
        even when the fetch equals the stored document; the database and the epoch are untouched
        """)
    func zoomInFlight_isStillACountedLoss_neverASkip() async throws {
        let rig = try LifecycleFlushHarness()
        let alpha = try #require(try rig.blocks().first { $0.blockType == .heading && $0.textContent == "Alpha" })
        rig.editorState.zoomedSectionId = alpha.id
        #expect(rig.editorState.zoomedBlockRange == nil)
        primeCheck(rig, fetch: LifecycleFlushHarness.seed)
        let epochBefore = try epoch(rig)

        let result = await rig.run()

        guard case .lost = result.fbOutcome else {
            Issue.record("expected a counted loss, got \(String(describing: result.fbOutcome))")
            return
        }
        #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentLost == 1)
        #expect(try epoch(rig) == epochBefore)
    }

    @Test("U-C5: a fetch that answered nothing (fallback to the content on hand) never skips, even when that content equals the stored document")
    func fallbackFetch_neverSkips() async throws {
        let rig = try LifecycleFlushHarness()
        primeCheck(rig, fetch: nil)
        #expect(rig.editorState.content == LifecycleFlushHarness.seed, "precondition: the content on hand equals the stored document")
        let epochBefore = try epoch(rig)

        let result = await rig.run()

        #expect(result.usedFallback)
        #expect(result.fbOutcome == .applied)
        #expect(try epoch(rig) == epochBefore + 1)
    }

    @Test("""
        U-C5 / plan-v2 C6: Rich Text with NO queue writer (the gate is open) takes the direct-write fallback, which \
        never inherits the skip decision: it writes (`.appliedDirectly`, epoch bumped) although the fetch equals the \
        stored document
        """)
    func noWriterDirectPath_alwaysWrites() async throws {
        let rig = try LifecycleFlushHarness()
        primeCheck(rig, fetch: LifecycleFlushHarness.seed)
        // A block-sync service that was never configured has no writer (the U7(c) pattern, here in Rich Text).
        let noWriter = BlockSyncService()
        noWriter.testJSEvaluator = rig.sync.testJSEvaluator
        rig.editorState.blockSyncService = noWriter
        #expect(noWriter.testWriterHandle == nil, "precondition: no writer")
        let epochBefore = try epoch(rig)

        let result = await rig.run(.close)

        #expect(result.capturedEditorMode == .wysiwyg)
        #expect(result.fetchedContent == LifecycleFlushHarness.seed, "precondition: the gate's conditions held")
        #expect(!result.usedFallback)
        #expect(result.fbSettledOutcome == .appliedDirectly, "the direct write is a write, never a skip")
        #expect(try epoch(rig) == epochBefore + 1)
        withExtendedLifetime(noWriter) {}
    }

    @Test("U-C5: a wedged page (flushAndAck unanswered) never skips, even when the content on hand equals the stored document")
    func wedgedPage_neverSkips() async throws {
        let rig = try LifecycleFlushHarness()
        rig.js.wedgeOn("flushReports")
        rig.fetchAnswer = LifecycleFlushHarness.seed
        let epochBefore = try epoch(rig)

        let result = await rig.run(bounds: LifecycleBounds.production.scaled(0.25))

        #expect(result.watchdogHit)
        #expect(result.fbOutcome == .applied)
        #expect(try epoch(rig) == epochBefore + 1)

        try await rig.releaseWedgeAndSettle()
    }
}
