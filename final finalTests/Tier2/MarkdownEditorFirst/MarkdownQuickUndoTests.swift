//
//  MarkdownQuickUndoTests.swift
//  final finalTests
//
//  t-4a8fd8af (Markdown-mode structural commands go editor-first), slice 1, round 7a: the QUICK Cmd-Z and Cmd-Shift-Z of a Markdown
//  Delete Section (StructuralUndoController+MarkdownQuickUndo.swift), against the REAL CodeMirror page, a real database and the real
//  writer (`MarkdownClickRig` with `routesUndo`: a real keydown reaches the controller through the real coordinator and
//  `routeStructuralRequest`, as in the app). The switch is on in every rig. Typing in these tests is USER-origin (`userTypes`, an
//  `insertAtCursor` transaction), never `setContent`, which the page treats as the application's own push. Needs `cd web && pnpm build`.
//  NOT RUN by the coder.
//
//  Break patches (a 1-5 line change in production code that must make the test fail), and the failure each shows:
//
//   T-2    a Markdown entry is quick-undoable only in Markdown mode, a Rich Text entry (no kind) only in Rich Text mode, both under the
//          structural-generation rule.
//          BREAK: in `quickPathPossible` (StructuralUndoController+QuickUndo.swift) put `.wysiwyg` back for the mode condition.
//          FAILS: "markdown entry refused".
//   T-U6   type, Delete, then Cmd-Z, Cmd-Shift-Z, Cmd-Z through real keys: the text is pre, post, pre; no notice; no hold left.
//          BREAK: in `sendMarkdownSwap` (StructuralUndoController+MarkdownQuickUndo.swift) pass `UUID()` as the opId.
//          FAILS: "Cmd-Z did not restore the text from before the Delete" (the page answers noEntry, the notice shows). The web twin of
//          this break, "do not pass ownRequestOpId in the swap's `decideLiveRouting` call" (api-structural-markdown.ts), shows the same
//          notice: "Some undo or redo presses could not be carried out." (a web edit; not made here).
//   T-U7   Delete, Cmd-Z, Cmd-Shift-Z, Cmd-Z, Cmd-Shift-Z: the entry survives two full cycles; the rows match the editor at the end.
//          BREAK (web): omit the `midOp` bracketing in `markdownStructuralSwap`. FAILS: "postOpDoc advanced to preOpDoc" (the second
//          cycle's Cmd-Z is not structural).
//          BREAK (Swift): in `markdownQuickRedo` delete the `performRedo(opId: opId)` guard's call. FAILS: "the second Cmd-Z was not structural".
//   T-U8   type inside chapter 3, Delete it, Cmd-Z, Cmd-Z: the second press removes the typing.
//          BREAK (web): swap with a minimal diff to `preOpDoc` instead of `setState(checkpoint)`.
//          FAILS: "typing still present after second Cmd-Z".
//   T-U21  Delete, type, Cmd-Z x2, Cmd-Shift-Z x2: the typing comes back (it passed as a pin on unmodified code).
//          BREAK (web): `buildSwappedState` returns the plain checkpoint (no redo carry). FAILS: "typing not restored by redo".
//   T-U10  (Cmd-Z half) a footnoted chapter with a bibliography after it: after Delete and Cmd-Z the footnote texts are in the editor and
//          the rows, each label once, in order, the bibliography unchanged.
//          BREAK: in `SectionReinsertJob.run` return `SystemWriteBody(value: Output())` right after `bodyHold?()`.
//          FAILS: "Notes row ids changed" (the step-8 flush heals the TEXT, so a missing reinsert shows in the row ids, status and tags).
//   rows   after a quick undo the rows equal the pre-delete rows: ids, text, status, tags, word goal (SectionReinsertJob restores them).
//          BREAK: the same.   FAILS: "rows differ from the pre-delete rows".
//   wait   typing made while the reinsert waits is kept and saved after the release (the T-U2 analogue for the undo).
//          BREAK: in `markdownQuickUndo` delete the `startMarkdownHoldContinuation(...)` line.   FAILS: "mm6 not saved after the release".
//          BREAK 2: in `startMarkdownHoldContinuation` wait on the registry again (`Self.awaitJobOutcomeOrCancellation(registry: registry,
//          opId: key)`) instead of the gate's `jobEnded`: typing after the undo drops the redo branch, the entry's job records are
//          forgotten and the continuation wakes while the reinsert is still queued.
//          FAILS: "the hold was released when the redo branch was dropped".
//   held   Cmd-Z pressed at once after a Delete whose job is still held waits for the job's apply and is never refused.
//          BREAK: in `resolveMarkdownQuickPath` delete the `awaitStructuralHoldReleased()` line AND the `holder.outcome == .applied`
//          condition.   FAILS: "the undo ran before the delete's job applied".
//   kind   typing after a quick undo drops the redo branch, and the entry's editor kind goes with the rest of its state.
//          BREAK: in `forgetQuickUndoState` delete the `efEditorKind[opId] = nil` line.   FAILS: "the entry kind was kept".
//
//  The refused swap, the quick redo whose timeline was cleared mid-press and the two Deletes back to back live in
//  MarkdownQuickUndoTests+Refusals.swift (an extension of this class, to keep this type's body short).
//
//  Only the VM can show: the felt speed of the quick undo on a book (the 12-chapter measurements), a Cmd-Z in the real window with
//  focus, and the Notes rebuild handlers' own pushes during a quick undo (ContentView; T-U24/T-U28 territory).
//

