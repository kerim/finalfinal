//
//  FootnotePerStepUndoTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Phase 3a-2 Step 6: every ⌘Z step brings back ITS OWN footnote with its text. A burst of deletes is one write and
//  one checkpoint, but the checkpoint now remembers every document the burst passed through (undo states), and a
//  restore moves the table from the numbering it is in to the numbering of the state it lands on. Each test asserts
//  the EXACT Notes rows (label -> text) after EVERY single step, through the real system writer. `flushPendingSync()`
//  stands in for the debounce deadline firing and also waits for a restore in flight.
//
//  Document shapes: three footnotes in one paragraph ("One", "two", "three" carry the markers) and a Notes section.
//  A state's body is compared with the Notes stripped, so undo checks carry no Notes (the removal push took them
//  out); the checks INSIDE a burst carry them (the editor still shows them until the write).
//

import Testing
import Foundation
@testable import final_final

private enum StepDoc {
    static let notes3 = "\n\n# Notes\n\n[^1]: T one.\n\n[^2]: T two.\n\n[^3]: T three."
    /// The Notes after the first write of U-P7 / U-P4b renumbered the survivors (2 -> 1, 3 -> 2).
    static let notesRenumbered = "\n\n# Notes\n\n[^1]: T two.\n\n[^2]: T three."

    /// The paragraph with the marker labels shown on the three words (nil = no marker).
    static func body(_ one: String?, _ two: String?, _ three: String?) -> String {
        func marker(_ label: String?) -> String { label.map { "[^\($0)]" } ?? "" }
        return "# A\n\nOne\(marker(one)) two\(marker(two)) three\(marker(three))."
    }

    static let all: [String: String] = ["1": "T one.", "2": "T two.", "3": "T three."]
}

/// Counts `.renumberFootnotes` posts (a restore must never post one).
private final class RenumberPostCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var posts = 0
    func note() { lock.withLock { posts += 1 } }
    var count: Int { lock.withLock { posts } }
}

/// A service on the real system writer with three known footnotes (`["1","2","3"]`), and the editor's checks.
@MainActor
private final class StepFixture {
    let stack: TestStack
    let service = FootnoteSyncService()

    private init(stack: TestStack) {
        self.stack = stack
    }

    static func make(
        content: String = StepDoc.body("1", "2", "3") + StepDoc.notes3, refs: [String] = ["1", "2", "3"]
    ) async throws -> StepFixture {
        let fixture = StepFixture(stack: try makeStack(content: content))
        let service = fixture.service
        service.configure(database: fixture.stack.db, projectId: fixture.stack.pid)
        service.systemWriter = SystemWriter(blockSync: fixture.stack.sync)
        service.debounceInterval = 30   // the tests end every burst with a flush
        fixture.check(refs, content)
        await service.flushPendingSync()
        fixture.check(refs, content)
        return fixture
    }

    func check(_ refs: [String], _ content: String) {
        service.checkAndUpdateFootnotes(footnoteRefs: refs, projectId: stack.pid, fullContent: content)
    }

    func flush() async { await service.flushPendingSync() }

    /// The Notes definition rows as label -> text.
    func rows() throws -> [String: String] {
        var result: [String: String] = [:]
        for block in try TestFixtureFactory.fetchBlocks(from: stack.db) where block.isNotes && block.blockType == .paragraph {
            if let parsed = FootnoteSyncService.parseNotesLabel(from: block.markdownFragment) { result[parsed.label] = parsed.text }
        }
        return result
    }

    /// One editor step (an undo or a redo): the check, then the flush that waits for whatever it started.
    func step(_ refs: [String], _ content: String, expect: [String: String], _ what: String) async throws {
        check(refs, content)
        await flush()
        let actual = try rows()
        let expected = expect.sorted { $0.key < $1.key }
        #expect(actual == expect, "\(what): the Notes rows must be exactly \(expected); got \(actual.sorted { $0.key < $1.key })")
    }

    /// The three deletes of U-P1/U-P4a inside one burst, last first, then the write.
    func burstDeleteLastFirst() async throws {
        check(["1", "2"], StepDoc.body("1", "2", nil) + StepDoc.notes3)
        check(["1"], StepDoc.body("1", nil, nil) + StepDoc.notes3)
        check([], StepDoc.body(nil, nil, nil) + StepDoc.notes3)
        await flush()
        #expect(try rows().isEmpty, "the burst must have removed all three definitions (test setup)")
    }

