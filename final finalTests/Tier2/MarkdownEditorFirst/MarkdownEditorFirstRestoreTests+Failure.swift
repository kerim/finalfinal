//
//  MarkdownEditorFirstRestoreTests+Failure.swift
//  final finalTests
//
//  t-4a8fd8af slice 4, round C2: the failure paths of the Markdown restores (a job that does not apply is put back; the typed-since case
//  keeps the restore), the presses that take the OLD body (a page that refuses, an unresolved target, the kill switch), the zoomed
//  press, and the footnote checkpoint guard of a whole restore. An extension of the class in MarkdownEditorFirstRestoreTests.swift.
//  Real page, real rows, real writer. Needs `cd web && pnpm build` first. NOT RUN by the coder.
//
//  Break patches (plan-v1-addendum section 11) and the first message each test shows under its patch:
//
//   U8   testAFailedReplaceJob... / testAFailedInsertAsNewJob... / testAWholeRestoreWhoseJobWasNeverReserved...
//        BREAK: remove `|| kind.isVersionRestore` from `putBackMarkdownJob`'s swap-back kinds.
//        testAWholeRestoreWhoseJobWasNeverReserved...  is THE PIN of `|| kind.isVersionRestore` (code review T5): only a job that never
//        held its place has no step 8, so only there does `putBackMarkdownJob` itself try the swap-back.   FAILS: "alert was []"
//        testAFailedReplaceJob... and testAFailedInsertAsNewJob...  are CONTROLS: their job WAS reserved, so step 8 swaps the page back
//        whatever the kind; they pin the everyday put-back (page, rows, sidebar, timeline, hold, alert) and cannot fail under the patch.
//        testTypingDoneSinceARestoreWhoseJobFailed...   the restore stands, the typing is saved, no alert (no patch of its own)
//   U9   testAPageRefusalRunsTheOldBodyAndRearmsAfterTheHoldIsReleased
//        BREAK: `performMarkdownEditorFirstRestore` returns `.refused` instead of nil.   FAILS: "the old body did not take the press"
//   U10  testAZoomedRestoreZoomsOutFirstAndThenGoesEditorFirst
//        BREAK: delete the zoom-out line in `performEditorFirstSectionRestoreReplace`.   FAILS: "the click fell back to the old body"
//   U11  testAnUnresolvedTargetTakesTheOldBodyWithTheExistingLogLine
//        BREAK: the Markdown builder returns `.refused` on `.unresolved`.   FAILS: "the press was refused"
//   U12  testWithTheSwitchOffThePressesTakeTheOldBody   CONTROL (the kill switch; patch: drop `MarkdownEditorFirstSwitch.enabled &&`)
//   U13  testAWholeRestoreDropsTheFootnoteCheckpointsAndTheNotesRowsAreTheVersions (and ...ASectionRestoreLeavesThem...)
//        BREAK: in `startEditorFirstRestoreJob` `plan.mode == .whole` -> `false`.   FAILS: "the footnote checkpoints were not dropped"
//

import Foundation
import XCTest
@testable import final_final

/// Records whether the writer's structural hold was up each time a re-parse was scheduled. A reference type the host closure can fill.
@MainActor
final class RestoreHoldProbe {
    var reparseHeldFlags: [Bool] = []
    var zoomAtPrepare: String??
    /// U15b: the page's raw text right after the preparation hook typed, and whether the controller had a page reply by then.
    var typedPage: String?
    var replyAlreadyThere: Bool?
}

/// Counts the notifications of the given names and records, at the moment each is POSTED, whether the writer's structural hold was up.
final class RestoreRepostProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [Bool] = []
    private var tokens: [NSObjectProtocol] = []

    init(_ names: [Notification.Name], isHeld: @escaping @MainActor @Sendable () -> Bool) {
        for name in names {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                // Delivered synchronously on the posting thread, which is the main thread (the controller is @MainActor).
                let isUp = MainActor.assumeIsolated { isHeld() }
                self?.note(isUp)
            })
        }
    }

    private func note(_ isUp: Bool) {
        lock.lock()
        held.append(isUp)
        lock.unlock()
    }

    var heldAtPost: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    func stop() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = []
    }
}

extension MarkdownEditorFirstRestoreTests {

    // MARK: - U8: a failed job

