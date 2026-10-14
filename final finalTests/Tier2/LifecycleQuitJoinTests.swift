//
//  LifecycleQuitJoinTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C6 (slice-3a-1b-everyday.md sections 4.4 "N3" and 4.5, 7.2 "C6"): a QUIT that
//  arrives while a close or project switch is running JOINS it, through `AppDelegate.runQuitSequence(reply:)` with
//  the reply injected (item 31). Quit on its own is in `LifecycleQuitSequenceTests`.
//
//    - quit joins a switch before its `perform` ran (item 35, N6): ONE FB in total, `perform` is NOT called (so no
//      write to the other project), the old project is backed up exactly once, with the backup service the
//      lifecycle CAPTURED (N4), never the app delegate's (here replaced by a decoy tied to the other project)
//    - quit joins after `perform` started: the tail makes the version (N3: bounded, started) and stands down, quit
//      does not make a second one
//    - N3: with less than 0.5s of the shared deadline left, the tail does NOT start its version, leaves the backup
//      service alone, and the quit makes it (N40: always attempted, the
//      5-minute throttle still applies)
//    - quit joins a close that gave up on a section operation before the quit's token replaced its own: quit runs
//      its own sequence on that editor and the user's typing is saved
//
//  Item 32: every test asserts the lifecycle armed (`.armed` event) and the quit joined (quit token on the editor
//  state), so a pass-through can never make one pass vacuously.
//

import Foundation
import GRDB
import Testing
@testable import final_final

private final class QuitReplies {
    var values: [Bool] = []
}

private final class Counter {
    var value = 0
}

extension LifecycleEntryStatic {
    @Suite("Quit joins a close or switch — Tier 2 (t-94369a83 3a-1b C6)", .serialized, .timeLimit(.minutes(1)))
    @MainActor
    struct LifecycleQuitJoinTests {

        private func makeDelegate(_ rig: LifecycleTailRig) -> AppDelegate {
            let delegate = AppDelegate()
            // No window captured on a bare delegate: the registry then resolves the earliest live registration.
            delegate.registerEditorState(rig.editorState, in: nil)
            return delegate
        }

        /// Counts the calls to the host's quit backup, then forwards to the real one (this view's backup service).
        private func countQuitBackups(_ rig: LifecycleTailRig, _ counter: Counter) throws {
            var host = try #require(rig.editorState.lifecycleHost)
            let original = host.backupForQuit
            host.backupForQuit = {
                counter.value += 1
                await original()
            }
            rig.editorState.lifecycleHost = host
        }

        private func snapshotCount(_ db: ProjectDatabase) throws -> Int {
            try db.dbWriter.read { database in
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM snapshot") ?? 0
            }
        }

        // MARK: - Joining before perform ran (N6, N4)

        @Test("""
            quit joins a switch BEFORE its perform runs (item 35, N6, N4): one FB in total, perform is not called so \
            nothing is written to the other project, the old project is backed up exactly once -- by the quit, with \
            the backup service the lifecycle captured, not the app delegate's (a decoy tied to the other project)
            """)
        func quitJoinsASwitchBeforePerform_oneFB_noWriteToB_aBackedUpOnce() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            // B: the project the switch would open, and a decoy backup service (what the app delegate's weak
            // reference points to after a Getting Started swap) configured for it.
            let other = try TestFixtureFactory.createTemporary(content: "# Bee\n\nbee text.\n")
            let otherPid = try TestFixtureFactory.getProjectId(from: other)
            let decoy = AutoBackupService()
            decoy.configure(database: other, projectId: otherPid)
            decoy.contentDidChange()
            defer { decoy.reset() }
            let delegate = makeDelegate(rig)
            delegate.autoBackupService = decoy
            let replies = QuitReplies()
            let backups = Counter()
            let before = try rig.snapshotCount()
            let otherBefore = try snapshotCount(other)
            rig.backup.contentDidChange()
            var performed = 0
            var outcome: LifecycleRunOutcome?
            // A running section operation holds the switch inside its save sequence (step 1, a 0.75s wait at this
            // scale) so the quit deterministically joins BEFORE perform; it clears right after the join.
            let controller = rig.view.structuralUndoController
            controller.testSetIsPerforming(true)
            defer { controller.testSetIsPerforming(false) }

