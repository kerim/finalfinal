//
//  LifecycleQuitSequenceTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C6 (slice-3a-1b-everyday.md sections 4.5 and 7.2 "C6"): QUIT on its own, through
//  `AppDelegate.runQuitSequence(reply:)` with the reply injected (item 31: no test reaches `NSApp.reply`). The
//  joining half (quit arriving while a close or switch runs) is in `LifecycleQuitJoinTests`.
//
//    - item 10: a second Cmd-Q while the first is saving returns `.terminateLater`, starts no second task and
//      replies once. (This proves THIS function; whether AppKit itself tolerates a second
//      `applicationShouldTerminate` while one reply is pending was not found documented either way, so the
//      end-to-end quit test is what proves the real app exits.)
//    - E1 slow FB at quit: FB loses its race, is waited for by the barrier, is applied BEFORE the reply, nothing is
//      counted lost, and the automatic version is made AFTER it (its snapshot ROW contains FB's text); the
//      barrier is still held when the quit replies
//    - a wedged quit still backs up (the editor not answering never costs the automatic version)
//    - C19: delete everything, quit inside the debounce: the sequence runs (the old `content.isEmpty` shortcut
//      did not) and the database has no user blocks; with no project open the shortcut is still taken
//    - a quit whose section operation never clears still replies and still backs up (F applied, no FB)
//    - N5: `applicationWillTerminate` skips its direct flush when the quit ran (`quitTask` / `didFlushForQuit`),
//      keyed on the quit's own state and not on `editorState.activeLifecycle`
//
//  Item 32: every test asserts the quit token armed (the guard path ran), so a shortcut can never pass vacuously.
//

import AppKit
import Foundation
import Testing
@testable import final_final

private final class QuitReplies {
    var values: [Bool] = []
}

extension LifecycleEntryStatic {
    @Suite("Quit sequence — Tier 2 (t-94369a83 3a-1b C6)", .serialized, .timeLimit(.minutes(1)))
    @MainActor
    struct LifecycleQuitSequenceTests {

        /// A delegate wired to the rig the way `ContentView`'s `.task` wires the real one.
        private func makeDelegate(_ rig: LifecycleTailRig) -> AppDelegate {
            let delegate = AppDelegate()
            // No window captured on a bare delegate: the registry then resolves the earliest live registration.
            delegate.registerEditorState(rig.editorState, in: nil)
            delegate.autoBackupService = rig.backup
            return delegate
        }

        // MARK: - Item 10: a second Cmd-Q

        @Test("""
            item 10: a second Cmd-Q while the first is saving returns .terminateLater, starts NO second task and the \
            reply comes once -- a third request after the quit finished does not reply again either
            """)
        func secondCommandQ_startsNoSecondTask_andRepliesOnce() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            let delegate = makeDelegate(rig)
            let replies = QuitReplies()

