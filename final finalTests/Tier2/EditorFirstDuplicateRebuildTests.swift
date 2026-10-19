//
//  EditorFirstDuplicateRebuildTests.swift
//  final finalTests
//
//  Tier 2 (t-18b7fa48 Phase 4b slice 3, round 1e-ii; plan-v3 tests U-S1-5, U-S1-6, U-S1-8, U-S1-9 with the judge's addendum and the
//  round verdicts 1a, 1b and 1a-ii). The sibling of EditorFirstDuplicateTests.swift (round 1e-i): the cases of Duplicate Section that
//  meet a Notes or Bibliography rebuild, a quick undo, or a refusal. Driven with `EditorFirstRig` (EditorFirstDeleteTests.swift); the
//  duplicate's answers are in EditorFirstRig+StructuralQueue.swift. The shared helpers are QuickUndoFixtures.swift's.
//
//  THE STAMP (D6, U-S1-5). A Notes or Bibliography rebuild reads the database, and some time later pushes what it read into the editor. A
//  Duplicate Section click changes the editor's document before the database follows, so a rebuild that read the table before the copy
//  existed would put a document WITHOUT the copy back over the editor. The guard (`rebuildPushStillWanted`) skips that push; it has two
//  halves and the model checks only the first (round 1a verdict M1), so the unit test covers BOTH orders:
//    (i)  a rebuild that read BEFORE the click and lands after it (the click generation moved);
//    (ii) a rebuild that read AFTER the click and lands while the duplicate's job is still pending (the table has no copy yet).
//  What each test looks at is what the user sees: the editor is never pushed a document without the copy, the editor's text keeps the copy,
//  the Notes end up as they do for a duplicate that met no rebuild at all, and typing into the copy reaches the database. The one
//  mechanism check is the addendum's must-fix 1: a rebuild that reads when the duplicate's own settle starts must count as current (the
//  pending-jobs count is down BEFORE the settle), or the settle's own Notes update is skipped for good.
//
//  Round 1g-B (review A3) adds the same two orders for the quick REDO of a duplicate (the extension at the end of the file).
//
//  The rig's editor has no ContentView, so no rebuild fires by itself: a stand-in Task (`startStampedRebuildNotingSkip`) plays the rebuild
//  through the real guard (`stampRebuildRead`, `setContentWithBlockIds(stillWanted:)`, `skipStaleRebuildTail`). The stand-in's push is
//  recorded by the rig only when the guard lets it through, so `rig.pushes` is what actually reached the editor.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import Testing
@testable import final_final