    /// The undo walk of U-P1: each step must bring back exactly its footnote.
    func undoLastFirstWalk(_ cycle: String) async throws {
        try await step(["1"], StepDoc.body("1", nil, nil), expect: ["1": "T one."], "\(cycle) undo 1")
        try await step(["1", "2"], StepDoc.body("1", "2", nil), expect: ["1": "T one.", "2": "T two."], "\(cycle) undo 2")
        try await step(["1", "2", "3"], StepDoc.body("1", "2", "3"), expect: StepDoc.all, "\(cycle) undo 3")
    }

    /// U-P3's burst: delete the FIRST and the LAST number; the write renumbers the survivor 2 -> 1; the editor's own
    /// renumber (its own undo step) follows and is seen as an equal-refs check.
    func burstDeleteFirstAndLast() async throws {
        check(["2", "3"], StepDoc.body(nil, "2", "3") + StepDoc.notes3)
        check(["2"], StepDoc.body(nil, "2", nil) + StepDoc.notes3)
        await flush()
        #expect(try rows() == ["1": "T two."], "the write must keep the survivor as [^1] (test setup)")
        check(["1"], StepDoc.body(nil, "1", nil))   // the editor's renumbered document: recorded as the written state
    }

    /// The undo walk of U-P3: the renumber first, then each delete.
    func undoRenumberWalk(_ cycle: String) async throws {
        try await step(["2"], StepDoc.body(nil, "2", nil), expect: ["2": "T two."], "\(cycle) undo 1 (the renumber)")
        try await step(["2", "3"], StepDoc.body(nil, "2", "3"), expect: ["2": "T two.", "3": "T three."], "\(cycle) undo 2")
        try await step(["1", "2", "3"], StepDoc.body("1", "2", "3"), expect: StepDoc.all, "\(cycle) undo 3")
    }
}

