//
//  MarkdownBlockWriteRaceTests.swift
//  final finalTests
//
//  t-94369a83 Phase 4a, plan v2 section 3, tests U2 (d), (e), (f), (g): what happens when typing, a second write, a
//  direct whole-document write, a Swift push or a canceller arrives WHILE a Markdown write is in flight.
//
//    - (d) typing during a write that waits its turn: the next write waits for the first, then lands; no duplicates
//    - (e) a direct whole-document write between the reservation and the apply, with an INSERT-ONLY batch: the whole
//          batch is refused for a stale epoch, counted, the baseline goes back to rows, the next fire writes the insert
//    - (f) `noteLoaded` during the flight: the completion does NOT put its (older) text over the newer baseline
//    - (g) cancellers: a cancelled fire writes nothing; `writeNow` and the debounce fire both waiting write once
//
//  "Hold" is a reserved, unapplied SYSTEM sequence: the Markdown write reserved after it parks on its turn (the
//  writer's `.parked` event says so; nothing sleeps for that). See `MarkdownWriterRig`.
//
//  Only where a test needs the debounced fire (a real Task) to have reached its wait does it sleep, for a few
//  milliseconds, and the outcome it asserts holds whether or not the fire got there first.
//

import Foundation
import Testing
@testable import final_final