@Suite("Editor-first duplicate and the rebuild guard (t-18b7fa48 slice 1, round 1e-ii, Tier 2)", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct EditorFirstDuplicateRebuildTests: QuickUndoFixtures {

    // MARK: - Helpers

    /// What the duplicate's settle saw when it started (written by the settle hold, read after the settle).
    private final class SettleStartProbe {
        var pendingJobsAtSettleStart = -1
        var stampAtSettleStart: RebuildReadStamp?
    }

    private func duplicate(_ rig: EditorFirstRig, _ title: String) async throws {
        let outcome = await rig.controller.performSectionDuplicate(rootId: try rig.heading(title).id)
        #expect(outcome == .performed, "the duplicate of \(title) ended \(outcome)")
    }

    private func press(_ rig: EditorFirstRig, _ direction: StructuralUndoController.UndoDirection) async throws {
        let entry = try #require(direction == .undo ? rig.unifiedUndo.undoStack.last : rig.unifiedUndo.redoStack.last)
        #expect(await rig.pressAndSettle(entry, direction), "the \(direction) did not end and settle")
        _ = await rig.waitUntilSettled()
    }

    /// The last level-2 section of the article that holds no footnote reference ("1.6 Conclusion").
    private func footnoteFreeSection(_ rig: EditorFirstRig) throws -> Block {
        let footnoted = Set(try footnotedSections(rig).map { $0.heading.id })
        return try #require(try rig.blocks()
            .filter { $0.blockType == .heading && $0.headingLevel == 2 && !$0.isNotes && !$0.isBibliography && !footnoted.contains($0.id) }
            .sorted { $0.sortOrder < $1.sortOrder }.last)
    }

    /// `QuickUndoFixtures.startStampedRebuild`, plus a `rebuild push skipped` event when the guard skipped the push (the stand-in's
    /// `skipStaleRebuildTail` returned true) and, BEFORE `rebuild landed`, whether `content` is the editor's own text at that moment (the
    /// stale rebuild assigns the database's older text to `content` first and the guard's tail must put the editor's own text back).
    /// Reads the database NOW, stamping first (as the three rebuild handlers do), and lands when `mayLand` opens.
    private func startStampedRebuildNotingSkip(_ rig: EditorFirstRig, mayLand: LifecycleEntryHarness.Gate) {
        let stamp = rig.editorState.stampRebuildRead()
        let read = rig.controller.fetchFullBlocksWithIds(db: rig.db, pid: rig.pid)
        rig.events.note("rebuild read")
        let task = Task { @MainActor in
            await mayLand.wait()
            if let read {
                rig.editorState.content = read.markdown
                _ = await rig.sync.setContentWithBlockIds(
                    markdown: read.markdown, blockIds: read.blockIds, imageMeta: read.imageMeta,
                    cursorBoundary: read.bibBoundaryIndex, cursorBoundaryEnd: read.bibBoundaryEndIndex,
                    expectedBlocks: read.expectedBlocks, managedBlockIds: read.managedBlockIds, preserveUserBlocks: true,
                    stillWanted: { rig.editorState.rebuildPushStillWanted(stamp) })
                if await rig.editorState.skipStaleRebuildTail(stamp, kind: "notes", blockSync: rig.sync) {
                    rig.events.note("rebuild push skipped")
                }
            }
            rig.editorState.contentState = .idle
            rig.events.note("rebuild content-equals-live=\(rig.editorState.content == rig.quickEditorText)")
            rig.events.note("rebuild landed")
        }
        rig.editorState.registerRebuildTask(task)
    }

    /// The article rig's settle hold, replaced: the settle waits for the stand-in rebuild to have landed (so its stale assignment of
    /// `content` can never fall between the sync below and the resyncs that read it), syncs `content` from the database as
    /// `makeArticleRig`'s own hold does, and records what a rebuild reading at that moment would stamp.
    private func holdSettleUntilTheRebuildLanded(_ rig: EditorFirstRig, _ probe: SettleStartProbe) {
        rig.controller.testEFSettleHold = { [weak rig, probe] in
            guard let rig else { return }
            _ = await gateWaitUntil({ rig.events.items.contains("rebuild landed") }, iterations: 600)
            _ = try? rig.syncEditorContentFromDatabase()
            probe.pendingJobsAtSettleStart = rig.editorState.pendingEditorFirstJobs
            probe.stampAtSettleStart = rig.editorState.stampRebuildRead()
        }
    }

    /// The article after the section titled `title` was duplicated with no stamped rebuild anywhere: what the document and its Notes are
    /// when nothing interferes. Its `content` is synced from the database, as `delete(settle: true)` does for a delete.
    private func referenceAfterDuplicate(of title: String) async throws -> EditorFirstRig {
        let reference = try makeArticleRig()
        try await duplicate(reference, title)
        _ = await reference.waitUntilSettled()
        try reference.syncEditorContentFromDatabase()
        return reference
    }

    /// The user's view after a duplicate that met a stale rebuild: nothing pushed after the click lacks the copy, the editor was given the
    /// database's Notes after the skipped push, the duplicate's own settle counted as current, the Notes and the text are the reference's,
    /// and typing into the copy reaches the database.
    private func expectTheUserSeesTheReference(
        _ rig: EditorFirstRig, reference: EditorFirstRig, probe: SettleStartProbe, copyTitle: String, pushesFrom: Int
    ) async throws {
        // 1. Nothing the editor was pushed after the click lacks the copy; the editor was given the database's Notes afterwards.
        #expect(rig.quickEditorText?.contains(copyTitle) == true, "the editor's own text lost the copy")
        let pushes = Array(rig.pushes[pushesFrom...])
        #expect(
            pushes.allSatisfy { $0.markdown.contains(copyTitle) },
            "the stale rebuild pushed a document without the copy (\(pushes.count) push(es) after the click)")
        #expect(
            pushes.contains { $0.preserveUserBlocks && $0.markdown.contains(copyTitle) },
            "the editor was never given the database's Notes and Bibliography after the skipped rebuild")

        // 2. The order (the addendum's must-fix 1): the pending count was down when the duplicate's own settle started, so a rebuild
        // reading there is current and its push is not skipped.
        #expect(
            probe.pendingJobsAtSettleStart == 0,
            "expected the pending count down before the settle started, got \(probe.pendingJobsAtSettleStart)")
        let settleStamp = try #require(probe.stampAtSettleStart, "the duplicate's settle never started")
        #expect(
            rig.editorState.rebuildPushStillWanted(settleStamp),
            "a rebuild reading when the duplicate's settle starts would have its push skipped: the settle's own Notes update would be lost")
        #expect(rig.editorState.pendingEditorFirstJobs == 0, "the pending count came back down")
        #expect(!rig.editorState.managedRegionsNeedRepush, "the re-push owed to the editor was made")

        // 3. The Notes and the editor's text are the reference duplicate's, and the copy is there.
        try rig.syncEditorContentFromDatabase()   // as `delete(settle: true)` does
        #expect(try rig.notesTexts() == (try reference.notesTexts()), "Notes differ from the duplicate that had no stamped rebuild")
        #expect(rig.editorState.content == reference.editorState.content, "the editor's text (Notes/Bibliography) differs from the reference")
        #expect(rig.editorState.content.contains(copyTitle), "the copy is missing from the editor's text")
        #expect(try rig.blocks().filter { $0.textContent == copyTitle }.count == 1, "the copy is not in the table exactly once")

        // 4. Typing into the copy reaches the database (the copy's rows carry the ids the editor gave them).
        let copyRoot = try rig.heading(copyTitle)
        let copyIds = try #require(try rig.db.sectionBlockIds(rootId: copyRoot.id, projectId: rig.pid))
        let body = try firstParagraph(in: copyIds, rig)
        rig.queueTyping(body, appending: " TYPED-IN-THE-COPY")
        #expect(await rig.awaitRuns([rig.startPoll()]), "the poll after the typing never ended")
        _ = await rig.waitUntilSettled()
        let stored = try rig.blocks().first { $0.id == body.id }
        #expect(
            stored?.textContent.hasSuffix("TYPED-IN-THE-COPY") == true,
            "typing into the copy did not reach the database: \(String(describing: stored?.textContent.suffix(40)))")
    }

    // MARK: - U-S1-5 (i)

    // U-S1-5 (i): a rebuild that read the database BEFORE the Duplicate click lands after it. Its push is skipped, `content` goes back to
    // the editor's own text (the copy included), and the duplicate's own settle leaves the Notes as they are with no stamped rebuild.
    @Test("U-S1-5 (i): a rebuild that read before the Duplicate Section click skips its push, and the copy and the Notes are as with no rebuild")
    func testStaleRebuildDoesNotPushOverTheCopy_article() async throws {
        let rig = try makeArticleRig()
        let title = try #require(try footnotedSections(rig).first).heading.textContent
        let copyTitle = title + " copy"
        let reference = try await referenceAfterDuplicate(of: title)

        let probe = SettleStartProbe()
        holdSettleUntilTheRebuildLanded(rig, probe)
        let mayLand = LifecycleEntryHarness.Gate()
        defer { mayLand.open() }
        startStampedRebuildNotingSkip(rig, mayLand: mayLand)   // reads the database BEFORE the click: the table has no copy yet
        let pushesBeforeClick = rig.pushes.count

        try await duplicate(rig, title)
        mayLand.open()
        let landed = await gateWaitUntil({ rig.events.items.contains("rebuild landed") }, iterations: 600)
        let settled = await rig.waitUntilSettled()

        #expect(landed, "the stand-in rebuild never landed")
        #expect(settled, "the duplicate never settled")
        #expect(rig.events.items.contains("rebuild push skipped"), "expected the guard to skip the push of the rebuild that read before the click")
        #expect(
            rig.events.items.contains("rebuild content-equals-live=true"),
            "content lost the copy to the stale rebuild (it was not put back to the editor's own text)")
        try await expectTheUserSeesTheReference(rig, reference: reference, probe: probe, copyTitle: copyTitle, pushesFrom: pushesBeforeClick)
    }

    // MARK: - U-S1-5 (ii)

    // U-S1-5 (ii): a rebuild that read the database AFTER the click but BEFORE the duplicate's job applied (the table has no copy yet) lands
    // while the job still pends. The click generation has not moved since it read; only the pending-jobs half of the stamp can skip it.
    @Test("U-S1-5 (ii): a rebuild that read while the duplicate's job was pending skips its push, and the copy and the Notes are as with no rebuild")
    func testRebuildThatReadWhileTheJobPendedDoesNotPushOverTheCopy_article() async throws {
        let rig = try makeArticleRig()
        let title = try #require(try footnotedSections(rig).first).heading.textContent
        let copyTitle = title + " copy"
        let reference = try await referenceAfterDuplicate(of: title)

        let probe = SettleStartProbe()
        holdSettleUntilTheRebuildLanded(rig, probe)
        let blocker = try rig.holdQueue()   // the duplicate's job waits behind this
        defer { rig.release(blocker) }
        let mayLand = LifecycleEntryHarness.Gate()
        defer { mayLand.open() }

        try await duplicate(rig, title)
        #expect(rig.editorState.pendingEditorFirstJobs == 1, "precondition: the duplicate's job is pending")
        #expect(try !rig.blocks().contains { $0.textContent == copyTitle }, "precondition: the table has no copy yet")
        let pushesBeforeRebuild = rig.pushes.count
        startStampedRebuildNotingSkip(rig, mayLand: mayLand)   // the click is over, the job is not: this read has no copy
        mayLand.open()
        let landed = await gateWaitUntil({ rig.events.items.contains("rebuild landed") }, iterations: 600)

        // The job has not run: the rebuild's older document must not have reached the editor.
        #expect(landed, "the stand-in rebuild never landed")
        #expect(
            rig.pushes.count == pushesBeforeRebuild,
            "the stale rebuild pushed a document without the copy while the duplicate's job was pending")
        #expect(
            rig.events.items.contains("rebuild push skipped"),
            "expected the guard to skip the push of the rebuild that read while the job was pending")
        #expect(
            rig.events.items.contains("rebuild content-equals-live=true"),
            "content lost the copy to the stale rebuild (it was not put back to the editor's own text)")

        rig.release(blocker)
        let settled = await rig.waitUntilSettled()
        #expect(settled, "the duplicate never settled")
        try await expectTheUserSeesTheReference(rig, reference: reference, probe: probe, copyTitle: copyTitle, pushesFrom: pushesBeforeRebuild)
    }

    // MARK: - U-S1-6

    // U-S1-6: the Cmd-Z of a plain Duplicate of a footnoted section on the article takes the copy out the quick way. (The real sequence
    // of t-1d2adbbc, with typing in between, is the e2e testFootnotedDuplicateTypeTextUndoUndo_article.)
    @Test("U-S1-6: Cmd-Z of a duplicated footnoted section takes the copy out the quick way")
    func testFootnotedDuplicateQuickUndo_article() async throws {
        let rig = try makeArticleRig()
        let section = try #require(try footnotedSections(rig).first).heading
        try await duplicate(rig, section.textContent)
        _ = await rig.waitUntilSettled()
        #expect(
            try rig.blocks().contains { $0.textContent == section.textContent + " copy" },
            "precondition: the duplicate put the copy in the table")

        try await press(rig, .undo)
        #expect(rig.quickUndoScripts.count == 1, "expected the quick undo, saw \(rig.quickUndoScripts.count) quick undo(s)")
        #expect(rig.scripts(containing: "performStructuralSwap").isEmpty, "expected no slow swap for the undo of a footnoted duplicate")
        #expect(rig.replyWords().suffix(1) == ["undo performed"], "got \(rig.replyWords())")
        #expect(try !rig.blocks().contains { $0.textContent == section.textContent + " copy" }, "the copy is still in the table")
        #expect(try rig.blocks().filter { $0.textContent == section.textContent }.count == 1, "and the original section is still there, once")
    }

    // MARK: - U-S1-8

    // U-S1-8 (judge item 1): Cmd-Z of a footnoted delete, then at once Duplicate. The duplicate is pressed while the undo's own settle is
    // still reading the editor, the one moment a click that moved the restore generation (D6 as plan v2 had it) would make that settle
    // stand down and never re-derive or push the Notes and Bibliography of the section that came back. The click does not touch
    // `editorRestoreGeneration`, so the undo's settle runs to its end and the document ends as if every settle had finished first.
    @Test("U-S1-8: Cmd-Z of a footnoted delete, then Duplicate at once: rows, Notes and sidebar are those of a reference that waited")
    func testQuickUndoThenDuplicateAtOnce_article() async throws {
        let reference = try makeArticleRig()
        let rig = try makeArticleRig()
        reference.duplicateInsertsIntoEditorText = true   // the editor's own text gets the copy, whatever the database holds meanwhile
        rig.duplicateInsertsIntoEditorText = true
        let deleted = try #require(try footnotedSections(rig).first).heading.textContent
        let duplicated = try footnoteFreeSection(rig).textContent
        let copyTitle = duplicated + " copy"
        let deletedInReference = try await delete(reference, deleted)
        let deletedInRig = try await delete(rig, deleted)

        // The reference: every settle ends before the next press.
        #expect(await reference.pressAndSettle(deletedInReference.entry), "the reference's undo did not end and settle")
        try await duplicate(reference, duplicated)
        _ = await reference.waitUntilSettled()

        // The rig: the duplicate is pressed while the undo's settle is waiting for the editor's live text.
        let readMayEnd = LifecycleEntryHarness.Gate()
        defer { readMayEnd.open() }
        let reads = GateOrderLog()
        rig.getContentHold = {
            reads.note("read")
            if reads.items.count == 1 { await readMayEnd.wait() }
        }
        let undo = rig.startPress(deletedInRig.entry)
        #expect(await rig.awaitRuns([undo]), "the undo did not end")
        #expect(await gateWaitUntil { reads.items.count >= 1 }, "the undo's settle is waiting for its live read")
        try await duplicate(rig, duplicated)
        readMayEnd.open()
        #expect(await rig.waitUntilSettled(), "the undo and the duplicate never settled")

        // What the user has.
        let rowsProblem = EditorFirstRig.parityProblem(try reference.blocks(), try rig.blocks())
        #expect(rowsProblem == nil, "rows differ from the reference: \(rowsProblem ?? "")")
        #expect(try rig.notesTexts() == (try reference.notesTexts()), "Notes differ from the reference")
        #expect(try rig.blocks().filter { $0.textContent == copyTitle }.count == 1, "the copy is not in the table exactly once")
        let shown: (EditorFirstRig) -> [String] = { $0.editorState.sections.map { "\($0.headerLevel) \($0.title)" } }
        #expect(shown(rig) == shown(reference), "the sidebar differs from the reference: \(shown(rig)) versus \(shown(reference))")
        #expect(shown(rig).filter { $0 == "2 \(copyTitle)" }.count == 1, "the copy is not listed once in the sidebar: \(shown(rig))")
        #expect(rig.editorState.pendingRestoreSections.isEmpty, "the overlay that showed the sections before their rows existed was not lifted")
        #expect(rig.editorState.pendingRemovalIds.isEmpty, "a filter that hid a section was not lifted: \(rig.editorState.pendingRemovalIds)")

        // The undo's own settle ran to its end: the restored section's Notes and Bibliography were re-derived and the editor was given the
        // database's. Under D6 as plan v2 had it, the duplicate click moves the restore generation while the settle is reading the editor,
        // the settle stands down ("another quick undo or redo took over") and nothing after the restore ever reaches the editor.
        #expect(
            rig.spyLog.items.contains("reinsertSettled"),
            "the undo's settle stood down after the duplicate click: the Notes of the restored section were never refreshed")
        let restore = try #require(rig.events.items.lastIndex { $0.contains("undoSectionDeleteEditorFirst") })
        let mergePushesAfterRestore = rig.events.items[restore...].filter { $0 == "setContent preserve=true" }.count
        #expect(mergePushesAfterRestore >= 1, "the editor was never given the database's Notes and Bibliography after the undo")
    }

    // MARK: - U-S1-9

    // U-S1-9 (D6a): the editor refuses the Duplicate click (ok:false, with the batch it consumed). The press ends `.refused` (the sidebar
    // then shows "Couldn't Duplicate Section": ContentView+SectionOperations.swift raises that alert from the outcome, so the controller
    // itself raises none), the typing the click consumed is not lost, the pending count comes down at once, and one fresh settle
    // re-pushes the managed regions (a rebuild whose push the click's stamp skipped would otherwise leave the editor's Notes half done).
    @Test("U-S1-9 (D6a): a Duplicate Section click the editor refuses ends refused, keeps the typing, and runs the fresh settle")
    func testRefusedDuplicateClickRunsTheFreshSettle_article() async throws {
        let rig = try makeArticleRig()
        rig.controller.testOrderingSpy = { [spyLog = rig.spyLog, events = rig.events] step in
            spyLog.note(step)
            events.note("spy " + step)
        }
        let section = try #require(try footnotedSections(rig).first).heading
        let sectionIds = try #require(try rig.db.sectionBlockIds(rootId: section.id, projectId: rig.pid))
        let lead = try paragraphOutside(sectionIds, rig)
        let suffix = " TYPED-BEFORE-THE-REFUSED-CLICK"
        rig.duplicateClickBatch = BlockChanges(updates: [BlockUpdate(
            id: lead.id, textContent: lead.textContent + suffix, markdownFragment: lead.markdownFragment + suffix, headingLevel: nil)])
        rig.forceEditorRefusal = true
        let generationBefore = rig.editorState.editorFirstClickGeneration

        let outcome = await rig.controller.performSectionDuplicate(rootId: section.id)
        _ = await gateWaitUntil({ rig.events.items.contains("spy efRepushManagedRegions") }, iterations: 2000)
        _ = await rig.waitUntilSettled()
        let typingKept = await gateWaitUntil({ (try? rig.blocks().first { $0.id == lead.id }?.textContent.hasSuffix(suffix)) == true })

        #expect(outcome == .refused, "the editor refused, so the press is refused (it ended \(outcome))")
        #expect(rig.duplicateScripts.count == 1, "the editor was asked once")
        #expect(rig.editorState.editorFirstClickGeneration == generationBefore + 1, "the click moved the stamp before its JavaScript went out")
        #expect(rig.editorState.pendingEditorFirstJobs == 0, "the pending count stayed up after a refused click")
        #expect(rig.events.items.contains("spy efRepushManagedRegions"), "no managed-region re-push after a refused click")
        #expect(!rig.editorState.managedRegionsNeedRepush, "the re-push owed to the editor was made")
        #expect(rig.unifiedUndo.undoStack.isEmpty, "a refused click records nothing")
        #expect(try !rig.blocks().contains { $0.textContent == section.textContent + " copy" }, "the table holds a copy although the editor refused")
        #expect(typingKept, "the typing the refused click consumed did not reach the database")
        #expect(rig.alerts.isEmpty, "the controller raised an alert of its own; the sidebar raises the one the user sees: \(rig.alerts)")
    }
}

