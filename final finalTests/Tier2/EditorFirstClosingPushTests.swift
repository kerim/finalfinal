//
//  EditorFirstClosingPushTests.swift
//  final finalTests
//
//  Tier 2 (t-94369a83 Phase 4b slice 2a, fix round 6): the VM end-to-end test `testQuitRightAfterDeleteNumbering_book6`, the bug
//  that round 4's fix introduced. On a six-chapter book with 54 footnotes, delete a chapter that holds nine of them and quit within
//  a couple of seconds: the saved book had 45 references still on their ORIGINAL numbers (up to 54), 45 definitions on those same
//  numbers and definitions 46 to 54 blank, so the notes' texts sat on the wrong numbers.
//
//  The mechanism: the delete's footnote resync renumbers the references IN THE EDITOR (28-54 become 19-45) with the content push
//  suppressed, so the renumber is an UNSENT edit to the editor's own blocks that only a poll carries to the database; lifecycle
//  step 0 has already stopped the routine poll. Round 4's closing push (`pushManagedRegionsWhileClosing`) then read the whole
//  document from the DATABASE (old reference numbers, already-renumbered Notes), assigned it to `editorState.content` without
//  `isResettingContent` (so the view pushed that stale text into the editor while the merge push was awaited), and the whole-document
//  save wrote the old numbers back; step 7 reconciled the Notes against them and blanked the rest.
//
//  The fix does what the normal Notes rebuild does, in its order: the ORDERED forced poll first (the editor's pending changes reach
//  the database), then the database read, with `isResettingContent` set from the `content` assignment until the merge push returns.
//
//  The rig models the editor with `EditorFirstRig.editorText` and the view's push of `content` with `modelsViewPushOfContent`
//  (`content` reaches the editor when a merge push runs while `isResettingContent` is false). The unsent edits are what the editor's
//  `getBlockChanges` answers, exactly the batch a poll would carry.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import Testing
@testable import final_final

@Suite("The closing push carries the editor's unsent edits first — Phase 4b slice 2a fix round 6 (Tier 2)", .serialized, .timeLimit(.minutes(5)))
@MainActor
struct EditorFirstClosingPushTests {

    private static let typedAnchor = "Anchor01 line of the fixture document."
    private static let typedMarker = " TYPED-CLOSING-PUSH"

    private struct Scenario {
        let rig: EditorFirstRig
        /// Opens the hold on the delete's follow-up work: the footnote resync and the closing push run.
        let settleMayRun: LifecycleEntryHarness.Gate
    }

