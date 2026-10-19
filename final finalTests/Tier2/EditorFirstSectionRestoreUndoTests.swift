//
//  EditorFirstSectionRestoreUndoTests.swift
//  final finalTests
//
//  Tier 2 (t-18b7fa48 Phase 4b slice 2, round 2d-ii; the judge's extra unit tests of round 2a (notes F2, F5) and the slice-1 lessons (a) to
//  (e)): the two SECTION Version History restores when their job fails, when a stale Notes rebuild meets them, when they are undone and
//  redone, and in the sidebar. The click, D8 and parity are EditorFirstSectionRestoreTests.swift. Helpers:
//  EditorFirstSectionRestoreFixtures.swift and EditorFirstRestoreFixtures.swift.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Editor-first section restores: failure, rebuild guard, undo, sidebar (t-18b7fa48 slice 2, 2d-ii)", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct EditorFirstSectionRestoreUndoTests: QuickUndoFixtures {

    // MARK: - A failed job (U-S2-7, U-S2-8 for the section kinds, C4)

    @Test("A failed section replace puts the document back, keeps the typing, and says so once")
    func testFailedSectionReplacePutBackKeepsTyping() async throws {
        let (rig, version) = try await makeSectionRigWithVersion()
        defer { unpinAllVersions(rig) }
        rig.modelsWholePushOnEditor = true
        let cBody = try blockWithText(rig, "The C body.")
        try rig.rewriteText(ofBlock: cBody.id, to: Self.editedBody)
        try await rig.fillSectionTable()
        let aBody = try blockWithText(rig, "The A body.")
        let bBody = try blockWithText(rig, "The B body.")
        rig.replaceClickBatch = typing(aBody, to: "The A body typed.")   // typing up to the click, in the click's batch
        rig.forceNextJobFailure = true

        #expect(await rig.performRestore("replace", from: version, section: "Section C") == .performed)
        rig.queueTyping(bBody, appending: " later")   // typing after the click, outside the restored section
        await settleThenCarryRestoreTyping(rig)

        let screen = try #require(rig.editorText, "the editor holds no document")
        #expect(screen.contains("The A body typed."), "the put-back removed the typing up to the click from the editor: \(screen)")
        #expect(screen.contains(Self.editedBody) && !screen.contains("The C body."), "the editor does not show the document as it was: \(screen)")
        let all = try documentTexts(rig)
        #expect(all.contains("The A body typed."), "the put-back lost the typing up to the click: \(all)")
        #expect(all.contains("The B body. later"), "the put-back lost the typing made after the click: \(all)")
        #expect(all.contains(Self.editedBody) && !all.contains("The C body."), "the table is not the document as it was: \(all)")
        #expect(rig.editorState.pendingRestoreSections.isEmpty && rig.editorState.pendingRemovalIds.isEmpty, "a sidebar overlay or filter stayed up")
        #expect(rig.unifiedUndo.undoStack.isEmpty, "the put-back removes the entry")
        #expect(rig.alerts.map(\.title) == ["Couldn't Restore Section"], "expected exactly one alert, got \(rig.alerts)")
        #expect(rig.alerts.first?.message == Self.failedSectionRestoreMessage, "got \(String(describing: rig.alerts.first?.message))")
    }

    @Test("A failed restore as duplicate returns .performed with exactly one alert, and leaves no copy")
    func testFailedRestoreAsDuplicateReturnsPerformedAndOneAlert() async throws {
        let (rig, version) = try await makeSectionRigWithVersion()
        defer { unpinAllVersions(rig) }
        rig.modelsWholePushOnEditor = true
        rig.forceNextJobFailure = true

        let outcome = await rig.performRestore("duplicate", from: version, section: "Section A")
        _ = await rig.waitUntilSettled()

        #expect(outcome == .performed, "the window would show 'Restore failed' beside the modal: \(outcome)")
        #expect(rig.controller.testShownAlerts == ["Couldn't Restore Section"], "got \(rig.controller.testShownAlerts)")
        #expect(rig.alerts.first?.message == Self.failedSectionRestoreMessage, "got \(String(describing: rig.alerts.first?.message))")
        #expect(try documentTexts(rig).filter { $0 == "Section A" }.count == 1, "the copy is still in the table")
        #expect(rig.unifiedUndo.undoStack.isEmpty, "the failed restore is still on the timeline")
        #expect(rig.editorState.pendingEditorFirstJobs == 0)
    }

    // Fix round F4 (break patch S1-08: `detectPausedEdits: true` of the put-back's push in `putBackAfterFailedEditorFirstOp`, shared by
    // every kind). The put-back's push replaces the editor's whole document while the editor's block sync is paused; keystrokes made in
    // that window survive as pending changes only when the push asks for `detectPausedEdits`, otherwise the replace discards them. Only
    // the duplicate's and the whole restore's put-back tests set `typedDuringNextWholePush`; this is the section restores' twin, for
    // both kinds. Predicted failure with the option switched off: "the put-back removed the typing made during its push from the editor".
    @Test("A failed section restore's put-back keeps the typing made while its push is in flight", arguments: ["replace", "duplicate"])
    func testFailedSectionRestorePutBackKeepsTypingMadeDuringItsPush(_ mode: String) async throws {
        let (rig, version) = try await makeSectionRigWithVersion()
        defer { unpinAllVersions(rig) }
        rig.modelsWholePushOnEditor = true
        if mode == "replace" {
            let cBody = try blockWithText(rig, "The C body.")
            try rig.rewriteText(ofBlock: cBody.id, to: Self.editedBody)   // the document changed after the version
            try await rig.fillSectionTable()
        }
        let bBody = try blockWithText(rig, "The B body.")
        rig.typedDuringNextWholePush = (bBody, " LATER")   // typed while the put-back's push is in flight
        rig.forceNextJobFailure = true

        #expect(await rig.performRestore(mode, from: version, section: mode == "replace" ? "Section C" : "Section A") == .performed)
        await settleThenCarryRestoreTyping(rig)

        let screen = try #require(rig.editorText, "the editor holds no document")
        #expect(screen.contains("The B body. LATER"), "the put-back removed the typing made during its push from the editor (\(mode)): \(screen)")
        let wholePushes = rig.pushes.filter { !$0.preserveUserBlocks }
        #expect(wholePushes.contains { $0.detectPausedEdits }, "the put-back's push did not ask for detectPausedEdits (\(mode))")
        #expect(
            try documentTexts(rig).contains("The B body. LATER"),
            "the typing made during the put-back's push never reached the table (\(mode))")
        #expect(rig.alerts.map(\.title) == ["Couldn't Restore Section"], "expected exactly one alert (\(mode)), got \(rig.alerts)")
        #expect(rig.unifiedUndo.undoStack.isEmpty, "the put-back removes the entry (\(mode))")
    }

    // MARK: - The stale-rebuild guard (article)

    // A Notes or bibliography rebuild that READ the database before the click lands after it: its push is skipped and the editor still shows
    // the restored section (the marker typed into the section before the restore is gone, and no later push brings it back).
    @Test("A rebuild that read before a section replace skips its push; the editor still shows the restored section")
    func testStaleRebuildDoesNotBringBackTheOldSection() async throws {
        let rig = try makeRestoreRig("article")
        defer { unpinAllVersions(rig) }
        try await rig.fillSectionTable()
        let version = try saveVersion(rig)
        let paragraph = try firstParagraph(in: try rig.blocks().map(\.id), rig)
        let owner = try owningLeader(of: paragraph, in: rig)
        try rig.rewriteText(ofBlock: paragraph.id, to: paragraph.textContent + " EDITED-BEFORE")
        try await rig.fillSectionTable()
        let mayLand = LifecycleEntryHarness.Gate()
        defer { mayLand.open() }
        startStampedRebuildNotingSkip(rig, mayLand: mayLand)   // reads the pre-restore document
        let pushesFrom = rig.pushes.count

        #expect(await rig.performRestore("replace", from: version, section: owner.textContent) == .performed)
        mayLand.open()
        let landed = await gateWaitUntil({ rig.events.items.contains("rebuild landed") }, iterations: 600)
        let settled = await rig.waitUntilSettled()

        #expect(landed, "the stand-in rebuild never landed")
        #expect(settled, "the restore never settled")
        #expect(restoreRanEditorFirst(rig), "no editor-first restore: \(rig.persistedLog)")
        #expect(rig.events.items.contains("rebuild push skipped"), "the guard did not skip the push of the rebuild that read before")
        let text = try #require(rig.editorText, "the editor holds no document")
        #expect(!text.contains("EDITED-BEFORE"), "the editor's text is the pre-restore document again")
        #expect(rig.pushes[pushesFrom...].allSatisfy { !$0.markdown.contains("EDITED-BEFORE") }, "the stale rebuild pushed the old section")
        #expect(!rig.editorState.content.contains("EDITED-BEFORE"), "content lost the restored text to the stale rebuild")
        #expect(rig.editorState.pendingEditorFirstJobs == 0, "the pending count stayed up")
    }

    // MARK: - The quick undo and redo

    @Test("Cmd-Z of a section replace brings back the old text with its old ids; Cmd-Shift-Z gives the restored ids again")
    func testQuickUndoAndRedoOfASectionReplace() async throws {
        let (rig, version) = try await makeSectionRigWithVersion()
        defer { unpinAllVersions(rig) }
        let bBody = try blockWithText(rig, "The B body.")
        try rig.rewriteText(ofBlock: bBody.id, to: "The B body EDITED.")
        try await rig.fillSectionTable()
        let idsBefore = Set(try rig.blocks().map(\.id))

        #expect(await rig.performRestore("replace", from: version, section: "Section B") == .performed)
        let plan = try #require(rig.controller.testLastRestorePlan)
        _ = await rig.waitUntilSettled()
        let restoredIds = Set(try rig.blocks().map(\.id))
        #expect(restoredIds == Set(plan.rows.map(\.id)).union(idsBefore.subtracting([bBody.id])), "the restore wrote other rows than the plan")
        let restoredTexts = try documentTexts(rig)
        #expect(restoredTexts.contains("The B body.") && !restoredTexts.contains("The B body EDITED."), "the section was not restored")

        try await restorePress(rig, .undo)
        #expect(Set(try rig.blocks().map(\.id)) == idsBefore, "the undo did not give back the rows it replaced, with their ids")
        let afterUndo = try documentTexts(rig)
        #expect(
            afterUndo.contains("The B body EDITED.") && !afterUndo.contains("The B body."),
            "the undo did not bring the old text back: \(afterUndo)")
        #expect(rig.quickUndoScripts.count == 1, "expected the quick undo, saw \(rig.quickUndoScripts.count) quick undo call(s)")

        try await restorePress(rig, .redo)
        #expect(Set(try rig.blocks().map(\.id)) == restoredIds, "the redo wrote other ids than the first restore (S9)")
        let afterRedo = try documentTexts(rig)
        #expect(
            afterRedo.contains("The B body.") && !afterRedo.contains("The B body EDITED."),
            "the redo did not restore the section: \(afterRedo)")
        #expect(rig.replyWords().suffix(2) == ["undo performed", "redo performed"], "got \(rig.replyWords())")
        #expect(rig.scripts(containing: "performStructuralSwap").isEmpty, "a slow swap ran")
        #expect(
            rig.editorState.pendingRemovalIds.isEmpty && rig.editorState.pendingRestoreSections.isEmpty,
            "the sidebar filter or overlay stayed up")
    }

    // A section replace whose restored text is a bare heading inserts no rows: its undo must still let the heading back into the sidebar.
    @Test("Cmd-Z of a section replace that inserted no rows still lifts the sidebar filter")
    func testQuickUndoOfAHeadingOnlyReplaceLiftsTheFilter() async throws {
        let rig = try EditorFirstRig(markdown: "# Chapter\n\n## Empty\n\n## Section B\n\nThe B body.")
        defer { unpinAllVersions(rig) }
        try await rig.fillSectionTable()
        let version = try saveVersion(rig)   // "Empty" has no body here
        let emptyHeading = try rig.heading("Empty")
        try insertParagraph(rig, after: emptyHeading, text: "Words added later.")
        try await rig.fillSectionTable()

        #expect(await rig.performRestore("replace", from: version, section: "Empty") == .performed)
        _ = await rig.waitUntilSettled()
        #expect(try !documentTexts(rig).contains("Words added later."), "the section was not restored to a bare heading")

        try await restorePress(rig, .undo)
        await rig.editorState.refreshSectionsAwaiting()
        #expect(try documentTexts(rig).contains("Words added later."), "the undo did not bring the text back")
        let titles = rig.editorState.sections.map(\.title)
        #expect(titles.contains("Empty"), "the heading is missing from the sidebar: \(titles)")
        #expect(rig.editorState.pendingRemovalIds.isEmpty, "the filter that hid the heading stayed up")
    }

    // MARK: - The sidebar

    // A restore as duplicate shows its leaders at once, after the last section, before the database has them; its undo hides only them.
    @Test("A restored duplicate is in the sidebar at once, and leaves with the undo")
    func testRestoredDuplicateIsInTheSidebarAtOnceAndLeavesWithTheUndo() async throws {
        let (rig, version) = try await makeSectionRigWithVersion()
        defer { unpinAllVersions(rig) }
        await rig.editorState.refreshSectionsAwaiting()
        let withCopy = ["Chapter", "Section A", "Section B", "Section C", "Section A"]
        let hold = try rig.holdQueue()   // the restore's job is reserved but cannot run: the database has no copy yet

        #expect(await rig.performRestore("duplicate", from: version, section: "Section A") == .performed)
        #expect(try documentTexts(rig).filter { $0 == "Section A" }.count == 1, "the job ran although the queue was held")
        #expect(rig.editorState.sections.map(\.title) == withCopy, "not the outline with the copy: \(rig.editorState.sections.map(\.title))")
        rig.release(hold)
        _ = await rig.waitUntilSettled()
        #expect(try documentTexts(rig).filter { $0 == "Section A" }.count == 2, "the job did not apply")
        #expect(rig.editorState.sections.map(\.title) == withCopy, "the outline changed when the rows arrived")
        #expect(rig.editorState.pendingRestoreSections.isEmpty, "the overlay was not lifted")
        let copyIds = Set(try rig.blocks().filter { $0.textContent == "Section A" }.map(\.id))

        try await restorePress(rig, .undo)
        await rig.editorState.refreshSectionsAwaiting()
        #expect(rig.editorState.sections.map(\.title) == ["Chapter", "Section A", "Section B", "Section C"], "the copy did not leave the sidebar")
        #expect(rig.editorState.pendingRemovalIds.isEmpty, "the filter that hid the copy was not lifted")
        #expect(try documentTexts(rig).filter { $0 == "Section A" }.count == 1, "the undo did not take the copy out of the table")

        try await restorePress(rig, .redo)
        await rig.editorState.refreshSectionsAwaiting()
        #expect(rig.editorState.sections.map(\.title) == withCopy, "the copy did not come back with the redo")
        #expect(
            Set(try rig.blocks().filter { $0.textContent == "Section A" }.map(\.id)) == copyIds,
            "the redo wrote other ids than the first restore (S9)")
    }

    // A1 for the sidebar: the restored heading's place is "after the entry before it", and that entry may be a leader the database does
    // not hold yet (the copy of a duplicate whose job is queued).
    @Test("A replaced section is placed after a leader that only the overlay shows")
    func testSectionReplaceIsPlacedAfterAnOverlayOnlyLeader() async throws {
        let (rig, version) = try await makeSectionRigWithVersion()
        defer { unpinAllVersions(rig) }
        await rig.editorState.refreshSectionsAwaiting()
        let hold = try rig.holdQueue()   // neither job runs: the copy exists in the editor and the sidebar only
        let sectionA = try rig.heading("Section A")
        #expect(await rig.controller.performSectionDuplicate(rootId: sectionA.id) == .performed)
        let withCopy = ["Chapter", "Section A", "Section A copy", "Section B", "Section C"]
        #expect(rig.editorState.sections.map(\.title) == withCopy, "precondition: \(rig.editorState.sections.map(\.title))")

        #expect(await rig.performRestore("replace", from: version, section: "Section B") == .performed)
        #expect(
            rig.editorState.sections.map(\.title) == withCopy,
            "the restored heading is not right after the copy: \(rig.editorState.sections.map(\.title))")
        #expect(restoreRanEditorFirst(rig), "no editor-first restore: \(rig.persistedLog)")
        rig.release(hold)
        _ = await rig.waitUntilSettled()

        await rig.editorState.refreshSectionsAwaiting()
        #expect(rig.editorState.sections.map(\.title) == withCopy, "the outline changed when the rows arrived")
        let all = try documentTexts(rig)
        #expect(all.contains("Section A copy") && all.contains("The B body."), "got \(all)")
        #expect(rig.editorState.pendingRestoreSections.isEmpty && rig.editorState.pendingRemovalIds.isEmpty, "an overlay or filter stayed up")
    }
}

/// Inserts a paragraph row right after `heading` (a row the version did not have). A plain (non-async) function on purpose: inside an
/// `async` test `dbWriter.write` resolves to GRDB's async overload.
@MainActor
private func insertParagraph(_ rig: EditorFirstRig, after heading: Block, text: String) throws {
    var row = Block(
        projectId: rig.pid, sortOrder: heading.sortOrder + 0.5, blockType: .paragraph, textContent: text, markdownFragment: text)
    _ = try rig.db.dbWriter.write { database in
        try row.insert(database)
    }
}
