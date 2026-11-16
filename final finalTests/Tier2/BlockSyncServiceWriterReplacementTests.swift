//
//  BlockSyncServiceWriterReplacementTests.swift
//  final finalTests
//
//  t-b7e3c791: the three places that replace the service's `DocumentWriter` -- `configure` (a different database or project),
//  `reconfigure` (a project switch) and `ensureWriter` (Markdown's safety net) -- all go through
//  `BlockSyncService.replaceWriter(database:projectId:retiringOldWriterFor:)`. One test per call site, each pinning the same four
//  things the routine does, so a change to how a writer is retired cannot slip past one of them:
//
//    1. the OLD writer is retired, and with the reason that call site owns (`.writerReplaced` for `configure` and `ensureWriter`,
//       `.projectSwitch` for `reconfigure`) -- seen as the one `.skipped` event the old writer emits for the turn it had reserved;
//    2. a NEW writer is installed for the new database and project, and it asserts MainActor callers;
//    3. the new writer continues the old one's sequence numbers;
//    4. the four DEBUG test knobs wired onto the old writer (event handler, late-after, drain timeout, late-abandon-after) are carried
//       onto the new one.
//
//  No WebView is loaded and no JS runs: only the service's writer is observed, through `testWriterHandle` and the writer's own
//  DEBUG accessors, the same way `MarkdownBlockWriteTests` and `DocumentWriterMainActorCallerTests` do.
//

import Foundation
import Testing
@testable import final_final

@Suite("Replacing the document writer — Tier 2 (t-b7e3c791)", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct BlockSyncServiceWriterReplacementTests {

    // The knob values are far beyond the length of any test, so none of the timers they arm can fire.
    private static let lateAfter: TimeInterval = 600
    private static let drainTimeout: TimeInterval = 700
    private static let lateAbandonAfter: TimeInterval = 900

    /// A configured service whose live writer has one reserved turn and the four test knobs set, plus a second project to move to.
    private struct Rig {
        let stack: TestStack
        let otherDb: ProjectDatabase
        let otherPid: String
        let old: DocumentWriter
        let events: WriterEventRecorder
        /// The turn reserved on the old writer; it stays reserved so retiring the writer has something to skip.
        let reservedTicket: WriterTicket
        let reservedSeq: UInt64
        /// The old writer's next sequence number: what the new writer must start from.
        let nextBefore: UInt64
        var sync: BlockSyncService { stack.sync }
    }

    private func arrange() throws -> Rig {
        let stack = try makeStack()
        let otherDb = try TestFixtureFactory.createTemporary(content: "# Other\n\nOther project.")
        let otherPid = try TestFixtureFactory.getProjectId(from: otherDb)
        let old = try #require(stack.sync.testWriterHandle)

        let events = WriterEventRecorder()
        stack.sync.testWriterEventHandler = { event in events.append(event) }
        stack.sync.testWriterLateAfterSeconds = Self.lateAfter
        stack.sync.testWriterLateAbandonAfterSeconds = Self.lateAbandonAfter
        old.testDrainTimeoutSeconds = Self.drainTimeout

        let ticket = old.reserve()
        return Rig(
            stack: stack, otherDb: otherDb, otherPid: otherPid, old: old, events: events,
            reservedTicket: ticket, reservedSeq: ticket.seq, nextBefore: old.nextSequence)
    }

    private func skippedEvents(_ events: WriterEventRecorder) -> [WriterEvent] {
        events.all.filter { if case .skipped = $0 { return true }; return false }
    }

    /// The four things every call site must leave true after it replaced the writer, with `reason` the one it retires the old one with.
    private func expectReplaced(_ rig: Rig, retiredWith reason: SkipReason, sourceLocation: SourceLocation = #_sourceLocation) throws {
        // 1. the old writer is retired, and its reserved turn was skipped with this call site's reason.
        #expect(rig.old.isRetired, "the old writer is retired", sourceLocation: sourceLocation)
        #expect(
            skippedEvents(rig.events) == [.skipped([rig.reservedSeq], reason)],
            "retiring the old writer skipped its reserved turn with \(reason), and nothing else was skipped",
            sourceLocation: sourceLocation)

        // 2. a new writer for the new database and project.
        let new = try #require(rig.sync.testWriterHandle, sourceLocation: sourceLocation)
        #expect(new !== rig.old, "a new writer was installed", sourceLocation: sourceLocation)
        #expect(!new.isRetired, sourceLocation: sourceLocation)
        #expect(new.database === rig.otherDb && new.projectId == rig.otherPid, "for the new database and project", sourceLocation: sourceLocation)
        #expect(new.assertsMainActorCallers, "it asserts MainActor callers", sourceLocation: sourceLocation)

        // 3. sequence continuity.
        #expect(new.nextSequence == rig.nextBefore, "sequence numbers continue across the replacement", sourceLocation: sourceLocation)

        // 4. the DEBUG test knobs wired onto the old writer are on the new one.
        #expect(new.testLateAfterSeconds == Self.lateAfter, sourceLocation: sourceLocation)
        #expect(new.testDrainTimeoutSeconds == Self.drainTimeout, sourceLocation: sourceLocation)
        #expect(new.testLateAbandonAfterSeconds == Self.lateAbandonAfter, sourceLocation: sourceLocation)
        // The carried event handler is the same recorder: a skip on the NEW writer lands in it.
        let nextTicket = new.reserve()
        new.skipAllReserved(reason: .editorReplaced)
        #expect(
            rig.events.all.contains(.skipped([nextTicket.seq], .editorReplaced)),
            "the event handler was carried onto the new writer", sourceLocation: sourceLocation)
    }

    @Test("""
        configure onto another database retires the old writer as .writerReplaced and installs a new one, with the sequence \
        numbers and the test knobs carried over
        """)
    func configureOntoAnotherProjectReplacesTheWriter() throws {
        let rig = try arrange()
        rig.sync.configure(database: rig.otherDb, projectId: rig.otherPid, webView: rig.stack.webView)
        try expectReplaced(rig, retiredWith: .writerReplaced)
    }

    @Test("""
        reconfigure retires the old writer as .projectSwitch and installs a new one, with the sequence numbers and the test \
        knobs carried over
        """)
    func reconfigureReplacesTheWriter() async throws {
        let rig = try arrange()
        await rig.sync.reconfigure(database: rig.otherDb, projectId: rig.otherPid)
        try expectReplaced(rig, retiredWith: .projectSwitch)
    }

    @Test("""
        ensureWriter for another project retires the old writer as .writerReplaced and installs a new one, with the sequence \
        numbers and the test knobs carried over
        """)
    func ensureWriterReplacesTheWriter() throws {
        let rig = try arrange()
        let outcome = rig.sync.ensureWriter(
            database: rig.otherDb, projectId: rig.otherPid, lifecycleActive: false, editorProjectId: rig.otherPid)
        #expect(outcome == .installed)
        try expectReplaced(rig, retiredWith: .writerReplaced)
    }
}