            try await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.25)) {
                let first = delegate.runQuitSequence(reply: { replies.values.append($0) })
                let task = try #require(delegate.quitTask, "the quit must have started its one task")
                #expect(rig.editorState.activeLifecycle?.kind == .quit, "the guard path ran: the quit token is armed")
                let second = delegate.runQuitSequence(reply: { replies.values.append($0) })

                #expect(first == .terminateLater)
                #expect(second == .terminateLater, "never .terminateCancel: that could cancel the pending reply")
                #expect(delegate.quitTask == task, "the second request must not replace the task")
                #expect(replies.values.isEmpty, "nothing replies before the save is done")

                await task.value
                #expect(replies.values == [true], "exactly one reply, and it is always true (A36)")
                #expect(delegate.didFlushForQuit)

                let third = delegate.runQuitSequence(reply: { replies.values.append($0) })
                #expect(third == .terminateLater)
                #expect(delegate.quitTask == task)
                await Task.yield()
                #expect(replies.values == [true], "a request after the quit finished replies to nothing")
            }

            #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentApplied == 1, "one save, however many Cmd-Q")
        }

        // MARK: - t-eb07cd67: a command after the quit's own sequence started

        @Test("""
            t-eb07cd67: once the quit's OWN sequence has started (nothing was running to join), an Open pressed right \
            behind the Cmd-Q does nothing: it returns .skippedForQuit, opens and posts nothing, and shows no notice
            """)
        func aCommandAfterTheQuitsOwnSequenceStartsDoesNothing() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            let delegate = makeDelegate(rig)
            let replies = QuitReplies()
            let recorder = ProjectCommandRecorder()
            let toasts = ToastCenter()
            rig.editorState.toastCenter = toasts
            var result: ProjectCommandResult?

            await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.25)) {
                #expect(LifecycleEntry.current == nil, "precondition: nothing is running, so the quit takes its own path")
                #expect(delegate.runQuitSequence(reply: { replies.values.append($0) }) == .terminateLater)
                #expect(rig.editorState.activeLifecycle?.kind == .quit)
                result = await ProjectCommands.open(url: URL(fileURLWithPath: "/tmp/after-the-quit.ff"), recorder.environment)
                await delegate.quitTask?.value
            }

            #expect(result == .lifecycle(.skippedForQuit))
            // Only check 4's `noteQuitStarted()` makes the turn drop the request and record this event: without it the command
            // reaches `armLifecycle`, whose refusal ends in the same `.skippedForQuit` result but records no `.droppedForQuit`.
            #expect(
                rig.entryEvents.contains(.droppedForQuit(.projectSwitch)),
                "the quit's own sequence started the quit, so the command is dropped at the turn; events: \(rig.entryEvents)")
            #expect(!rig.entryEvents.contains(.armed(.projectSwitch)), "the command never reached the guard path")
            #expect(recorder.openedURLs.isEmpty, "nothing is opened while the app quits")
            #expect(recorder.posts.isEmpty)
            #expect(toasts.current == nil, "the app is quitting: no notice")
            #expect(replies.values == [true])
        }

        // MARK: - E1: a slow FB at quit

        @Test("""
            E1 slow FB at quit: FB loses its race and is waited for by the barrier, so it is APPLIED before the reply, \
            lifecycleWholeDocumentLost stays 0, the automatic version is made AFTER it (the snapshot ROW has FB's \
            text), and the barrier is still held when the quit replies
            """)
        func slowFB_isAppliedBeforeTheReply_andTheVersionFollowsIt() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            let delegate = makeDelegate(rig)
            let replies = QuitReplies()
            let before = try rig.snapshotCount()
            rig.backup.contentDidChange()   // typing since the last version: what makes a version due
            // The hold is an unsettled editor sequence below FB (FB's own body runs synchronously on the main actor,
            // so holding it would freeze the race timer too). Settled after ~1s; FB's own race is 0.5s at 0.25x.
            let blocker = try #require(rig.writer).reserve()
            let releaser = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1000))
                blocker.settleIfOpen(.noBatch)
            }

            await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.25)) {
                #expect(delegate.runQuitSequence(reply: { replies.values.append($0) }) == .terminateLater)
                #expect(rig.editorState.activeLifecycle?.kind == .quit)
                await delegate.quitTask?.value
            }
            await releaser.value

            #expect(replies.values == [true])
            #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentApplied == 1, "FB was applied before the reply")
            #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentLost == 0, "a slow FB is never a loss (E1)")
            #expect(rig.sync.testLifecycleLossReports == 0)
            let events = rig.writerEvents.events
            let applied = try #require(events.firstIndex { if case .systemApplied = $0 { return true }; return false })
            let reached = try #require(events.firstIndex { $0 == .barrierReached })
            #expect(applied < reached, "FB is applied before the barrier is reached; events: \(events)")
            #expect(try rig.paragraphTexts().contains("fresh Y paragraph."))
            // The automatic version came after FB: a real snapshot ROW (not a stub's call count) holding FB's text.
            #expect(try rig.snapshotCount() == before + 1)
            let preview = try #require(try rig.snapshotPreviews().last)
            #expect(preview.contains("fresh Y paragraph."), "the version must hold FB's text; got: \(preview)")
            // Quit exits holding the barrier.
            #expect(rig.editorState.lifecycleBarrier != nil, "the quit holds the barrier until the process exits")
            #expect(rig.writer?.testOpenBarrierSeq != nil)
        }

        // MARK: - A wedged quit still backs up

        @Test("""
            a wedged quit still backs up: a page that never answers step F's flushReports is given up on at F's bound, \
            the fetch is skipped, FB writes the content on hand, and the automatic version is made before the reply
            """)
        func wedgedQuit_stillMakesTheAutomaticVersion() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            let delegate = makeDelegate(rig)
            let replies = QuitReplies()
            let before = try rig.snapshotCount()
            rig.backup.contentDidChange()
            rig.js.wedgeOn("flushReports")
            rig.fetchAnswer = "THE FETCH MUST NOT HAPPEN"
            rig.editorState.content = "# Alpha\n\nfallback paragraph.\n\n# Beta\n\nfour five six.\n"

            await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.25)) {
                #expect(delegate.runQuitSequence(reply: { replies.values.append($0) }) == .terminateLater)
                #expect(rig.editorState.activeLifecycle?.kind == .quit)
                await delegate.quitTask?.value
            }

            #expect(replies.values == [true], "a wedged editor must not keep the app from quitting")
            #expect(try rig.snapshotCount() == before + 1, "the automatic version is made even with a wedged editor")
            #expect(try rig.paragraphTexts().contains("fallback paragraph."), "FB wrote the content on hand")

            rig.js.releaseWedge()
        }

        // MARK: - C19: delete everything, then quit

        @Test("""
            C19: the user deleted everything and quits inside the 2s debounce (the content on hand is already empty, \
            the database still has the old paragraphs): the sequence runs, F sends the deletion, and the database \
            ends with no user blocks -- the old text does not come back on reopen
            """)
        func deleteAllThenQuit_leavesNoUserBlocks() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            let delegate = makeDelegate(rig)
            let replies = QuitReplies()
            let paragraphIds = try TestFixtureFactory.fetchBlocks(from: rig.db).filter { $0.blockType == .paragraph }.map(\.id)
            #expect(paragraphIds.count == 2, "precondition: the seed has two paragraphs")
            rig.editorState.content = ""     // the content push already carried the deletion to Swift
            // The editor's pending changes: both paragraphs deleted (not a 100% delete, which a guard refuses).
            rig.js.reportOnFlush(BlockChanges(deletes: paragraphIds), to: rig.sync)
            rig.fetchAnswer = ""

            await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.25)) {
                let reply = delegate.runQuitSequence(reply: { replies.values.append($0) })
                #expect(reply == .terminateLater, "an open project with empty content must NOT take the terminate-now shortcut")
                #expect(rig.editorState.activeLifecycle?.kind == .quit, "the guard path ran")
                await delegate.quitTask?.value
            }

            #expect(replies.values == [true])
            let texts = try rig.paragraphTexts()
            #expect(texts.isEmpty, "the deletion must be in the database; got \(texts)")
        }

        @Test("the empty-content shortcut is still taken when NO project is open (nothing to save)")
        func emptyContentWithNoOpenProject_terminatesNow() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            let delegate = makeDelegate(rig)
            rig.editorState.content = ""

            await rig.withEntry {
                LifecycleEntry.environment.hasOpenProject = { false }
                let reply = delegate.runQuitSequence(reply: { _ in })
                #expect(reply == .terminateNow)
                #expect(delegate.quitTask == nil, "no task is started for a shortcut")
                #expect(rig.editorState.activeLifecycle == nil)
            }
        }

        // MARK: - A section operation that never clears

        @Test("""
            a quit whose section operation never clears still replies and still backs up: F ran, NO FB (it would undo \
            the operation), the barrier is taken, the automatic version is made
            """)
        func quitWithAnOperationStillRunning_repliesAndBacksUp() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            let delegate = makeDelegate(rig)
            let replies = QuitReplies()
            let before = try rig.snapshotCount()
            rig.backup.contentDidChange()
            rig.view.structuralUndoController.testSetIsPerforming(true)
            defer { rig.view.structuralUndoController.testSetIsPerforming(false) }

            await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.1)) {
                #expect(delegate.runQuitSequence(reply: { replies.values.append($0) }) == .terminateLater)
                #expect(rig.editorState.activeLifecycle?.kind == .quit)
                await delegate.quitTask?.value
            }

            #expect(replies.values == [true])
            #expect(rig.sync.testWriterLedger.lifecycleWholeDocumentApplied == 0, "no FB while the operation runs")
            #expect(try rig.paragraphTexts().contains("one two three."), "the document is as the operation left it")
            #expect(try rig.snapshotCount() == before + 1, "the automatic version still starts")
            #expect(rig.editorState.lifecycleBarrier != nil, "and the barrier is held to exit")
        }

        // MARK: - N5: applicationWillTerminate

        @Test("""
            N5: applicationWillTerminate skips its direct flush when the quit ran (quitTask set), and still does it \
            as the safety net when no quit ran -- keyed on the quit's own state, not on an armed close token
            """)
        func applicationWillTerminate_skipsTheDirectFlush_onlyForAQuit() async throws {
            let edited = "# Alpha\n\nwritten by the direct flush.\n"
            let notification = Notification(name: NSApplication.willTerminateNotification)

            // Control: no quit ran -> the safety net writes the content on hand.
            let control = try LifecycleTailRig()
            defer { control.shutdown() }
            let controlDelegate = makeDelegate(control)
            control.editorState.content = edited
            controlDelegate.applicationWillTerminate(notification)
            #expect(try control.paragraphTexts().contains("written by the direct flush."), "precondition: the flush works")

            // A quit task is set -> the quit owns the save; the direct flush must not write around its barrier.
            let quitting = try LifecycleTailRig()
            defer { quitting.shutdown() }
            let quittingDelegate = makeDelegate(quitting)
            quitting.editorState.content = edited
            quittingDelegate.quitTask = Task {}
            quittingDelegate.applicationWillTerminate(notification)
            #expect(try !quitting.paragraphTexts().contains("written by the direct flush."), "quitTask set: no direct flush")
            #expect(try quitting.paragraphTexts().contains("one two three."))

            // didFlushForQuit alone also skips it.
            let flushed = try LifecycleTailRig()
            defer { flushed.shutdown() }
            let flushedDelegate = makeDelegate(flushed)
            flushed.editorState.content = edited
            flushedDelegate.didFlushForQuit = true
            flushedDelegate.applicationWillTerminate(notification)
            #expect(try !flushed.paragraphTexts().contains("written by the direct flush."))

            // N5: an armed CLOSE token on the editor state (what the new Getting Started state could look like) is not
            // the quit's state and does not skip the safety net.
            let closing = try LifecycleTailRig()
            defer { closing.shutdown() }
            let closingDelegate = makeDelegate(closing)
            closing.editorState.content = edited
            _ = closing.arm(.close)
            closingDelegate.applicationWillTerminate(notification)
            #expect(try closing.paragraphTexts().contains("written by the direct flush."), "not keyed on activeLifecycle")
        }
    }
}
