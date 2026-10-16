//
//  QuickUndoCommittedStateTests.swift
//  final finalTests
//
//  Tier 2 (t-94369a83 Phase 4b slice 2b; the second real-app bug, VM test testRedoStraightAfterQuickUndo_book6): Cmd-Z and then
//  Cmd-Shift-Z within a second on a chapter with footnotes left the remaining references numbered up to 54 and the Notes holding the
//  deleted chapter's nine definitions. The footnote service skipped the redo's resync because it looked identical to the delete's own
//  (`lastRenumberedHash`), while the quick undo had put the 54 pre-delete Notes rows back behind the service's back. The fix: the quick
//  undo and redo make the services forget what they last committed (`StructuralUndoController.forgetCommittedDerivedState`), at four
//  points (the quick undo's restore, the reinsert settle's applied branch, the quick redo's reply, the C5 fallback).
//
//  The rig has no editor that renames the body references (the editor does that on `.renumberFootnotes`), so the observable result is
//  the Notes TABLE (45 definitions, labels 1...45, each with the text of the reference's original label) and the notification itself.
//    - U-Q32   redo straight after the undo, before the reinsert applies
//    - U-Q32b  the delete's own resync write commits after both presses (needs the reset in the reinsert's settle, sw76)
//    - U-Q32c  the same late commit while the reinsert's settle is held (needs the reset in the redo, sw77)
//    - U-Q48   the Bibliography loses the deleted chapter's entry (sw80)
//    - U-Q32d  the C5 fallback rewrote the Notes: the next resync with the same references performs (sw78; the late commit is simulated)
//  The point-by-point verification (which patch reddens which test, and which patch no unit test can reach) is in swift-break-map.md.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Quick undo: a redo straight after the undo renumbers and cleans the Notes (Phase 4b slice 2b, Tier 2)", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct QuickUndoCommittedStateTests: QuickUndoFixtures {

    /// The third chapter of book6: its nine references are labels 19 to 27 of 54 (the remaining 45 end up 1...45).
    private static let thirdChapter = "Chapter 3: The Quiet Archive and Its Ledgers"

    /// book6 with the footnote and bibliography services writing through the queue; the delete's settle reads the database's text.
    private func makeFootnotedBookRig() throws -> EditorFirstRig {
        let rig = try EditorFirstRig(markdown: EditorFirstFootnoteLifecycleTests.markedBook6, lifecycleServices: true)
        rig.controller.testEFSettleHold = { [weak rig] in _ = try? rig?.syncEditorContentFromDatabase() }
        return rig
    }

    /// label -> text of every Notes definition line of `markdown`.
    private static func definitionTexts(in markdown: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^\[\^(\d+)\]:[ \t]*(.*)$"#) else { return [:] }
        var result: [String: String] = [:]
        for match in regex.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)) {
            guard let label = Range(match.range(at: 1), in: markdown), let text = Range(match.range(at: 2), in: markdown) else { continue }
            result[String(markdown[label])] = String(markdown[text])
        }
        return result
    }

    /// "" when the Notes table is what a redo must leave (45 definitions, labels 1...45, definition n with the text the reference's ORIGINAL
    /// label had: labels 19 to 27 were the deleted chapter's), else a short description of the first problem.
    private func notesProblem(_ rig: EditorFirstRig, original: String) throws -> String {
        let after = Self.definitionTexts(in: try rig.assembledMarkdown())
        let originals = Self.definitionTexts(in: original)
        guard after.count == 45 else { return "\(after.count) definitions in the Notes, wanted 45" }
        let wrong = (1...45).filter { after[String($0)] != originals[String($0 <= 18 ? $0 : $0 + 9)] }
        return wrong.isEmpty ? "" : "definition(s) \(wrong.prefix(3)) carry the wrong text or label"
    }

    private func renumbersPosted(_ rig: EditorFirstRig) -> Int {
        rig.events.items.filter { $0.hasPrefix("renumber mapping=") }.count
    }

    // MARK: - U-Q32

    @Test("U-Q32 (VM bug): Cmd-Z then Cmd-Shift-Z before the reinsert applies: the Notes lose the deleted chapter's definitions")
    func testRedoBeforeReinsertSettleRenumbersAndCleansNotes_book6() async throws {
        let rig = try makeFootnotedBookRig()
        let observer = rig.observeRenumbers()
        defer { NotificationCenter.default.removeObserver(observer) }
        let original = try rig.assembledMarkdown()
        let deleted = try await delete(rig, Self.thirdChapter)
        let afterDelete = renumbersPosted(rig)
        #expect(afterDelete >= 1, "precondition: the delete's own resync renumbered 28...54 to 19...45")
        let reinsertMayRun = DispatchSemaphore(value: 0)
        defer { reinsertMayRun.signal() }
        rig.controller.testReinsertBodyHold = { reinsertMayRun.wait() }

        let undo = rig.startPress(deleted.entry)
        let redo = rig.startPress(deleted.entry, .redo)
        #expect(await rig.awaitRuns([undo, redo]), "both presses ended")
        reinsertMayRun.signal()
        #expect(await rig.waitUntilSettled(iterations: 2000))

        let problem = try notesProblem(rig, original: original)
        #expect(problem.isEmpty, "expected the Notes cleaned and renumbered after the redo: \(problem)")
        #expect(renumbersPosted(rig) > afterDelete, "expected .renumberFootnotes posted by the redo's resync")
        #expect(rig.replyWords() == ["undo performed", "redo performed"], "got \(rig.replyWords())")
    }

    // MARK: - U-Q32b, U-Q32c: the delete's own resync write commits late

    /// The third chapter is deleted and its follow-up footnote write has RESERVED behind a held ticket but not yet applied: the state of
    /// a delete whose resync write was queued when the user pressed Cmd-Z. That write has a rename map, so it is not asked again at its
    /// turn: it commits after the undo whatever the undo did, and sets the committed state back to the post-delete one.
    private struct QueuedResync {
        let rig: EditorFirstRig
        let deleted: QuickUndoDeleted
        let original: String
        let blocker: WriterTicket
    }

    private func deleteWithResyncWriteQueued() async throws -> QueuedResync {
        let rig = try makeFootnotedBookRig()
        let original = try rig.assembledMarkdown()
        let settleMayRun = LifecycleEntryHarness.Gate()
        rig.controller.testEFSettleHold = { [weak rig] in
            _ = try? rig?.syncEditorContentFromDatabase()
            await settleMayRun.wait()
        }
        let deleted = try await delete(rig, Self.thirdChapter, settle: false)
        _ = await rig.editorState.efJobRegistry.awaitOutcome(deleted.entry.id)
        let blocker = try rig.holdQueue()
        settleMayRun.open()
        let queued = await gateWaitUntil({ rig.footnotes.state == .syncing })
        #expect(queued, "precondition: the delete's footnote write is reserved behind the held ticket")
        return QueuedResync(rig: rig, deleted: deleted, original: original, blocker: blocker)
    }

    @Test("U-Q32b (VM bug): the delete's resync write commits after both presses: the Notes are still cleaned and renumbered")
    func testRedoAfterTheLateCommitRenumbersAndCleansNotes_book6() async throws {
        let queued = try await deleteWithResyncWriteQueued()
        let rig = queued.rig
        defer { rig.release(queued.blocker) }
        let observer = rig.observeRenumbers()
        defer { NotificationCenter.default.removeObserver(observer) }
        let afterDelete = renumbersPosted(rig)

        let undo = rig.startPress(queued.deleted.entry)
        let redo = rig.startPress(queued.deleted.entry, .redo)
        #expect(await rig.awaitRuns([undo, redo]), "both presses ended")
        rig.release(queued.blocker)   // the delete's write applies and commits now: after the undo's and the redo's own resets
        #expect(await rig.waitUntilSettled(iterations: 2000))

        let problem = try notesProblem(rig, original: queued.original)
        #expect(problem.isEmpty, "expected the Notes cleaned and renumbered after a late commit of the delete's resync: \(problem)")
        #expect(renumbersPosted(rig) > afterDelete, "expected .renumberFootnotes posted by the redo's resync")
    }

    @Test("U-Q32c (VM bug): the late commit lands while the reinsert's settle is held: the redo still cleans and renumbers the Notes")
    func testRedoWhileTheReinsertSettleIsHeldRenumbersAndCleansNotes_book6() async throws {
        let queued = try await deleteWithResyncWriteQueued()
        let rig = queued.rig
        defer { rig.release(queued.blocker) }
        let settleMayRun = LifecycleEntryHarness.Gate()   // the reinsert's settle (and its own reset) starts only when told
        defer { settleMayRun.open() }
        rig.controller.testReinsertSettleHold = { await settleMayRun.wait() }

        let undo = rig.startPress(queued.deleted.entry)
        #expect(await rig.awaitRuns([undo]))
        rig.release(queued.blocker)   // the delete's write applies and commits now: after the undo's reset
        let applied = await gateWaitUntil({ rig.footnotes.state == .idle && rig.editorState.pendingReinsertCount == 0 })
        #expect(applied, "precondition: the late write has committed and the reinsert has applied")
        let redo = rig.startPress(queued.deleted.entry, .redo)
        #expect(await rig.awaitRuns([redo]))

        // The reinsert's settle is still held: only the redo's own reset can have let its resync perform.
        let original = queued.original
        let cleaned = await gateWaitUntil({ ((try? self.notesProblem(rig, original: original)) ?? "unreadable").isEmpty }, iterations: 800)
        let problem = (try? notesProblem(rig, original: original)) ?? "unreadable"
        #expect(cleaned, "expected the redo's resync to clean the Notes while the reinsert's settle was held: \(problem)")

        settleMayRun.open()
        #expect(await rig.waitUntilSettled(iterations: 2000))
        let final = try notesProblem(rig, original: original)
        #expect(final.isEmpty, "expected the Notes cleaned and renumbered at the end: \(final)")
    }

    // MARK: - U-Q32d: the C5 fallback

    @Test("U-Q32d (VM bug): the C5 fallback rewrote the Notes from the editor: the next resync with the same references still performs")
    func testReinsertFallbackThenRedoRenumbersAndCleansNotes_book6() async throws {
        let rig = try makeFootnotedBookRig()
        let original = try rig.assembledMarkdown()
        let deleted = try await delete(rig, Self.thirdChapter)
        let afterDeleteText = try rig.assembledMarkdown()
        let remainingRefs = FootnoteSyncService.extractFootnoteRefs(from: afterDeleteText)   // 1...18 and 28...54
        #expect(remainingRefs.count == 45, "precondition: the delete left 45 references")
        // A footnote write commits while the fallback's flush is in flight (the delete's own resync write can land there): the committed
        // state then describes the post-delete Notes again, just before the flush rewrites them from the editor's text.
        let lateCommit = GateOrderLog()
        rig.getContentHold = { [weak rig] in
            guard let rig, lateCommit.items.isEmpty else { return }
            lateCommit.note("late commit")
            await rig.footnotes.resyncNow(footnoteRefs: remainingRefs, projectId: rig.pid, fullContent: afterDeleteText)
        }
        let blocker = try rig.holdQueue()
        defer { rig.release(blocker) }

        let undo = rig.startPress(deleted.entry)
        #expect(await rig.awaitRuns([undo]))
        rig.sync.testWriterHandle?.skipAllReserved(reason: .drainTimeout)   // the reinsert is refused and no lifecycle is armed: C5
        rig.release(blocker)
        let flushed = await gateWaitUntil({
            rig.controller.efSlots.slot(deleted.entry.id)?.state == .fallback && rig.editorState.liveFlushRunning == 0
                && !lateCommit.items.isEmpty && rig.footnotes.state == .idle
        }, iterations: 2000)
        #expect(flushed, "precondition: the reinsert fell back, the flush ended, and a footnote write committed meanwhile")
        let definitions = Self.definitionTexts(in: try rig.assembledMarkdown()).count
        #expect(definitions == 54, "precondition: the flush wrote the editor's 54 definitions over the Notes (got \(definitions))")

        await rig.footnotes.resyncNow(footnoteRefs: remainingRefs, projectId: rig.pid, fullContent: afterDeleteText)

        let problem = try notesProblem(rig, original: original)
        #expect(problem.isEmpty, "expected the resync after the fallback to clean and renumber the Notes: \(problem)")
    }

    // MARK: - U-Q48: the Bibliography

    @Test("U-Q48 (VM bug): a redo straight after the undo removes the deleted chapter's only citation from the Bibliography (book6 id)")
    func testRedoAfterQuickUndoRemovesTheDeletedChaptersCitationFromTheBibliography_book6() async throws {
        let alpha = #"{"id":"u48alpha2026","type":"book","title":"U48 Alpha","#
            + #""author":[{"family":"Alphaquill","given":"Ann"}],"issued":{"date-parts":[[2020]]}}"#
        let beta = #"{"id":"u48beta2026","type":"book","title":"U48 Beta","#
            + #""author":[{"family":"Betaquill","given":"Bob"}],"issued":{"date-parts":[[2021]]}}"#
        ZoteroService.shared.isConnected = true
        ZoteroService.shared.loadItem(try JSONDecoder().decode(CSLItem.self, from: Data(alpha.utf8)))
        ZoteroService.shared.loadItem(try JSONDecoder().decode(CSLItem.self, from: Data(beta.utf8)))
        defer {
            ZoteroService.shared.isConnected = false
            ZoteroService.shared.clearCache()
        }
        let rig = try EditorFirstRig(
            markdown: "# One\n\nFirst chapter cites [@u48alpha2026].\n\n# Two\n\nSecond chapter cites [@u48beta2026].\n", lifecycleServices: true)
        rig.controller.testEFSettleHold = { [weak rig] in _ = try? rig?.syncEditorContentFromDatabase() }
        await rig.bibliography.resyncNow(citekeys: ["u48alpha2026", "u48beta2026"], projectId: rig.pid)
        try rig.syncEditorContentFromDatabase()
        func bibliography() throws -> String {
            try rig.blocks().filter { $0.isBibliography && $0.blockType != .heading }.map(\.markdownFragment).joined(separator: "\n")
        }
        let written = try bibliography()
        #expect(written.contains("Alphaquill") && written.contains("Betaquill"), "precondition: the Bibliography lists both entries")

        let deleted = try await delete(rig, "Two")
        let afterDelete = try bibliography()
        let droppedSecond = afterDelete.contains("Alphaquill") && !afterDelete.contains("Betaquill")
        #expect(droppedSecond, "precondition: the delete's resync dropped the second entry")
        let reinsertMayRun = DispatchSemaphore(value: 0)
        defer { reinsertMayRun.signal() }
        rig.controller.testReinsertBodyHold = { reinsertMayRun.wait() }

        let undo = rig.startPress(deleted.entry)
        let redo = rig.startPress(deleted.entry, .redo)
        #expect(await rig.awaitRuns([undo, redo]), "both presses ended")
        reinsertMayRun.signal()
        #expect(await rig.waitUntilSettled(iterations: 2000))

        let final = try bibliography()
        #expect(
            final.contains("Alphaquill") && !final.contains("Betaquill"),
            "expected the Bibliography without the deleted chapter's entry after the redo, got the pre-delete Bibliography")
    }
}