@Suite("Footnote per-step undo — every ⌘Z brings back its own footnote (Step 6)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct FootnotePerStepUndoTests {

    @Test("""
        U-P1: three numbers deleted last-first inside one burst, then undone ONE AT A TIME: each ⌘Z restores exactly \
        its own footnote and text (only the last undo used to fill them in)
        """)
    func burstDeletedLastFirstIsUndoneOneAtATime() async throws {
        let fixture = try await StepFixture.make()
        try await fixture.burstDeleteLastFirst()
        try await fixture.undoLastFirstWalk("last-first")
    }

    @Test("""
        U-P2: the numbers deleted first-first inside one burst (the editor has not renumbered yet): each undo step \
        restores its own footnote under the number the user saw, and the restore posts NO renumber to the editor
        """)
    func burstDeletedFirstFirstIsUndoneOneAtATimeWithoutRenumbering() async throws {
        let fixture = try await StepFixture.make()
        let posts = RenumberPostCounter()
        let observer = NotificationCenter.default.addObserver(forName: .renumberFootnotes, object: nil, queue: nil) { _ in posts.note() }
        defer { NotificationCenter.default.removeObserver(observer) }

        fixture.check(["2", "3"], StepDoc.body(nil, "2", "3") + StepDoc.notes3)
        fixture.check(["3"], StepDoc.body(nil, nil, "3") + StepDoc.notes3)
        fixture.check([], StepDoc.body(nil, nil, nil) + StepDoc.notes3)
        await fixture.flush()
        #expect(try fixture.rows().isEmpty, "the burst must have removed all three definitions (test setup)")

        try await fixture.step(["3"], StepDoc.body(nil, nil, "3"), expect: ["3": "T three."], "undo 1")
        try await fixture.step(["2", "3"], StepDoc.body(nil, "2", "3"), expect: ["2": "T two.", "3": "T three."], "undo 2")
        try await fixture.step(["1", "2", "3"], StepDoc.body("1", "2", "3"), expect: StepDoc.all, "undo 3")
        #expect(posts.count == 0, "a restore must never post a renumber to the editor")
    }

    @Test("""
        U-P3: first and last number deleted in one burst (the survivor is renumbered 2 -> 1): undo the editor's renumber, \
        then each delete: every step restores exactly its own rows, including the survivor's label going back to [^2]
        """)
    func firstAndLastDeletedWithRenumberingAreUndoneStepByStep() async throws {
        let fixture = try await StepFixture.make()
        try await fixture.burstDeleteFirstAndLast()
        try await fixture.undoRenumberWalk("first+last")
    }

    @Test("""
        U-P3b (the S2 data loss, t-a73373e6): with 3 footnotes delete the FIRST number, let the write apply, undo only \
        the editor's renumber, then run the close-time refresh (`resyncNow`, allowRenumber false): the rows are \
        {2: T two., 3: T three.} and NO text is lost to a blank row
        """)
    func undoingOnlyTheRenumberThenTheCloseRefreshLosesNothing() async throws {
        let fixture = try await StepFixture.make()
        fixture.check(["2", "3"], StepDoc.body(nil, "2", "3") + StepDoc.notes3)
        await fixture.flush()
        #expect(try fixture.rows() == ["1": "T two.", "2": "T three."], "the write renumbers the survivors (test setup)")
        fixture.check(["1", "2"], StepDoc.body(nil, "1", "2"))   // the editor's renumbered document
        try await fixture.step(["2", "3"], StepDoc.body(nil, "2", "3"), expect: ["2": "T two.", "3": "T three."], "undo of the renumber")

        await fixture.service.resyncNow(
            footnoteRefs: ["2", "3"], projectId: fixture.stack.pid, fullContent: StepDoc.body(nil, "2", "3"), allowRenumber: false)

        let rows = try fixture.rows()
        #expect(rows == ["2": "T two.", "3": "T three."], "the close-time refresh must lose nothing; got \(rows.sorted { $0.key < $1.key })")
    }

    @Test("""
        U-P4a: after the full undo of U-P1, redo the three deletes (the redo deletes after the deadline like any \
        delete, and records a fresh checkpoint), then undo one at a time again, and repeat the whole cycle once more: \
        every step shows exactly its rows
        """)
    func redoThenUndoAgainWorksAsOftenAsTheUserLikes() async throws {
        let fixture = try await StepFixture.make()
        try await fixture.burstDeleteLastFirst()
        try await fixture.undoLastFirstWalk("cycle 1")

        for cycle in ["cycle 2", "cycle 3"] {
            // Redo: the Notes are shown again, the three deletes come back as ordinary changes (fewer refs: no restore).
            fixture.check(["1", "2"], StepDoc.body("1", "2", nil) + StepDoc.notes3)
            fixture.check(["1"], StepDoc.body("1", nil, nil) + StepDoc.notes3)
            fixture.check([], StepDoc.body(nil, nil, nil) + StepDoc.notes3)
            #expect(try fixture.rows() == StepDoc.all, "\(cycle): a redo that deletes waits for the deadline; the text stays until then")
            await fixture.flush()
            #expect(try fixture.rows().isEmpty, "\(cycle): the redo's own write must remove the texts")
            try await fixture.undoLastFirstWalk(cycle)
        }
    }

    @Test("""
        U-P4b: the renumbering case twice over: undo the whole burst, redo the renumber (the written state restores at \
        once), undo again from the SAME checkpoint (the second restore must not re-apply the inverse rename and blank \
        the survivor), then redo through the deadline and undo once more
        """)
    func redoThenUndoAgainWithRenumberingNeverBlanksTheSurvivor() async throws {
        let fixture = try await StepFixture.make()
        try await fixture.burstDeleteFirstAndLast()
        try await fixture.undoRenumberWalk("cycle 1")

        // Redo 1: through the written state, which restores at once (the same checkpoint, the second restore from it).
        fixture.check(["2", "3"], StepDoc.body(nil, "2", "3") + StepDoc.notes3)
        fixture.check(["2"], StepDoc.body(nil, "2", nil) + StepDoc.notes3)
        try await fixture.step(["1"], StepDoc.body(nil, "1", nil), expect: ["1": "T two."], "cycle 2 redo of the renumber")
        try await fixture.undoRenumberWalk("cycle 2")

        // Redo 2: the deletes go through the deadline (a fresh write and a fresh checkpoint), then undo again.
        fixture.check(["2", "3"], StepDoc.body(nil, "2", "3") + StepDoc.notes3)
        fixture.check(["2"], StepDoc.body(nil, "2", nil) + StepDoc.notes3)
        await fixture.flush()
        #expect(try fixture.rows() == ["1": "T two."], "cycle 3: the redo's own write must delete 1 and 3 and keep the survivor")
        fixture.check(["1"], StepDoc.body(nil, "1", nil))
        try await fixture.undoRenumberWalk("cycle 3")
    }

    @Test("""
        U-P5: after the full undo of U-P3, redo the two deletes and then the renumber with NO flush in between: the \
        renumber matches the written state and restores at once, and ANY restore ends the burst (nothing pending); \
        then undo three times as in U-P3
        """)
    func quickRedoOfTheRenumberRestoresAtOnceAndEndsTheBurst() async throws {
        let fixture = try await StepFixture.make()
        try await fixture.burstDeleteFirstAndLast()
        try await fixture.undoRenumberWalk("first undo")

        fixture.check(["2", "3"], StepDoc.body(nil, "2", "3") + StepDoc.notes3)
        fixture.check(["2"], StepDoc.body(nil, "2", nil) + StepDoc.notes3)
        #expect(fixture.service.testHasPendingUpdate, "the two redo deletes wait for the deadline (test setup)")
        fixture.check(["1"], StepDoc.body(nil, "1", nil))   // the redo of the editor's renumber
        #expect(!fixture.service.testHasPendingUpdate, "a restore ends the current burst: nothing may stay pending")
        #expect(fixture.service.debounceTask == nil, "and the burst's timer must be cancelled")
        await fixture.flush()
        #expect(try fixture.rows() == ["1": "T two."], "the redo of the renumber must restore the written rows at once")

        try await fixture.undoRenumberWalk("second undo")
    }

    @Test("""
        U-P6: a redo that DELETES again (fewer references) is not a restore: it waits for the deadline like any delete, \
        so the text is still in the table until the flush
        """)
    func redoThatDeletesStillWaitsForTheDeadline() async throws {
        let fixture = try await StepFixture.make()
        try await fixture.burstDeleteLastFirst()
        try await fixture.undoLastFirstWalk("undo")

        fixture.check(["1", "2"], StepDoc.body("1", "2", nil) + StepDoc.notes3)
        #expect(fixture.service.testHasPendingUpdate, "a redo with fewer references schedules a burst")
        #expect(try fixture.rows() == StepDoc.all, "no restore and no write before the deadline: all three texts are still there")
        await fixture.flush()
        #expect(try fixture.rows() == ["1": "T one.", "2": "T two."], "after the deadline the redo's delete removes the third text")
    }

    @Test("""
        U-P7: slow single deletes, one write and one checkpoint each (the second delete is a renumbered label), undone \
        in reverse: the renumber, the delete, the renumber, the delete; the numbering guard picks the right rename \
        every time and the older checkpoint applies again once the newer one is undone
        """)
    func slowSingleDeletesAreUndoneInReverse() async throws {
        let fixture = try await StepFixture.make()
        // Delete [^1]: one write (survivors renumbered 2 -> 1, 3 -> 2), then the editor's renumbered document.
        fixture.check(["2", "3"], StepDoc.body(nil, "2", "3") + StepDoc.notes3)
        await fixture.flush()
        #expect(try fixture.rows() == ["1": "T two.", "2": "T three."], "first write (test setup)")
        fixture.check(["1", "2"], StepDoc.body(nil, "1", "2"))
        // Delete the NEW [^1] (the word "two"): a second write (survivor 2 -> 1), then its renumbered document.
        fixture.check(["2"], StepDoc.body(nil, nil, "2") + StepDoc.notesRenumbered)
        await fixture.flush()
        #expect(try fixture.rows() == ["1": "T three."], "second write (test setup)")
        fixture.check(["1"], StepDoc.body(nil, nil, "1"))

        try await fixture.step(["2"], StepDoc.body(nil, nil, "2"), expect: ["2": "T three."], "undo 1 (second renumber)")
        try await fixture.step(["1", "2"], StepDoc.body(nil, "1", "2"), expect: ["1": "T two.", "2": "T three."], "undo 2 (second delete)")
        try await fixture.step(["2", "3"], StepDoc.body(nil, "2", "3"), expect: ["2": "T two.", "3": "T three."], "undo 3 (first renumber)")
        try await fixture.step(["1", "2", "3"], StepDoc.body("1", "2", "3"), expect: StepDoc.all, "undo 4 (first delete)")
    }

    @Test("""
        U-P8a (stale-row rule): a footnote added with /footnote after the burst removed the texts starts BLANK: \
        beginImmediateInsertion drops every checkpoint
        """)
    func slashFootnoteAfterTheBurstStartsBlank() async throws {
        let fixture = try await StepFixture.make()
        try await fixture.burstDeleteLastFirst()

        let generation = fixture.service.beginImmediateInsertion()
        #expect(fixture.service.undoCheckpoints.isEmpty, "an explicit new footnote must clear the checkpoints")
        _ = await fixture.service.commitImmediateInsertion(label: "1", projectId: fixture.stack.pid, generation: generation)
        fixture.check(["1"], StepDoc.body("1", nil, nil))
        await fixture.flush()

        #expect(try fixture.rows() == ["1": ""], "the new footnote must be blank, never the deleted text")
    }

    @Test("U-P8b (stale-row rule): a reference typed by hand in a different sentence after the burst gets a BLANK definition")
    func handTypedReferenceElsewhereAfterTheBurstStaysBlank() async throws {
        let fixture = try await StepFixture.make()
        try await fixture.burstDeleteLastFirst()

        try await fixture.step(["1"], "# A\n\nNew sentence[^1]. One two three.", expect: ["1": ""], "hand-typed reference")
    }

    @Test("""
        U-P8c (numbering guard): another write moves the table on after the burst (the stored references are no longer \
        the checkpoint's), so a document that matches one of its states restores NOTHING and the number gets a blank row
        """)
    func anUnrelatedWriteMakesTheCheckpointInert() async throws {
        let fixture = try await StepFixture.make()
        try await fixture.burstDeleteLastFirst()

        // An unrelated write (the close-time refresh shape) leaves the table with the reference ["2"].
        await fixture.service.resyncNow(
            footnoteRefs: ["2"], projectId: fixture.stack.pid, fullContent: "# A\n\nElsewhere[^2].", allowRenumber: false)
        #expect(try fixture.rows() == ["2": ""], "the unrelated write (test setup)")

        // This document IS one of the checkpoint's states ([1]); only the numbering guard keeps it from restoring.
        try await fixture.step(["1"], StepDoc.body("1", nil, nil), expect: ["1": ""], "inert checkpoint")
    }

    @Test("""
        U-P9: a burst that changes 20 references keeps at most 16 states (the oldest middle ones are dropped, the one \
        before the burst is always kept): undo to a recorded state restores exactly its rows, and undo on to the \
        state before the burst still restores everything
        """)
    func stateCapKeepsTheStateBeforeTheBurst() async throws {
        let labels = (1...20).map(String.init)
        func definitions(_ count: Int) -> [String: String] { Dictionary(uniqueKeysWithValues: labels.prefix(count).map { ($0, "T\($0).") }) }
        func body(_ count: Int) -> String {
            "# A\n\n" + labels.prefix(count).map { "w\($0)[^\($0)]" }.joined(separator: " ") + "."
        }
        let notes = "\n\n# Notes\n\n" + labels.map { "[^\($0)]: T\($0)." }.joined(separator: "\n\n")
        let fixture = try await StepFixture.make(content: body(20) + notes, refs: labels)

        // The burst: delete the last number twenty times (20 -> 0 references), then the write.
        for count in stride(from: 19, through: 0, by: -1) { fixture.check(Array(labels.prefix(count)), body(count) + notes) }
        await fixture.flush()
        #expect(try fixture.rows().isEmpty, "the burst must have removed every definition (test setup)")
        let checkpoint = try #require(fixture.service.undoCheckpoints.last)
        #expect(checkpoint.states.count == 16, "the checkpoint keeps at most 16 states; got \(checkpoint.states.count)")
        #expect(checkpoint.states.first?.refs == labels, "the state before the burst is always kept")

        // A recorded state (3 references): restores exactly its own rows.
        try await fixture.step(Array(labels.prefix(3)), body(3), expect: definitions(3), "undo to a recorded state")
        // The state before the burst: everything.
        try await fixture.step(labels, body(20), expect: definitions(20), "undo to the state before the burst")
    }
}
