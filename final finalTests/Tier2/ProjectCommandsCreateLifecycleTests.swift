//
//  ProjectCommandsCreateLifecycleTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C8a (slice-3a-1b-everyday.md sections 5.5, 7.2 "C8a" and 9 steps 9, 11, 12):
//  Save As (E4), Finder open (E5), New Project (E7) and Import (E8) against the REAL save sequence and the REAL tails,
//  on a bare `ContentView` wired to a temporary project database (`LifecycleTailRig`, `LifecycleFlushHarness`):
//
//    - "the old project saved first": at the instant `perform` creates the new project (or copies the package for
//      Save As) the OLD project's database already holds what the editor had (FB, through the ordered queue), so the
//      copy contains the typing and the new project starts from a saved original
//    - "and backed up first": the create / open tail makes the old project's automatic version, a real snapshot ROW
//      that holds that text (made after FB, N30), and nothing is left armed or held
//    - U5 for the four commands: a section operation that never clears CANCELS them -- `perform` is never called
//      (nothing copied, opened or created, no post, no alert) and the generic cancel notice is shown (section 8)
//
//  Item 32: every test asserts the `.armed` event so a pass-through can never make one pass vacuously. The seed the
//  create tail puts into the new editor is pinned in `LifecycleOpenTailTests`; here Import is checked up to the host
//  (`ProjectCommandsCreateTests`) so no test writes through `DocumentManager.shared`.
//

import Foundation
import Testing
@testable import final_final

private struct LifecycleCommandBoom: Error, Equatable {}

extension LifecycleEntryStatic {
    @Suite("ProjectCommands create-style commands through the real tails — Tier 2 (t-94369a83 3a-1b C8a)", .serialized, .timeLimit(.minutes(1)))
    @MainActor
    struct ProjectCommandsCreateLifecycleTests {

        private let url = URL(fileURLWithPath: "/tmp/command-lifecycle-c.ff")
        private let source = URL(fileURLWithPath: "/tmp/command-lifecycle-a.ff")

        // MARK: - Old project saved and backed up first

        @Test("""
            E7: New Project saves the OLD project first (it already holds the fresh text when the new project is created) and \
            backs it up (a real snapshot row with that text) before opening the new one
            """)
        func newProjectSavesAndBacksUpTheOldProjectFirst() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            let recorder = ProjectCommandRecorder()
            let before = try rig.snapshotCount()
            rig.backup.contentDidChange()
            var oldProjectHadFreshTextWhenCreated: Bool?
            recorder.onNewProject = {
                oldProjectHadFreshTextWhenCreated = try? rig.paragraphTexts().contains("fresh Y paragraph.")
            }
            var result: ProjectCommandResult?

            await rig.withEntry {
                result = await ProjectCommands.newProject(at: url, title: "C", recorder.environment)
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
            #expect(result == .lifecycle(.performed))
            #expect(recorder.order == ["newProject", "post:projectDidCreate"], "order: \(recorder.order)")
            #expect(oldProjectHadFreshTextWhenCreated == true, "the old project was saved BEFORE the new one was created")
            #expect(try rig.snapshotCount() == before + 1, "the old project's automatic version was made")
            let rows = try rig.snapshotPreviews()
            #expect(rows.last?.contains("fresh Y paragraph.") == true, "the version was made after FB, so it holds the fresh text; got \(rows)")
            #expect(!rig.entryEvents.contains(.safetyNetReleasedBarrier), "the tail retired the writer: nothing for the net")
            #expect(rig.editorState.activeLifecycle == nil)
            #expect(rig.editorState.lifecycleBarrier == nil)
            #expect(rig.editorState.lifecycleBackupDoneFor != nil)
        }

        @Test("""
            E4: Save As makes its copy AFTER the save: at the instant the package is copied the old project's database already \
            holds the fresh text, and the old project's automatic version (a real row) follows
            """)
        func saveAsCopiesAfterTheSaveAndBacksUpTheOriginal() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            let recorder = ProjectCommandRecorder()
            let before = try rig.snapshotCount()
            rig.backup.contentDidChange()
            var databaseHadFreshTextAtCopy: Bool?
            recorder.onCopy = {
                databaseHadFreshTextAtCopy = try? rig.paragraphTexts().contains("fresh Y paragraph.")
            }
            var result: ProjectCommandResult?

            await rig.withEntry {
                result = await ProjectCommands.saveAs(from: source, to: url, recorder.environment)
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
            #expect(result == .lifecycle(.performed))
            #expect(recorder.order == ["copy", "open", "rename", "post:projectDidOpen"], "order: \(recorder.order)")
            #expect(databaseHadFreshTextAtCopy == true, "the copy contains the typing made just before Save As")
            #expect(try rig.snapshotCount() == before + 1)
            #expect(try rig.snapshotPreviews().last?.contains("fresh Y paragraph.") == true)
            #expect(!rig.entryEvents.contains(.safetyNetReleasedBarrier))
            #expect(rig.editorState.activeLifecycle == nil)
            #expect(rig.editorState.lifecycleBarrier == nil)
        }