    /// The state a failed restore must leave, whichever way the job failed.
    private func assertRestorePutBack(
        before: String, titlesBefore: [String], alert: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let alerts = rig.controller.testShownAlerts
        XCTAssertEqual(alerts, [alert], "alert was \(alerts) (wanted exactly [\(alert)])", file: file, line: line)
        let page = try await pageText()
        XCTAssertEqual(
            lines(MarkdownLeaderMap.recordText(fromRaw: page)), lines(MarkdownLeaderMap.recordText(fromRaw: before)),
            "page not swapped back to the text from before the restore", file: file, line: line)
        XCTAssertEqual(
            lines(try rig.writerRig.storedText()), lines(MarkdownLeaderMap.recordText(fromRaw: before)),
            "the rows are not the document from before the restore", file: file, line: line)
        try await refreshSidebar()
        XCTAssertEqual(rig.editorState.sections.map(\.title), titlesBefore, "the sidebar still shows the restored outline", file: file, line: line)
        XCTAssertTrue(
            rig.editorState.pendingRestoreSections.isEmpty,
            "the sidebar still shows the restored outline (overlay)", file: file, line: line)
        XCTAssertTrue(rig.unifiedUndo.undoStack.isEmpty, "the failed restore's entry is still on the timeline", file: file, line: line)
        XCTAssertTrue(rig.controller.efEditorKind.isEmpty, "the failed restore's entry kind was kept", file: file, line: line)
        XCTAssertTrue(rig.markdownWriter.structuralHoldState.step8Gates.isEmpty, "the failed restore's step-8 gate was kept", file: file, line: line)
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 0, "the pending count stayed up", file: file, line: line)
        XCTAssertTrue(rig.editorState.pendingRemovalIds.isEmpty, "the sidebar still hides a section", file: file, line: line)
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "the hold is still up", file: file, line: line)
    }

    // CONTROL (code review T5): the job WAS reserved, so step 8 swaps the page back whatever the kind; this cannot fail under the
    // `|| kind.isVersionRestore` patch. The never-reserved variant below is the pin of that line.
    //
    // CLAIM: a Replace whose job FAILS after it reserved its place is put back: the editor is swapped back to the text before the click
    // (nothing was typed since), the rows and the sidebar are as before, the entry is gone, nothing is left held, and the user is told
    // once with the RESTORE SECTION alert. The job fails because the target heading's row is removed from the database while the job
    // waits behind a held system sequence (the Duplicate's recipe).
    func testAFailedReplaceJobIsPutBackAndTheUserIsToldWithTheRestoreSectionAlert() async throws {
        try await startRig(Self.book)
        let version = try await saveVersion()
        try await typeAndSave(" EDITED", after: "Second chapter text.")
        let before = try await pageText()
        let titlesBefore = rig.editorState.sections.map(\.title)
        let chapter2 = try rig.section("Chapter 2")
        let ticket = rig.writerRig.hold()

        let outcome = try await replaceSection("Chapter 2", from: version)
        XCTAssertEqual(outcome, .performed)
        let afterClick = try await pageText()
        XCTAssertNotEqual(afterClick, before, "premise: the editor already shows the restored text")
        let overlayUp = await rig.waitUntil { !self.rig.editorState.pendingRestoreSections.isEmpty }
        XCTAssertTrue(overlayUp, "premise: the sidebar shows the restored outline while the job waits (the overlay is up)")
        let rootId = chapter2.id
        try rig.db.write { database in
            try database.execute(sql: "DELETE FROM block WHERE id = ?", arguments: [rootId])
        }
        try await releaseTicket(ticket)
        try await settleAll()

        try await assertRestorePutBack(before: before, titlesBefore: titlesBefore, alert: "Couldn't Restore Section")
    }

    // CONTROL (code review T5): as the Replace test above, the job WAS reserved; it cannot fail under the `|| kind.isVersionRestore` patch.
    //
    // CLAIM: the same for Insert as New Section: the job fails because the row the new section goes after is gone; the page is swapped
    // back, the inserted section is out of the page, the rows and the sidebar, and the user is told with the RESTORE SECTION alert.
    func testAFailedInsertAsNewJobIsPutBackAndTheUserIsToldWithTheRestoreSectionAlert() async throws {
        try await startRig(Self.book)
        let version = try await saveVersion()
        let before = try await pageText()
        let titlesBefore = rig.editorState.sections.map(\.title)
        let anchorRow = try XCTUnwrap(
            try rig.writerRig.rows().first { $0.markdownFragment == "Fourth chapter text." }, "premise: the last row of the last chapter")
        let ticket = rig.writerRig.hold()

        let outcome = try await insertAsNewSection("Chapter 2", from: version)
        XCTAssertEqual(outcome, .performed)
        let afterClick = try await pageText()
        XCTAssertNotEqual(afterClick, before, "premise: the editor already shows the inserted section")
        let anchorId = anchorRow.id
        try rig.db.write { database in
            try database.execute(sql: "DELETE FROM block WHERE id = ?", arguments: [anchorId])
        }
        try await releaseTicket(ticket)
        try await settleAll()

        try await assertRestorePutBack(before: before, titlesBefore: titlesBefore, alert: "Couldn't Restore Section")
    }

    // THE PIN of `|| kind.isVersionRestore` in `putBackMarkdownJob` (code review T5): with no step 8 for a job that never held its place,
    // only that line makes the put-back swap the page back and show the alert; without it this test fails with "alert was []".
    //
    // CLAIM: a Restore Entire Project whose job is never reserved (the writer is pointed at another project between the click's guards and
    // its job) has no step 8: the put-back itself swaps the page back (nothing was typed since) and shows the RESTORE VERSION alert.
    func testAWholeRestoreWhoseJobWasNeverReservedIsSwappedBackAndTheUserIsToldWithTheRestoreVersionAlert() async throws {
        try await startRig(Self.book)
        let version = try await saveVersion()
        try await typeAndSave(" EDITED", after: "Second chapter text.")
        let before = try await pageText()
        let titlesBefore = rig.editorState.sections.map(\.title)
        let other = try TestFixtureFactory.createTemporary(content: "# Other project\n\nBody.")
        let otherPid = try TestFixtureFactory.getProjectId(from: other)
        let sync = rig.writerRig.sync
        let view = rig.helper.webView
        rig.controller.testBeforeMarkdownPagePrepare = {
            // After the click's guards (they compared the writer with this project), before its page call and its job.
            sync.configure(database: other, projectId: otherPid, webView: view)
        }

        let outcome = try await restoreProject(from: version)
        XCTAssertEqual(outcome, .performed)
        try await settleAll()

        try await assertRestorePutBack(before: before, titlesBefore: titlesBefore, alert: "Couldn't Restore Version")
    }

    // CLAIM: if the user typed since the restore (into the restored text, while the job waited), a job that then fails does NOT take the
    // restore back: the restore stands, the typing is saved in the rows, the entry goes off the timeline, and NO alert shows (the known
    // Markdown gap shared by delete, duplicate and reorder; UX contract 4.3).
    func testTypingDoneSinceARestoreWhoseJobFailedLetsTheRestoreStandAndShowsNoAlert() async throws {
        try await startRig(Self.book)
        let version = try await saveVersion()
        try await typeAndSave(" EDITED", after: "Second chapter text.")
        let chapter2 = try rig.section("Chapter 2")
        let ticket = rig.writerRig.hold()

        let outcome = try await replaceSection("Chapter 2", from: version)
        XCTAssertEqual(outcome, .performed)
        let rootId = chapter2.id
        try rig.db.write { database in
            try database.execute(sql: "DELETE FROM block WHERE id = ?", arguments: [rootId])
        }
        try await userTypes(" ts1", after: "Second chapter text.")   // typed into the restored text after the click
        let reported = await rig.waitUntil { self.rig.editorState.content.contains("ts1") }
        XCTAssertTrue(reported, "premise: the typing reached the content record")
        try await releaseTicket(ticket)
        try await settleAll()
        try await settleWriter()

        XCTAssertEqual(rig.controller.testShownAlerts, [], "an alert was shown although the user had typed since (the restore stands)")
        let page = try await pageText()
        XCTAssertTrue(page.contains("Second chapter text. ts1"), "the typing or the restored text is gone from the page")
        XCTAssertFalse(page.contains("EDITED"), "the restore did not stand: the text it replaced is back")
        XCTAssertTrue(try rig.writerRig.storedText().contains("Second chapter text. ts1"), "the typing was not saved in the rows")
        try await assertRowsMatchPage("after the failed job (the restore stands)")
        XCTAssertTrue(rig.unifiedUndo.undoStack.isEmpty, "the failed restore's entry is still on the timeline")
        XCTAssertTrue(rig.controller.efEditorKind.isEmpty, "the failed restore's entry kind was kept")
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "the hold is still up")
    }

    // MARK: - U9: the page refuses

    // CLAIM: when the page refuses the restore (here a stand-in answering `unsupportedKind`), the click gives the press to the OLD body in
    // the same gate turn: the outcome is the old body's `.performed`, the section is restored by it, no editor-first entry exists, and
    // the persisted line "[EF-STRUCT] ... fell back to the old path: page refused" is written. The pending re-parse is scheduled again
    // and the owed Notes and Bibliography re-post (O20) is made only AFTER the click's hold is released (the old body runs with no hold
    // up, and a re-parse scheduled while the hold was up would be held back).
    func testAPageRefusalRunsTheOldBodyAndRearmsAfterTheHoldIsReleased() async throws {
        try await startRig(Self.book)
        let version = try await saveVersion()
        try await typeAndSave(" EDITED", after: "Second chapter text.")
        let log = RestoreAlwaysLog()
        alwaysLog = log
        let probe = RestoreHoldProbe()
        let writer = rig.markdownWriter
        let webView = rig.helper.webView
        rig.editorState.lifecycleHost = LifecycleHost(
            activeWebView: { webView },
            runOpenTail: { _ in },
            runCreateTail: { _, _ in },
            runCloseTail: { _, _ in },
            repostDeferredRebuilds: {},
            scheduleSourceModeReparse: { _ in probe.reparseHeldFlags.append(writer.isHeldForStructuralWork) },
            toastCenter: { ToastCenter() })
        let reposts = RestoreRepostProbe([.notesSectionChanged, .bibliographySectionChanged]) { writer.isHeldForStructuralWork }
        defer { reposts.stop() }
        rig.editorState.managedRegionsNeedRepush = true   // a rebuild's push was skipped by the click's stamp: the Notes are owed
        rig.controller.testBeforeMarkdownPagePrepare = {
            _ = try? await webView.evaluateJavaScript(
                "window.FinalFinal.markdownStructuralRestore = function () { "
                    + "return { ok: false, reason: 'unsupportedKind', detail: 'stub' }; }; true")
        }

        let outcome = try await replaceSection("Chapter 2", from: version)

        XCTAssertEqual(outcome, .performed, "the old body did not take the press after the page refused")
        XCTAssertTrue(rig.controller.efEditorKind.isEmpty, "an editor-first entry was made although the page refused")
        XCTAssertNil(rig.controller.testLastRestorePlan, "the editor-first click got as far as a reply")
        XCTAssertTrue(
            log.lines.contains { $0.contains("[EF-STRUCT]") && $0.contains("fell back to the old path: page refused") },
            "no 'fell back to the old path: page refused' line in the persisted log: \(log.lines.filter { $0.contains("EF-STRUCT") })")
        try await settleAll()
        XCTAssertTrue(try rig.writerRig.storedText().contains("Second chapter text."), "the old body did not restore the section")
        XCTAssertFalse(try rig.writerRig.storedText().contains("EDITED"), "the old body did not take the typed text away")
        XCTAssertEqual(rig.markdownWriter.structuralHoldCount, 0, "a hold is still up after the press")
        XCTAssertFalse(probe.reparseHeldFlags.isEmpty, "the re-parse was not scheduled again after the refused press")
        XCTAssertFalse(probe.reparseHeldFlags.contains(true), "a re-parse was scheduled while the click's hold was still up")
        XCTAssertFalse(reposts.heldAtPost.isEmpty, "the owed Notes and Bibliography re-post (O20) was not made")
        XCTAssertFalse(reposts.heldAtPost.contains(true), "the Notes or Bibliography re-post was made while the click's hold was still up")
        XCTAssertFalse(rig.editorState.managedRegionsNeedRepush, "the owed re-push is still standing")
    }

    // MARK: - U10: zoomed

    // CLAIM: a restore pressed while a section is zoomed zooms OUT first (both editors already do), and only then goes editor-first: at the
    // moment the click prepares the page the zoom is gone, the click does not fall back to the old body, and the restore is carried out.
    // The rig has no ContentView, so this is the controller's own `zoomOut()` with the content push stood in for; the REAL zoomed
    // restore (the page rebuilt to the whole document, caret and scroll) is the real-app class's.
    func testAZoomedRestoreZoomsOutFirstAndThenGoesEditorFirst() async throws {
        try await startRig(Self.book)
        let version = try await saveVersion()
        try await typeAndSave(" EDITED", after: "Second chapter text.")
        let chapter2 = try rig.section("Chapter 2")
        rig.writerRig.sync.testSetContentHook = { _, _, _, _ in nil }   // the zoom-out's content push goes nowhere (no Milkdown here)
        let probe = RestoreHoldProbe()
        let editorState = rig.editorState
        rig.controller.testBeforeMarkdownPagePrepare = { probe.zoomAtPrepare = .some(editorState.zoomedSectionId) }
        rig.editorState.zoomedSectionId = chapter2.id
        defer { rig.writerRig.sync.testSetContentHook = nil }

        let outcome = try await replaceSection("Chapter 2", from: version)

        XCTAssertEqual(outcome, .performed, "the zoomed restore was not carried out")
        let zoomWhenPrepared = try XCTUnwrap(probe.zoomAtPrepare, "the click never prepared the page: it fell back to the old body")
        XCTAssertNil(zoomWhenPrepared, "the click prepared the page while still zoomed (no zoom-out first)")
        XCTAssertNil(rig.editorState.zoomedSectionId, "the restore did not zoom out")
        XCTAssertTrue(rig.controller.efEditorKind.values.contains(.markdown), "the click fell back to the old body")
        XCTAssertNotNil(rig.controller.testLastRestorePlan, "the editor-first click got no reply from the page")
        try await settleAll()
        XCTAssertFalse(try rig.writerRig.storedText().contains("EDITED"), "the restore did not replace the section")
    }

    // MARK: - U11: the target cannot be told apart

    // CLAIM: a target the document cannot confirm (the section table is BEHIND the document: Chapter 3 was renamed in the page and the
    // rows after the table was filled) takes the old restore, with the existing log line "[EF-STRUCT] restoreSectionReplace target
    // unresolved: ..."; the editor-first click is not reached. The flush-and-retry cannot help (the rename is in the rows already).
    func testAnUnresolvedTargetTakesTheOldBodyWithTheExistingLogLine() async throws {
        try await startRig(Self.book)
        let version = try await saveVersion()
        try await typeAndSave(" EDITED", after: "Second chapter text.")
        await syncSectionTable()   // the window syncs the table from the document when it opens
        try await typeAndSave(" renamed", after: "# Chapter 3")   // the table now says "Chapter 3", the page and the rows say otherwise
        let log = RestoreAlwaysLog()
        alwaysLog = log

        let outcome = try await replaceSection("Chapter 3", from: version)

        XCTAssertEqual(outcome, .performed, "the press was refused: \(outcome)")
        XCTAssertTrue(
            log.lines.contains { $0.contains("[EF-STRUCT] restoreSectionReplace target unresolved:") },
            "no unresolved line in the persisted log: \(log.lines.filter { $0.contains("EF-STRUCT") })")
        XCTAssertTrue(rig.controller.efEditorKind.isEmpty, "an editor-first entry was made although the target was unresolved")
        XCTAssertNil(rig.controller.testLastRestorePlan, "the editor-first click ran although the target was unresolved")
        XCTAssertEqual(rig.markdownWriter.structuralHoldCount, 0, "a hold is still up after the press")
        try await settleAll()
    }

    // MARK: - U12: the kill switch (CONTROL)

    // CONTROL (no break patch of its own: it pins the OLD behaviour the other tests are measured against): with the kill switch off none
    // of the three presses takes the editor-first click. Each takes the old body, which restores and records no editor-first entry.
    func testWithTheSwitchOffThePressesTakeTheOldBody() async throws {
        try await startRig(Self.book)
        let version = try await saveVersion()
        try await typeAndSave(" EDITED", after: "Second chapter text.")
        MarkdownEditorFirstSwitch.enabled = false
        XCTAssertFalse(rig.controller.takesTheMarkdownEditorFirstRestorePath, "the path is taken with the switch off")
        let generation = rig.editorState.editorFirstClickGeneration
        let pageBefore = try await pageText()

        let direct = await rig.controller.performMarkdownEditorFirstRestore(kind: .restoreProject) { .legacy }
        XCTAssertNil(direct, "the click ran with the switch off")
        XCTAssertEqual(rig.markdownWriter.structuralHoldCount, 0, "the click took a hold with the switch off")
        XCTAssertEqual(rig.editorState.editorFirstClickGeneration, generation, "the click ran with the switch off")
        let pageUntouched = try await pageText()
        XCTAssertEqual(pageUntouched, pageBefore, "the page was changed with the switch off")

        let outcome = try await restoreProject(from: version)

        XCTAssertEqual(outcome, .performed, "the old body did not carry out the restore")
        XCTAssertTrue(rig.controller.efEditorKind.isEmpty, "the editor-first click ran with the switch off")
        XCTAssertNil(rig.controller.testLastRestorePlan, "the editor-first click ran with the switch off")
        XCTAssertEqual(rig.markdownWriter.structuralHoldCount, 0)
        XCTAssertFalse(try rig.writerRig.storedText().contains("EDITED"), "the old body did not restore the version")
    }

    // MARK: - U13: the footnote checkpoint guard of a whole restore

    private func seedFootnoteCheckpoint() {
        let checkpoint = FootnoteUndoCheckpoint(
            bodyBefore: "# Chapter 1\n\nFirst chapter text.[^1]", refsBefore: ["1"], deletedDefinitions: [:], appliedRenameMap: [:])
        rig.footnotes.undoCheckpoints = [checkpoint]
    }

    private func notesFragments() throws -> [String] {
        try rig.writerRig.rows().filter { $0.isNotes }.sorted { $0.sortOrder < $1.sortOrder }.map(\.markdownFragment)
    }

    // CLAIM: a Restore Entire Project rewrites every Notes row from the version, so the footnote undo checkpoints go in the click's
    // synchronous stretch (the guard runs: `guardFootnoteCheckpointsForNotesRewrite`), and afterwards the Notes rows are the VERSION's
    // (the Notes text typed after the version is gone), once each.
    func testAWholeRestoreDropsTheFootnoteCheckpointsAndTheNotesRowsAreTheVersions() async throws {
        try await startRig(Self.footnotedBook)
        let version = try await saveVersion()
        let notesAtVersion = try notesFragments()
        XCTAssertEqual(notesAtVersion.count, 3, "premise: the Notes heading and two definitions")
        try await typeAndSave(" EDITED", after: "[^1]: Note one.")
        XCTAssertNotEqual(try notesFragments(), notesAtVersion, "premise: the Notes text was changed after the version")
        seedFootnoteCheckpoint()
        XCTAssertEqual(rig.footnotes.undoCheckpoints.count, 1, "premise: a footnote checkpoint is recorded")

        let outcome = try await restoreProject(from: version)

        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.controller.efEditorKind.values.contains(.markdown), "the click fell back to the old body")
        XCTAssertTrue(rig.footnotes.undoCheckpoints.isEmpty, "the footnote checkpoints were not dropped (the guard did not run)")
        try await settleAll()
        XCTAssertEqual(try notesFragments(), notesAtVersion, "the Notes rows are not the version's")
        let page = try await pageText()
        XCTAssertEqual(page.components(separatedBy: "[^1]: Note one.").count - 1, 1, "Note one is not on the page exactly once")
        XCTAssertFalse(page.contains("EDITED"), "the Notes text typed after the version is still on the page")
        try await assertRowsMatchPage("after the whole restore")
    }

    // CLAIM (mode gating of the same guard): a section restore writes no Notes row, so it does NOT drop the footnote checkpoints.
    func testASectionRestoreLeavesTheFootnoteCheckpointsAlone() async throws {
        try await startRig(Self.footnotedBook)
        let version = try await saveVersion()
        try await typeAndSave(" EDITED", after: "Second chapter text.")
        seedFootnoteCheckpoint()

        let outcome = try await replaceSection("Chapter 2", from: version)

        XCTAssertEqual(outcome, .performed)
        XCTAssertTrue(rig.controller.efEditorKind.values.contains(.markdown), "the click fell back to the old body")
        try await settleAll()
        XCTAssertEqual(rig.footnotes.undoCheckpoints.count, 1, "a section restore dropped the footnote checkpoints")
    }
}
