//
//  FootnoteBurstStandAsideTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  t-f1a22aa7 (Phase 4c): in Markdown mode the footnote service's burst timer (3 s) could come due while a section command
//  (Delete, drag, Duplicate, a Version History restore) was still finishing. Its renumber then reached the page outside the
//  command's settle flag: an undo step of its own (one more Cmd-Z) and no sort of the Notes. The fix makes the timer STAND ASIDE
//  while `FootnoteSyncService.structuralWorkPending` says the command has unfinished work: it writes nothing, keeps its waiting
//  snapshot and asks again `standAsideRecheck` later; the command's own settle (`resyncNow`) takes the burst over. A burst that does
//  write is refused by the writer when a command starts before its write gets its turn (`stillWanted`).
//
//  These five tests pin the service on its own (the hook is a box the test flips; the real wiring and the editor page are the rig
//  tests in Tier2/MarkdownEditorFirst). Every wait is on the DEBUG counter `testBurstDueDuringStructuralWorkCount`, the run counter
//  (`testInFlightHook`) or a task's own completion, with a bound; there are no fixed sleeps.
//
//  Break patches (docs/architecture/write-queue-plan/phase4c/footnote-timer/break-patches/):
//    BP-A (the re-arm branch of `fireBurst` off, and the burst's `stillWanted` nil): U-SA1, U-SA2, U-SA3, U-SA4 fail.
//    BP-B (no re-arm): U-SA1 and U-SA2 fail ("never landed").
//    BP-F (the burst's `stillWanted` nil): U-SA4 fails.
//    BP-G (the forget inside `resyncNow` removed): U-SA5 fails.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import Testing
@testable import final_final

// MARK: - Documents and helpers (copied from FootnoteUndoCheckpointTests / ReorderFootnoteSettleTests, which keep theirs private)

private enum StandAsideDoc {
    // Three footnotes; the last one is deleted, so the committed [1,2,3] and the new [1,2] differ and the burst has a Notes row to remove.
    static let triple = "# A\n\nOne[^1] two[^2] three[^3].\n\n# Notes\n\n[^1]: First.\n\n[^2]: Second.\n\n[^3]: Third."
    static let lastDeleted = "# A\n\nOne[^1] two[^2] three.\n\n# Notes\n\n[^1]: First.\n\n[^2]: Second.\n\n[^3]: Third."
    static let bothDeleted = "# A\n\nOne[^1] two three.\n\n# Notes\n\n[^1]: First.\n\n[^2]: Second.\n\n[^3]: Third."
}

/// The Notes definition paragraphs of the database, in table order.
private func standAsideDefinitions(_ db: ProjectDatabase) throws -> [String] {
    try TestFixtureFactory.fetchBlocks(from: db).filter { $0.isNotes && $0.blockType == .paragraph }.map(\.markdownFragment)
}

/// Counts the runs of `performFootnoteUpdate` that got past its entry guards (through `testInFlightHook`).
@MainActor
private final class StandAsideRunCounter {
    var count = 0
}

/// The answer of the hook the test installs as `structuralWorkPending`.
@MainActor
private final class StructuralWorkBox {
    var pending: Bool
    init(pending: Bool) { self.pending = pending }
}