// An extension of the same suite (the struct body is at the linter's length limit): the A3 tests below use the suite's private helpers.
extension EditorFirstDuplicateRebuildTests {

    // MARK: - A3 (round 1g-B): the quick redo of a duplicate is covered like the click
    //
    // Cmd-Shift-Z of a quick-undone duplicate is a fresh editor-first duplicate: the editor shows the copy at once and the redo's job
    // writes the rows later. Until round 1g-B it raised no `pendingEditorFirstJobs` and moved no click generation, so a Notes or
    // Bibliography rebuild that read the table AFTER the redo's reply (no copy in it yet, and the undo's reinsert long applied) was
    // judged current and pushed a document without the copy. The two orders again, as U-S1-5:
    //    (i)  a rebuild that read BEFORE the redo and lands after it;
    //    (ii) a rebuild that read AFTER the redo's reply, while the redo's job is still queued.
    // These use the four-section document: it has no Notes, so the rig's stand-in for the merge-guarded push hands back the database's
    // text, and a stale push shows up on the screen (`editorText`) as the copy missing, as it would in the real editor.

    /// Duplicates Section C, takes the copy out again with Cmd-Z (everything settled), holds the writer's queue and presses Cmd-Shift-Z:
    /// the press has ended, the copy is on the screen, and the redo's job waits behind the hold so the table has no copy yet.
    /// `beforeRedo` runs after the hold is taken and before the press (where order (i) starts its rebuild).
    private func redoDuplicateWithItsJobQueued(
        _ rig: EditorFirstRig, beforeRedo: () -> Void = {}
    ) async throws -> (blocker: WriterTicket, copyIds: [String]) {
        try await duplicate(rig, "Section C")
        _ = await rig.waitUntilSettled()
        let copyIds = try #require(rig.duplicateClicks.values.first).copyIds
        try await press(rig, .undo)
        let blocker = try rig.holdQueue()
        beforeRedo()
        let redo = rig.startPress(try #require(rig.unifiedUndo.redoStack.last), .redo)
        #expect(await rig.awaitRuns([redo]), "the redo did not end")
        #expect(rig.editorState.pendingEditorFirstJobs == 1, "precondition: the redo's job is pending and holds the count")
        #expect(try rig.presentRowCount(copyIds) == 0, "precondition: the table has no copy yet")
        return (blocker, copyIds)
    }

    /// The non-empty lines of a Markdown text: what the screen and the table are compared by (blank lines carry no content).
    private func contentLines(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// What the user has once the redo's job has applied: the copy in the table under the first click's ids and on the screen, the screen
    /// equal to the table, nothing the editor was pushed after the redo lacks the copy, and the editor was given the database's Notes
    /// and Bibliography afterwards (the re-push the skipped rebuild owed).
    private func expectTheRedoneCopyIsEverywhere(_ rig: EditorFirstRig, copyIds: [String], pushesFrom: Int) throws {
        #expect(try rig.presentRowCount(copyIds) == copyIds.count, "the redo's job did not put the copy's rows back under the first click's ids")
        let screen = try #require(rig.editorText, "the editor holds no document")
        #expect(screen.contains("Section C copy"), "the copy is not in the editor: \(screen)")
        let table = try rig.assembledMarkdown()
        #expect(contentLines(screen) == contentLines(table), "the editor and the table differ:\n\(screen)\n---\n\(table)")
        let pushes = Array(rig.pushes[pushesFrom...])
        #expect(
            pushes.allSatisfy { $0.markdown.contains("Section C copy") },
            "a document without the copy was pushed into the editor after the redo (\(pushes.count) push(es))")
        #expect(
            pushes.contains { $0.preserveUserBlocks && $0.markdown.contains("Section C copy") },
            "the editor was never given the database's Notes and Bibliography after the skipped rebuild")
        #expect(rig.editorState.pendingEditorFirstJobs == 0, "the pending count came back down")
        #expect(!rig.editorState.managedRegionsNeedRepush, "the re-push owed to the editor was made")
        #expect(rig.alerts.isEmpty, "an alert was raised: \(rig.alerts)")
    }

