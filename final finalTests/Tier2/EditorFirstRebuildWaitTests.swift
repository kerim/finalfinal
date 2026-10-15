//
//  EditorFirstRebuildWaitTests.swift
//  final finalTests
//
//  Tier 2 (t-94369a83 Phase 4b slice 2a, fix round 5, part A): the VM end-to-end test `testDeleteUndoAtOnce_article`. On the article,
//  delete a section whose footnote references are not the last ones and press Cmd-Z at once: afterwards the article had 9 footnote
//  references but only 7 definitions, for good.
//
//  The mechanism: the delete's follow-up work (the footnote and bibliography resyncs) starts a background rebuild that reads the
//  database and, some time later, pushes what it read into the editor. The undo did not wait for it. The rebuild had read the
//  document as it was AFTER the delete, so its push, landing after the undo's checkpoint swap, put the post-delete document back
//  over the restored one, set `contentState` to idle in the middle of the undo, and the undo's own footnote resync then read the
//  post-delete text and deleted the "orphan" definitions from the restored database.
//
//  The fix has two waits, each with its own test:
//    - A1 (`testDeleteIsNotSettledUntilItsRebuildHasLanded_article`): the delete's follow-up work ends only when the rebuilds it
//      started have landed, so everything that waits for the delete (the undo, the close and quit wait, zoom, the switch to
//      Markdown, Save Version, export) waits for them too.
//    - A2 (`testUndoWaitsForARebuildSomethingElseStarted_article`): every structural command waits at its entry for the rebuilds
//      that are running, before its first change; this covers a rebuild the settle did not start (a citation debounce).
//  `testUndoAtOnceAfterDeleteWaitsForTheRebuild_article` is the whole scenario and passes with either wait; it fails only without both.
//
//  The rebuild is a stand-in Task registered through the real `registerRebuildTask` (the ContentView handlers that normally run it
//  are not mounted in a unit test): it reads the database through the same read the real rebuild makes, is held "in flight" by a
//  gate, and when released sets the content, pushes with the merge-guarded push and sets `contentState` idle, as the handlers do.
//  The fixture's one chapter holds nine footnote references; deleting "1.2 The Village Registers" takes out references 3 and 4.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import Testing
@testable import final_final

