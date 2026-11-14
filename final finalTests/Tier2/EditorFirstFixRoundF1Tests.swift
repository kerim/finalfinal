//
//  EditorFirstFixRoundF1Tests.swift
//  final finalTests
//
//  Tier 2 (t-18b7fa48 Phase 4b, fix round F1; judge-review-slice23.md must-fix items 1 to 4 and the real-app finding D): the guards of
//  the fixes of the slice 2-3 code review, each written to FAIL on the code as it stood before the round:
//
//    A1   Insert as New Section after a section that ends in a list puts the copy after the WHOLE list (database order)
//    B2   a slow undo pressed while a quick undo's reinsert is still queued waits for it (the reinsert's section keeps its id)
//    B3   a slow undo that has to wait for an earlier job shows "Undoing..." from the start of the press
//    B1   typing straight after a slow Cmd-Z does not leave the sidebar overlay, the hidden leaders and the hierarchy wait behind
//    D    a slow undo of a footnoted delete leaves the Notes exactly as they were (no second renumbering from a stale checkpoint)
//    C1   the settle derives Notes from the editor's OWN text when `content` has not caught up (D14), for each kind
//
//  Driven with `EditorFirstRig` (EditorFirstDeleteTests.swift) and the helpers of `QuickUndoFixtures`. Every expected value is the
//  document as the user had it (the rows and Notes before the operation), never what the code printed.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Editor-first fix round F1 (t-18b7fa48, Tier 2)", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct EditorFirstFixRoundF1Tests: QuickUndoFixtures {

    // MARK: - A1: Insert as New Section after a list

    // A1: the editor's anchor for a multi-item list is its FIRST item; the database job inserted right after that row, between the
    // list's first and second item. WHEN A LIST IS SEVERAL ROWS (found in the follow-up to fix round F1): the Rich Text editor writes
    // a list as ONE row (`block-sync-plugin.ts`, one fragment per list node), and since t-4eb7bfa9 `BlockParser` keeps a loose list
    // (a blank line between the items) in ONE row too. Several rows for one editor list node exist only in a document an EARLIER
    // parser saved, which cut a loose list at every blank line: one row per item, all with the same marker. The fixture below
    // builds exactly that, ONE list (`- first item`, `- second item`, `- third item`, one editor node) stored as three rows,
    // by inserting the rows directly; the parser can no longer produce it from Markdown. Break patch: `jobAnchorBlockId =
    // nodeIds.last` in `performEditorFirstRestoreSectionDuplicate`. Predicted failure: "the copy was inserted inside the list".
    @Test("A1: Insert as New Section after a section that ends in a three-row (per-item) list puts the copy after the third item")
    func testInsertAsNewSectionGoesAfterTheWholeList() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let lastSortOrder = try rig.blocks().map(\.sortOrder).max() ?? 0
        for (index, item) in ["first item", "second item", "third item"].enumerated() {
            try rig.db.insertBlock(Block(
                projectId: rig.pid, sortOrder: lastSortOrder + Double(index + 1), blockType: .bulletList,
                textContent: item, markdownFragment: "- \(item)"))
        }
        defer { unpinAllVersions(rig) }
        try await rig.fillSectionTable()
        let version = try saveVersion(rig)
        let itemsBefore = BlockParser.assemblySorted(try rig.blocks()).filter { $0.blockType == .bulletList }
        #expect(itemsBefore.count == 3, "precondition: the fixture's list is three rows, got \(itemsBefore.count)")

        #expect(await rig.performRestore("duplicate", from: version, section: "Section A") == .performed)
        _ = await rig.waitUntilSettled()

        let rows = BlockParser.assemblySorted(try rig.blocks())
        let kinds = rows.map(\.blockType)
        let firstItem = try #require(kinds.firstIndex(of: .bulletList), "the list is gone")
        let afterList = firstItem + 3
        try #require(rows.count > afterList + 1, "the rows after the list are missing: \(rows.map(\.textContent))")
        #expect(
            kinds[firstItem..<afterList].allSatisfy { $0 == .bulletList },
            "the copy was inserted inside the list: \(rows.map(\.textContent))")
        #expect(
            rows[afterList].blockType == .heading && rows[afterList].textContent == "Section A"
                && rows[afterList + 1].textContent == "The A body.",
            "the copy does not follow the third item: \(rows.map(\.textContent))")
        #expect(rows.map(\.textContent).filter { $0 == "Section A" }.count == 2, "the version's section was not added")
        #expect(restoreRanEditorFirst(rig), "no editor-first restore: \(rig.persistedLog)")
    }

    // MARK: - B2: the slow undo waits for a pending quick undo's reinsert

    // B2 (A2): reorder-like situation with two deletes. The quick undo of the second delete leaves its reinsert in the writer's queue (held);
    // the slow undo of the first delete used to read its plan at once, against a table that lacks the second section, and so gave that
    // section's heading a FRESH id; the reinsert then wrote the original id and the slow undo's job replaced it. Now the press waits for
    // all editor-first work to settle before it reads the plan. Break patch: delete the `awaitAllSettled()` line in
    // `awaitPendingSnapshotSwap`. Predicted failure: "the section's heading got a fresh id".
    @Test("B2: a slow undo pressed while a quick undo's reinsert is queued keeps the reinserted section's ids, and both redos work")
    func testSlowUndoWaitsForAPendingQuickUndoReinsert() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        defer { unpinAllVersions(rig) }
        let deletedB = try await delete(rig, "Section B")
        let deletedC = try await delete(rig, "Section C")
        let hold = try rig.holdQueue()   // the quick undo's reinsert is reserved but cannot run
        let quick = rig.startPress(deletedC.entry)
        #expect(await rig.awaitRuns([quick]), "the quick undo did not end")
        #expect(rig.quickUndoScripts.count == 1, "precondition: the first press took the quick road")
        rig.controller.testForceSlowDeleteUndo = true   // the second press takes the slow road (its entry's quick path is closed)
        let slow = rig.startPress(deletedB.entry)
        rig.release(hold)
        #expect(await rig.awaitRuns([slow]), "the slow undo did not end")
        _ = await rig.waitUntilSettled()

        #expect(rig.replyWords() == ["undo performed", "undo performed"], "got \(rig.replyWords())")
        let headingC = try rig.heading("Section C")
        #expect(headingC.id == deletedC.root.id, "the section's heading got a fresh id: the reinsert's id was replaced by the slow undo's")
        #expect(try rig.heading("Section B").textContent == "Section B", "the slow undo did not bring Section B back")

        try await restorePress(rig, .redo)   // the slow undo's own redo
        try await restorePress(rig, .redo)   // the quick undo's redo
        #expect(
            rig.replyWords() == ["undo performed", "undo performed", "redo performed", "redo performed"],
            "both redos must be carried out, got \(rig.replyWords())")
        let titles = try rig.blocks().map(\.textContent)
        #expect(!titles.contains("Section B") && !titles.contains("Section C"), "the redos did not delete both sections again: \(titles)")
    }

    // MARK: - B3: "Undoing..." from the start of a press that has to wait

    // B3 (floor item 3): the second of two back-to-back slow presses waits for the first one's job and settle. The notice used to be
    // created after that wait (and only for editor-first entries), so nothing was on screen. Break patch: move the toast's creation in
    // `performUndo` back below `awaitPendingSnapshotSwap`. Predicted failure: "no Undoing... notice by 1.2 s".
    @Test("B3: a slow undo that has to wait for the previous one's job shows \"Undoing...\" within 1.2 s")
    func testAWaitingSlowUndoShowsTheUndoingNotice() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        defer { unpinAllVersions(rig) }
        rig.controller.testForceSlowDeleteUndo = true
        let deletedB = try await delete(rig, "Section B")
        let deletedC = try await delete(rig, "Section C")
        let hold = try rig.holdQueue()   // the first slow undo's job cannot run
        let first = rig.startPress(deletedC.entry)
        #expect(await rig.awaitRuns([first]), "the first slow undo did not end")
        let second = rig.startPress(deletedB.entry)   // must wait for the first job
        let shown = await gateWaitUntil({ rig.toasts.current?.message == DelayedProgressToast.undoingMessage }, iterations: 240)
        #expect(shown, "no Undoing... notice by 1.2 s, the toast centre shows \(String(describing: rig.toasts.current?.message))")
        #expect(!second.done, "precondition: the second press must still be waiting for the first one's job")

        rig.release(hold)
        #expect(await rig.awaitRuns([second]), "the second press did not end")
        _ = await rig.waitUntilSettled()
        #expect(rig.toasts.current?.message != DelayedProgressToast.undoingMessage, "the Undoing... notice stayed after the press ended")
        #expect(rig.replyWords() == ["undo performed", "undo performed"], "got \(rig.replyWords())")
    }

    // MARK: - B1: typing straight after a slow Cmd-Z

    // B1 (EVERYDAY): a slow undo's job is still queued when the user types (typing drops the redo branch, which discards the entry and
    // forgets its latest-job key). The settle used to find "not my key" and leave the sidebar overlay, the hidden leaders and the
    // hierarchy-enforcement wait behind for the session. Break patch: `isLatestJob()` back to `efLatestJobKey[opId] == jobKey` in
    // `editorFirstJobSettled`. Predicted failure: "the sidebar overlay was left behind".
    @Test("B1: typing right after a slow undo, before its job has run, does not leave the sidebar frozen")
    func testTypingAfterASlowUndoLeavesNoOverlayBehind() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        defer { unpinAllVersions(rig) }
        rig.controller.testForceSlowDeleteUndo = true
        let deleted = try await delete(rig, "Section A")
        let hold = try rig.holdQueue()   // the slow undo's job is reserved but cannot run
        let press = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([press]), "the slow undo did not end")
        #expect(rig.unifiedUndo.redoStack.last?.id == deleted.entry.id, "precondition: the entry waits on the redo stack")
        #expect(rig.editorState.pendingRestoreSections[deleted.entry.id] != nil, "precondition: the sidebar shows the overlay")

        rig.unifiedUndo.invalidateRedoBranch(reason: "text edit after structural undo")   // the user types straight away
        rig.release(hold)
        _ = await rig.waitUntilSettled()

        #expect(rig.editorState.pendingRestoreSections[deleted.entry.id] == nil, "the sidebar overlay was left behind")
        #expect(rig.editorState.pendingRemovalIds.isEmpty, "leaders stayed hidden: \(rig.editorState.pendingRemovalIds)")
        #expect(!ContentView.hierarchyEnforcementWaitsForQuickUndo(rig.editorState), "hierarchy enforcement would wait for ever")
        #expect(try rig.blocks().contains { $0.textContent == "Section A" }, "the slow undo did not apply")
    }

    // MARK: - D: the footnote checkpoint

    // D (real-app finding, EVERYDAY on footnoted documents): a delete whose resync renumbered the footnotes left a footnote undo
    // checkpoint. The slow undo's swapped-in text equals that checkpoint's first state, so the editor's content push (50 ms after the
    // swap) started a footnote restore planned against the post-delete table and queued it behind the slow undo's own job, which had
    // already written the old numbering: the renumbering was undone twice (a definition duplicated, another lost). Break patch: delete
    // the `guardFootnoteCheckpointsForNotesRewrite(token: jobKey)` line in `startSnapshotSwapJob`. Predicted failure: "the Notes after
    // the undo differ from the Notes before the delete".
    @Test("D: a slow undo of a footnoted delete leaves the Notes as they were before the delete")
    func testSlowUndoDoesNotRenumberTheFootnotesTwice_article() async throws {
        let rig = try makeArticleRig()
        defer { unpinAllVersions(rig) }
        rig.controller.testForceSlowDeleteUndo = true
        let before = try rig.assembledMarkdown()
        let notesBefore = try rig.notesTexts()
        // The state an open project's first footnote sync leaves: the table matches the document.
        rig.footnotes.lastKnownRefs = FootnoteSyncService.extractFootnoteRefs(from: before)
        rig.footnotes.lastContentWithKnownRefs = before
        let deleted = try await delete(rig, Self.villageRegisters)   // the settle's resync renumbers the Notes and records a checkpoint
        _ = await gateWaitUntil({ rig.footnotes.state == .idle && rig.footnotes.inFlightCount == 0 }, iterations: 1200)
        #expect(try rig.notesTexts() != notesBefore, "precondition: the delete's resync changed the Notes")
        #expect(rig.footnotes.undoCheckpoints.count == 1, "precondition: the delete's resync recorded a checkpoint")

        rig.emulatesFootnoteContentChange = true   // the editor's content push after the swap reaches the footnote service
        let hold = try rig.holdQueue()   // the slow undo's job cannot run yet: a footnote restore would queue behind it
        let press = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([press]), "the slow undo did not end")
        let pushed = await gateWaitUntil({ rig.events.items.contains("content push") }, iterations: 400)
        #expect(pushed, "precondition: the editor's content push did not arrive")
        rig.release(hold)
        _ = await rig.waitUntilSettled()
        _ = await gateWaitUntil({ rig.footnotes.state == .idle && rig.footnotes.inFlightCount == 0 }, iterations: 1200)
        await rig.footnotes.flushPendingSync()
        _ = await rig.waitUntilSettled()

        #expect(rig.replyWords() == ["undo performed"], "got \(rig.replyWords())")
        let notesAfter = try rig.notesTexts()
        #expect(
            notesAfter == notesBefore,
            "the Notes after the undo differ from the Notes before the delete (\(notesAfter.count) vs \(notesBefore.count) rows)")
    }

    // D, the whole-project restore (fix round F4; break patch S2-24: the `guardFootnoteCheckpointsForNotesRewrite` call in
    // `startEditorFirstRestoreJob`). The twin of the test above. A Version History restore of the version saved just BEFORE the footnoted
    // delete swaps in a document that equals the first state of the delete's footnote checkpoint, and its queued job rewrites every Notes
    // row from the version. The editor's content push (50 ms after the click's reply) reaches the footnote service while the job is
    // still pending: with the checkpoint still armed it "matches" and queues a footnote restore planned against the table as it was
    // AFTER the delete (the new numbering), which then runs behind the restore's job and renumbers the rows the job has already put in
    // order a second time. Every definition must be as it was before the delete, label by label. No test turned
    // `emulatesFootnoteContentChange` on for a restore before; the rig now models the push for the whole restore's click too.
    // Predicted failure with the guard call removed: "the Notes after the restore differ from the Notes before the delete".
    @Test("D2: a whole restore of the version saved before a footnoted delete leaves the Notes as they were before the delete")
    func testWholeRestoreDoesNotRenumberTheFootnotesTwice_article() async throws {
        let rig = try makeArticleRig()
        defer { unpinAllVersions(rig) }
        let before = try rig.assembledMarkdown()
        let notesBefore = try notesDefinitions(rig)
        // The state an open project's first footnote sync leaves: the table matches the document.
        rig.footnotes.lastKnownRefs = FootnoteSyncService.extractFootnoteRefs(from: before)
        rig.footnotes.lastContentWithKnownRefs = before
        let version = try saveVersion(rig)   // the document the user then deletes a section of
        _ = try await delete(rig, Self.villageRegisters)   // the settle's resync renumbers the Notes and records a checkpoint
        _ = await gateWaitUntil({ rig.footnotes.state == .idle && rig.footnotes.inFlightCount == 0 }, iterations: 1200)
        #expect(try notesDefinitions(rig) != notesBefore, "precondition: the delete's resync changed the Notes")
        #expect(rig.footnotes.undoCheckpoints.count == 1, "precondition: the delete's resync recorded a checkpoint")
        let checkpointFirstState = rig.footnotes.undoCheckpoints.first?.states.first

        rig.emulatesFootnoteContentChange = true   // the editor's content push after the restore reaches the footnote service
        let hold = try rig.holdQueue()   // the restore's job cannot run yet: a footnote restore would queue behind it
        #expect(await rig.performRestore("project", from: version) == .performed)
        let plan = try #require(rig.controller.testLastRestorePlan)
        #expect(
            FootnoteSyncService.undoComparable(plan.markdown) == checkpointFirstState?.body
                && FootnoteSyncService.extractFootnoteRefs(from: plan.markdown) == checkpointFirstState?.refs,
            "precondition: the restored text equals the first state of the checkpoint, so the editor's push would match it")
        let pushed = await gateWaitUntil({ rig.events.items.contains("content push") }, iterations: 400)
        #expect(pushed, "precondition: the editor's content push did not arrive")
        rig.release(hold)
        _ = await rig.waitUntilSettled()
        _ = await gateWaitUntil({ rig.footnotes.state == .idle && rig.footnotes.inFlightCount == 0 }, iterations: 1200)
        await rig.footnotes.flushPendingSync()
        _ = await rig.waitUntilSettled()

        let notesAfter = try notesDefinitions(rig)
        #expect(
            notesAfter == notesBefore,
            "the Notes after the restore differ from the Notes before the delete (\(notesAfter.count) vs \(notesBefore.count) rows)")
    }

    /// Every Notes definition row (label and text), in document order.
    private func notesDefinitions(_ rig: EditorFirstRig) throws -> [String] {
        try rig.blocks().filter { $0.isNotes && $0.blockType != .heading }.sorted { $0.sortOrder < $1.sortOrder }.map(\.markdownFragment)
    }

    // MARK: - C1: the settle reads the editor's own text (D14), for each kind

    private static let footnotedDocument = """
    # Doc

    ## Alpha

    Alpha text.[^1]

    ## Beta

    Beta text.[^2]

    ## Gamma

    Gamma text.[^3]

    # Notes

    [^1]: Alpha note.

    [^2]: Beta note.

    [^3]: Gamma note.
    """

    private static let allThreeNotes = ["Alpha note.", "Beta note.", "Gamma note."]

    // C1: `content` (the editor's `contentChanged` push) has not caught up when the job's settle starts, so it still holds the text from
    // BEFORE the operation, which has no reference to the Gamma note; the footnote resync would take the Gamma definition out of the
    // Notes. The settle reads the editor's own text first (`adoptLiveEditorText`, D14). No `testEFSettleHold` here: the article rig's one
    // copies the database text into `content` before the adopt and so masks the line. Break patch: delete the `adoptLiveEditorText` call in
    // `editorFirstJobSettled`. Predicted failure: "the Gamma note was taken out of the Notes by a resync of the old text".
    @Test(
        "C1: the settle derives the Notes from the editor's own text when content is behind",
        arguments: ["whole", "replace", "insert", "slowUndo"])
    func testTheSettleReadsTheEditorsOwnText(_ kind: String) async throws {
        let rig = try EditorFirstRig(markdown: Self.footnotedDocument, lifecycleServices: true)
        defer { unpinAllVersions(rig) }
        rig.footnotes.lastKnownRefs = FootnoteSyncService.extractFootnoteRefs(from: Self.footnotedDocument)
        rig.footnotes.lastContentWithKnownRefs = Self.footnotedDocument
        #expect(try rig.notesTexts() == Self.allThreeNotes, "precondition: the fixture's Notes")

        switch kind {
        case "whole":
            let version = try saveVersion(rig)
            try removeRows(rig, ofSectionTitled: "Gamma")   // the document the user then had: no Gamma, its note still in the Notes
            rig.editorState.content = try rig.assembledMarkdown()
            rig.withholdContentUpdate = true
            #expect(await rig.performRestore("project", from: version) == .performed)
        case "replace":
            try await rig.fillSectionTable()
            let version = try saveVersion(rig)
            let body = try #require(try rig.blocks().first { $0.textContent.hasPrefix("Gamma text") })
            try rig.rewriteText(ofBlock: body.id, to: "Gamma text.")   // no reference any more
            try await rig.fillSectionTable()
            rig.withholdContentUpdate = true
            #expect(await rig.performRestore("replace", from: version, section: "Gamma") == .performed)
        case "insert":
            try await rig.fillSectionTable()
            let version = try saveVersion(rig)
            try removeRows(rig, ofSectionTitled: "Gamma")
            try await rig.fillSectionTable()
            rig.withholdContentUpdate = true
            #expect(await rig.performRestore("duplicate", from: version, section: "Gamma") == .performed)
        default:
            rig.controller.testForceSlowDeleteUndo = true
            let deleted = try await delete(rig, "Gamma")   // content is the post-delete text afterwards
            rig.withholdContentUpdate = true
            #expect(await rig.pressAndSettle(deleted.entry), "the slow undo did not end and settle")
        }
        _ = await rig.waitUntilSettled()
        _ = await gateWaitUntil({ rig.footnotes.state == .idle && rig.footnotes.inFlightCount == 0 }, iterations: 1200)

        let notesAfter = try rig.notesTexts()
        #expect(
            notesAfter == Self.allThreeNotes,
            "the Gamma note was taken out of the Notes by a resync of the old text (\(kind)): \(notesAfter)")
        #expect(rig.editorText?.contains("Gamma text.[^3]") == true, "the editor does not show the restored Gamma text (\(kind))")
    }
}