        @Test("""
            must-fix #23 with the real tails: a title update that fails after the open still posts, runs the open tail (the \
            old project is backed up) and leaves nothing armed or held
            """)
        func saveAsTitleFailureStillRunsTheRealTail() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            let recorder = ProjectCommandRecorder()
            recorder.renameError = LifecycleCommandBoom()
            let before = try rig.snapshotCount()
            rig.backup.contentDidChange()
            var result: ProjectCommandResult?

            await rig.withEntry {
                result = await ProjectCommands.saveAs(from: source, to: url, recorder.environment)
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
            #expect(result == .lifecycle(.performed))
            #expect(recorder.errorAlerts.isEmpty)
            #expect(recorder.posts.count == 1, "the post was made")
            #expect(try rig.snapshotCount() == before + 1, "the open tail ran: the old project was backed up, not aborted")
            #expect(rig.editorState.activeLifecycle == nil)
            #expect(rig.editorState.lifecycleBarrier == nil)
        }

        // MARK: - U5: a running section operation cancels all four

        /// A rig with a section operation that "never clears", a toast center to read, and the polls answered.
        private func rigWithRunningOperation() throws -> (rig: LifecycleFlushHarness, toasts: ToastCenter) {
            let rig = try LifecycleFlushHarness()
            rig.js.answer("flushPendingBlockChanges", true)
            rig.fetchAnswer = "# Alpha\n\nfresh Y paragraph.\n\n# Beta\n\nfour five six.\n"
            let toasts = ToastCenter()
            rig.editorState.toastCenter = toasts
            rig.controller.testSetIsPerforming(true)
            return (rig, toasts)
        }

        @Test("U5 Save As: a section operation that never clears CANCELS it -- no copy is made, nothing opened or posted")
        func saveAsIsCancelled_performNeverCalled() async throws {
            let (rig, toasts) = try rigWithRunningOperation()
            defer { rig.controller.testSetIsPerforming(false) }
            let recorder = ProjectCommandRecorder()
            var result: ProjectCommandResult?

            await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.2)) {
                result = await ProjectCommands.saveAs(from: source, to: url, recorder.environment)
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
            #expect(result == .lifecycle(.cancelled))
            #expect(recorder.order.isEmpty, "perform never called: no copy, no open, no post, no alert; got \(recorder.order)")
            #expect(toasts.current?.message == ToastFactory.lifecycleCancelled().message)
            #expect(!rig.log.contains { $0.hasPrefix("tail:") }, "log: \(rig.log)")
            #expect(rig.editorState.activeLifecycle == nil)
        }

        @Test("U5 Finder open: the same -- the other project is not opened, no failure is reported")
        func finderOpenIsCancelled_performNeverCalled() async throws {
            let (rig, toasts) = try rigWithRunningOperation()
            defer { rig.controller.testSetIsPerforming(false) }
            let recorder = ProjectCommandRecorder()
            recorder.currentProjectURL = source
            var result: ProjectCommandResult?

            await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.2)) {
                result = await ProjectCommands.openFromFinder(url: url, recorder.environment)
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
            #expect(result == .lifecycle(.cancelled))
            #expect(recorder.order.isEmpty, "perform never called; got \(recorder.order)")
            #expect(toasts.current?.message == ToastFactory.lifecycleCancelled().message)
            #expect(rig.editorState.activeLifecycle == nil)
        }

        @Test("U5 New Project: the same -- no project is created, no alert")
        func newProjectIsCancelled_performNeverCalled() async throws {
            let (rig, toasts) = try rigWithRunningOperation()
            defer { rig.controller.testSetIsPerforming(false) }
            let recorder = ProjectCommandRecorder()
            var result: ProjectCommandResult?

            await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.2)) {
                result = await ProjectCommands.newProject(at: url, title: "C", recorder.environment)
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
            #expect(result == .lifecycle(.cancelled))
            #expect(recorder.order.isEmpty, "perform never called; got \(recorder.order)")
            #expect(toasts.current?.message == ToastFactory.lifecycleCancelled().message)
            #expect(rig.editorState.activeLifecycle == nil)
        }

        @Test("U5 Import: the same -- no project is created and the imported content is not saved anywhere")
        func importIsCancelled_performNeverCalled() async throws {
            let (rig, toasts) = try rigWithRunningOperation()
            defer { rig.controller.testSetIsPerforming(false) }
            let recorder = ProjectCommandRecorder()
            var result: ProjectCommandResult?

            await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.2)) {
                result = await ProjectCommands.importMarkdown("# Imported\n", to: url, recorder.environment)
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
            #expect(result == .lifecycle(.cancelled))
            #expect(recorder.order.isEmpty, "perform never called; got \(recorder.order)")
            #expect(toasts.current?.message == ToastFactory.lifecycleCancelled().message)
            #expect(toasts.current?.style == .warning)
            #expect(rig.editorState.activeLifecycle == nil)
        }
    }
}