    // A3 (ii): the rebuild reads after the redo's reply, while the redo's job is queued. Only the pending-jobs half of the stamp can skip it.
    @Test("A3 (ii): a rebuild that read after the Duplicate redo's reply skips its push, and the copy stays on the screen and reaches the table")
    func testRebuildThatReadAfterTheDuplicateRedoSkipsItsPush() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let (blocker, copyIds) = try await redoDuplicateWithItsJobQueued(rig)
        defer { rig.release(blocker) }
        let pushesBefore = rig.pushes.count
        let mayLand = LifecycleEntryHarness.Gate()
        defer { mayLand.open() }

        startStampedRebuildNotingSkip(rig, mayLand: mayLand)   // the redo's reply is over, its job is not: this read has no copy
        mayLand.open()
        let landed = await gateWaitUntil({ rig.events.items.contains("rebuild landed") }, iterations: 600)

        #expect(landed, "the stand-in rebuild never landed")
        #expect(
            rig.events.items.contains("rebuild push skipped"),
            "expected the guard to skip the push of the rebuild that read while the redo's job was pending")
        #expect(rig.pushes.count == pushesBefore, "the stale rebuild pushed a document without the copy while the redo's job was pending")
        #expect(
            rig.events.items.contains("rebuild content-equals-live=true"),
            "content lost the copy to the stale rebuild (it was not put back to the editor's own text)")
        #expect(rig.editorText?.contains("Section C copy") == true, "the copy left the editor")

        rig.release(blocker)
        #expect(await rig.waitUntilSettled(), "the redo never settled")
        try expectTheRedoneCopyIsEverywhere(rig, copyIds: copyIds, pushesFrom: pushesBefore)
    }

    // A3 (i): the rebuild read before the redo and lands after it. The restore generation already skips its push; the click generation is
    // what makes the skip owe the editor a re-push (a stamp that went stale only because a quick undo or redo started raises nothing, since
    // the reinsert's own settle is expected to push, and the redo has taken the reinsert's settle away).
    @Test("A3 (i): a rebuild that read before the Duplicate redo skips its push, and the editor is given the database's Notes after the redo's job")
    func testRebuildThatReadBeforeTheDuplicateRedoSkipsItsPushAndTheRegionsAreRepushed() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let mayLand = LifecycleEntryHarness.Gate()
        defer { mayLand.open() }
        let (blocker, copyIds) = try await redoDuplicateWithItsJobQueued(rig) {
            self.startStampedRebuildNotingSkip(rig, mayLand: mayLand)   // reads the table with no copy, BEFORE the redo's stretch
        }
        defer { rig.release(blocker) }
        let pushesBefore = rig.pushes.count

        mayLand.open()
        let landed = await gateWaitUntil({ rig.events.items.contains("rebuild landed") }, iterations: 600)

        #expect(landed, "the stand-in rebuild never landed")
        #expect(
            rig.events.items.contains("rebuild push skipped"), "expected the guard to skip the push of the rebuild that read before the redo")
        #expect(rig.pushes.count == pushesBefore, "the stale rebuild pushed a document without the copy")
        #expect(
            rig.events.items.contains("rebuild content-equals-live=true"),
            "content lost the copy to the stale rebuild (it was not put back to the editor's own text)")

        rig.release(blocker)
        #expect(await rig.waitUntilSettled(), "the redo never settled")
        try expectTheRedoneCopyIsEverywhere(rig, copyIds: copyIds, pushesFrom: pushesBefore)
    }

    // A3, the abandon exits: the editor refuses the redo. No job was reserved, so the count the redo raised comes down at once, BEFORE the
    // fresh settle (its repush stamps after the count is down, so the stamp is current and the push reaches the editor), and a rebuild
    // that reads afterwards is current. A count left up would skip every later rebuild's push for good.
    @Test("A3: a Duplicate redo the editor refuses brings the pending count back down before the fresh settle, so later rebuilds are current")
    func testRefusedDuplicateRedoReleasesThePendingCount() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        try await duplicate(rig, "Section C")
        _ = await rig.waitUntilSettled()
        try await press(rig, .undo)
        let pushesBefore = rig.pushes.count
        rig.refuseNextDuplicateRedoWith = "docChanged"

        let redo = rig.startPress(try #require(rig.unifiedUndo.redoStack.last), .redo)
        #expect(await rig.awaitRuns([redo]), "the redo did not end")
        #expect(await rig.waitUntilSettled(), "the fresh settle after the refused redo never ended")

        #expect(rig.replyWords().suffix(1) == ["redo failed"], "got \(rig.replyWords())")
        #expect(rig.editorState.pendingEditorFirstJobs == 0, "the pending count stayed up after a refused redo")
        let stamp = rig.editorState.stampRebuildRead()
        #expect(rig.editorState.rebuildPushStillWanted(stamp), "a rebuild reading after the refused redo would have its push skipped for good")
        #expect(
            rig.pushes[pushesBefore...].contains { $0.preserveUserBlocks },
            "the fresh settle's re-push was skipped as stale: the count was still up when it stamped")
        #expect(try !rig.blocks().contains { $0.textContent == "Section C copy" }, "the refused redo put a copy into the table")
    }
}