@Suite("Markdown block writes: races — Tier 2 (t-94369a83 Phase 4a, U2 d-g)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MarkdownBlockWriteRaceTests {

    private static let base = "# Alpha\n\nOne.\n\nTwo.\n\nThree.\n\n# Beta\n\nFour."
    private static let text1 = base.replacingOccurrences(of: "Two.", with: "Two, first edit.")
    private static let text2 = text1.replacingOccurrences(of: "Three.", with: "Three.\n\nBrand new paragraph.")

    private func isOutOfTurn(_ event: WriterEvent) -> Bool {
        if case .refused(_, .outOfTurn) = event { return true }
        return false
    }

    // MARK: - (d) typing while the first write waits its turn

    @Test("(d) typing during a write that waits its turn: the second write waits for the first, then both land, in order, with no duplicate rows")
    func typingWhileTheFirstWriteWaitsItsTurn() async throws {
        let rig = try MarkdownWriterRig(content: Self.base)
        let parked = rig.parkedSignal()
        let held = rig.hold()

        // Write 1 is reserved behind the held sequence and parks.
        #expect(rig.fire(Self.text1) == .started)
        await parked.wait()
        #expect(try rig.storedText() == Self.base, "nothing is written while the held sequence is open")

        // The user keeps typing; the bibliography flush's `writeNow` stands in for the second write (it waits for write 1
        // exactly as the debounce fire does, through the same `while let` loop).
        rig.editorState.content = Self.text2
        let second = Task { @MainActor in await rig.writeNow() }
        await Task.yield()
        await rig.release(held)
        let outcome = await second.value
        await rig.settle()

        #expect(outcome == .proceeded)
        #expect(try rig.storedText() == Self.text2, "the database equals the editor text")
        #expect(try rig.rows().count == rig.parse(Self.text2).count, "one row per parsed block")
        #expect(try rig.duplicateFragments().isEmpty, "no duplicate rows")
        #expect(rig.markdownWriter.lastTimingLine?.contains("mode=text") == true, "write 2 compared with write 1's text, not the rows")
        #expect(!rig.events.all.contains(where: isOutOfTurn), "no out-of-turn refusal")
        #expect(rig.ledger.failedWrites == 0)

        // Two separate turns, in order: the edited row carries write 1's sequence, the new row write 2's.
        let stamps = try rig.stamps()
        let edited = try #require(try rig.rows().first { $0.markdownFragment == "Two, first edit." })
        let inserted = try #require(try rig.rows().first { $0.markdownFragment == "Brand new paragraph." })
        #expect(stamps[edited.id]?.last == Int64(held.seq) + 1)
        #expect(stamps[inserted.id]?.last == Int64(held.seq) + 2)
    }

    // MARK: - (e) stale epoch

    @Test("""
        (e) a direct whole-document write between the reservation and the apply, with an INSERT-ONLY batch: the whole \
        batch is refused for a stale epoch, counted, the baseline is rows, no retry is requested (judge R7), and the next fire writes the insert
        """)
    func staleEpochRefusesAnInsertOnlyBatch() async throws {
        let rig = try MarkdownWriterRig(content: Self.base)
        let parked = rig.parkedSignal()
        let typed = Self.base + "\n\nBrand new paragraph."   // insert-only against the stored rows
        let held = rig.hold()
        #expect(rig.fire(typed) == .started)
        await parked.wait()

        // A zoom or mode-switch style flush lands first, from the text the editor had BEFORE the keystrokes.
        let epochBefore = try rig.db.currentBlockWriteEpoch(projectId: rig.pid)
        rig.editorState.flushContentToDatabase(overrideContent: Self.base)
        try #require(try rig.db.currentBlockWriteEpoch(projectId: rig.pid) != epochBefore, "premise: a direct whole-document write moves the epoch")

        await rig.release(held)
        await rig.settle()

        #expect(rig.ledger.markdownStaleEpochRejections == 1)
        #expect(rig.markdownWriter.lastTimingLine?.contains("outcome=stale-epoch") == true)
        #expect(try rig.storedText() == Self.base, "the insert was dropped silently: only the flush's rows are stored")
        #expect(rig.markdownWriter.baseline.isRows)
        // Judge R7: the direct write moved the version (`noteDirectWholeWrite`), so this completion belongs to a baseline
        // that already restarted: it asks for no retry and counts no failure. (In the app the direct write carries the
        // editor's CURRENT text, so there is nothing left to retry; this test flushes older text on purpose.)
        #expect(rig.refireCount == 0, "a stale completion schedules nothing; there is no immediate retry either")
        #expect(rig.markdownWriter.consecutiveFailures == 0)

        // The next normal fire writes the insert (rows mode: the text against the flush's rows).
        let retry = await rig.fireAndSettle(typed)
        #expect(retry == .started)
        #expect(try rig.storedText() == typed)
        #expect(try rig.duplicateFragments().isEmpty)
        #expect(rig.ledger.markdownStaleEpochRejections == 1, "the retry itself was not refused")
    }

    // MARK: - (f) the version counter

    @Test("(f) a Swift push (`noteLoaded`) during the flight: the write lands, and its completion leaves the baseline on rows")
    func noteLoadedDuringTheFlightLeavesRows() async throws {
        // Arm 1: a push lands while the write waits its turn.
        let rig = try MarkdownWriterRig(content: Self.base)
        let parked = rig.parkedSignal()
        let held = rig.hold()
        #expect(rig.fire(Self.text1) == .started)
        await parked.wait()
        let versionAtReservation = rig.markdownWriter.version
        rig.markdownWriter.noteLoaded(text: Self.text1, pid: rig.pid)
        await rig.release(held)
        await rig.settle()

        #expect(try rig.storedText() == Self.text1, "the write itself landed")
        #expect(rig.markdownWriter.baseline.isRows, "the completion did not overwrite the newer baseline with the older text")
        #expect(rig.markdownWriter.version == versionAtReservation + 1, "only the push bumped the version, the completion did not")

        // Control: the identical run without the push ends on a text baseline, so the assertion above is not vacuous.
        let control = try MarkdownWriterRig(content: Self.base)
        let controlParked = control.parkedSignal()
        let controlHeld = control.hold()
        #expect(control.fire(Self.text1) == .started)
        await controlParked.wait()
        await control.release(controlHeld)
        await control.settle()
        #expect(try control.storedText() == Self.text1)
        #expect(!control.markdownWriter.baseline.isRows, "control: a clean write with no push in between leaves a text baseline")
    }

    // MARK: - (f2) judge R7: a stale failure completion neither retries nor counts

    @Test("""
        (f2) a write that FAILS after a reset (a mode change, zoom or project switch) came in during its flight changes nothing: no \
        retry is scheduled and no failure is counted (control: the same run without the reset schedules one retry and counts one)
        """, arguments: [true, false])
    func aStaleFailureCompletionNeitherRetriesNorCounts(resetDuringTheFlight: Bool) async throws {
        let rig = try MarkdownWriterRig(content: Self.base)
        let parked = rig.parkedSignal()
        let held = rig.hold()
        #expect(rig.fire(Self.text1) == .started)
        await parked.wait()
        if resetDuringTheFlight { rig.markdownWriter.reset() }
        rig.writer.retire(reason: .projectSwitch)   // the waiting turn is skipped: nothing is written
        await rig.settle()
        _ = held

        #expect(rig.markdownWriter.lastTimingLine?.contains("outcome=skipped") == true, "premise: the write did not land")
        #expect(try rig.storedText() == Self.base)
        #expect(rig.markdownWriter.consecutiveFailures == (resetDuringTheFlight ? 0 : 1))
        #expect(rig.refireCount == (resetDuringTheFlight ? 0 : 1))
        #expect(rig.markdownWriter.baseline.isRows)
    }

    // MARK: - (g) cancellation and double waiting

    @Test("(g) a canceller during the in-flight wait means the debounce fire writes nothing (control: the same run uncancelled writes)")
    func cancelledFireWritesNothing() async throws {
        let rig = try MarkdownWriterRig(content: Self.base, debounce: .milliseconds(5))
        let parked = rig.parkedSignal()
        let held = rig.hold()
        #expect(rig.fire(Self.text1) == .started)
        await parked.wait()
        let task = try #require(rig.schedule(Self.text2), "precondition: the fire was scheduled")
        try await Task.sleep(for: .milliseconds(40))   // let the fire pass its sleep and reach its wait for write 1
        rig.editorState.blockReparseTask?.cancel()      // what a mode change or `flushContentToDatabase` does
        await rig.release(held)
        await task.value
        await rig.settle()
        #expect(try rig.storedText() == Self.text1, "write 1 landed; the cancelled fire added nothing")
        #expect(rig.refireCount == 0)

        // Control.
        let control = try MarkdownWriterRig(content: Self.base, debounce: .milliseconds(5))
        let controlParked = control.parkedSignal()
        let controlHeld = control.hold()
        #expect(control.fire(Self.text1) == .started)
        await controlParked.wait()
        let controlTask = try #require(control.schedule(Self.text2))
        try await Task.sleep(for: .milliseconds(40))
        await control.release(controlHeld)
        await controlTask.value
        await control.settle()
        #expect(try control.storedText() == Self.text2, "control: uncancelled, the fire writes the newer text after write 1")
        #expect(try control.duplicateFragments().isEmpty)
    }

    @Test("(g) `writeNow` and the debounce fire both waiting for the write in flight: the new paragraph is written exactly once")
    func writeNowAndTheFireBothWaitingWriteOnce() async throws {
        let rig = try MarkdownWriterRig(content: Self.base, debounce: .milliseconds(5))
        let parked = rig.parkedSignal()
        let held = rig.hold()
        #expect(rig.fire(Self.text1) == .started)
        await parked.wait()

        // `writeNow` first (it cancels a SCHEDULED fire as its first step), then the debounce fire: both end up waiting.
        rig.editorState.content = Self.text2
        let now = Task { @MainActor in await rig.writeNow() }
        await Task.yield()
        await Task.yield()
        let fireTask = try #require(rig.schedule(Self.text2))
        try await Task.sleep(for: .milliseconds(40))

        await rig.release(held)
        let outcome = await now.value
        await fireTask.value
        await rig.settle()

        #expect(outcome == .proceeded)
        #expect(try rig.storedText() == Self.text2)
        #expect(try rig.rows().filter { $0.markdownFragment == "Brand new paragraph." }.count == 1, "exactly one insert")
        #expect(try rig.duplicateFragments().isEmpty)
        #expect(rig.ledger.failedWrites == 0)
        #expect(!rig.events.all.contains(where: isOutOfTurn))
    }
}