// Fix round F4 (break patch S2-23: the `adoptLiveEditorText` call in `editorFirstJobSettled`). C1 above is ONE parameterised test, and a
// test run's summary shows only the first issue of a failing parameterised test: with the call removed it seemed to fail for the
// "whole" argument only, although all four arguments fail. (Checked by playing the call's absence in the rig: the editor answering
// `getContent()` with the stale `content`, so that reading the editor changes nothing. The settle then resynced the OLD text and the
// Notes lost the Gamma note for whole, replace, insert and slowUndo alike; with the real read all four keep all three notes.) The same
// scenarios as four tests of their own, so that every kind is reported on its own line, with one more check: `content` really is
// behind the editor's own text when the settle starts, so none of them can pass for a reason other than the settle's read.
// Predicted failure with the call removed, per kind: "the Gamma note was taken out of the Notes by a resync of the old text (<kind>)".
extension EditorFirstFixRoundF1Tests {

    @Test("C1 whole: the settle of a whole restore derives the Notes from the editor's own text when content is behind")
    func testSettleOfAWholeRestoreReadsTheEditorsOwnText() async throws {
        try await expectTheSettleReadsTheEditorsOwnText("whole")
    }

    @Test("C1 replace: the settle of Replace Current Section derives the Notes from the editor's own text when content is behind")
    func testSettleOfASectionReplaceReadsTheEditorsOwnText() async throws {
        try await expectTheSettleReadsTheEditorsOwnText("replace")
    }

