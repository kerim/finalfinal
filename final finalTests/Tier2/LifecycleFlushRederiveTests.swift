//
//  LifecycleFlushRederiveTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C3b (slice-3a-1b-everyday.md section 4.2 step 7 and "Why step 7 makes the
//  footnote case safe", section 7.2 "C3b"): after FB, the bibliography and footnotes are re-derived from the
//  FRESH content, with `allowRenumber: false` -- references are kept as written, no `.renumberFootnotes` is
//  posted, and the WHOLE composed rename map is empty (E2), so a footnote added right before closing keeps
//  its definition.
//
//    - footnote invariant: a reference without a definition gets a definition row, and another footnote's
//      typed definition text is unchanged; a definition typed for the new footnote is kept
//    - C5: delete an earlier footnote, close within 3s: the body keeps `[^2]` and Notes keeps `[^2]: X`
//    - E2: a `carriedRenameMap` left at arm by a refused in-flight renumber (whose prepare step already renamed
//      the editor's references) must not be applied on top of FB's already-renamed content
//    - C22: a refresh slower than its bound does not hold the close
//
//  Harness: `LifecycleFlushHarness` (Helpers/), with real sync services on the rig's writer.
//

import Foundation
import Testing
@testable import final_final

/// Thread-safe recorder of every `.renumberFootnotes` mapping posted (the observer closure is `@Sendable`).
private final class RenumberPostRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var mappings: [[String: String]] = []
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(forName: .renumberFootnotes, object: nil, queue: nil) { [self] note in
            lock.withLock { mappings.append(note.userInfo?["mapping"] as? [String: String] ?? [:]) }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    var all: [[String: String]] { lock.withLock { mappings } }
}

