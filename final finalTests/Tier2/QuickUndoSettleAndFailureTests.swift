//
//  QuickUndoSettleAndFailureTests.swift
//  final finalTests
//
//  This file: U-Q9, U-Q11, U-Q12, U-Q18, U-Q20, U-Q21.
//  Tier 2 (t-94369a83 Phase 4b slice 2b; plan-v1 F2, plan-v2-addendum 6.2, plan-v3-addendum A1/D1/D2/D7, plan-v4-addendum 5): guards of
//  the quick undo and quick redo of an editor-first Delete Section, driven with `EditorFirstRig` (EditorFirstDeleteTests.swift). The
//  quick undo replies BEFORE its reinsert has applied, so every test that reads the database waits with
//  `EditorFirstRig.waitUntilSettled()` first. Every wait is bounded. Shared helpers: QuickUndoFixtures.swift.
//

import Foundation
import GRDB
import SwiftUI
import Testing
@testable import final_final

@Suite("Quick undo: close, settle and the failure paths (Phase 4b slice 2b, Tier 2)", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct QuickUndoSettleAndFailureTests: QuickUndoFixtures {

    // MARK: - U-Q9, U-Q11, U-Q12, U-Q18, U-Q20, U-Q21

    @Test("U-Q9: a close pressed right after the quick undo waits for the reinsert and its settle, then saves the restored section")
    func testCloseRightAfterQuickUndoWaitsForReinsert_book6() async throws {
        let rig = try makeBookRig()
        rig.js.answer("flushPendingBlockChanges", true)
        rig.js.answer("hasBlockChanges", false)
        rig.fetchAnswerProvider = { [weak rig] in try? rig?.assembledMarkdown() }
        let deleted = try await delete(rig)
        let settleMayGo = LifecycleEntryHarness.Gate()
        defer { settleMayGo.open() }
        rig.controller.testReinsertSettleHold = { await settleMayGo.wait() }
        let undo = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([undo]))

        let finished = GateOrderLog()
        let close = Task { @MainActor in
            let result = await rig.runLifecycle(.close, bounds: .production)
            finished.note("close done")
            return result
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(finished.items.isEmpty, "expected the close to wait for the reinsert settle (the settle is parked)")
        settleMayGo.open()
        let result = await close.value

        #expect(result.outcome == .flushed, "the close completed")
        #expect(try rig.missingRowCount(deleted.subtree) == 0, "the saved document has the restored section")
        #expect(!rig.editorState.efJobRegistry.hasUnsettledWork)
        #expect(rig.editorState.structuralGate.isIdle)
    }

    // U-Q11: a reinsert that fails writes the editor's own text to the database at once (not after waiting out its own entry), and the
    // slot falls back
    @Test("U-Q11: a reinsert that fails writes the editor's own text to the database at once")
    func testReinsertNotAppliedFlushesEditorContent_book6() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)
        // A payload row whose parent is nowhere: the reinsert's transaction rolls back (`brokenParentChain`).
        let holder = try #require(rig.controller.efHolders[deleted.entry.id])
        var payload = holder.snapshot().preDeleteRows
        payload.append(Block(
            projectId: rig.pid, parentId: "a-parent-that-never-existed", sortOrder: 9_999, blockType: .listItem,
            textContent: "orphan item", markdownFragment: "- orphan item"))
        holder.fill(rows: payload, leaders: holder.snapshot().leaders, resolvedRootId: deleted.root.id)
        let started = Date()

        let run = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([run]))
        let settled = await rig.waitUntilSettled(iterations: 1200)

        #expect(settled, "expected the whole-document flush within the bounded wait (it waited for its own entry's settle)")
        #expect(Date().timeIntervalSince(started) < 8, "no 15 s wait")
        // The fallback settles its marker FIRST and flushes after it, so "settled" does not yet say the flush has written: wait for the
        // rows themselves (the flush itself is not slow, but a busy machine can delay it past the first look).
        let root = deleted.root.textContent
        let written = await gateWaitUntil({ ((try? rig.blocks().contains { $0.textContent == root }) ?? false) }, iterations: 1000)
        #expect(written, "expected the database to hold the restored section after a reinsert that did not apply")
        #expect(rig.controller.efSlots.slot(deleted.entry.id)?.state == .fallback)
    }

    // U-Q12: right after the quick undo, before the reinsert has applied, the sidebar shows the restored section; once the rows are back
    // the overlay is gone
    @Test("U-Q12: right after the quick undo")
    func testSidebarShowsSectionRightAfterQuickUndo_book6() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)
        let blocker = try rig.holdQueue()   // the reinsert waits behind it
        defer { rig.release(blocker) }

        let run = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([run]))

        let overlay = try #require(rig.editorState.pendingRestoreSections[deleted.entry.id], "the restored leaders are kept in an overlay")
        #expect(overlay.contains { $0.id == deleted.root.id })
        let withoutSection = try rig.blocks().filter { $0.blockType == .heading }
        #expect(!withoutSection.contains { $0.id == deleted.root.id }, "precondition: the database still lacks the section")
        #expect(
            rig.editorState.mergingPendingRestores(into: withoutSection).contains { $0.id == deleted.root.id },
            "expected the restored section's heading in the outline results")
        let shown = await gateWaitUntil({ rig.editorState.sections.contains { $0.id == deleted.root.id } })
        #expect(shown, "the sidebar lists the section")

        rig.release(blocker)
        _ = await rig.waitUntilSettled()
        #expect(rig.editorState.pendingRestoreSections[deleted.entry.id] == nil, "the overlay is cleared once the reinsert has put the rows back")
        #expect(try rig.blocks().contains { $0.id == deleted.root.id })
    }

    // U-Q18 (S9, M20): when the editor's contentChanged never arrives, the settle reads the editor's own text and does not resync from the
    // post-delete content
    @Test("U-Q18 (S9, M20): when the editor's contentChanged never arrives")
    func testSettleNeverResyncsFromStaleContent_article() async throws {
        let rig = try makeArticleRig()
        let before = try rig.assembledMarkdown()
        let deleted = try await delete(rig, Self.villageRegisters)
        rig.withholdContentUpdate = true
        let contentIsStillTheOldText = rig.editorState.content == before
        #expect(!contentIsStillTheOldText, "precondition: content is the post-delete text")
        let readsBefore = rig.getContentCalls
        // The number of reads the editor had answered at the moment the reinsert applied: the settle's own live read comes after it.
        let readsAtApply = GateOrderLog()
        rig.controller.testOrderingSpy = { [weak rig, readsAtApply] step in
            if step == "reinsertApplied", let rig { readsAtApply.note("\(rig.getContentCalls)") }
        }

        let everythingSettled = await rig.pressAndSettle(deleted.entry)

        #expect(everythingSettled)
        // The read is not only made, its text is what the resync works from: the footnote resync of the restored document (every
        // reference of the original) replaces the post-delete one. A resync from the stale content has the same references as the delete's
        // own, which the service skips as unchanged: it would leave the post-delete references as the last resync's.
        let reads = rig.getContentCalls
        let appliedAfterReads = Int(readsAtApply.items.first ?? "") ?? Int.max
        let restoredReferences = FootnoteSyncService.extractFootnoteRefs(from: before).count
        let resyncedReferences = rig.footnotes.lastKnownRefs.count
        let evidence = "reads \(reads) (before the press \(readsBefore), when the reinsert applied \(appliedAfterReads)); "
            + "resync references \(resyncedReferences) of \(restoredReferences)"
        #expect(
            resyncedReferences == restoredReferences,
            "expected the settle's footnote resync to work from the editor's text, not the stale content (\(evidence))")
        #expect(reads > appliedAfterReads, "expected the settle to read the editor's text after the reinsert applied (\(evidence))")
        #expect(reads > readsBefore, "the settle asked the editor for its text (\(evidence))")
        #expect(
            try rig.documentDiff(before) == nil,
            "expected the resync refs to be the restored document's (the stale content was used): nothing is lost")
        let labels = EditorFirstFootnoteLifecycleTests.footnoteLabels(in: try rig.assembledMarkdown())
        #expect(labels.references.count == 9 && labels.definitions.count == 9, "\(labels)")
    }

    // U-Q20 (S11): a reinsert that cannot be reserved replies exactly once (cancelled while the gate is closed to new work) and still lets
    // the editor queue typing again
    @Test("U-Q20 (S11): a reinsert that cannot be reserved replies exactly once")
    func testReinsertNotReservedRepliesOnceAndResumes_book6() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)
        let other = try TestFixtureFactory.createTemporary(content: "# Other project\n\nBody.")
        let otherPid = try TestFixtureFactory.getProjectId(from: other)
        rig.controller.testQuickUndoAfterRestore = { [weak rig] in
            // The project is switching away: the gate refuses new work and the service is pointed at the next project's writer, so the
            // reinsert (built for this project) is refused before it reserves anything (`.identityMismatch`).
            guard let rig else { return }
            rig.editorState.structuralGate.isClosedToNewWork = true
            rig.sync.configure(database: other, projectId: otherPid, webView: rig.view)
        }
        defer { rig.editorState.structuralGate.isClosedToNewWork = false }

        let run = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([run]))

        let replies = rig.scripts(containing: "receiveUndoOutcome")
        #expect(replies.count == 1 && replies.first?.contains("'cancelled'") == true, "exactly one reply, cancelled: \(replies)")
        #expect(rig.resumeScripts.count == 1, "expected resumeSyncAfterQuickUndo after a refused or unreserved quick undo")
        #expect(rig.editorState.pendingReinsertCount == 0, "the pending count went back down")
        #expect(!rig.sync.structuralClickPending)
    }

    // U-Q21 (S12): an editor that refuses the restore (the document changed) leaves everything as it was, tells the user, and still
    // resumes the editor
    @Test("U-Q21 (S12): an editor that refuses the restore")
    func testRefusedRecheckShowsNotice_book6() async throws {
        let rig = try makeBookRig()
        let deleted = try await delete(rig)
        let after = try rig.blocks()
        rig.quickUndoAnswer = .refuse(reason: "docChanged")

        let everythingSettled = await rig.pressAndSettle(deleted.entry)

        #expect(everythingSettled)
        #expect(rig.replyWords() == ["undo failed"], "got \(rig.replyWords())")
        #expect(
            rig.toasts.current?.message == ToastFactory.undoQueueDropped().message,
            "expected the notice 'Some undo or redo presses could not be carried out.' after a refused restore")
        let changed = EditorFirstRig.parityProblem(try rig.blocks(), after)
        #expect(changed == nil, "nothing changed in the database: \(changed ?? "")")
        #expect(rig.unifiedUndo.undoStack.last?.id == deleted.entry.id && rig.unifiedUndo.redoStack.isEmpty, "the entry stays where it was")
        #expect(rig.resumeScripts.count == 1, "the editor is resumed after a refused restore")
        #expect(rig.editorState.pendingReinsertCount == 0, "expected pendingReinsertCount 0 after a refused restore")
        #expect(rig.editorState.pendingRestoreSections.isEmpty)
    }

    // MARK: - A switch to Markdown around a quick undo (quick siblings of the two slow-undo lifecycle tests)

    // Quick sibling of 'a switch pressed during a slow undo is held': a press while the quick undo holds the gate is held, not refused,
    // and happens once when the undo is over
    @Test("Quick sibling: a switch pressed while a quick undo holds the gate is held, then happens once")
    func testSwitchPressedDuringAQuickUndoIsHeld() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let posted = GateOrderLog()
        let observer = NotificationCenter.default.addObserver(forName: .willToggleEditorMode, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { posted.note("toggle requested") }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let deleted = try await delete(rig, "Section A")
        // The quick undo stops between its reinsert holding a place and the editor's resume: the gate is held, the writer is free.
        let undoMayEnd = LifecycleEntryHarness.Gate()
        defer { undoMayEnd.open() }
        rig.controller.testQuickUndoResumeHold = { await undoMayEnd.wait() }
        let undo = rig.startPress(deleted.entry)
        let running = await gateWaitUntil { rig.quickUndoScripts.count == 1 && rig.resumeScripts.isEmpty && rig.editorState.structuralGate.isHeld }
        #expect(running, "the quick undo is mid-way and holds the gate")

        rig.editorState.requestEditorModeToggle()
        #expect(rig.editorState.heldModeToggleTask != nil, "the press is held, not refused")
        try await Task.sleep(for: .milliseconds(150))
        #expect(posted.items.isEmpty, "the switch must not start while the undo is running")

        undoMayEnd.open()
        #expect(await rig.awaitRuns([undo]))
        let happened = await gateWaitUntil { posted.items == ["toggle requested"] }
        #expect(happened, "the held press starts the switch once the undo is over: \(posted.items)")
        let released = await gateWaitUntil { rig.editorState.heldModeToggleTask == nil }
        #expect(released)
        _ = await rig.waitUntilSettled()
        try await Task.sleep(for: .milliseconds(100))
        #expect(posted.items == ["toggle requested"], "exactly once: \(posted.items)")
    }

    // Quick sibling of 'the switch is never dropped': a switch to Markdown pressed right after a quick undo waits for the reinsert's
    // settle, then happens once, with the restored section in the Markdown
    @Test("Quick sibling of 'the switch is never dropped': a switch to Markdown pressed right after a quick undo")
    func testSwitchRightAfterQuickUndoWaitsForTheReinsertSettle() async throws {
        let rig = try EditorFirstRig(markdown: Self.fourSections)
        let deleted = try await delete(rig, "Section A")
        let settleMayGo = LifecycleEntryHarness.Gate()
        defer { settleMayGo.open() }
        rig.controller.testReinsertSettleHold = { await settleMayGo.wait() }
        let undo = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([undo]), "the quick undo is over; its reinsert's settle is parked")

        // The REAL handler of the switch, the way the Markdown-switch tests of slice 2a drive it.
        let generationBefore = rig.unifiedUndo.generation
        Color.clear.handleEditorModeToggle(
            editorState: rig.editorState, sectionSyncService: SectionSyncService(),
            findBarState: FindBarState(), unifiedUndoService: rig.unifiedUndo)
        try await Task.sleep(for: .milliseconds(250))
        #expect(rig.editorState.editorMode == .wysiwyg, "the switch has not happened while the reinsert's settle is pending")
        #expect(rig.unifiedUndo.generation == generationBefore, "no barrier fired: the switch changed nothing yet")

        settleMayGo.open()
        let switched = await gateWaitUntil({ rig.editorState.editorMode == .source }, iterations: 2000)
        #expect(switched, "the switch runs once the settle has ended")
        #expect(rig.unifiedUndo.generation == generationBefore + 1, "and exactly once")
        #expect(rig.editorState.sourceContent.contains("Section A"), "the Markdown editor is handed the text with the restored section in it")
        #expect(try rig.blocks().contains { $0.textContent == "Section A" }, "and the database has it")
    }
}