    @Test("C1 insert: the settle of Insert as New Section derives the Notes from the editor's own text when content is behind")
    func testSettleOfARestoreAsDuplicateReadsTheEditorsOwnText() async throws {
        try await expectTheSettleReadsTheEditorsOwnText("insert")
    }

    @Test("C1 slowUndo: the settle of a slow undo derives the Notes from the editor's own text when content is behind")
    func testSettleOfASlowUndoReadsTheEditorsOwnText() async throws {
        try await expectTheSettleReadsTheEditorsOwnText("slowUndo")
    }

    /// C1's scenario for one kind. `content` (the editor's `contentChanged` push) is withheld, so when the settle starts it still holds
    /// the text from BEFORE the operation, which has no reference to the Gamma note (the operation brings the reference back: the
    /// restored or swapped-in text has `[^3]`, `content` has not); a footnote resync of that text would take the Gamma definition out of
    /// the Notes. No `testEFSettleHold` copying the database text into `content` (the article rig's would mask the read); the hold used
    /// here only looks.
    private func expectTheSettleReadsTheEditorsOwnText(_ kind: String) async throws {
        let rig = try EditorFirstRig(markdown: Self.footnotedDocument, lifecycleServices: true)
        defer { unpinAllVersions(rig) }
        rig.footnotes.lastKnownRefs = FootnoteSyncService.extractFootnoteRefs(from: Self.footnotedDocument)
        rig.footnotes.lastContentWithKnownRefs = Self.footnotedDocument
        #expect(try rig.notesTexts() == Self.allThreeNotes, "precondition (\(kind)): the fixture's Notes")
        let probe = StaleContentProbe()
        rig.controller.testEFSettleHold = { [weak rig, probe] in
            guard let rig else { return }
            probe.contentRefs = FootnoteSyncService.extractFootnoteRefs(from: rig.editorState.content)
            probe.editorRefs = FootnoteSyncService.extractFootnoteRefs(from: rig.editorText ?? "")
        }

        switch kind {
        case "whole":
            let version = try saveVersion(rig)
            try removeRows(rig, ofSectionTitled: "Gamma")   // the document the user then had: no Gamma, its note still in the Notes
            rig.editorState.content = try rig.assembledMarkdown()
            rig.withholdContentUpdate = true
            #expect(await rig.performRestore("project", from: version) == .performed)
        case "replace":
            try await rig.fillSectionTable()
            let version = try saveVersion(rig)
            let body = try #require(try rig.blocks().first { $0.textContent.hasPrefix("Gamma text") })
            try rig.rewriteText(ofBlock: body.id, to: "Gamma text.")   // no reference any more
            try await rig.fillSectionTable()
            rig.withholdContentUpdate = true
            #expect(await rig.performRestore("replace", from: version, section: "Gamma") == .performed)
        case "insert":
            try await rig.fillSectionTable()
            let version = try saveVersion(rig)
            try removeRows(rig, ofSectionTitled: "Gamma")   // no Gamma section, its note still in the Notes
            try await rig.fillSectionTable()
            rig.withholdContentUpdate = true
            #expect(await rig.performRestore("duplicate", from: version, section: "Gamma") == .performed)   // the copy brings [^3]
        default:
            rig.controller.testForceSlowDeleteUndo = true
            let deleted = try await delete(rig, "Gamma")   // content is the post-delete text afterwards
            rig.withholdContentUpdate = true
            #expect(await rig.pressAndSettle(deleted.entry), "the slow undo did not end and settle")
        }
        _ = await rig.waitUntilSettled()
        _ = await gateWaitUntil({ rig.footnotes.state == .idle && rig.footnotes.inFlightCount == 0 }, iterations: 1200)

        #expect(probe.contentRefs != nil, "the settle never started (\(kind))")
        let (contentRefs, editorRefs) = (String(describing: probe.contentRefs), String(describing: probe.editorRefs))
        #expect(
            probe.contentRefs != probe.editorRefs,
            "precondition (\(kind)): content was not behind the editor's text when the settle started (\(contentRefs) vs \(editorRefs))")
        let notesAfter = try rig.notesTexts()
        #expect(
            notesAfter == Self.allThreeNotes,
            "the Gamma note was taken out of the Notes by a resync of the old text (\(kind)): \(notesAfter)")
        #expect(rig.editorText?.contains("Gamma text.[^3]") == true, "the editor does not show the restored Gamma text (\(kind))")
    }
}

/// What the settle of C1 saw when it started: the footnote references of `content` against those of the editor's own text.
private final class StaleContentProbe {
    var contentRefs: [String]?
    var editorRefs: [String]?
}