    /// book6 with footnotes, the third chapter (references 19 to 27) deleted, its job ended and the follow-up work held. The editor
    /// holds what it holds by then and has not yet sent: with `renumber`, the references renumbered 1 to 45 (and the Notes it
    /// renumbered half-way); with `typing`, a sentence typed in the first chapter. A poll would carry exactly those edits.
    ///
    /// `contentEchoesTyping`: `editorState.content` (the mirror the editor's own echo keeps) already holds the typed sentence, as it
    /// does after the editor's 50 ms push. `fetchFails`: the save's fetch of the editor's live text gets no answer, so it falls back to
    /// `editorState.content`. `wedgePoll`: the page does not answer the closing push's `flushReports`, so its flush does not complete.
    private func setUp(
        renumber: Bool, typing: Bool, contentEchoesTyping: Bool = false, fetchFails: Bool = false, wedgePoll: Bool = false
    ) async throws -> Scenario {
        let rig = try EditorFirstRig(markdown: EditorFirstFootnoteLifecycleTests.markedBook6, lifecycleServices: true)
        rig.modelsViewPushOfContent = true
        rig.js.answer("flushPendingBlockChanges", true)
        rig.fetchAnswerProvider = { [unowned rig] in rig.editorText }
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

        // The editor's document by now. The database still holds the old numbers in the user blocks.
        let afterJob = try rig.assembledMarkdown()
        rig.editorState.content = afterJob
        let mapping = EditorFirstFootnoteLifecycleTests.renumberMapping(for: afterJob)
        var editorText = renumber ? EditorFirstFootnoteLifecycleTests.applyRenumbering(afterJob, mapping: mapping) : afterJob
        if typing {
            editorText = editorText.replacingOccurrences(of: Self.typedAnchor, with: Self.typedAnchor + Self.typedMarker)
        }
        rig.editorText = editorText

        // The batch the page would report: the user blocks the editor changed.
        var updates: [BlockUpdate] = []
        for block in try rig.blocks() where !block.isNotes && !block.isBibliography {
            var text = renumber ? EditorFirstFootnoteLifecycleTests.applyRenumbering(block.textContent, mapping: mapping) : block.textContent
            var fragment = renumber
                ? EditorFirstFootnoteLifecycleTests.applyRenumbering(block.markdownFragment, mapping: mapping) : block.markdownFragment
            if typing, block.textContent == Self.typedAnchor {
                text += Self.typedMarker
                fragment += Self.typedMarker
            }
            if text != block.textContent || fragment != block.markdownFragment {
                updates.append(BlockUpdate(id: block.id, textContent: text, markdownFragment: fragment, headingLevel: nil))
            }
        }
        #expect(!updates.isEmpty, "the editor has unsent edits")
        rig.typingQueue.append(BlockChanges(updates: updates))   // the page reports them when Swift asks (`flushReports`)
        if contentEchoesTyping { rig.editorState.content = editorText }
        if fetchFails { rig.fetchAnswerProvider = { nil } }
        if wedgePoll {
            rig.sync.testRebuildFlushBound = 0.3
            rig.wedgeNextFlushReports = true
        }
        return Scenario(rig: rig, settleMayRun: settleMayRun)
    }

    private func closeAndRunTheFollowUp(_ scenario: Scenario) async -> LifecycleFlushResult {
        let rig = scenario.rig
        let lifecycle = Task { @MainActor in await rig.runLifecycle(.close, bounds: .production) }
        let armed = await gateWaitUntil { rig.editorState.structuralGate.isClosedToNewWork }
        #expect(armed, "the close must have reached its step 1")
        scenario.settleMayRun.open()
        return await lifecycle.value
    }

    // MARK: - The unsent renumber

    @Test("The closing push carries the editor's unsent renumber to the database before it reads it: the saved references and Notes match (book6)")
    func testClosingPushKeepsTheUnsentRenumber_book6() async throws {
        let scenario = try await setUp(renumber: true, typing: false)
        let rig = scenario.rig

        let result = await closeAndRunTheFollowUp(scenario)

        #expect(result.outcome == .flushed, "the close completed: \(result.outcome)")
        // The push read a database that already carried the editor's renumber, and ran with the view kept from pushing `content`.
        let closing = try #require(rig.pushes.first { $0.preserveUserBlocks }, "the follow-up work must push the database's Notes into the editor")
        let pushed = EditorFirstFootnoteLifecycleTests.footnoteLabels(in: closing.markdown)
        let wanted = (1...45).map(String.init)
        #expect(
            pushed.references.sorted(by: EditorFirstFootnoteLifecycleTests.numeric) == wanted,
            "the closing push must read references already renumbered 1 to 45, got \(pushed.references.count) references: \(pushed.references)")
        #expect(closing.isResettingContent, "the view must not push `content` while the merge push is awaited (isResettingContent)")
        #expect(!rig.editorState.isResettingContent, "and the flag is released when the push has returned")

