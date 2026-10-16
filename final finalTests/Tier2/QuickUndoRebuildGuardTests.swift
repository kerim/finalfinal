//
//  QuickUndoRebuildGuardTests.swift
//  final finalTests
//
//  This file: U-Q26-rebuild, U-Q27, U-Q26b (verdict-v4), U-Q22 (the holder survives a discard), U-Q23 (a non-empty undo batch).
//  Tier 2 (t-94369a83 Phase 4b slice 2b; plan-v1 F2, plan-v2-addendum 6.2, plan-v3-addendum A1/D1/D2/D7, plan-v4-addendum 5): guards of
//  the quick undo and quick redo of an editor-first Delete Section, driven with `EditorFirstRig` (EditorFirstDeleteTests.swift). The
//  quick undo replies BEFORE its reinsert has applied, so every test that reads the database waits with
//  `EditorFirstRig.waitUntilSettled()` first. Every wait is bounded. Shared helpers: QuickUndoFixtures.swift.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Quick undo: the stale-rebuild guard and the holder (Phase 4b slice 2b, Tier 2)", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct QuickUndoRebuildGuardTests: QuickUndoFixtures {

    // MARK: - U-Q26 (V4), U-Q27, U-Q26b: the rebuild guard

    // U-Q26-rebuild: a rebuild that read the post-delete database before the quick undo pushes nothing after it, and the content stays the
    // editor's own text
    @Test("U-Q26-rebuild: a rebuild that read the post-delete database before the quick undo pushes nothing after it")
    func testStaleRebuildPushIsSkippedAfterQuickUndo_article() async throws {
        let rig = try makeArticleRig()
        rig.controller.testOrderingSpy = { [spyLog = rig.spyLog, events = rig.events] step in
            spyLog.note(step)
            events.note("spy " + step)
        }
        let deleted = try await delete(rig, Self.villageRegisters)
        let typedIn = try paragraphOutside(deleted.subtree, rig)
        let mayLand = LifecycleEntryHarness.Gate()
        defer { mayLand.open() }
        startStampedRebuild(rig, mayLand: mayLand)
        let pushesBefore = rig.pushes.count

        let undo = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([undo]), "the quick restore is not held by the running rebuild")
        rig.typeIntoEditor(typedIn, appending: " KEPT-RB")
        let typing = rig.startPoll()
        #expect(await rig.awaitRuns([typing]))
        // G-T2: the rebuild lands only after the reinsert's settle has had every chance to push ahead of it. A settle that WAITS for the
        // running rebuild (`awaitNoRunningRebuilds`) is still waiting after the reinsert is applied; one that does not wait pushes within
        // milliseconds. So: wait for the reinsert, then for the A20 push to show up (500 ms at most), and only then let the rebuild land.
        _ = await gateWaitUntil({ rig.events.items.contains("spy reinsertApplied") }, iterations: 600)
        _ = await gateWaitUntil({ rig.events.items.contains("spy efRepushManagedRegions") }, iterations: 100)
        mayLand.open()
        _ = await rig.waitUntilSettled()
        // A settle that did not wait for the rebuild is over before the rebuild lands: wait for the landing itself, so that such a
        // settle fails the ordering expectation below with its own message.
        _ = await gateWaitUntil({ rig.events.items.contains("rebuild landed") }, iterations: 600)

        let events = rig.events.items
        let landed = try #require(events.firstIndex(of: "rebuild landed"))
        #expect(
            events.contains("rebuild content-equals-live=true"),
            "expected editorState.content to equal the editor's live text when the stale rebuild had landed")
        let pushes = rig.pushes[pushesBefore...]
        #expect(
            pushes.count == 1,
            "expected the stale rebuild push to be skipped, got \(pushes.count) pushes: only the settle's A20 push is expected")
        let repush = try #require(events.lastIndex(of: "spy efRepushManagedRegions"))
        #expect(landed < repush, "expected the A20 push (efRepushManagedRegions) after the stale rebuild had landed, got it before")
        #expect(rig.editorState.content.contains("KEPT-RB"), "the typing survived")
        let rows = try rig.blocks()
        #expect(rows.first { $0.id == typedIn.id }?.textContent.contains("KEPT-RB") == true, "and reached the database")
        #expect(try rig.missingRowCount(deleted.subtree) == 0)
    }

    @Test("U-Q27: a rebuild that read the database AFTER the reinsert applied still pushes (the guard does not over-skip)")
    func testRebuildReadAfterReinsertAppliedStillPushes_article() async throws {
        let rig = try makeArticleRig()
        let deleted = try await delete(rig, Self.villageRegisters)
        #expect(await rig.pressAndSettle(deleted.entry))
        let pushesBefore = rig.pushes.count
        let mayLand = LifecycleEntryHarness.Gate()
        mayLand.open()

        startStampedRebuild(rig, mayLand: mayLand)
        _ = await gateWaitUntil({ rig.events.items.contains("rebuild landed") })

        #expect(rig.pushes.count - pushesBefore == 1, "expected 1 push, got \(rig.pushes.count - pushesBefore)")
    }

    // U-Q26b (V1): a restore the editor refuses while a rebuild's push was skipped: the fresh settle puts the database's Notes into the
    // editor with exactly one push, and later rebuilds push again
    @Test("U-Q26b (V1): after a refused restore the database's Notes reach the editor with one push")
    func testRefusedRestoreRepushesTheDatabasesNotes_article() async throws {
        let rig = try makeArticleRig()
        let deleted = try await delete(rig, Self.villageRegisters)
        rig.editorText = rig.editorState.content
        let mayLand = LifecycleEntryHarness.Gate()
        defer { mayLand.open() }
        rig.controller.testOrderingSpy = { [spyLog = rig.spyLog, events = rig.events] step in
            spyLog.note(step)
            events.note("spy " + step)
        }
        startStampedRebuild(rig, mayLand: mayLand)
        rig.quickUndoAnswer = .refuse(reason: "docChanged")
        let pushesBefore = rig.pushes.count

        let undo = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([undo]))
        mayLand.open()
        _ = await rig.waitUntilSettled()

        #expect(rig.replyWords() == ["undo failed"])
        // The spy fires only in the settle's own re-push (the stand-in rebuild above does not call it): it is the push the fresh settle
        // owes the editor after a refused restore, whatever else was pushed meanwhile.
        let repushed = rig.events.items.contains("spy efRepushManagedRegions")
        let recent = rig.events.items.suffix(6).map { String($0.prefix(60)) }
        let pushed = rig.pushes.count - pushesBefore
        #expect(
            repushed,
            "expected the fresh settle after the refused restore to re-push the database's Notes, got none; pushes \(pushed), last events \(recent)")
        #expect(
            rig.pushes.count - pushesBefore == 1,
            "expected the database's Notes to reach the editor after the refused restore (exactly 1 push), got \(rig.pushes.count - pushesBefore)")
        #expect(rig.editorState.pendingReinsertCount == 0, "expected pendingReinsertCount 0 after a refused restore")

        // A rebuild that reads now is not skipped as stale.
        let later = LifecycleEntryHarness.Gate()
        later.open()
        let pushesNow = rig.pushes.count
        startStampedRebuild(rig, mayLand: later)
        _ = await gateWaitUntil({ rig.events.items.filter { $0 == "rebuild landed" }.count == 2 })
        #expect(rig.pushes.count - pushesNow == 1, "expected 1 push, got \(rig.pushes.count - pushesNow)")
    }

    // MARK: - U-Q22, U-Q23

    // U-Q22 (S1): a text edit that empties the redo branch discards the entry's slot and holder while the reinsert is still queued; the
    // reinsert still applies from its own reference
    @Test("U-Q22 (S1): the holder survives a discard of the entry while the reinsert is queued")
    func testHolderSurvivesDiscard_book6() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig, settle: false)
        let blocker = try rig.holdQueue()   // the delete job, then the reinsert, wait behind this
        defer { rig.release(blocker) }
        let undo = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([undo]))
        #expect(rig.controller.efHolders[deleted.entry.id] != nil && rig.controller.efSlots.slot(deleted.entry.id) != nil, "precondition")

        await rig.controller.handleHistoryEdited()
        #expect(rig.controller.efHolders[deleted.entry.id] == nil, "the controller let go of the holder")
        #expect(rig.controller.efSlots.slot(deleted.entry.id) == nil, "and of the slot")
        rig.release(blocker)
        _ = await rig.waitUntilSettled()

        let ids = Set(try rig.blocks().map(\.id))
        let missingRows = deleted.subtree.filter { id in !ids.contains(id) }.count
        #expect(
            missingRows == 0,
            "expected the section's rows in the database (the reinsert did nothing after the entry was discarded): \(missingRows) missing")
    }

    // Design assumption (G-T6): the editor consumes a batch only while the live document equals its post-op copy, so the restored
    // screen never holds what the batch carries, and the reinsert (exactly the payload) may overwrite it.
    // U-Q23 (S15): a batch the undo's JS call consumed (an edit pending at the press, with an insert and its own delete of a temp id) is
    // applied before the reinsert, and the reinsert still leaves exactly the pre-delete rows
    @Test("U-Q23 (S15): a batch the undo's JS call consumed")
    func testNonEmptyUndoBatchWithInsertThenDeleteOfTempId_book6() async throws {
        let rig = try makeBookRig()
        let before = try rig.blocks()
        let deleted = try await delete(rig)
        let anchor = try paragraphOutside(deleted.subtree, rig)
        let batch = BlockChanges(
            updates: [BlockUpdate(
                id: anchor.id, textContent: anchor.textContent + " PENDING-Q23",
                markdownFragment: anchor.markdownFragment + " PENDING-Q23", headingLevel: nil)],
            inserts: [BlockInsert(
                tempId: "temp-q23", blockType: "paragraph", textContent: "inserted then deleted",
                markdownFragment: "inserted then deleted", headingLevel: nil, afterBlockId: anchor.id)],
            deletes: ["temp-q23"])
        rig.quickUndoAnswer = .restoreWithBatch(batch)

        let everythingSettled = await rig.pressAndSettle(deleted.entry)

        #expect(everythingSettled)
        #expect(rig.replyWords() == ["undo performed"], "got \(rig.replyWords())")
        let after = try rig.blocks()
        #expect(try rig.idDifferenceCount(before) == 0, "no row of the inserted-then-deleted block is left")
        let rowProblem = EditorFirstRig.parityProblem(after, before)   // a short description of the first difference, never the rows
        #expect(rowProblem == nil, "every row is the payload's: \(rowProblem ?? "")")
    }
}