            try await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.25)) {
                try countQuitBackups(rig, backups)
                let switching = Task { @MainActor in
                    try await LifecycleEntry.run(kind: .projectSwitch) {
                        performed += 1
                        try? other.replaceBlocks(BlockParser.parse(markdown: "# Bee\n\nWRITTEN BY PERFORM.\n", projectId: otherPid), for: otherPid)
                        return .open
                    }
                }
                await LifecycleEntryHarness.waitUntil("the switch to arm") { LifecycleEntry.current != nil }
                #expect(LifecycleEntry.current?.token.kind == .projectSwitch, "precondition: the switch is running")

                let reply = delegate.runQuitSequence(reply: { replies.values.append($0) })
                #expect(reply == .terminateLater)
                #expect(rig.editorState.activeLifecycle?.kind == .quit, "the quit joined: its token replaced the switch's")
                controller.testSetIsPerforming(false)
                outcome = try await switching.value
                await delegate.quitTask?.value
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran")
            #expect(rig.entryEvents.contains(.performSkippedForQuit(.projectSwitch)), "N6: perform skipped; events: \(rig.entryEvents)")
            #expect(outcome == .skippedForQuit)
            #expect(performed == 0, "perform must not run once a quit joined before it")
            #expect(replies.values == [true])
            #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentApplied == 1, "exactly one FB, the switch's own; the quit does not flush again")
            #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentLost == 0)
            #expect(try rig.paragraphTexts().contains("fresh Y paragraph."))
            // A is backed up exactly once, by the quit, through the CAPTURED service (a row in A's database).
            #expect(try rig.snapshotCount() == before + 1)
            #expect(backups.value == 1)
            // Nothing reached B: no perform, and the decoy was never used.
            #expect(try snapshotCount(other) == otherBefore, "the app delegate's weak backup service must not be used (N4)")
            let otherParagraphs = try TestFixtureFactory.fetchBlocks(from: other).filter { $0.blockType == .paragraph }.map(\.textContent)
            #expect(otherParagraphs == ["bee text."], "no write to B")
            // The tail never ran, so the old project is exactly as the quit found it.
            #expect(rig.editorState.content == LifecycleTailRig.seed)
            #expect(rig.editorState.lifecycleBarrier != nil, "the quit holds the barrier until exit")
        }

        // MARK: - Joining after perform started (N3)

        @Test("""
            quit joins AFTER perform started: the switch's tail makes the automatic version once (N3: started, bounded) \
            and stands down; the quit does not make a second one, and replies
            """)
        func quitJoinsAfterPerform_theTailBacksUp_onceOnly() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            let delegate = makeDelegate(rig)
            let replies = QuitReplies()
            let backups = Counter()
            let before = try rig.snapshotCount()
            rig.backup.contentDidChange()
            let gate = LifecycleEntryHarness.Gate()
            var performEntered = false
            var outcome: LifecycleRunOutcome?

            try await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.25)) {
                try countQuitBackups(rig, backups)
                let switching = Task { @MainActor in
                    try await LifecycleEntry.run(kind: .projectSwitch) {
                        performEntered = true
                        await gate.wait()
                        return .open
                    }
                }
                await LifecycleEntryHarness.waitUntil("perform to be entered") { performEntered }
                #expect(rig.editorState.lifecycleFlushDoneFor != nil, "precondition: the save sequence is done")

                #expect(delegate.runQuitSequence(reply: { replies.values.append($0) }) == .terminateLater)
                #expect(rig.editorState.activeLifecycle?.kind == .quit)
                gate.open()
                outcome = try await switching.value
                await delegate.quitTask?.value
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran")
            #expect(outcome == .performed, "perform had already started, so the switch carried on to its tail")
            #expect(replies.values == [true])
            #expect(try rig.snapshotCount() == before + 1, "A is backed up exactly once")
            #expect(backups.value == 0, "the tail made it: the quit must not make a second version")
            #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentApplied == 1)
            #expect(rig.editorState.content == LifecycleTailRig.seed, "the open tail stood down before the new project was set up")
            #expect(rig.editorState.lifecycleBarrier != nil, "the tail must not release or retire what the quit holds")
        }

        @Test("""
            N3: with less than 0.5s of the shared deadline left when a quit has joined, the tail does NOT start its \
            version and leaves the backup service alone, and the quit makes it (N40): one version, made by the quit
            """)
        func joinedTailBackup_isSkippedWhenAlmostNoTimeRemains_theQuitMakesIt() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            let delegate = makeDelegate(rig)
            let replies = QuitReplies()
            let backups = Counter()
            let before = try rig.snapshotCount()
            rig.backup.contentDidChange()
            let gate = LifecycleEntryHarness.Gate()
            var performEntered = false

            try await rig.withEntry(bounds: LifecycleBounds.production) {
                try countQuitBackups(rig, backups)
                let switching = Task { @MainActor in
                    try await LifecycleEntry.run(kind: .projectSwitch) {
                        performEntered = true
                        await gate.wait()
                        return .open
                    }
                }
                await LifecycleEntryHarness.waitUntil("perform to be entered") { performEntered }

                #expect(delegate.runQuitSequence(reply: { replies.values.append($0) }) == .terminateLater)
                #expect(rig.editorState.activeLifecycle?.kind == .quit)
                // The shared deadline is (almost) spent by the time the tail runs.
                LifecycleEntry.current?.deadline.tighten(to: LifecycleDeadline(total: 0.01))
                gate.open()
                _ = try await switching.value
                await delegate.quitTask?.value
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran")
            #expect(replies.values == [true])
            #expect(backups.value == 1, "the tail skipped its version, so the quit made it (N40: always attempted)")
            #expect(try rig.snapshotCount() == before + 1, "still exactly one version")
        }

        // MARK: - Joining a close that gave up

        @Test("""
            quit joins a CLOSE that is waiting on a section operation and gives up before saving (the quit's token \
            replaced its own): the close stands down without a notice and the quit runs its OWN sequence on that \
            editor -- the typing is saved, perform never ran, and the quit replies
            """)
        func quitJoinsACloseThatGaveUp_runsItsOwnSequence() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            let delegate = makeDelegate(rig)
            let replies = QuitReplies()
            let before = try rig.snapshotCount()
            rig.backup.contentDidChange()
            let controller = rig.view.structuralUndoController
            controller.testSetIsPerforming(true)
            defer { controller.testSetIsPerforming(false) }
            // The section operation clears after the close gave up (0.6s at 0.2x) and while the quit's own wait runs.
            let releaser = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1000))
                controller.testSetIsPerforming(false)
            }
            var performed = 0
            var outcome: LifecycleRunOutcome?

            try await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.2)) {
                let closing = Task { @MainActor in
                    try await LifecycleEntry.run(kind: .close) {
                        performed += 1
                        return .close
                    }
                }
                await LifecycleEntryHarness.waitUntil("the close to arm") { LifecycleEntry.current != nil }
                #expect(LifecycleEntry.current?.token.kind == .close, "precondition: the close is running")

                #expect(delegate.runQuitSequence(reply: { replies.values.append($0) }) == .terminateLater)
                #expect(rig.editorState.activeLifecycle?.kind == .quit)
                outcome = try await closing.value
                await delegate.quitTask?.value
            }
            await releaser.value

            #expect(rig.entryEvents.first == .armed(.close), "the guard path ran")
            #expect(outcome == .cancelled, "the close gave up on the section operation")
            #expect(performed == 0)
            #expect(rig.toasts.current == nil, "the close stood down: the quit owns the editor, no cancel notice")
            #expect(replies.values == [true])
            #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentApplied == 1, "the quit's own sequence wrote the document")
            #expect(try rig.paragraphTexts().contains("fresh Y paragraph."), "the typing is saved")
            #expect(try rig.snapshotCount() == before + 1)
        }
    }
}