/// The `.renumberFootnotes` notifications posted while it is alive, with their mappings (as in ReorderFootnoteSettleTests).
private final class StandAsideRenumberLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String: String]] = []
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(forName: .renumberFootnotes, object: nil, queue: nil) { [weak self] note in
            guard let self else { return }
            let mapping = (note.userInfo?["mapping"] as? [String: String]) ?? [:]
            self.lock.lock()
            self.recorded.append(mapping)
            self.lock.unlock()
        }
    }

    deinit { if let token { NotificationCenter.default.removeObserver(token) } }

    var mappings: [[String: String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Whether a mapping that sends label 10 to 1 and 1 to 10 was posted: the move's own renumber.
    var postedTheMoveRenumber: Bool {
        mappings.contains { $0["10"] == "1" && $0["1"] == "10" && $0["18"] == "9" && $0["9"] == "18" }
    }
}

/// The document of ReorderFootnoteSettleTests: 21 footnotes in three chapters, the middle one (labels 10 to 18) moved to the top.
private enum MoveDoc {
    static let labelCount = 21
    static let one = Array(1...9)
    static let two = Array(10...18)
    static let three = Array(19...21)

    static func chapter(_ title: String, _ labels: [Int]) -> String {
        (["# \(title)"] + labels.map { "Claim \($0) rests on a source[^\($0)]." }).joined(separator: "\n\n")
    }

    static var notesSection: String {
        (["# Notes"] + (1...labelCount).map { "[^\($0)]: Note \($0) text." }).joined(separator: "\n\n")
    }

    static var original: String {
        [chapter("Chapter One", one), chapter("Chapter Two", two), chapter("Chapter Three", three), notesSection].joined(separator: "\n\n")
    }

    static var moved: String {
        [chapter("Chapter Two", two), chapter("Chapter One", one), chapter("Chapter Three", three), notesSection].joined(separator: "\n\n")
    }

    static var movedLabels: [String] { (two + one + three).map(String.init) }
    static var sequentialLabels: [String] { (1...labelCount).map(String.init) }
}

@Suite("Footnote burst stands aside while a section command is unfinished (t-f1a22aa7)", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct FootnoteBurstStandAsideTests {

    /// A service whose first write committed `["1","2","3"]` and that recorded the content, with a shortened burst interval, a short
    /// stand-aside re-check and a run counter installed AFTER that setup. `box` answers `structuralWorkPending`.
    private func serviceWithKnownTriple(
        db: ProjectDatabase, projectId: String, interval: TimeInterval, writer: SystemWriter? = nil, box: StructuralWorkBox
    ) async -> (service: FootnoteSyncService, runs: StandAsideRunCounter) {
        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)
        service.systemWriter = writer
        service.debounceInterval = interval
        service.standAsideRecheck = 0.05
        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2", "3"], projectId: projectId, fullContent: StandAsideDoc.triple)
        await service.flushPendingSync()
        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2", "3"], projectId: projectId, fullContent: StandAsideDoc.triple)
        let runs = StandAsideRunCounter()
        service.testInFlightHook = { runs.count += 1 }
        service.structuralWorkPending = { box.pending }
        return (service, runs)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("""
        U-SA1: the burst's deadline (0.1 s) comes while a section command is unfinished: nothing is written, however many \
        times it is checked again; the waiting snapshot and a live timer stay; once the command is finished exactly ONE write \
        happens and the deleted definition is gone
        """)
    func aDeadlineThatComesWhileStructuralWorkIsUnfinishedWritesNothingUntilItEnds() async throws {
        let db = try TestFixtureFactory.createTemporary(content: StandAsideDoc.triple)
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        let box = StructuralWorkBox(pending: true)
        let (service, runs) = await serviceWithKnownTriple(db: db, projectId: projectId, interval: 0.1, box: box)

        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2"], projectId: projectId, fullContent: StandAsideDoc.lastDeleted)
        #expect(service.testHasPendingUpdate, "the change must have started a burst (test setup)")

        // Two checks of the deadline while the work is unfinished (the second is the first re-check), or a write if the burst does not stand aside.
        let stood = await waitUntil(timeout: 5) { service.testBurstDueDuringStructuralWorkCount >= 2 || runs.count >= 1 }
        #expect(runs.count == 0, "no write may happen while structural work is unfinished; got \(runs.count)")
        #expect(stood && service.testBurstDueDuringStructuralWorkCount >= 2,
                "the burst must be checked again after it stood aside; checks \(service.testBurstDueDuringStructuralWorkCount)")
        #expect(service.testHasPendingUpdate, "the stand-aside must keep the waiting snapshot")
        #expect(service.debounceTask?.isCancelled == false, "the stand-aside must leave a live timer for the next check")
        #expect(try standAsideDefinitions(db).count == 3, "no definition may be removed while the command is unfinished")

        // The command ends: the next check writes once.
        box.pending = false
        let lastTimer = service.debounceTask   // the timer that wakes next and finds the work finished (no await since the flip)
        let wrote = await waitUntil(timeout: 5) { runs.count >= 1 && service.state == .idle }
        #expect(wrote, "the burst that stood aside never landed; runs \(runs.count)")
        await lastTimer?.value
        #expect(runs.count == 1, "exactly one write once the command is finished; got \(runs.count)")
        #expect(service.debounceTask == lastTimer, "no further timer may be started after the write")
        #expect(!service.testHasPendingUpdate, "the written burst must leave no snapshot")
        #expect(try standAsideDefinitions(db) == ["[^1]: First.", "[^2]: Second."], "the deleted [^3] definition must be gone")
    }

    @Test("""
        U-SA2: a reference change that arrives while the burst stands aside rides along (it replaces the waiting snapshot, the \
        timer stays) and the burst still lands exactly once, with the LATEST references, after the command ends
        """)
    func aChangeWhileTheBurstStandsAsideRidesAlongAndStillLandsOnce() async throws {
        let db = try TestFixtureFactory.createTemporary(content: StandAsideDoc.triple)
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        let box = StructuralWorkBox(pending: true)
        let (service, runs) = await serviceWithKnownTriple(db: db, projectId: projectId, interval: 0.1, box: box)

        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2"], projectId: projectId, fullContent: StandAsideDoc.lastDeleted)
        let stood = await waitUntil(timeout: 5) { service.testBurstDueDuringStructuralWorkCount >= 1 }
        #expect(stood, "the deadline never came (test setup)")
        #expect(runs.count == 0, "the burst wrote while structural work was unfinished; got \(runs.count) write(s)")

        // A second reference is deleted while the burst stands aside.
        service.checkAndUpdateFootnotes(footnoteRefs: ["1"], projectId: projectId, fullContent: StandAsideDoc.bothDeleted)
        let waitingRefs = service.pendingUpdate?.refs
        #expect(waitingRefs == ["1"], "the later change must replace the waiting snapshot; got \(String(describing: waitingRefs))")
        #expect(service.debounceTask?.isCancelled == false, "the burst's timer must still be live")

        box.pending = false
        let wrote = await waitUntil(timeout: 5) { runs.count >= 1 && service.state == .idle }
        #expect(wrote, "the burst that stood aside never landed; runs \(runs.count)")
        await service.debounceTask?.value
        #expect(runs.count == 1, "the burst must land exactly once; got \(runs.count)")
        #expect(try standAsideDefinitions(db) == ["[^1]: First."], "the burst must carry the latest references (only [^1] left)")
    }

    @Test("""
        U-SA3: the command's settle calls resyncNow while the burst is standing aside: that ONE write is the only one, it ends \
        the burst (no snapshot, no timer), and the cancelled timer never writes afterwards, not even once the work is finished
        """)
    func theSettlesResyncTakesOverABurstThatStoodAside() async throws {
        let db = try TestFixtureFactory.createTemporary(content: StandAsideDoc.triple)
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        let box = StructuralWorkBox(pending: true)
        let (service, runs) = await serviceWithKnownTriple(db: db, projectId: projectId, interval: 0.1, box: box)

        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2"], projectId: projectId, fullContent: StandAsideDoc.lastDeleted)
        let stood = await waitUntil(timeout: 5) { service.testBurstDueDuringStructuralWorkCount >= 1 }
        #expect(stood, "the deadline never came (test setup)")
        #expect(runs.count == 0, "the timer wrote before the settle's resync; got \(runs.count) write(s)")

        let standingAsideTimer = service.debounceTask
        await service.resyncNow(footnoteRefs: ["1", "2"], projectId: projectId, fullContent: StandAsideDoc.lastDeleted)
        #expect(runs.count == 1, "the settle's resync must be the one write; got \(runs.count)")
        #expect(!service.testHasPendingUpdate, "the resync must end the burst: no snapshot may be left")
        #expect(service.debounceTask == nil, "the resync must cancel the burst's timer")
        #expect(try standAsideDefinitions(db) == ["[^1]: First.", "[^2]: Second."], "the resync must have removed the [^3] definition")

        // The work finishes; the timer that was standing aside must not write a second time.
        box.pending = false
        await standingAsideTimer?.value   // it was cancelled by the resync and ends at once
        #expect(runs.count == 1, "the timer wrote after the settle's resync; got \(runs.count) write(s) in all")
    }

    @Test("""
        U-SA4 (through the writer): a command starts AFTER the burst's check passed and before its write gets its turn: the \
        writer refuses the write (stillWanted), nothing is written and nothing is posted to the page, the burst is not left \
        waiting, and the next change of the references starts a fresh burst that writes once
        """)
    func aBurstRefusedBecauseACommandStartedDuringItsRunLeavesNoWedge() async throws {
        let stack = try makeStack(content: StandAsideDoc.triple)
        let box = StructuralWorkBox(pending: false)
        // A REAL writer: with none, performFootnoteUpdate writes directly and never asks stillWanted.
        let (service, runs) = await serviceWithKnownTriple(
            db: stack.db, projectId: stack.pid, interval: 0.1, writer: SystemWriter(blockSync: stack.sync), box: box)
        // The first run of the burst starts a command (the hook is awaited right after the run entered, before the write is submitted).
        service.testInFlightHook = {
            runs.count += 1
            if runs.count == 1 { box.pending = true }
        }

        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2"], projectId: stack.pid, fullContent: StandAsideDoc.lastDeleted)
        let ran = await waitUntil(timeout: 5) { runs.count >= 1 && service.state == .idle }
        #expect(ran, "the burst never ran (test setup); runs \(runs.count)")
        let definitionsAfterRefusal = try standAsideDefinitions(stack.db)
        #expect(
            definitionsAfterRefusal.count == 3,
            "the burst wrote although a structural command started before its write: \(definitionsAfterRefusal)")
        #expect(service.lastKnownRefs == ["1", "2", "3"], "a refused write must not commit its references; got \(service.lastKnownRefs)")
        #expect(!service.testHasPendingUpdate, "the refused burst must not be left waiting (no wedge)")

        // The command is over; the same references change again: a fresh burst starts and writes once.
        box.pending = false
        service.checkAndUpdateFootnotes(footnoteRefs: ["1", "2"], projectId: stack.pid, fullContent: StandAsideDoc.lastDeleted)
        #expect(service.testHasPendingUpdate, "the next change must start a fresh burst")
        let wroteAgain = await waitUntil(timeout: 5) { runs.count >= 2 && service.state == .idle }
        #expect(wroteAgain, "the fresh burst never ran; runs \(runs.count)")
        await service.debounceTask?.value
        #expect(runs.count == 2, "the fresh burst must run once; got \(runs.count) runs in all")
        #expect(try standAsideDefinitions(stack.db) == ["[^1]: First.", "[^2]: Second."], "the fresh burst must remove the [^3] definition")
    }

    @Test("""
        U-SA5: resyncNow(forgetCommittedHash: true) renumbers a MOVE that only reorders the references (the renumber ends in the \
        list the service last committed, which the hash guard would skip) and puts the Notes in reading order
        """)
    func aResyncWithForgetCommittedHashRenumbersAMoveTheGuardWouldSkip() async throws {
        let db = try TestFixtureFactory.createTemporary(content: MoveDoc.original)
        let projectId = try TestFixtureFactory.getProjectId(from: db)
        let service = FootnoteSyncService()
        service.configure(database: db, projectId: projectId)
        await service.resyncNow(footnoteRefs: MoveDoc.sequentialLabels, projectId: projectId, fullContent: MoveDoc.original)
        #expect(service.lastKnownRefs == MoveDoc.sequentialLabels, "precondition: 1..\(MoveDoc.labelCount) is committed")
        let log = StandAsideRenumberLog()

        await service.resyncNow(
            footnoteRefs: MoveDoc.movedLabels, projectId: projectId, fullContent: MoveDoc.moved, forgetCommittedHash: true)

        #expect(log.postedTheMoveRenumber, "a resync with forgetCommittedHash was skipped at the hash guard: no renumber was posted: \(log.mappings)")
        let rows = try TestFixtureFactory.fetchBlocks(from: db)
            .filter { $0.isNotes && $0.blockType != .heading }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map(\.markdownFragment)
        #expect(rows.count == MoveDoc.labelCount, "\(rows.count) Notes rows instead of \(MoveDoc.labelCount)")
        for (index, old) in MoveDoc.movedLabels.enumerated() where index < rows.count {
            #expect(
                rows[index].hasPrefix("[^\(index + 1)]:") && rows[index].contains("Note \(old) text."),
                "Notes row \(index + 1) should be '[^\(index + 1)]: Note \(old) text.', it is '\(rows[index])'")
        }
        #expect(
            service.lastKnownRefs == MoveDoc.sequentialLabels,
            "the service does not hold 1..\(MoveDoc.labelCount) afterwards: \(service.lastKnownRefs)")
    }
}
