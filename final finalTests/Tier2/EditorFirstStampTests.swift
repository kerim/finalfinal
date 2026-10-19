//
//  EditorFirstStampTests.swift
//  final finalTests
//
//  This file: U-S1-0 (t-18b7fa48 round 1b, plan-v3 D6 / D6a with the judge's round-3 addendum). Tier 2.
//
//  The editor-first CLICK (Delete Section now; Duplicate Section and the Version History restores in the next rounds) bumps
//  `EditorViewState.editorFirstClickGeneration` and raises `pendingEditorFirstJobs` in its synchronous stretch, and the rebuild
//  guard (`rebuildPushStillWanted`) reads both. These tests pin the three things the guard owes:
//    * a rebuild that read the database BEFORE the click skips its editor push (it would put the pre-click text back);
//    * the pending-jobs count is back down BEFORE the operation's own settle starts, so the settle's own rebuilds, which read the
//      table after the job has applied, stamp as current and push (the addendum's must-fix 1: otherwise the editor's Notes never
//      update after a delete of a footnoted section);
//    * a click that reserves no job (the editor refused) brings the count down at once and runs the fresh settle (D6a).
//  Driven with `EditorFirstRig` (EditorFirstDeleteTests.swift); helpers: QuickUndoFixtures.swift.
//
//  Round 1g-B (review A3) adds the same three things for the quick REDO of a Delete Section, which raises the count and moves the
//  click generation too: a rebuild that read after the redo's reply, one that read before it, and the redo the editor refuses.
//  (The twin for a Duplicate Section redo is in EditorFirstDuplicateRebuildTests.swift.)
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Editor-first click stamp (t-18b7fa48 round 1b, Tier 2)", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct EditorFirstStampTests: QuickUndoFixtures {

    /// What the settle's first step saw (written by the rig's settle hold, read after the settle).
    private final class SettleStartProbe {
        var pendingJobsAtSettleStart = -1
        var stampAtSettleStart: RebuildReadStamp?
    }

    /// The document the editor shows the moment `root`'s section is gone: the database's rows without the section, assembled the way
    /// the rig's quick redo assembles them (the Notes are still the old ones: the delete's follow-up has not rewritten them yet).
    private func textWithoutSection(_ rig: EditorFirstRig, root: Block) throws -> String {
        let removed = Set(try #require(try rig.db.sectionBlockIds(rootId: root.id, projectId: rig.pid)))
        let rows = try rig.blocks().filter { !removed.contains($0.id) }
            .sorted { ($0.sortOrder, $0.blockType == .heading ? 0 : 1) < ($1.sortOrder, $1.blockType == .heading ? 0 : 1) }
        return BlockParser.assembleMarkdownForEditor(from: rows)
    }

    /// `QuickUndoFixtures.startStampedRebuild`, plus a `rebuild push skipped` event when the guard skipped the push (the stand-in's
    /// `skipStaleRebuildTail` returned true). Reads the database NOW, stamping first (as the three rebuild handlers do), and lands
    /// when `mayLand` opens.
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
            rig.events.note("rebuild landed")
        }
        rig.editorState.registerRebuildTask(task)
    }

    // U-S1-0: a rebuild that read before a DELETE click skips its push; the pending count is down before the delete's own settle
    // starts; and the delete's follow-up leaves the Notes in line with a delete that had no stamped rebuild at all
    @Test("U-S1-0: a rebuild that read before a Delete Section click skips its push, and the delete's own settle is not skipped")
    func testRebuildReadBeforeDeleteClickSkipsItsPush_article() async throws {
        let rig = try makeArticleRig()
        let reference = try makeArticleRig()
        let title = try #require(try footnotedSections(rig).first).heading.textContent

        // The reference: the same delete of a footnoted section, with no stamped rebuild anywhere.
        _ = try await delete(reference, title)

        let root = try rig.heading(title)
        let headingLine = String(repeating: "#", count: root.headingLevel ?? 1) + " " + root.textContent
        let afterDelete = try textWithoutSection(rig, root: root)
        rig.quickEditorText = afterDelete   // what the editor's own text is once the section is gone (`getContent()`)
        rig.editorText = afterDelete

        // What the delete's settle sees when it starts (before its resyncs): the same syncing of `content` the article rig does, and
        // the stamp a rebuild reading at that moment would take. The settle's own rebuilds read after the job has applied. The settle
        // waits here for the stand-in rebuild to have landed, so that the stand-in's own (stale) assignment of `content` can never
        // fall between the sync below and the resyncs that read it.
        let probe = SettleStartProbe()
        rig.controller.testEFSettleHold = { [weak rig, probe] in
            guard let rig else { return }
            _ = await gateWaitUntil({ rig.events.items.contains("rebuild landed") }, iterations: 600)
            _ = try? rig.syncEditorContentFromDatabase()
            probe.pendingJobsAtSettleStart = rig.editorState.pendingEditorFirstJobs
            probe.stampAtSettleStart = rig.editorState.stampRebuildRead()
        }

        let mayLand = LifecycleEntryHarness.Gate()
        defer { mayLand.open() }
        startStampedRebuildNotingSkip(rig, mayLand: mayLand)   // reads the database BEFORE the click
        let pushesBeforeClick = rig.pushes.count

        let deleted = try await delete(rig, title, settle: false)
        mayLand.open()
        let landed = await gateWaitUntil({ rig.events.items.contains("rebuild landed") }, iterations: 600)
        await rig.settle(deleted.entry.id)

        // 1. The stale rebuild: skipped, and nothing pushed after the click carries the deleted heading.
        #expect(landed, "the stand-in rebuild never landed")
        #expect(rig.events.items.contains("rebuild push skipped"), "expected the guard to skip the push of the rebuild that read before the click")
        let pushesAfterClick = Array(rig.pushes[pushesBeforeClick...])
        #expect(
            pushesAfterClick.allSatisfy { !$0.markdown.contains(headingLine) },
            "the stale rebuild pushed its pre-delete text (\(pushesAfterClick.count) push(es) after the click)")

        // 2. The order: the count was already down when the delete's own settle started, so a rebuild reading there is current.
        #expect(
            probe.pendingJobsAtSettleStart == 0,
            "expected the pending count down before the settle started, got \(probe.pendingJobsAtSettleStart)")
        let settleStamp = try #require(probe.stampAtSettleStart, "the delete's settle never started")
        #expect(
            rig.editorState.rebuildPushStillWanted(settleStamp),
            "a rebuild reading when the delete's settle starts would have its push skipped: the settle's own Notes update would be lost")
        #expect(rig.editorState.pendingEditorFirstJobs == 0, "the pending count came back down")

        // 3. The follow-up: the Notes and the editor's text are the reference delete's.
        try rig.syncEditorContentFromDatabase()   // as `delete(settle: true)` does for the reference
        #expect(try rig.notesTexts() == (try reference.notesTexts()), "Notes differ from the delete that had no stamped rebuild")
        #expect(rig.editorState.content == reference.editorState.content, "the editor's text (Notes/Bibliography) differs from the reference")
        #expect(!rig.editorState.content.contains(headingLine), "the deleted section is back in the editor's text")
    }

    // D6a, on Delete Section: the editor refuses the click. No job was reserved, so the count comes down at once, and one fresh settle
    // puts the database's Notes into the editor (a rebuild whose push the click's stamp skipped would otherwise leave them half done)
    @Test("D6a: a refused Delete Section click brings the pending count down and runs the fresh settle")
    func testRefusedDeleteClickRunsTheFreshSettle_article() async throws {
        let rig = try makeArticleRig()
        rig.controller.testOrderingSpy = { [events = rig.events] step in events.note("spy " + step) }
        let root = try #require(try footnotedSections(rig).first).heading
        // `managedRoot`, not `rootNotFound`: since round 1g-A (review A7) a `rootNotFound` reply sends the press down the old way instead
        // of refusing it. `managedRoot` (the editor's managed set calls the root Notes or Bibliography) is still a real refusal.
        try rig.setReply(.init(succeeded: false, reason: "managedRoot"), forRoot: root.id)
        let generationBefore = rig.editorState.editorFirstClickGeneration

        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        _ = await gateWaitUntil({ rig.events.items.contains("spy efRepushManagedRegions") }, iterations: 2000)
        _ = await rig.waitUntilSettled()

        #expect(outcome == .refused, "the editor refused, so the press is refused")
        #expect(rig.editorState.editorFirstClickGeneration == generationBefore + 1, "the click moved the stamp before its JavaScript went out")
        #expect(rig.editorState.pendingEditorFirstJobs == 0, "the pending count stayed up after a refused click")
        #expect(rig.events.items.contains("spy efRepushManagedRegions"), "no managed-region re-push after a refused click")
        #expect(rig.unifiedUndo.undoStack.isEmpty, "a refused click records nothing")
        #expect(try rig.blocks().contains { $0.id == root.id }, "the section is still in the database")
    }

    // MARK: - A3 (round 1g-B): the delete's quick redo is covered like the click
    //
    // Cmd-Shift-Z of a quick-undone Delete Section is a fresh editor-first delete: the editor takes the section off the screen at once
    // and the redo's job deletes the rows later. Until round 1g-B it raised no `pendingEditorFirstJobs` and moved no click generation,
    // so a rebuild that read the table AFTER the redo's reply (the section still in it) was judged current and pushed a document WITH
    // the deleted section. The two orders, as U-S1-0: (i) the rebuild read BEFORE the redo and lands after it; (ii) it read AFTER the
    // redo's reply, while the redo's job is queued. The four-section document has no Notes, so the rig's stand-in for the merge-guarded
    // push hands back the database's text, and a stale push shows on the screen (`editorText`) as the deleted section back.

    /// Deletes Section A (settled), takes the delete back with Cmd-Z (settled), holds the writer's queue and presses Cmd-Shift-Z: the press
    /// has ended, the section is off the screen, and the redo's job waits behind the hold so the table still has the section.
    /// `beforeRedo` runs after the hold is taken and before the press (where order (i) starts its rebuild).
    private func redoDeleteWithItsJobQueued(
        _ rig: EditorFirstRig, beforeRedo: () -> Void = {}
    ) async throws -> (blocker: WriterTicket, deleted: QuickUndoDeleted) {
        let deleted = try await delete(rig, "Section A")
        #expect(await rig.pressAndSettle(deleted.entry), "the undo did not end and settle")
        let blocker = try rig.holdQueue()
        beforeRedo()
        let redo = rig.startPress(try #require(rig.unifiedUndo.redoStack.last), .redo)
        #expect(await rig.awaitRuns([redo]), "the redo did not end")
        #expect(rig.editorState.pendingEditorFirstJobs == 1, "precondition: the redo's job is pending and holds the count")
        #expect(
            try rig.presentRowCount(deleted.subtree) == deleted.subtree.count,
            "precondition: the table still has the section (the undo put it back, the redo's job has not run)")
        #expect(rig.editorText?.contains("Section A") == false, "precondition: the redo took the section off the screen")
        return (blocker, deleted)
    }

    /// What the user has once the redo's job has applied: the section gone from the table, the screen and the sidebar, nothing the editor
    /// was pushed after the redo shows it, and the editor was given the database's Notes and Bibliography afterwards (the re-push the
    /// skipped rebuild owed).
    private func expectTheSectionStaysDeleted(_ rig: EditorFirstRig, deleted: QuickUndoDeleted, pushesFrom: Int) async throws {
        #expect(try rig.presentRowCount(deleted.subtree) == 0, "the redo's job did not delete the section's rows")
        #expect(rig.editorText?.contains("Section A") == false, "the deleted section is back on the screen: \(rig.editorText ?? "")")
        let pushes = Array(rig.pushes[pushesFrom...])
        #expect(
            pushes.allSatisfy { !$0.markdown.contains("Section A") },
            "a document with the deleted section was pushed into the editor after the redo (\(pushes.count) push(es))")
        #expect(
            pushes.contains { $0.preserveUserBlocks },
            "the editor was never given the database's Notes and Bibliography after the skipped rebuild")
        await rig.editorState.refreshSectionsAwaiting()
        #expect(!rig.editorState.sections.contains { $0.id == deleted.root.id }, "the deleted section is in the sidebar")
        #expect(rig.editorState.pendingEditorFirstJobs == 0, "the pending count came back down")
        #expect(!rig.editorState.managedRegionsNeedRepush, "the re-push owed to the editor was made")
        #expect(rig.alerts.isEmpty, "an alert was raised: \(rig.alerts)")
    }

    // A3 (ii), Delete: the rebuild reads after the redo's reply, while the redo's job is queued. Only the pending-jobs half of the stamp can skip it.
    @Test("A3 (ii): a rebuild that read after the Delete Section redo's reply skips its push, and the section stays deleted")
    func testRebuildThatReadAfterTheDeleteRedoSkipsItsPush() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let (blocker, deleted) = try await redoDeleteWithItsJobQueued(rig)
        defer { rig.release(blocker) }
        let pushesBefore = rig.pushes.count
        let mayLand = LifecycleEntryHarness.Gate()
        defer { mayLand.open() }

        startStampedRebuildNotingSkip(rig, mayLand: mayLand)   // the redo's reply is over, its job is not: this read still has the section
        mayLand.open()
        let landed = await gateWaitUntil({ rig.events.items.contains("rebuild landed") }, iterations: 600)

        #expect(landed, "the stand-in rebuild never landed")
        #expect(
            rig.events.items.contains("rebuild push skipped"),
            "expected the guard to skip the push of the rebuild that read while the redo's job was pending")
        #expect(rig.pushes.count == pushesBefore, "the stale rebuild pushed a document with the deleted section while the redo's job was pending")
        #expect(
            rig.editorState.content == rig.quickEditorText,
            "content kept the deleted section: the stale rebuild's text was not replaced by the editor's own")
        #expect(rig.editorText?.contains("Section A") == false, "the deleted section is back on the screen")

        rig.release(blocker)
        #expect(await rig.waitUntilSettled(), "the redo never settled")
        try await expectTheSectionStaysDeleted(rig, deleted: deleted, pushesFrom: pushesBefore)
    }

    // A3 (i), Delete: the rebuild read before the redo and lands after it. The restore generation already skips its push; the click
    // generation is what makes the skip owe the editor a re-push.
    @Test("A3 (i): a rebuild that read before the Delete Section redo skips its push, and the editor is given the database's Notes afterwards")
    func testRebuildThatReadBeforeTheDeleteRedoSkipsItsPushAndTheRegionsAreRepushed() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let mayLand = LifecycleEntryHarness.Gate()
        defer { mayLand.open() }
        let (blocker, deleted) = try await redoDeleteWithItsJobQueued(rig) {
            self.startStampedRebuildNotingSkip(rig, mayLand: mayLand)   // reads the table with the section, BEFORE the redo's stretch
        }
        defer { rig.release(blocker) }
        let pushesBefore = rig.pushes.count

        mayLand.open()
        let landed = await gateWaitUntil({ rig.events.items.contains("rebuild landed") }, iterations: 600)

        #expect(landed, "the stand-in rebuild never landed")
        #expect(
            rig.events.items.contains("rebuild push skipped"), "expected the guard to skip the push of the rebuild that read before the redo")
        #expect(rig.pushes.count == pushesBefore, "the stale rebuild pushed a document with the deleted section")
        #expect(
            rig.editorState.content == rig.quickEditorText,
            "content kept the deleted section: the stale rebuild's text was not replaced by the editor's own")

        rig.release(blocker)
        #expect(await rig.waitUntilSettled(), "the redo never settled")
        try await expectTheSectionStaysDeleted(rig, deleted: deleted, pushesFrom: pushesBefore)
    }

    // A3, the abandon exits: the editor refuses the redo. The count the redo raised comes down at once, before the fresh settle (whose
    // re-push stamps after it and so reaches the editor), and a rebuild that reads afterwards is current.
    @Test("A3: a Delete Section redo the editor refuses brings the pending count back down before the fresh settle, so later rebuilds are current")
    func testRefusedDeleteRedoReleasesThePendingCount() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let deleted = try await delete(rig, "Section A")
        #expect(await rig.pressAndSettle(deleted.entry), "the undo did not end and settle")
        let pushesBefore = rig.pushes.count
        try rig.setReply(.init(succeeded: false, reason: "docChanged"), forRoot: deleted.root.id)   // the editor refuses the redo

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
        #expect(try rig.presentRowCount(deleted.subtree) == deleted.subtree.count, "the refused redo deleted the section")
    }
}
