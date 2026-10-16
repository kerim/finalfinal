//
//  QuickUndoSectionDeleteTests.swift
//  final finalTests
//
//  This file: U-Q3 (parity with the slow undo), U-Q4, U-Q5 / U-Q25 (the delete's settle after the undo), U-Q7, U-Q8.
//  Tier 2 (t-94369a83 Phase 4b slice 2b; plan-v1 F2, plan-v2-addendum 6.2, plan-v3-addendum A1/D1/D2/D7, plan-v4-addendum 5): guards of
//  the quick undo and quick redo of an editor-first Delete Section, driven with `EditorFirstRig` (EditorFirstDeleteTests.swift). The
//  quick undo replies BEFORE its reinsert has applied, so every test that reads the database waits with
//  `EditorFirstRig.waitUntilSettled()` first. Every wait is bounded. Shared helpers: QuickUndoFixtures.swift.
//

import Foundation
import GRDB
import Testing
@testable import final_final

// Quick undo of an editor-first delete: parity, labels, the delete's own settle (Phase 4b slice 2b, Tier 2)
@Suite("Quick undo of an editor-first delete: parity", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct QuickUndoSectionDeleteTests: QuickUndoFixtures {

    // MARK: - U-Q3: parity with the slow undo

    /// Delete the document's first chapter (the article: the section 1.2), press Cmd-Z, let everything settle, and answer the rows
    /// before the delete and after the undo.
    private func rowsAroundDeleteAndUndo(article: Bool, slow: Bool) async throws -> (before: [Block], after: [Block]) {
        let rig = article ? try makeArticleRig() : try makeBookRig()
        rig.controller.testForceSlowDeleteUndo = slow
        rig.editorTextAfterUndoSwap = try rig.assembledMarkdown()
        let before = try rig.blocks()
        let deleted = try await delete(rig, article ? Self.villageRegisters : nil)
        let everythingSettled = await rig.pressAndSettle(deleted.entry)
        #expect(everythingSettled, "the press and everything after it settled (slow: \(slow))")
        #expect(rig.replyWords() == ["undo performed"], "got \(rig.replyWords())")
        #expect(slow == !rig.scripts(containing: "performStructuralSwap").isEmpty, "the path that ran is the one asked for")
        return (before, try rig.blocks())
    }

    @Test("U-Q3: Cmd-Z the quick way leaves the book6 database equal to the slow way, row for row (managed regions compared after the settle)")
    func testQuickUndoDatabaseParityWithSlowUndo_book6() async throws {
        let slow = try await rowsAroundDeleteAndUndo(article: false, slow: true)
        let quick = try await rowsAroundDeleteAndUndo(article: false, slow: false)
        // The comparison with the SLOW undo leaves out ONLY the section status: the slow undo re-parses the snapshot and gives a heading
        // that had no status the default `next`; the quick undo leaves the rows exactly as they were. Everything else (type, level,
        // Notes/Bibliography flags, tags, text, Markdown, order) must be equal. The second check below is exact, status included.
        let parity = EditorFirstRig.parityProblem(quick.after, slow.after, includingStatus: false)
        #expect(parity == nil, "the quick and the slow undo leave different documents: \(parity ?? "")")
        let asItWas = EditorFirstRig.parityProblem(quick.after, quick.before)
        #expect(asItWas == nil, "and the quick one is the document as it was: \(asItWas ?? "")")
        let sameIds = Set(quick.after.map(\.id)).symmetricDifference(Set(quick.before.map(\.id))).isEmpty
        #expect(sameIds, "the quick undo keeps every row's id")
    }

    @Test("U-Q3: the same on the article, whose delete renumbers the footnotes and cleans the Notes")
    func testQuickUndoDatabaseParityWithSlowUndo_article() async throws {
        let slow = try await rowsAroundDeleteAndUndo(article: true, slow: true)
        let quick = try await rowsAroundDeleteAndUndo(article: true, slow: false)
        // The comparison with the SLOW undo leaves out ONLY the section status: the slow undo re-parses the snapshot and gives a heading
        // that had no status the default `next`; the quick undo leaves the rows exactly as they were. Everything else (type, level,
        // Notes/Bibliography flags, tags, text, Markdown, order) must be equal. The second check below is exact, status included.
        let parity = EditorFirstRig.parityProblem(quick.after, slow.after, includingStatus: false)
        #expect(parity == nil, "the quick and the slow undo leave different documents: \(parity ?? "")")
        let asItWas = EditorFirstRig.parityProblem(quick.after, quick.before)
        #expect(asItWas == nil, "and the quick one is the document as it was: \(asItWas ?? "")")
    }

    // MARK: - U-Q4

    @Test("U-Q4: Cmd-Z puts the ORIGINAL footnote labels back in the database (the delete's resync had renumbered the references after the section)")
    func testUndoPutsOriginalReferenceLabelsBackInTheDatabase_article() async throws {
        let rig = try makeArticleRig()
        let before = try rig.assembledMarkdown()
        let beforeLabels = EditorFirstFootnoteLifecycleTests.footnoteLabels(in: before)
        let deleted = try await delete(rig, Self.villageRegisters)
        let afterDelete = EditorFirstFootnoteLifecycleTests.footnoteLabels(in: try rig.assembledMarkdown())
        #expect(
            afterDelete.references.count == 7 && afterDelete.definitions.count == 7,
            "precondition: the delete took two of the nine footnotes: \(afterDelete)")

        let everythingSettled = await rig.pressAndSettle(deleted.entry)

        #expect(everythingSettled)
        let labels = EditorFirstFootnoteLifecycleTests.footnoteLabels(in: try rig.assembledMarkdown())
        let numeric = EditorFirstFootnoteLifecycleTests.numeric
        #expect(labels.references.sorted(by: numeric) == beforeLabels.references.sorted(by: numeric))
        #expect(labels.definitions.sorted(by: numeric) == beforeLabels.definitions.sorted(by: numeric))
        #expect(try rig.documentDiff(before) == nil, "expected the body row to carry the original reference label again: every row is as it was")
    }

    // MARK: - U-Q5 and U-Q25: the delete's own settle after the undo

    // U-Q25 (D1): a delete settle that reaches its resync while the restore is on its way is superseded: no renumber after the restore,
    // the Notes stay the document's own
    @Test("U-Q25 (D1): a delete settle reaching its resync as the restore goes out is superseded")
    func testDeleteSettleCannotRenumberAfterRestoreSent_article() async throws {
        let rig = try makeArticleRig()
        let observer = rig.observeRenumbers()
        defer { NotificationCenter.default.removeObserver(observer) }
        let before = try rig.assembledMarkdown()
        // The delete's settle is parked before its resyncs; the post-delete text is what `content` holds when it goes on.
        let settleMayGo = LifecycleEntryHarness.Gate()
        defer { settleMayGo.open() }
        rig.controller.testEFSettleHold = { [weak rig] in
            await settleMayGo.wait()
            _ = try? rig?.syncEditorContentFromDatabase()
        }
        let deleted = try await delete(rig, Self.villageRegisters, settle: false)
        _ = await rig.editorState.efJobRegistry.awaitOutcome(deleted.entry.id)   // the job has applied; the settle is parked

        // The press: the restore's reply is held in the editor, after the epoch was bumped and the restore script handed over.
        let replyMayGo = LifecycleEntryHarness.Gate()
        defer { replyMayGo.open() }
        rig.quickUndoReplyHold = { await replyMayGo.wait() }
        let undo = rig.startPress(deleted.entry)
        let sent = await gateWaitUntil({ !rig.quickUndoScripts.isEmpty }, iterations: 1000)
        #expect(sent, "the restore script reached the editor")

        // The delete's settle now runs its resyncs against a document the restore is about to replace.
        settleMayGo.open()
        if let settle = rig.controller.efSettleTasks[deleted.entry.id] { await settle.value }
        replyMayGo.open()
        let ended = await rig.awaitRuns([undo])
        #expect(ended)
        _ = await rig.waitUntilSettled()

        let events = rig.events.items
        let restoreIndex = try #require(events.firstIndex { $0.contains("undoSectionDeleteEditorFirst") })
        let renumbersAfterRestore = events[restoreIndex...].filter { $0.hasPrefix("renumber") && $0 != "renumber empty" }
        #expect(renumbersAfterRestore.isEmpty, "expected no renumber after the restore: \(renumbersAfterRestore)")
        #expect(try rig.documentDiff(before) == nil, "the document is as it was before the delete")
    }

    @Test("Control for U-Q25: with no undo, the same delete settle does renumber the references (the premise of the test above)")
    func testDeleteSettleRenumbersWhenNoUndoIntervenes_article() async throws {
        let rig = try makeArticleRig()
        let observer = rig.observeRenumbers()
        defer { NotificationCenter.default.removeObserver(observer) }

        _ = try await delete(rig, Self.villageRegisters)
        _ = await rig.waitUntilSettled()

        #expect(
            rig.events.items.contains { $0.hasPrefix("renumber mapping=") },
            "the delete's resync posts a renumber: \(rig.events.items.filter { $0.hasPrefix("renumber") })")
    }

    @Test("U-Q5: a delete settle that was parked when the undo ran finds the entry taken and skips its resyncs")
    func testDeleteSettleResyncIsSkippedAfterTheUndo_article() async throws {
        let rig = try makeArticleRig()
        let observer = rig.observeRenumbers()
        defer { NotificationCenter.default.removeObserver(observer) }
        let before = try rig.assembledMarkdown()
        let settleMayGo = LifecycleEntryHarness.Gate()
        defer { settleMayGo.open() }
        rig.controller.testEFSettleHold = { [weak rig] in
            await settleMayGo.wait()
            _ = try? rig?.syncEditorContentFromDatabase()
        }
        let deleted = try await delete(rig, Self.villageRegisters, settle: false)
        _ = await rig.editorState.efJobRegistry.awaitOutcome(deleted.entry.id)

        // The editor's `contentChanged` never arrives: `content` stays whatever the parked settle will set (the post-delete text).
        rig.withholdContentUpdate = true
        let undo = rig.startPress(deleted.entry)
        let ended = await rig.awaitRuns([undo])
        #expect(ended)
        settleMayGo.open()
        _ = await rig.waitUntilSettled()

        let events = rig.events.items
        let restoreIndex = try #require(events.firstIndex { $0.contains("undoSectionDeleteEditorFirst") })
        let renumbersAfterRestore = events[restoreIndex...].filter { $0.hasPrefix("renumber") && $0 != "renumber empty" }
        #expect(renumbersAfterRestore.isEmpty, "expected no resync after the quick undo: \(renumbersAfterRestore)")
        #expect(try rig.documentDiff(before) == nil)
    }

    // U-Q25b (the inner check of resyncNow): a delete settle already waiting inside the footnote service's resync when the undo is pressed
    // is superseded when the wait ends: no renumber after the restore
    @Test("U-Q25b (the inner check of resyncNow): a delete settle already waiting inside the footnote service's")
    func testDeleteSettleParkedInsideResyncNowIsSupersededByTheUndo_article() async throws {
        let rig = try makeArticleRig()
        let observer = rig.observeRenumbers()
        defer { NotificationCenter.default.removeObserver(observer) }
        let before = try rig.assembledMarkdown()
        let settleMayGo = LifecycleEntryHarness.Gate()
        defer { settleMayGo.open() }
        rig.controller.testEFSettleHold = { [weak rig] in
            await settleMayGo.wait()
            _ = try? rig?.syncEditorContentFromDatabase()
        }
        let deleted = try await delete(rig, Self.villageRegisters, settle: false)
        _ = await rig.editorState.efJobRegistry.awaitOutcome(deleted.entry.id)   // the job has applied; the settle is parked

        // A footnote write of the test's own, parked behind a held ticket, keeps the footnote service busy (`.syncing`): the settle's
        // resync then waits (up to 2 s, polling) INSIDE `resyncNow`, past the call site's check of the epoch.
        try rig.syncEditorContentFromDatabase()
        let postDeleteText = rig.editorState.content
        let blocker = try rig.holdQueue()
        defer { rig.release(blocker) }
        let busyWrite = Task { @MainActor in
            await rig.footnotes.resyncNow(
                footnoteRefs: FootnoteSyncService.extractFootnoteRefs(from: postDeleteText), projectId: rig.pid, fullContent: postDeleteText)
        }
        let busy = await gateWaitUntil { rig.footnotes.state == .syncing }
        #expect(busy, "precondition: the footnote service is busy with a write parked behind the held ticket")
        settleMayGo.open()
        // The settle runs its (empty) bibliography resync and goes into the footnote resync's wait within milliseconds; a wait of this
        // length is a margin, not a requirement: a settle that came late finds the epoch moved at the call site and the test passes
        // without having covered the inner check.
        try await Task.sleep(for: .milliseconds(300))

        let undo = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([undo]), "the quick undo does not wait for the footnote service")
        rig.release(blocker)
        await busyWrite.value
        if let settle = rig.controller.efSettleTasks[deleted.entry.id] { await settle.value }
        _ = await rig.waitUntilSettled()

        let events = rig.events.items
        let restoreIndex = try #require(events.firstIndex { $0.contains("undoSectionDeleteEditorFirst") })
        let renumbersAfterRestore = events[restoreIndex...].filter { $0.hasPrefix("renumber") && $0 != "renumber empty" }
        #expect(renumbersAfterRestore.isEmpty, "expected no renumber after the restore: \(renumbersAfterRestore)")
        #expect(try rig.documentDiff(before) == nil, "the document is as it was before the delete")
    }

    // MARK: - U-Q7 and U-Q8

    @Test("U-Q7: two deletes, two quick undos: both sections come back, each by its own undo, on the quick path")
    func testTwoDeletesTwoQuickUndos_book6() async throws {
        let rig = try makeBookRig()
        let chapters = try rig.chapterHeadings()
        let first = try #require(chapters.first)
        let second = try #require(chapters.dropFirst().first)
        let firstSubtree = try #require(try rig.db.sectionBlockIds(rootId: first.id, projectId: rig.pid))
        let secondSubtree = try #require(try rig.db.sectionBlockIds(rootId: second.id, projectId: rig.pid))
        try rig.setReply(.init(removedLeaderIds: [first.id]), forRoot: first.id)
        try rig.setReply(.init(removedLeaderIds: [second.id]), forRoot: second.id)
        let firstOutcome = await rig.controller.performSectionDelete(rootId: first.id)
        let secondOutcome = await rig.controller.performSectionDelete(rootId: second.id)
        #expect(firstOutcome == .performed && secondOutcome == .performed)
        let entries = rig.unifiedUndo.undoStack
        #expect(entries.count == 2)
        for entry in entries { await rig.settle(entry.id) }
        try rig.syncEditorContentFromDatabase()
        let entryFirst = try #require(entries.first)
        let entrySecond = try #require(entries.last)

        let one = await rig.pressAndSettle(entrySecond)
        let two = await rig.pressAndSettle(entryFirst)

        #expect(one && two)
        #expect(rig.replyWords() == ["undo performed", "undo performed"], "got \(rig.replyWords())")
        #expect(rig.quickUndoScripts.count == 2 && rig.scripts(containing: "performStructuralSwap").isEmpty, "both ran quick")
        let ids = Set(try rig.blocks().map(\.id))
        let missing = (firstSubtree + secondSubtree).filter { id in !ids.contains(id) }.count
        #expect(missing == 0, "both sections are back in the database (\(missing) rows missing)")
    }

    @Test("U-Q8: undo, redo, undo on the quick path: the sections come back, and exactly the live snapshot id stays pinned")
    func testUndoRedoUndoQuick_book6() async throws {
        let rig = try makeBookRig()
        let snapshots = SnapshotService(database: rig.db, projectId: rig.pid)
        defer { for snapshot in (try? snapshots.fetchAllSnapshots()) ?? [] { SnapshotService.unpinUndoPointSnapshot(snapshot.id) } }
        let deleted = try await delete(rig)
        let firstSnapshot = try #require(rig.controller.efSlots.slot(deleted.entry.id)?.snapshotId)

        let undo = await rig.pressAndSettle(deleted.entry)
        let afterUndo = Set(try rig.blocks().map(\.id))
        let redo = await rig.pressAndSettle(deleted.entry, .redo)
        let afterRedo = Set(try rig.blocks().map(\.id))
        let undoAgain = await rig.pressAndSettle(deleted.entry)

        #expect(undo && redo && undoAgain)
        #expect(rig.replyWords() == ["undo performed", "redo performed", "undo performed"], "got \(rig.replyWords())")
        let missingAfterUndo = deleted.subtree.filter { id in !afterUndo.contains(id) }.count
        let presentAfterRedo = deleted.subtree.filter { id in afterRedo.contains(id) }.count
        #expect(missingAfterUndo == 0, "the first undo brought the section back (\(missingAfterUndo) rows missing)")
        #expect(presentAfterRedo == 0, "the redo took it out again (\(presentAfterRedo) rows still there)")
        #expect(try rig.missingRowCount(deleted.subtree) == 0, "the last undo brought it back")
        let live = try #require(rig.controller.efSlots.slot(deleted.entry.id)?.snapshotId)
        #expect(live != firstSnapshot, "the redo's delete job wrote a fresh Version History copy")
        let inThisProject = Set(try snapshots.fetchAllSnapshots().map(\.id))
        let pinned = SnapshotService.pinnedUndoPointSnapshotIdsForTesting.intersection(inThisProject)
        #expect(pinned == [live], "expected the pinned snapshot ids to equal the slot's live id; pinned \(pinned.count)")
        #expect(rig.quickUndoScripts.count == 2 && rig.quickRedoScripts.count == 1 && rig.scripts(containing: "performStructuralSwap").isEmpty)
    }
}