@Suite("Delete, then Cmd-Z at once, with a rebuild in flight — Phase 4b slice 2a fix round 5 (Tier 2)", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct EditorFirstRebuildWaitTests {

    // MARK: - Helpers

    private static let sectionTitle = "1.2 The Village Registers"

    private func makeRig() throws -> EditorFirstRig {
        // The footnote service writes through the queue and is the editor state's own, as in the app, so the resyncs really renumber
        // the references and clean the Notes.
        let rig = try EditorFirstRig(markdown: ComplexDocumentFixture.article.editorMarkdown, lifecycleServices: true)
        // The undo's checkpoint swap puts the editor's document back to what it was when the delete was pressed (the restored section
        // is in the editor's own blocks again). The rig's editor model does the same, so the undo's merge-guarded re-push keeps the
        // restored section, as the real push does, and the footnote resync that follows reads the restored document. (Before this the
        // model kept the post-delete blocks a stand-in rebuild had pushed, which no real swap leaves behind.)
        rig.editorTextAfterUndoSwap = try rig.assembledMarkdown()
        return rig
    }

    /// Starts a stand-in for a Notes or bibliography rebuild: it reads the database now, waits "in flight" for `mayLand`, then lands
    /// the way the ContentView handlers do (content, merge-guarded push, `contentState` idle). Registered like the real ones.
    private func startRebuild(_ rig: EditorFirstRig, mayLand: LifecycleEntryHarness.Gate) {
        let task = Task { @MainActor in
            let read = rig.controller.fetchFullBlocksWithIds(db: rig.db, pid: rig.pid)
            rig.events.note("rebuild read")
            await mayLand.wait()
            if let read {
                rig.editorState.content = read.markdown
                _ = await rig.sync.setContentWithBlockIds(
                    markdown: read.markdown, blockIds: read.blockIds, imageMeta: read.imageMeta,
                    cursorBoundary: read.bibBoundaryIndex, cursorBoundaryEnd: read.bibBoundaryEndIndex,
                    expectedBlocks: read.expectedBlocks, managedBlockIds: read.managedBlockIds, preserveUserBlocks: true)
            }
            rig.editorState.contentState = .idle
            rig.events.note("rebuild landed")
        }
        rig.editorState.registerRebuildTask(task)
    }

    private func swapSeen(_ rig: EditorFirstRig) -> Bool {
        rig.events.items.contains { $0.contains("performStructuralSwap") }
    }

    private func indexOf(_ rig: EditorFirstRig, _ event: String) -> Int? { rig.events.items.firstIndex(of: event) }

    private func expectNotesMatchTheReferences(_ rig: EditorFirstRig, _ context: String) throws {
        let notes = EditorFirstFootnoteLifecycleTests.footnoteLabels(in: try rig.assembledMarkdown())
        let wanted = (1...9).map(String.init)
        #expect(notes.references.sorted(by: EditorFirstFootnoteLifecycleTests.numeric) == wanted, "\(context): nine references: \(notes.references)")
        #expect(
            notes.definitions.sorted(by: EditorFirstFootnoteLifecycleTests.numeric) == wanted,
            "\(context): nine definitions for nine references, none lost: \(notes.definitions.count) definitions, labels \(notes.definitions)")
    }

    /// Presses Cmd-Z for `entry` the way the editor's undo coordinator does.
    private func pressUndo(_ rig: EditorFirstRig, _ entry: StructuralEntry) -> Task<Void, Never> {
        Task { @MainActor in
            await rig.controller.handleStructuralRequest(opId: entry.id.uuidString, direction: .undo)
        }
    }

    // MARK: - The whole scenario

    @Test("Delete, then Cmd-Z at once, the delete's rebuild still in flight: the undo waits for it to land, and no definition is lost")
    func testUndoAtOnceAfterDeleteWaitsForTheRebuild_article() async throws {
        let rig = try makeRig()
        let before = EditorFirstFootnoteLifecycleTests.footnoteLabels(in: try rig.assembledMarkdown())
        #expect(before.references.count == 9 && before.definitions.count == 9, "the article has nine footnotes: \(before)")
        let root = try rig.heading(Self.sectionTitle)
        try rig.setReply(.init(removedLeaderIds: [root.id]))
        let rebuildMayLand = LifecycleEntryHarness.Gate()
        defer { rebuildMayLand.open() }
        // The delete's follow-up work starts the rebuild (here: when the job has ended and the editor holds the post-delete text).
        rig.controller.testEFSettleHold = { [weak rig] in
            guard let rig else { return }
            _ = try? rig.syncEditorContentFromDatabase()
            self.startRebuild(rig, mayLand: rebuildMayLand)
        }

        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        #expect(outcome == .performed)
        let entry = try #require(rig.unifiedUndo.undoStack.last)
        // Cmd-Z at once, before the job has even ended.
        let undo = pressUndo(rig, entry)
        let inFlight = await gateWaitUntil({ self.indexOf(rig, "rebuild read") != nil }, iterations: 4000)
        #expect(inFlight, "the delete's follow-up work must have started its rebuild")

        // The undo must not swap while the rebuild is in flight: its push would land on top of the restored document.
        let swappedEarly = await gateWaitUntil({ self.swapSeen(rig) }, iterations: 60)
        #expect(!swappedEarly, "the undo went ahead while the delete's rebuild was still in flight")
        rebuildMayLand.open()
        await undo.value

        let landed = try #require(indexOf(rig, "rebuild landed"))
        let swap = try #require(rig.events.items.firstIndex { $0.contains("performStructuralSwap") })
        #expect(landed < swap, "the rebuild's push must land BEFORE the undo's swap: landed at \(landed), swap at \(swap)")
        let replies = rig.scripts(containing: "receiveUndoOutcome")
        #expect(replies.count == 1 && replies.first?.contains("'performed'") == true, "got \(replies)")
        try expectNotesMatchTheReferences(rig, "after the undo")
    }

    // MARK: - A1: the settle waits for its own rebuild

    @Test("A1: the delete is not settled while its rebuild is in flight: what waits for the delete (zoom, switch, export) waits for the rebuild")
    func testDeleteIsNotSettledUntilItsRebuildHasLanded_article() async throws {
        let rig = try makeRig()
        let root = try rig.heading(Self.sectionTitle)
        try rig.setReply(.init(removedLeaderIds: [root.id]))
        let rebuildMayLand = LifecycleEntryHarness.Gate()
        defer { rebuildMayLand.open() }
        rig.controller.testEFSettleHold = { [weak rig] in
            guard let rig else { return }
            _ = try? rig.syncEditorContentFromDatabase()
            self.startRebuild(rig, mayLand: rebuildMayLand)
        }
        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        #expect(outcome == .performed)
        let started = await gateWaitUntil({ self.indexOf(rig, "rebuild read") != nil }, iterations: 4000)
        #expect(started, "the delete's follow-up work must have started its rebuild")

        // The shared wait zoom, the switch to Markdown, Save Version and export use, started while the rebuild is in flight.
        let waiting = Task { @MainActor in
            await rig.editorState.awaitPendingStructuralJobs()
            rig.events.note("wait ended")
        }
        try await Task.sleep(for: .milliseconds(250))
        #expect(indexOf(rig, "wait ended") == nil, "the wait must not end while the delete's rebuild is still in flight")
        #expect(rig.editorState.efJobRegistry.hasUnsettledWork, "the delete is not settled yet")

        rebuildMayLand.open()
        await waiting.value
        let landed = try #require(indexOf(rig, "rebuild landed"))
        let ended = try #require(indexOf(rig, "wait ended"))
        #expect(landed < ended, "the wait ends only after the rebuild has landed: landed at \(landed), ended at \(ended)")
        #expect(!rig.editorState.efJobRegistry.hasUnsettledWork)
    }

    // MARK: - A2: every structural command waits at its entry

    @Test("A2: a rebuild that something else started (a citation debounce) after the delete: the undo waits for it before its swap")
    func testUndoWaitsForARebuildSomethingElseStarted_article() async throws {
        let rig = try makeRig()
        let root = try rig.heading(Self.sectionTitle)
        try rig.setReply(.init(removedLeaderIds: [root.id]))
        // The editor holds the post-delete text when the follow-up work starts, so its footnote resync really cleans the Notes.
        rig.controller.testEFSettleHold = { [weak rig] in
            guard let rig else { return }
            _ = try? rig.syncEditorContentFromDatabase()
        }
        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        #expect(outcome == .performed)
        let entry = try #require(rig.unifiedUndo.undoStack.last)
        await rig.settle(entry.id)   // the delete is fully settled: the settle's wait cannot be what holds the undo
        try rig.syncEditorContentFromDatabase()

        // A rebuild that is NOT the settle's starts now and is still in flight when Cmd-Z is pressed.
        let rebuildMayLand = LifecycleEntryHarness.Gate()
        defer { rebuildMayLand.open() }
        startRebuild(rig, mayLand: rebuildMayLand)
        let started = await gateWaitUntil { self.indexOf(rig, "rebuild read") != nil }
        #expect(started)
        let undo = pressUndo(rig, entry)

        let swappedEarly = await gateWaitUntil({ self.swapSeen(rig) }, iterations: 60)
        #expect(!swappedEarly, "the undo went ahead (past its entry) while a rebuild was still in flight")
        #expect(rig.controller.isPerforming, "the undo holds the gate while it waits")
        rebuildMayLand.open()
        await undo.value

        let landed = try #require(indexOf(rig, "rebuild landed"))
        let swap = try #require(rig.events.items.firstIndex { $0.contains("performStructuralSwap") })
        #expect(landed < swap, "the rebuild's push must land BEFORE the undo's swap: landed at \(landed), swap at \(swap)")
        try expectNotesMatchTheReferences(rig, "after the undo")
        #expect(rig.editorState.structuralGate.isIdle)
    }

    // MARK: - F1: a rebuild that starts while the undo waits for the delete

    @Test("F1: a rebuild that starts after the undo has waited for the delete (before it sets its guard) is waited for before the swap")
    func testUndoWaitsForARebuildThatStartedWhileItWaitedForTheDelete_article() async throws {
        let rig = try makeRig()
        let root = try rig.heading(Self.sectionTitle)
        try rig.setReply(.init(removedLeaderIds: [root.id]))
        rig.controller.testEFSettleHold = { [weak rig] in
            guard let rig else { return }
            _ = try? rig.syncEditorContentFromDatabase()
        }
        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        #expect(outcome == .performed)
        let entry = try #require(rig.unifiedUndo.undoStack.last)
        await rig.settle(entry.id)
        try rig.syncEditorContentFromDatabase()

        // The undo's entry wait finds nothing running. A rebuild (a citation or footnote debounce) starts later, when the undo has
        // found its snapshot, i.e. after the seconds it can spend waiting for the delete's job and settle, and is still in flight.
        let rebuildMayLand = LifecycleEntryHarness.Gate()
        defer { rebuildMayLand.open() }
        rig.controller.testAfterUndoSnapshotResolved = { [weak rig] in
            guard let rig else { return }
            self.startRebuild(rig, mayLand: rebuildMayLand)
        }
        let undo = pressUndo(rig, entry)
        let started = await gateWaitUntil({ self.indexOf(rig, "rebuild read") != nil }, iterations: 4000)
        #expect(started, "the stand-in rebuild must have started inside the undo")

        let swappedEarly = await gateWaitUntil({ self.swapSeen(rig) }, iterations: 60)
        #expect(!swappedEarly, "the undo went ahead to its swap while a rebuild that started during its wait was still in flight")
        rebuildMayLand.open()
        await undo.value

        let landed = try #require(indexOf(rig, "rebuild landed"))
        let swap = try #require(rig.events.items.firstIndex { $0.contains("performStructuralSwap") })
        #expect(landed < swap, "the rebuild's push must land BEFORE the undo's swap: landed at \(landed), swap at \(swap)")
        try expectNotesMatchTheReferences(rig, "after the undo")
    }

    // MARK: - F7: the Delete click is not held by a running rebuild

    @Test("F7: a Delete click is granted at once while a rebuild runs; a Duplicate still waits for it")
    func testDeleteClickIsNotHeldByARunningRebuild_article() async throws {
        let rig = try makeRig()
        let root = try rig.heading(Self.sectionTitle)
        try rig.setReply(.init(removedLeaderIds: [root.id]))
        let firstRebuildMayLand = LifecycleEntryHarness.Gate()
        defer { firstRebuildMayLand.open() }
        startRebuild(rig, mayLand: firstRebuildMayLand)
        let started = await gateWaitUntil { self.indexOf(rig, "rebuild read") != nil }
        #expect(started)

        // The Delete click runs at once although a rebuild is in flight (the editor removes the section first; the click does not
        // wait for a rebuild that takes seconds on a book).
        let delete = Task { @MainActor in await rig.controller.performSectionDelete(rootId: root.id) }
        let finishedAtOnce = await gateWaitUntil({ rig.unifiedUndo.undoStack.count == 1 }, iterations: 200)
        #expect(finishedAtOnce, "the Delete click was held by the running rebuild")
        #expect(!rig.editorState.runningRebuildTasks.isEmpty, "and the rebuild is still in flight")
        let outcome = await delete.value
        #expect(outcome == .performed)
        let entry = try #require(rig.unifiedUndo.undoStack.last)
        firstRebuildMayLand.open()
        await rig.settle(entry.id)
        try rig.syncEditorContentFromDatabase()

        // A Duplicate (another structural command) still waits at its entry for a running rebuild.
        let secondRebuildMayLand = LifecycleEntryHarness.Gate()
        defer { secondRebuildMayLand.open() }
        let before = rig.events.items.count
        startRebuild(rig, mayLand: secondRebuildMayLand)
        let second = try rig.heading("1.4 Bridges and Boundaries")
        let duplicate = Task { @MainActor in await rig.controller.performSectionDuplicate(rootId: second.id) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.unifiedUndo.undoStack.count == 1, "the Duplicate must wait for the running rebuild: \(rig.unifiedUndo.undoStack.count) entries")
        #expect(rig.events.items.dropFirst(before).allSatisfy { !$0.contains("beginStructuralOp") }, "and has not started its sequence")
        secondRebuildMayLand.open()
        let duplicateOutcome = await duplicate.value
        #expect(duplicateOutcome == .performed)
    }
}