import Foundation
import XCTest
@testable import final_final

@MainActor
final class MarkdownQuickUndoTests: XCTestCase {

    var rig: MarkdownClickRig!

    override func tearDown() async throws {
        rig?.controller.testReinsertBodyHold = nil
        rig?.restore()
        rig = nil
        try await super.tearDown()
    }

    static let book4 =
        "# Chapter 1\n\nFirst chapter text.\n\n# Chapter 2\n\nSecond chapter text.\n\n# Chapter 3\n\nThird chapter text.\n\n"
        + "# Chapter 4\n\nFourth chapter text."

    private static let footnotedRecord =
        "# Chapter 1\n\nFirst chapter text.[^1]\n\n# Chapter 2\n\nSecond chapter text.[^2]\n\n# Chapter 3\n\nThird chapter text.[^3][^4]\n\n"
        + "## Notes\n\n[^1]: Note one.\n\n[^2]: Note two.\n\n[^3]: Note three.\n\n[^4]: Note four.\n\n"
        + "# Bibliography\n\nSmith, J. (2020). A book.\n\nJones, K. (2021). Another.\n\n<!-- ::auto-bibliography-end:: -->"
    private static let glueMarker = "<!-- ::auto-bibliography:: -->"
    static let droppedNotice = "Some undo or redo presses could not be carried out."
    static let footnotedBook4 =
        "# Chapter 1\n\nFirst chapter text.[^1]\n\n# Chapter 2\n\nSecond chapter text.[^2]\n\n# Chapter 3\n\nThird chapter text.[^3]\n\n"
        + "# Chapter 4\n\nFourth chapter text.[^4]\n\n## Notes\n\n[^1]: Note one.\n\n[^2]: Note two.\n\n[^3]: Note three.\n\n[^4]: Note four."

    func startRig(_ markdown: String) async throws {
        rig = try await MarkdownClickRig(markdown: markdown, observesPage: true, routesUndo: true)
    }

    /// Delete Section on `title` through the click, then everything it started has finished. Returns the page before and after.
    func deleteSection(_ title: String) async throws -> (pre: String, post: String) {
        let root = try rig.section(title)
        let pre = try await rig.pageText()
        let outcome = await rig.controller.performSectionDelete(rootId: root.id)
        XCTAssertEqual(outcome, .performed)
        await rig.settleEverything()
        return (pre, try await rig.pageText())
    }