@Suite("Lifecycle save sequence, step 7 re-derive — Tier 2 (t-94369a83 3a-1b C3b)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct LifecycleFlushRederiveTests {

    private func prime(_ rig: LifecycleFlushHarness, fetch: String) {
        rig.js.answer("flushPendingBlockChanges", true)
        rig.fetchAnswer = fetch
    }

    // MARK: - Footnote invariant

    @Test("""
        footnote invariant: a reference with no definition gets a definition row after the sequence, and another \
        footnote's typed definition text is unchanged
        """)
    func referenceWithoutDefinition_getsARow_otherTextUnchanged() async throws {
        let seed = "Body[^1] text.\n\n# Notes\n\n[^1]: Typed definition one.\n"
        let fresh = "Body[^1] and new[^2] text.\n\n# Notes\n\n[^1]: Typed definition one.\n"
        let rig = try LifecycleFlushHarness(content: seed)
        let footnotes = rig.attachFootnoteService()
        prime(rig, fetch: fresh)
        #expect(try rig.notesDefinitions().keys.sorted() == ["1"], "precondition: only [^1] has a definition row")

        let result = await rig.run()

        #expect(result.outcome == .flushed)
        #expect(result.footnoteRefresh == .completed)
        let definitions = try rig.notesDefinitions()
        #expect(definitions.keys.sorted() == ["1", "2"], "step 7 must add the missing definition row; got \(definitions)")
        #expect(definitions["1"] == "Typed definition one.", "another footnote's typed text must be unchanged")
        #expect(try rig.bodyFootnoteRefs() == ["1", "2"], "references are kept as written")
        withExtendedLifetime(footnotes) {}
    }

    @Test("footnote invariant: the definition text the user typed for the NEW footnote is what ends up in the database")
    func typedDefinitionForTheNewFootnote_isKept() async throws {
        let seed = "Body[^1] text.\n\n# Notes\n\n[^1]: Typed definition one.\n"
        let fresh = "Body[^1] and new[^2] text.\n\n# Notes\n\n[^1]: Typed definition one.\n\n[^2]: Note text eight.\n"
        let rig = try LifecycleFlushHarness(content: seed)
        let footnotes = rig.attachFootnoteService()
        prime(rig, fetch: fresh)

        let result = await rig.run()

        #expect(result.outcome == .flushed)
        // Step 7 is the only writer of `footnoteRefresh` (default `.notRun`), so without step 7 this fails.
        #expect(result.footnoteRefresh == .completed, "step 7 must have run: the typed text is only proven kept if it did")
        let definitions = try rig.notesDefinitions()
        #expect(definitions["2"] == "Note text eight.", "the typed definition must survive step 7; got \(definitions)")
        #expect(definitions["1"] == "Typed definition one.")
        #expect(try rig.bodyFootnoteRefs() == ["1", "2"])
        withExtendedLifetime(footnotes) {}
    }

    // MARK: - C5: no renumbering

    @Test("""
        C5: body `[^2]` only, Notes `[^1]` orphan + `[^2]: X`: after the sequence the body keeps `[^2]`, Notes has \
        `[^2]: X`, and no `.renumberFootnotes` was posted
        """)
    func deletedEarlierFootnote_isNotRenumbered() async throws {
        let seed = "Body[^2] here.\n\n# Notes\n\n[^1]: Orphan.\n\n[^2]: X\n"
        let rig = try LifecycleFlushHarness(content: seed)
        let footnotes = rig.attachFootnoteService()
        prime(rig, fetch: seed)
        let posts = RenumberPostRecorder()

        let result = await rig.run()

        #expect(result.outcome == .flushed)
        #expect(result.footnoteRefresh == .completed)
        #expect(try rig.bodyFootnoteRefs() == ["2"], "the body must keep [^2]: renumbering would split it from its definition")
        let definitions = try rig.notesDefinitions()
        #expect(definitions == ["2": "X"], "Notes must keep [^2]: X and drop only the orphan; got \(definitions)")
        // The notification is process-global, so a footnote test running in another suite could post its own
        // mapping into this recorder: assert on the one mapping THIS scenario would have produced.
        #expect(!posts.all.contains(["2": "1"]),
                "allowRenumber == false: the [^2] -> [^1] renumber must not be posted; got \(posts.all)")
        withExtendedLifetime(footnotes) {}
    }

    // MARK: - E2: the carried rename map

    @Test("""
        E2: a carriedRenameMap left at arm by a refused in-flight renumber (its prepare step already renamed the \
        editor's references) is NOT applied on top of FB's content: every reference label in the database matches a \
        definition label, each definition keeps its text, and the carry is cleared
        """)
    func carriedRenameMap_isNotAppliedUnderNoRenumber() async throws {
        let seed = "Body[^1] and[^2] and[^3].\n\n# Notes\n\n[^1]: Alpha body text.\n\n[^2]: Beta body text.\n\n[^3]: Gamma body text.\n"
        let rig = try LifecycleFlushHarness(content: seed)
        let footnotes = rig.attachFootnoteService()

        // Build the carry exactly as SystemWriteOrderingTests' T9c does: the user deletes the FIRST reference
        // (editor refs ["2","3"], renumber {"2":"1","3":"2"}); that run's write FAILS after its prepare step
        // told the editor, with a newer update already pending, so the composed map is carried forward.
        try rig.setQueryOnly(true)
        footnotes.checkAndUpdateFootnotes(footnoteRefs: ["2", "3"], projectId: rig.pid, fullContent: seed)
        footnotes.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: rig.pid, fullContent: seed)
        await footnotes.performFootnoteUpdate(
            refs: ["2", "3"], projectId: rig.pid, fullContent: seed, scheduledGeneration: 0)
        try rig.setQueryOnly(false)
        #expect(footnotes.testCarriedRenameMap == ["2": "1", "3": "2"], "precondition: the refused renumber left its map carried")

        // The editor already shows the renamed labels, with their definitions.
        let editorNow = "Body and[^1] and[^2].\n\n# Notes\n\n[^1]: Beta body text.\n\n[^2]: Gamma body text.\n"
        prime(rig, fetch: editorNow)

        let result = await rig.run()

        #expect(result.outcome == .flushed)
        #expect(result.footnoteRefresh == .completed)
        let refs = try rig.bodyFootnoteRefs()
        let definitions = try rig.notesDefinitions()
        #expect(refs == ["1", "2"], "FB wrote the editor's labels; got \(refs)")
        #expect(Set(refs) == Set(definitions.keys), "every reference label must match a definition label; refs \(refs), definitions \(definitions)")
        #expect(definitions["1"] == "Beta body text.", "each definition keeps its text; got \(definitions)")
        #expect(definitions["2"] == "Gamma body text.", "each definition keeps its text; got \(definitions)")
        #expect(footnotes.testCarriedRenameMap.isEmpty, "the carry is cleared once the write applies")
    }

    // MARK: - C22: a slow refresh does not hold the close

    @Test("C22: a footnote refresh slower than its bound is accepted as an orphan; the sequence continues within its deadline")
    func slowFootnoteRefresh_doesNotHoldTheClose() async throws {
        let seed = "Body[^1] text.\n\n# Notes\n\n[^1]: Typed definition one.\n"
        let fresh = "Body[^1] and new[^2] text.\n\n# Notes\n\n[^1]: Typed definition one.\n"
        let rig = try LifecycleFlushHarness(content: seed)
        let footnotes = rig.attachFootnoteService()
        let gate = LifecycleEntryHarness.Gate()
        footnotes.testInFlightHook = { await gate.wait() }
        prime(rig, fetch: fresh)
        let bounds = LifecycleBounds.production.scaled(0.1)       // refresh bound 0.3s, close total 1.5s

        let clock = ContinuousClock()
        let started = clock.now
        let result = await rig.run(.close, bounds: bounds)
        let elapsed = clock.now - started

        #expect(result.outcome == .flushed, "a slow refresh must not abort the close")
        #expect(result.footnoteRefresh == .timedOut)
        #expect(elapsed < .seconds(bounds.closeTotal), "the sequence must finish inside its deadline; took \(elapsed)")
        #expect(result.barrier == .waited(.reached), "the barrier is still taken after a timed-out refresh")
        gate.open()
        for _ in 0..<300 where footnotes.state != .idle { try await Task.sleep(for: .milliseconds(10)) }
        footnotes.reset()
    }

    @Test("C22: a bibliography refresh slower than its bound (Zotero connected but not answering) does not hold the close")
    func slowBibliographyRefresh_doesNotHoldTheClose() async throws {
        let seed = "Body text [@lifecyclec22key2026].\n"
        let rig = try LifecycleFlushHarness(content: seed)
        let bibliography = rig.attachBibliographyService()
        let gate = LifecycleEntryHarness.Gate()
        bibliography.testInFlightHook = { await gate.wait() }
        let itemJSON = """
        {"id":"lifecyclec22key2026","type":"book","title":"Lifecycle C22 Title",\
        "author":[{"family":"Slowfam","given":"Sam"}],"issued":{"date-parts":[[2024]]}}
        """
        let item = try JSONDecoder().decode(CSLItem.self, from: Data(itemJSON.utf8))
        // `ZoteroService.shared` is process-global and other suites set it too, so this test leaves it as it found
        // it and does not clear the shared item cache (the item has a key of its own, so nothing else reads it).
        let wasConnected = ZoteroService.shared.isConnected
        ZoteroService.shared.isConnected = true
        ZoteroService.shared.loadItem(item)
        defer { ZoteroService.shared.isConnected = wasConnected }
        prime(rig, fetch: seed)
        let bounds = LifecycleBounds.production.scaled(0.1)

        let clock = ContinuousClock()
        let started = clock.now
        let result = await rig.run(.close, bounds: bounds)
        let elapsed = clock.now - started

        #expect(result.outcome == .flushed)
        #expect(result.bibliographyRefresh == .timedOut)
        #expect(elapsed < .seconds(bounds.closeTotal), "took \(elapsed)")
        gate.open()
        for _ in 0..<300 where bibliography.state != .idle { try await Task.sleep(for: .milliseconds(10)) }
        bibliography.reset()
    }

    // MARK: - Skips

    @Test("step 7 is skipped for a zoomed editor (the fresh content is a subset: refreshing from it would delete the definitions outside the zoom)")
    func zoomedEditor_skipsTheRefresh() async throws {
        let seed = "# Alpha\n\nBody[^1] text.\n\n# Beta\n\nOther[^2] text.\n\n# Notes\n\n[^1]: One.\n\n[^2]: Two.\n"
        let rig = try LifecycleFlushHarness(content: seed)
        let footnotes = rig.attachFootnoteService()
        let alpha = try #require(try rig.blocks().first { $0.blockType == .heading && $0.textContent == "Alpha" })
        let beta = try #require(try rig.blocks().first { $0.blockType == .heading && $0.textContent == "Beta" })
        rig.editorState.zoomedSectionId = alpha.id
        rig.editorState.zoomedBlockRange = (start: alpha.sortOrder, end: beta.sortOrder)
        prime(rig, fetch: "# Alpha\n\nBody[^1] text.\n")

        let result = await rig.run()

        #expect(result.footnoteRefresh == .skipped)
        #expect(try rig.notesDefinitions().keys.sorted() == ["1", "2"], "the definition for [^2] (outside the zoom) must survive")
        withExtendedLifetime(footnotes) {}
    }

    @Test("""
        step 7 is skipped for an empty fetch in Rich Text too (A1): FB wrote nothing, so deriving from "" would \
        delete the Notes definitions while the body still holds the reference
        """)
    func emptyFetch_inRichText_skipsTheRefresh_andKeepsTheDefinitions() async throws {
        let seed = "See[^1].\n\n# Notes\n\n[^1]: Def\n"
        let rig = try LifecycleFlushHarness(content: seed)
        let footnotes = rig.attachFootnoteService()
        prime(rig, fetch: "")
        #expect(try rig.notesDefinitions() == ["1": "Def"], "precondition: [^1] has a definition row")

        let result = await rig.run()

        #expect(result.outcome == .flushed)
        #expect(result.fetchedContent == "", "an empty fetch is a valid fetch")
        #expect(result.fbStatus == .skippedEmptyContent)
        #expect(result.footnoteRefresh != .completed, "step 7 must not derive from an empty document")
        #expect(try rig.notesDefinitions()["1"] == "Def", "the definition row must survive")
        withExtendedLifetime(footnotes) {}
    }
}