        // What the whole-document save wrote: references 1 to 45, one definition per reference, no blank and no shifted note.
        let stored = try rig.assembledMarkdown()
        let notes = EditorFirstFootnoteLifecycleTests.footnoteLabels(in: stored)
        #expect(notes.references.sorted(by: EditorFirstFootnoteLifecycleTests.numeric) == wanted, "stored references: \(notes.references)")
        #expect(
            notes.definitions.sorted(by: EditorFirstFootnoteLifecycleTests.numeric) == wanted,
            "the Notes hold one definition for each reference: \(notes.definitions.count) definitions, labels \(notes.definitions)")
        #expect(!stored.contains("GONE-"), "none of the deleted chapter's notes is left, on any number")
        // No blank definition: every definition line has text after its label.
        let blank = stored.components(separatedBy: "\n").filter { $0.range(of: #"^\[\^\d+\]:\s*$"#, options: .regularExpression) != nil }
        #expect(blank.isEmpty, "no definition is blank: \(blank)")
    }

    // MARK: - Typing the poll has not carried yet

    @Test("The closing push does not revert typing the poll has not carried yet: it reaches the database first and is saved")
    func testClosingPushKeepsPendingTyping_book6() async throws {
        let scenario = try await setUp(renumber: true, typing: true)
        let rig = scenario.rig

        let result = await closeAndRunTheFollowUp(scenario)

        #expect(result.outcome == .flushed, "the close completed: \(result.outcome)")
        let closing = try #require(rig.pushes.first { $0.preserveUserBlocks })
        let typed = Self.typedMarker.trimmingCharacters(in: .whitespaces)
        #expect(closing.markdown.contains(typed), "the closing push read the typing: the poll carried it first")
        let stored = try rig.assembledMarkdown()
        #expect(stored.contains(Self.typedAnchor + Self.typedMarker), "the typed sentence is in the saved document")
        let notes = EditorFirstFootnoteLifecycleTests.footnoteLabels(in: stored)
        #expect(
            notes.definitions.sorted(by: EditorFirstFootnoteLifecycleTests.numeric) == (1...45).map(String.init),
            "and the Notes still match the references: \(notes.definitions.count) definitions")
    }

    // MARK: - F6: the forced poll did not complete

    @Test("F6: when the forced poll does not complete, the closing push does nothing and the save falls back to content with the typing")
    func testClosingPushIsSkippedWhenThePollDidNotComplete_book6() async throws {
        // The editor holds typing that is not in the database yet (the poll is wedged, so it cannot carry it); `content` has it (the
        // editor's echo), and the save's fetch fails, so the save falls back to `content`. Reading the database after a poll that did
        // not complete would hand `content` an OLDER document and the save would write that.
        let scenario = try await setUp(renumber: false, typing: true, contentEchoesTyping: true, fetchFails: true, wedgePoll: true)
        let rig = scenario.rig
        defer { rig.js.releaseWedge() }

        _ = await closeAndRunTheFollowUp(scenario)

        #expect(
            !rig.pushes.contains { $0.preserveUserBlocks },
            "no closing push may be made after a poll that did not complete: \(rig.pushes.count) pushes")
        #expect(!rig.editorState.isResettingContent, "and nothing is left set")
        let stored = try rig.assembledMarkdown()
        #expect(stored.contains(Self.typedAnchor + Self.typedMarker), "the typed sentence is in the saved document (written from `content`)")
    }

    @Test("F6: when the save cannot fetch the editor's text it falls back to content, which the closing push left as the renumbered text")
    func testSaveFallsBackToTheRenumberedContent_book6() async throws {
        let scenario = try await setUp(renumber: true, typing: false, fetchFails: true)
        let rig = scenario.rig

        let result = await closeAndRunTheFollowUp(scenario)

        #expect(result.usedFallback, "the save's fetch gave no answer, so it used the content on hand")
        let stored = try rig.assembledMarkdown()
        let notes = EditorFirstFootnoteLifecycleTests.footnoteLabels(in: stored)
        let wanted = (1...45).map(String.init)
        #expect(notes.references.sorted(by: EditorFirstFootnoteLifecycleTests.numeric) == wanted, "stored references: \(notes.references)")
        #expect(
            notes.definitions.sorted(by: EditorFirstFootnoteLifecycleTests.numeric) == wanted,
            "the Notes match: \(notes.definitions.count) definitions, labels \(notes.definitions)")
    }
}
