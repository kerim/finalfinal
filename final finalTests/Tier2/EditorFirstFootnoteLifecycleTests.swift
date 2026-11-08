//
//  EditorFirstFootnoteLifecycleTests.swift
//  final finalTests
//
//  Tier 2 (t-94369a83 Phase 4b slice 2a, fix round 4): the VM end-to-end test `testQuitRightAfterDeleteNumbering_book6`. On a
//  book with footnotes, delete a chapter that has footnote references and close or quit within a second or two: the saved book kept
//  the deleted chapter's footnote definitions in its Notes (45 references, 54 definitions, labels 19 to 27 twice), and reopening
//  never repaired it.
//
//  The mechanism, in the order it happens:
//    1. the delete's job ends (its rows are gone); the work after it (`resyncAfterEditorFirstDelete`: the footnote resync, which
//       renumbers the references in the EDITOR from 28-54 to 19-45 but cannot take the deleted chapter's definitions out of the
//       editor's Notes) has not run yet;
//    2. the close or quit starts and waits for "the delete", which used to mean only its job;
//    3. the editor's Notes are half updated, and the Notes rebuild that would put the database's right ones into the editor is
//       held back while the lifecycle is armed;
//    4. the lifecycle's whole-document save writes the editor's half-updated Notes over the database's correct ones.
//
//  The fix has three parts, each with its own test below: the lifecycle (and everything else that waits for a delete) waits for the
//  delete's follow-up work as well as its job; that follow-up work ends, while a lifecycle holds the editor, by pushing the
//  database's Notes and Bibliography into the editor; and the shared wait zoom, the switch to Markdown, Save Version and export use
//  covers the same follow-up work.
//
//  The rig models the editor with `EditorFirstRig.editorText` (what a merge-guarded push replaces) and holds the follow-up work open
//  with `StructuralUndoController.testEFSettleHold`, so the order above is exactly the order the tests run in.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import Testing
@testable import final_final