    /// A real keydown; waits until the page's text satisfies `condition`, then until the structural gate and everything the press started
    /// have finished.
    @discardableResult @nonobjc   // internal on an XCTestCase: without `@nonobjc` its async ObjC thunk would capture the non-escaping closure
    func press(_ direction: String, until condition: (String) -> Bool, _ message: String) async throws -> String {
        try await rig.press(direction)
        let text = try await rig.waitForPage(condition)
        XCTAssertTrue(condition(text), message)
        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isIdle }
        await rig.settleEverything()
        return text
    }

    func assertQuiet(_ context: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(rig.editorState.toastCenter.current, "a notice or progress toast is showing \(context)", file: file, line: line)
        XCTAssertEqual(rig.toastLog.lines, [], "a notice was shown \(context)", file: file, line: line)
        XCTAssertFalse(rig.markdownWriter.isHeldForStructuralWork, "the writer is still held \(context)", file: file, line: line)
        XCTAssertEqual(rig.editorState.pendingReinsertCount, 0, "a reinsert is still pending \(context)", file: file, line: line)
        XCTAssertEqual(rig.editorState.pendingEditorFirstJobs, 0, "an editor-first job is still pending \(context)", file: file, line: line)
    }

    /// The non-empty lines of a document, in order: what must agree between the rows and the editor.
    func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func assertRowsMatchPage(_ context: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let page = MarkdownLeaderMap.recordText(fromRaw: try await rig.pageText())
        XCTAssertEqual(lines(try rig.writerRig.storedText()), lines(page), "the rows differ from the editor \(context)", file: file, line: line)
    }

    // MARK: - T-2

    func testQuickPathEligibilityFollowsTheEntrysEditorAndTheGenerationRule() async throws {
        try await startRig(Self.book4)
        _ = try await deleteSection("Chapter 3")
        let entry = try XCTUnwrap(rig.unifiedUndo.undoStack.last)
        let controller = rig.controller
        let editorState = rig.editorState
        XCTAssertEqual(controller.efEditorKind[entry.id], .markdown, "premise: the click recorded a Markdown entry")

        XCTAssertTrue(controller.quickUndoEligible(entry), "markdown entry refused")   // Markdown mode
        editorState.editorMode = .wysiwyg
        XCTAssertFalse(controller.quickUndoEligible(entry), "a markdown entry is eligible in Rich Text mode")
        controller.efEditorKind[entry.id] = nil   // an entry with no kind is a Rich Text entry
        XCTAssertTrue(controller.quickUndoEligible(entry), "a Rich Text entry is refused in Rich Text mode")
        editorState.editorMode = .source
        XCTAssertFalse(controller.quickUndoEligible(entry), "a Rich Text entry is eligible in Markdown mode")

        controller.efEditorKind[entry.id] = .markdown
        XCTAssertTrue(controller.quickUndoEligible(entry), "markdown entry refused")
        editorState.structuralOutOfQueueGeneration += 1   // an old whole-document write touched the project since the entry
        XCTAssertFalse(controller.quickUndoEligible(entry), "the generation rule is ignored for a Markdown entry")
        editorState.editorMode = .wysiwyg
        controller.efEditorKind[entry.id] = nil
        XCTAssertFalse(controller.quickUndoEligible(entry), "the generation rule is ignored for a Rich Text entry")
        editorState.editorMode = .source
    }

    // MARK: - T-U6

    func testCmdZCmdShiftZCmdZThroughTheRealKeysGivesPreThenPostThenPreWithNoNotice() async throws {
        try await startRig(Self.book4)
        try await rig.userTypes(" zq7", after: "Second chapter text.")
        let (pre, post) = try await deleteSection("Chapter 3")
        XCTAssertFalse(post.contains("Chapter 3"), "premise: the Delete took the chapter out of the editor")
        XCTAssertTrue(post.contains("zq7"), "premise: the typing before the Delete is in the editor")

        try await press("undo", until: { $0 == pre }, "Cmd-Z did not restore the text from before the Delete")
        assertQuiet("after the first Cmd-Z")
        XCTAssertTrue(rig.unifiedUndo.undoStack.isEmpty && rig.unifiedUndo.redoStack.count == 1, "the entry did not move to the redo stack")
        try await assertRowsMatchPage("after the first Cmd-Z")

        try await press("redo", until: { $0 == post }, "Cmd-Shift-Z did not delete the chapter again")
        assertQuiet("after Cmd-Shift-Z")
        XCTAssertTrue(rig.unifiedUndo.undoStack.count == 1 && rig.unifiedUndo.redoStack.isEmpty, "the entry did not move back to the undo stack")
        try await assertRowsMatchPage("after Cmd-Shift-Z")

        try await press("undo", until: { $0 == pre }, "the second Cmd-Z did not restore the text from before the Delete")
        assertQuiet("after the second Cmd-Z")
        try await assertRowsMatchPage("after the second Cmd-Z")
        XCTAssertTrue(try rig.writerRig.storedText().contains("Chapter 3"), "the chapter is not back in the rows")
    }

    // MARK: - T-U7

    func testTwoFullUndoRedoCyclesKeepTheEntryAndTheRowsInStep() async throws {
        try await startRig(Self.book4)
        let (pre, post) = try await deleteSection("Chapter 3")
        for cycle in 1...2 {
            try await press("undo", until: { $0 == pre }, "the Cmd-Z of cycle \(cycle) was not structural: postOpDoc advanced to preOpDoc?")
            assertQuiet("after the Cmd-Z of cycle \(cycle)")
            try await assertRowsMatchPage("after the Cmd-Z of cycle \(cycle)")
            try await press("redo", until: { $0 == post }, "the second Cmd-Z was not structural: the redo of cycle \(cycle) did not delete again")
            assertQuiet("after the Cmd-Shift-Z of cycle \(cycle)")
            try await assertRowsMatchPage("after the Cmd-Shift-Z of cycle \(cycle)")
        }
        XCTAssertEqual(rig.unifiedUndo.undoStack.count, 1, "the entry is not back on the undo stack")
        XCTAssertFalse(try rig.writerRig.storedText().contains("Chapter 3"), "the chapter is back in the rows")
    }

    // MARK: - T-U8

    func testTypingInsideTheDeletedChapterIsRemovedByTheSecondCmdZ() async throws {
        try await startRig(Self.book4)
        try await rig.userTypes(" tt5", after: "Third chapter text.")
        let (pre, _) = try await deleteSection("Chapter 3")
        XCTAssertTrue(pre.contains("tt5"), "premise: the typing is in chapter 3")

        try await press("undo", until: { $0 == pre }, "the first Cmd-Z did not restore chapter 3")
        let afterSecond = try await press(
            "undo", until: { !$0.contains("tt5") && $0.contains("Chapter 3") }, "typing still present after second Cmd-Z")
        XCTAssertTrue(afterSecond.contains("Third chapter text."), "the second Cmd-Z removed more than the typing")
        // The text undo is an ordinary edit: the re-parse that follows it saves it (ContentView arms it; the rig does it by hand).
        let reported = await rig.waitUntil { !self.rig.editorState.content.contains("tt5") }
        XCTAssertTrue(reported, "premise: the text undo reached the content record")
        _ = rig.writerRig.schedule(rig.editorState.content)
        await rig.editorState.blockReparseTask?.value
        await rig.writerRig.settle()
        XCTAssertFalse(try rig.writerRig.storedText().contains("tt5"), "typing still present in the rows after second Cmd-Z")
        XCTAssertTrue(try rig.writerRig.storedText().contains("Third chapter text."), "chapter 3 is not in the rows")
    }

    // MARK: - T-U21

    func testDeleteTypeCmdZTwiceCmdShiftZTwiceBringsTheTypingBack() async throws {
        try await startRig(Self.book4)
        let (pre, post) = try await deleteSection("Chapter 3")
        let typed = try await rig.userTypes(" kp3", after: "Second chapter text.")
        XCTAssertTrue(typed.contains("kp3"), "premise: the typing is in the editor")

        try await press("undo", until: { $0 == post }, "the first Cmd-Z did not undo the typing")
        try await press("undo", until: { $0 == pre }, "the second Cmd-Z did not undo the Delete")
        try await press("redo", until: { $0 == post }, "the first Cmd-Shift-Z did not delete the chapter again")
        try await press("redo", until: { $0 == typed }, "typing not restored by redo")
        assertQuiet("at the end")
    }

    // MARK: - T-U10, Cmd-Z half

    func testFootnotedChapterComesBackWithItsFootnotesInTheEditorAndTheRowsAndTheBibliographyIsUnchanged() async throws {
        try await startRig(Self.footnotedRecord)
        try await rig.type(Self.footnotedRecord.replacingOccurrences(of: "# Bibliography", with: Self.glueMarker + "# Bibliography"))
        let notesIdsBefore = try rig.writerRig.rows().filter { $0.isNotes }.map(\.id)
        XCTAssertGreaterThan(notesIdsBefore.count, 4, "premise: the rows hold the Notes heading and four definitions")
        let (pre, post) = try await deleteSection("Chapter 3")
        XCTAssertFalse(post.contains("[^3]:") || post.contains("[^4]:"), "premise: the Delete took chapter 3's definitions out of the editor")

        try await press("undo", until: { $0 == pre }, "Cmd-Z did not restore the text from before the Delete")
        assertQuiet("after Cmd-Z")

        let page = try await rig.pageText()
        let stored = try rig.writerRig.storedText()
        for (name, text) in [("editor", page), ("rows", stored)] {
            var previousEnd = text.startIndex
            for label in 1...4 {
                let definition = "[^\(label)]: Note \(["", "one", "two", "three", "four"][label])."
                XCTAssertEqual(
                    text.components(separatedBy: definition).count - 1, 1,
                    label <= 2 ? "duplicate label \(label) in the \(name)" : "Notes rows missing [^\(label)]: in the \(name)")
                if let range = text.range(of: definition, range: previousEnd..<text.endIndex) {
                    previousEnd = range.upperBound
                } else {
                    XCTFail("the definitions are not numbered 1..4 in order in the \(name)")
                }
            }
            XCTAssertTrue(text.contains("Third chapter text.[^3][^4]"), "chapter 3's references are not back in the \(name)")
            XCTAssertTrue(
                text.contains("Smith, J. (2020). A book.") && text.contains("Jones, K. (2021). Another."),
                "the bibliography changed in the \(name)")
        }
        XCTAssertEqual(try rig.writerRig.rows().filter { $0.isNotes }.map(\.id), notesIdsBefore, "Notes row ids changed")
    }

    // MARK: - The rows

    func testAfterAQuickUndoTheRowsEqualThePreDeleteRowsIncludingIdsStatusAndTags() async throws {
        try await startRig(Self.book4)
        try rig.writerRig.setMetadata(onHeading: "Chapter 3", status: .review, tags: ["alpha", "beta"], wordGoal: 500)
        func snapshot() throws -> [String] {
            try rig.writerRig.rows().map {
                "\($0.id)|\($0.markdownFragment)|\($0.status?.rawValue ?? "-")|\(($0.tags ?? []).joined(separator: ","))|\($0.wordGoal ?? 0)"
            }
        }
        let before = try snapshot()
        let (pre, _) = try await deleteSection("Chapter 3")
        XCTAssertNotEqual(try snapshot(), before, "premise: the Delete changed the rows")

        try await press("undo", until: { $0 == pre }, "Cmd-Z did not restore the text from before the Delete")
        XCTAssertEqual(try snapshot(), before, "rows differ from the pre-delete rows")
    }

    // MARK: - Typing while the reinsert waits

    func testTypingMadeWhileTheReinsertWaitsIsKeptAndSavedAfterTheRelease() async throws {
        try await startRig(Self.book4)
        let idsBefore = try rig.writerRig.rows().map(\.id)
        let (pre, _) = try await deleteSection("Chapter 3")
        let hold = rig.holdReinsert()

        try await rig.press("undo")
        try await rig.waitForPage { $0 == pre }
        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isIdle }
        XCTAssertTrue(rig.markdownWriter.isHeldForStructuralWork, "premise: the reinsert is held, so the writer's hold is up")

        let typed = try await rig.userTypes(" mm6", after: "Second chapter text.")
        let reported = await rig.waitUntil { self.rig.editorState.content.contains("mm6") }
        XCTAssertTrue(reported, "premise: the typing reached the content record")
        // Typing after the undo drops the redo branch: the entry is discarded and its job records are forgotten WHILE the reinsert is
        // still queued. The hold must stay up until the job itself has ended, or the next save would run ahead of the reinsert.
        let dropped = await rig.waitUntil { self.rig.unifiedUndo.redoStack.isEmpty }
        XCTAssertTrue(dropped, "premise: the typing dropped the redo branch")
        XCTAssertTrue(rig.markdownWriter.isHeldForStructuralWork, "the hold was released when the redo branch was dropped")
        // The debounced re-parse comes due during the hold: it reserves nothing and keeps its refire.
        _ = rig.writerRig.schedule(rig.editorState.content)
        await rig.editorState.blockReparseTask?.value
        XCTAssertFalse(try rig.writerRig.storedText().contains("mm6"), "premise: nothing was saved while the reinsert was held")

        hold.release()
        await rig.settleEverything()
        await rig.editorState.blockReparseTask?.value
        await rig.writerRig.settle()
        let saved = await rig.waitUntil { (try? self.rig.writerRig.storedText().contains("mm6")) == true }
        XCTAssertTrue(saved, "mm6 not saved after the release")
        XCTAssertTrue(try rig.writerRig.storedText().contains("Chapter 3"), "the chapter is not back in the rows")
        XCTAssertEqual(try rig.writerRig.rows().map(\.id), idsBefore, "the rows are not the pre-delete rows: the save ran ahead of the reinsert")
        XCTAssertEqual(try rig.writerRig.duplicateFragments(), [], "the chapter's rows are in the table twice")
        let page = try await rig.pageText()
        XCTAssertEqual(page, typed, "the typing was overwritten or the restored text was changed")
        assertQuiet("after the release")
    }

    // MARK: - A Cmd-Z at once after a Delete

    func testCmdZAtOnceAfterADeleteWaitsForTheDeletesApplyAndIsNeverRefused() async throws {
        try await startRig(Self.book4)
        let hold = rig.holdNextJob()
        let chapter3 = try rig.section("Chapter 3")
        let pre = try await rig.pageText()
        let outcome = await rig.controller.performSectionDelete(rootId: chapter3.id)
        XCTAssertEqual(outcome, .performed)
        let post = try await rig.pageText()
        XCTAssertNotEqual(post, pre, "premise: the editor already shows the delete")

        try await rig.press("undo")
        try await Task.sleep(for: .milliseconds(500))
        let whileHeld = try await rig.pageText()
        XCTAssertEqual(whileHeld, post, "the undo ran before the delete's job applied")
        XCTAssertNil(rig.editorState.toastCenter.current, "the press was refused with a notice")
        XCTAssertEqual(rig.toastLog.lines, [], "the press was refused with a notice (shown and replaced)")
        XCTAssertTrue(rig.markdownWriter.isHeldForStructuralWork, "premise: the delete's hold is still up")

        hold.release()
        try await rig.waitForPage { $0 == pre }
        _ = await rig.waitUntil { self.rig.editorState.structuralGate.isIdle }
        await rig.settleEverything()
        let after = try await rig.pageText()
        XCTAssertEqual(after, pre, "the held Cmd-Z was lost instead of carried out")
        XCTAssertNil(rig.editorState.toastCenter.current, "the press was refused with a notice")
        XCTAssertEqual(rig.toastLog.lines, [], "the press was refused with a notice (shown and replaced)")
        XCTAssertTrue(try rig.writerRig.storedText().contains("Chapter 3"), "the chapter is not back in the rows")
        try await assertRowsMatchPage("after the held Cmd-Z")
        assertQuiet("after the held Cmd-Z")
    }

    // MARK: - The entry's state

    func testTypingAfterAQuickUndoDropsTheRedoBranchAndTheEntrysKindGoesWithIt() async throws {
        try await startRig(Self.book4)
        let (pre, _) = try await deleteSection("Chapter 3")
        let opId = try XCTUnwrap(rig.unifiedUndo.undoStack.last?.id)
        try await press("undo", until: { $0 == pre }, "Cmd-Z did not restore the text from before the Delete")
        XCTAssertEqual(rig.controller.efEditorKind[opId], .markdown, "premise: the entry is on the redo stack with its kind")

        try await rig.userTypes(" yy2", after: "Second chapter text.")
        let dropped = await rig.waitUntil { self.rig.unifiedUndo.redoStack.isEmpty }
        XCTAssertTrue(dropped, "typing after the undo did not drop the redo branch")
        let cleared = await rig.waitUntil { self.rig.controller.efEditorKind[opId] == nil }
        XCTAssertTrue(cleared, "the entry kind was kept")
        await rig.settleEverything()
    }
}
