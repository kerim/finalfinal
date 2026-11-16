//
//  ProjectCommandsCancelTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C7a (slice-3a-1b-everyday.md sections 7.2 "C7a", 8 and 9): U5 -- a section
//  operation (delete, duplicate, version restore) that never clears makes Close Project, Open Project and Open
//  Recent CANCEL, with the plain notice, and the command's `perform` is NEVER CALLED.
//
//  "`perform` never called" is asserted on what `perform` does (the project is not closed, the other project is not
//  opened, nothing is posted, no failure is reported), not on a project URL (B32). The save sequence runs for real
//  against the real `StructuralUndoController` latch (`LifecycleFlushHarness`), with the section-operation bound
//  scaled to 0.6s.
//
//  Each cancelled command also shows the section 8 string for ITS kind (a close has its own wording, B17) through
//  the editor state's own toast center (item 38), leaves nothing armed or held, and a retry after the operation
//  cleared goes through ("Try again in a moment").
//

import Foundation
import Testing
@testable import final_final

extension LifecycleEntryStatic {
    @Suite("ProjectCommands cancel on a running section operation — Tier 2 (t-94369a83 3a-1b C7a, U5)", .serialized, .timeLimit(.minutes(1)))
    @MainActor
    struct ProjectCommandsCancelTests {

        private static let fresh = "# Alpha\n\nfresh Y paragraph.\n\n# Beta\n\nfour five six.\n"
        private let url = URL(fileURLWithPath: "/tmp/command-cancel-b.ff")

        /// A rig with a section operation that "never clears", a toast center to read, and the polls answered.
        private func rigWithRunningOperation() throws -> (rig: LifecycleFlushHarness, toasts: ToastCenter) {
            let rig = try LifecycleFlushHarness()
            rig.js.answer("flushPendingBlockChanges", true)
            rig.fetchAnswer = Self.fresh
            let toasts = ToastCenter()
            rig.editorState.toastCenter = toasts
            rig.controller.testSetIsPerforming(true)
            return (rig, toasts)
        }

        @Test("""
            U5 close: a section operation that never clears CANCELS Cmd-W -- perform never called (the project is not \
            closed, nothing posted), the close notice is shown, nothing is left armed or held
            """)
        func closeIsCancelled_performNeverCalled() async throws {
            let (rig, toasts) = try rigWithRunningOperation()
            defer { rig.controller.testSetIsPerforming(false) }
            let recorder = ProjectCommandRecorder()
            var result: ProjectCommandResult?

            await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.2)) {
                result = await ProjectCommands.close(recorder.environment)
                #expect(LifecycleEntry.current == nil, "the slot is free again as soon as the command returns")
            }

            #expect(rig.entryEvents.first == .armed(.close), "the guard path ran (item 32)")
            #expect(result == .lifecycle(.cancelled))
            #expect(recorder.closes == 0, "perform never called: the project must not be closed")
            #expect(recorder.posts.isEmpty, "perform never called: no .projectDidClose post")
            #expect(toasts.current?.message == ToastFactory.lifecycleCloseCancelled().message)
            #expect(toasts.current?.style == .warning)
            #expect(!rig.log.contains { $0.hasPrefix("tail:") }, "no tail may run; log: \(rig.log)")
            #expect(rig.editorState.activeLifecycle == nil)
            #expect(rig.editorState.lifecycleBarrier == nil)
        }

        @Test("""
            U5 open: the same for Cmd-O -- perform never called (the other project is not opened, no failure reported), \
            the other notice is shown
            """)
        func openIsCancelled_performNeverCalled() async throws {
            let (rig, toasts) = try rigWithRunningOperation()
            defer { rig.controller.testSetIsPerforming(false) }
            let recorder = ProjectCommandRecorder()
            var result: ProjectCommandResult?

            await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.2)) {
                result = await ProjectCommands.open(url: url, recorder.environment)
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
            #expect(result == .lifecycle(.cancelled))
            #expect(recorder.openedURLs.isEmpty, "perform never called: no project was opened")
            #expect(recorder.posts.isEmpty)
            #expect(recorder.reported.isEmpty, "a cancel is not an open failure: no error sheet")
            #expect(toasts.current?.message == ToastFactory.lifecycleCancelled().message)
            #expect(!rig.log.contains { $0.hasPrefix("tail:") }, "log: \(rig.log)")
            #expect(rig.editorState.activeLifecycle == nil)
        }

        @Test("U5 open recent: the same for File > Open Recent")
        func openRecentIsCancelled_performNeverCalled() async throws {
            let (rig, toasts) = try rigWithRunningOperation()
            defer { rig.controller.testSetIsPerforming(false) }
            let recorder = ProjectCommandRecorder()
            var result: ProjectCommandResult?

            await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.2)) {
                result = await ProjectCommands.openRecent(ProjectCommandRecorder.recentEntry(), recorder.environment)
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
            #expect(result == .lifecycle(.cancelled))
            #expect(recorder.openedRecentIds.isEmpty, "perform never called")
            #expect(recorder.posts.isEmpty)
            #expect(recorder.reported.isEmpty)
            #expect(toasts.current?.message == ToastFactory.lifecycleCancelled().message)
        }

        @Test("U5: a retry after the section operation cleared goes through (Try again in a moment)")
        func retryAfterTheOperationClearedCloses() async throws {
            let (rig, toasts) = try rigWithRunningOperation()
            defer { rig.controller.testSetIsPerforming(false) }
            let recorder = ProjectCommandRecorder()
            var first: ProjectCommandResult?
            var second: ProjectCommandResult?

            await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.2)) {
                first = await ProjectCommands.close(recorder.environment)
                rig.controller.testSetIsPerforming(false)
                toasts.dismissCurrent()
                second = await ProjectCommands.close(recorder.environment)
            }

            #expect(first == .lifecycle(.cancelled))
            #expect(second == .lifecycle(.performed))
            #expect(rig.entryEvents.filter { $0 == .armed(.close) }.count == 2, "both attempts armed")
            #expect(recorder.closes == 1, "only the retry closed the project")
            #expect(recorder.posts.count == 1)
            #expect(try rig.paragraphTexts().contains("fresh Y paragraph."), "the retry saved through the queue first")
            #expect(rig.log.contains("tail:close"))
            #expect(rig.editorState.activeLifecycle == nil)
            #expect(rig.editorState.lifecycleBarrier == nil)
        }
    }
}