@Suite("Delete a chapter with footnotes, then close or quit — Phase 4b slice 2a fix round 4 (Tier 2)", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct EditorFirstFootnoteLifecycleTests {

    // MARK: - Fixture and helpers

    /// book6 with the third chapter's nine definitions (labels 19 to 27) made recognisable: the fixture repeats the same prose in
    /// every chapter, so without a marker a leftover definition could not be told from a right one by its text.
    static let markedBook6: String = {
        var text = ComplexDocumentFixture.book6.editorMarkdown
        for label in 19...27 {
            text = text.replacingOccurrences(of: "\n[^\(label)]: ", with: "\n[^\(label)]: GONE-\(label) ")
        }
        return text
    }()

    /// The footnote references (in document order) and the labels of the Notes definitions (as written) of `markdown`.
    static func footnoteLabels(in markdown: String) -> (references: [String], definitions: [String]) {
        let references = FootnoteSyncService.extractFootnoteRefs(from: markdown)
        guard let regex = try? NSRegularExpression(pattern: #"(?m)^\[\^(\d+)\]:"#) else { return (references, []) }
        let whole = NSRange(markdown.startIndex..., in: markdown)
        let definitions = regex.matches(in: markdown, range: whole).compactMap { match -> String? in
            Range(match.range(at: 1), in: markdown).map { String(markdown[$0]) }
        }
        return (references, definitions)
    }

    /// What the Rich Text editor shows after the footnote renumber: the references renamed to 1...n in document order, and every
    /// definition carrying one of the renamed labels renamed with it. The deleted chapter's own definitions (labels 19 to 27) are
    /// not in the map, so they stay, and labels 19 to 27 then appear twice: the state the VM run found.
    static func renumbered(_ markdown: String) -> String {
        applyRenumbering(markdown, mapping: renumberMapping(for: markdown))
    }

    /// The old-label to new-label map the footnote renumber computes for `markdown`: the references numbered 1...n in document order.
    static func renumberMapping(for markdown: String) -> [String: String] {
        let references = FootnoteSyncService.extractFootnoteRefs(from: markdown)
        var mapping: [String: String] = [:]
        for (index, label) in references.enumerated() where label != String(index + 1) { mapping[label] = String(index + 1) }
        return mapping
    }

    /// Renames every `[^label]` in `text` (a reference or a definition) that `mapping` names, in one pass.
    static func applyRenumbering(_ text: String, mapping: [String: String]) -> String {
        guard !mapping.isEmpty, let regex = try? NSRegularExpression(pattern: #"\[\^(\d+)\]"#) else { return text }
        let result = NSMutableString(string: text)
        let whole = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: whole).reversed() {
            guard let labelRange = Range(match.range(at: 1), in: text), let renamed = mapping[String(text[labelRange])] else { continue }
            result.replaceCharacters(in: match.range(at: 1), with: renamed)
        }
        return result as String
    }

    static func numeric(_ lhs: String, _ rhs: String) -> Bool { (Int(lhs) ?? 0) < (Int(rhs) ?? 0) }

    /// The state both tests start from: the third chapter (references 19 to 27) is deleted, its job has ended and its rows are gone,
    /// and the follow-up work (the footnote resync) is held before it has run. The editor holds what it would hold by now: the
    /// chapter gone and the references renumbered, but the Notes half updated (the deleted chapter's definitions still in them).
    private struct DeleteInProgress {
        let rig: EditorFirstRig
        /// Opens the hold: the follow-up work runs.
        let settleMayRun: LifecycleEntryHarness.Gate
    }

    private func deleteThirdChapterAndHoldTheFollowUp() async throws -> DeleteInProgress {
        #expect(Self.markedBook6.contains("GONE-19"), "the fixture's third chapter definitions carry the marker")
        let rig = try EditorFirstRig(markdown: Self.markedBook6, lifecycleServices: true)
        rig.js.answer("flushPendingBlockChanges", true)
        rig.fetchAnswerProvider = { [unowned rig] in rig.editorText }
        let before = Self.footnoteLabels(in: try rig.assembledMarkdown())
        #expect(before.references.count == 54, "six chapters with nine footnote references each: \(before.references.count)")
        #expect(before.definitions.count == 54, "and nine definitions each: \(before.definitions.count)")

        let chapter = try #require(try rig.chapterHeadings().dropFirst(2).first)
        try rig.setReply(.init(removedLeaderIds: [chapter.id]))
        let settleMayRun = LifecycleEntryHarness.Gate()
        let held = GateOrderLog()
        rig.controller.testEFSettleHold = {
            held.note("held")
            await settleMayRun.wait()
        }
        let outcome = await rig.controller.performSectionDelete(rootId: chapter.id)
        #expect(outcome == .performed)
        let reached = await gateWaitUntil({ held.items == ["held"] }, iterations: 4000)
        #expect(reached, "the delete's job must have ended and its follow-up work be held: \(held.items)")

        // The editor, as it is by now: the chapter removed (the rows say the same) and the references renumbered by the footnote
        // renumber, with the Notes half updated. `content` is what the follow-up work reads.
        let afterJob = try rig.assembledMarkdown()
        let afterJobLabels = Self.footnoteLabels(in: afterJob)
        #expect(afterJobLabels.references.count == 45, "nine references went with the chapter: \(afterJobLabels.references.count)")
        #expect(afterJobLabels.definitions.count == 54, "the Notes have not been cleaned yet: \(afterJobLabels.definitions.count)")
        rig.editorState.content = afterJob
        rig.editorText = Self.renumbered(afterJob)
        let editor = Self.footnoteLabels(in: rig.editorText ?? "")
        #expect(editor.references.count == 45 && editor.definitions.count == 54, "precondition: the editor's Notes are half updated")
        #expect(Set(editor.definitions).count == 45, "with labels 19 to 27 twice: \(Set(editor.definitions).count) distinct labels")
        return DeleteInProgress(rig: rig, settleMayRun: settleMayRun)
    }

    /// The Notes of the stored document: one definition for every reference, labels 1...n, no label twice, nothing of the deleted
    /// chapter's definitions left.
    private func expectNotesMatchTheReferences(_ rig: EditorFirstRig, _ context: String) throws {
        let final = try rig.assembledMarkdown()
        let notes = Self.footnoteLabels(in: final)
        let wanted = (1...45).map(String.init)
        #expect(
            notes.references.sorted(by: Self.numeric) == wanted,
            "\(context): the references are 1 to 45: \(notes.references.count) references")
        let counts = "\(notes.definitions.count) definitions for \(notes.references.count) references"
        #expect(
            notes.definitions.sorted(by: Self.numeric) == wanted,
            "\(context): the Notes hold exactly one definition for each reference: \(counts), \(Set(notes.definitions).count) labels")
        #expect(!final.contains("GONE-"), "\(context): the deleted chapter's definitions are not in the stored document")
    }

    // MARK: - Close and quit

    private func closeOrQuitDuringTheFollowUp(_ kind: LifecycleKind) async throws {
        let setup = try await deleteThirdChapterAndHoldTheFollowUp()
        let rig = setup.rig
        let finished = GateOrderLog()
        let lifecycle = Task { @MainActor in
            let result = await rig.runLifecycle(kind, bounds: .production)
            finished.note("lifecycle done")
            return result
        }
        let armed = await gateWaitUntil { rig.editorState.structuralGate.isClosedToNewWork }
        #expect(armed, "the \(kind) must have reached its step 1")
        // Step 0 suspended the footnote service BEFORE the delete's follow-up work ran: that work must still write.
        #expect(rig.footnotes.isSuspendedForLifecycle, "step 0 suspended the footnote service")
        try await Task.sleep(for: .milliseconds(200))
        // Fix part 1: the lifecycle waits for the follow-up work, not only for the job (which ended long ago).
        #expect(finished.items.isEmpty, "the \(kind) must wait for the delete's follow-up work, not only for its job: \(finished.items)")

        setup.settleMayRun.open()
        let result = await lifecycle.value

        #expect(result.outcome == .flushed, "the \(kind) completed: \(result.outcome)")
        #expect(!result.opStillRunning, "the follow-up work ended inside the wait")
        // Fix part 2: the follow-up work pushed the database's Notes and Bibliography into the editor before the save captured it.
        #expect(
            rig.pushes.contains { $0.preserveUserBlocks },
            "the database's Notes must have been pushed into the editor before the save: \(rig.pushes.count) pushes")
        try expectNotesMatchTheReferences(rig, "after the \(kind)")
        #expect(rig.editorState.efJobRegistry.unsettledCount == 0, "nothing of the delete is left unfinished")
    }

    @Test("Delete a chapter with footnotes, then close: the follow-up work finishes first and the saved Notes match the references")
    func testCloseDuringTheDeleteFollowUpLeavesTheNotesRight_book6() async throws {
        try await closeOrQuitDuringTheFollowUp(.close)
    }

    @Test("Delete a chapter with footnotes, then quit: the follow-up work finishes first and the saved Notes match the references")
    func testQuitDuringTheDeleteFollowUpLeavesTheNotesRight_book6() async throws {
        try await closeOrQuitDuringTheFollowUp(.quit)
    }

    // MARK: - Zoom, the switch to Markdown, Save Version and export

    @Test("The wait zoom, the switch to Markdown, Save Version and export share ends only after the delete's follow-up work: the Notes are clean")
    func testSharedWaitCoversTheDeleteFollowUp_book6() async throws {
        let setup = try await deleteThirdChapterAndHoldTheFollowUp()
        let rig = setup.rig
        let order = GateOrderLog()
        let waiting = Task { @MainActor in
            await rig.editorState.awaitPendingStructuralJobs()
            let notes = Self.footnoteLabels(in: (try? rig.assembledMarkdown()) ?? "")
            order.note("wait ended: \(notes.definitions.count) definitions for \(notes.references.count) references")
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(order.items.isEmpty, "the wait must still be waiting for the follow-up work (the job ended long ago): \(order.items)")

        setup.settleMayRun.open()
        await waiting.value

        #expect(
            order.items == ["wait ended: 45 definitions for 45 references"],
            "the Notes are clean by the time the wait ends, so the flush that follows cannot write half-updated ones: \(order.items)")
        let final = try rig.assembledMarkdown()
        #expect(!final.contains("GONE-"), "the deleted chapter's definitions are gone from the stored document")
        #expect(rig.editorState.efJobRegistry.unsettledCount == 0)
    }
}
