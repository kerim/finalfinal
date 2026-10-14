//
//  ProjectCommandsGettingStartedTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C8b (slice-3a-1b-everyday.md sections 5.5 "E9" and "N2", 7.2 "C8b", obligations 12,
//  N1, N2, N7): Help > Getting Started and every way OUT of Getting Started, against the REAL save sequence and the
//  REAL tails, on a bare `ContentView` wired to a temporary project database (`LifecycleTailRig`).
//
//    - E9: with a regular project open, Help > Getting Started saves and BACKS UP that project first (a real snapshot
//      ROW holding the fresh text), opens Getting Started, runs the close tail without `onProjectClosed`, and leaves no
//      token and no barrier. `wasGettingStarted` is captured at arm (N1): by the time the tail runs `DocumentManager`
//      already says Getting Started, which the tests model by flipping the answer inside `perform`.
//    - Getting Started to Getting Started passes through: it is already open, nothing is armed (the re-copy is the
//      known bug t-d844594f, not fixed here).
//    - N2, the reverse swap (Getting Started to a regular project): the old state gets the CLOSE tail, never the open
//      tail. Pinned through Open Project and Import with the real tails: no automatic version, no `onProjectClosed`,
//      the undo history left alone, nothing seeded into the discarded editor.
//    - Import from Getting Started: the imported content reaches the new project through ITS DATABASE, written before
//      the post, and the NEW ContentView finds it on mount.
//    - The Getting Started close: nothing to save, no lifecycle; the token-less close resets the view, backs nothing up
//      and calls `onProjectClosed`, with no project left in `DocumentManager` (N7).
//
//  Item 32: every guarded test asserts the `.armed` entry event so a pass-through can never make one pass vacuously.
//

import Foundation
import Testing
@testable import final_final

private struct GettingStartedBoom: Error {}

extension LifecycleEntryStatic {
    @Suite("ProjectCommands Getting Started (E9, N2) — Tier 2 (t-94369a83 3a-1b C8b)", .serialized, .timeLimit(.minutes(1)))
    @MainActor
    struct ProjectCommandsGettingStartedTests {

        private let url = URL(fileURLWithPath: "/tmp/command-gs-b.ff")

        /// The live answer to `DocumentManager.isGettingStartedProject` for the lifecycle entry: the recorder's flag, which
        /// the recorder (and `onOpen` / `onNewProject`) flips the way a real open does.
        private func gettingStarted(_ recorder: ProjectCommandRecorder) -> @MainActor () -> Bool {
            { recorder.isGettingStarted }
        }

        // MARK: - E9

        @Test("""
            E9: Help > Getting Started with a project open saves it first (it already holds the fresh text when Getting \
            Started is opened), backs it up (a real snapshot row with that text), calls the swap but NOT onProjectClosed, \
            and leaves no token and no barrier
            """)
        func gettingStartedSavesAndBacksUpTheOpenProject() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            var projectClosedCalls = 0
            rig.view.onProjectClosed = { projectClosedCalls += 1 }
            let recorder = ProjectCommandRecorder()
            let before = try rig.snapshotCount()
            rig.backup.contentDidChange()
            var oldProjectHadFreshTextWhenOpened: Bool?
            var tokenWasGettingStartedAtArm: Bool?
            recorder.onOpenGettingStarted = {
                oldProjectHadFreshTextWhenOpened = try? rig.paragraphTexts().contains("fresh Y paragraph.")
                tokenWasGettingStartedAtArm = rig.editorState.activeLifecycle?.wasGettingStarted
            }
            var shown = 0
            var pickers = 0
            var result: ProjectCommandResult?

            await rig.withEntry(isGettingStartedProvider: gettingStarted(recorder)) {
                result = await ProjectCommands.openGettingStarted(
                    showGettingStarted: { shown += 1 }, showPicker: { pickers += 1 }, recorder.environment)
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
            #expect(result == .lifecycle(.performed))
            #expect(recorder.order == ["openGettingStarted"], "order: \(recorder.order)")
            #expect(recorder.isGettingStarted, "precondition: DocumentManager says Getting Started by the time the tail ran")
            #expect(tokenWasGettingStartedAtArm == false, "N1: the token was captured when a regular project was open")
            #expect(shown == 1 && pickers == 0, "the root view swapped to Getting Started")
            #expect(oldProjectHadFreshTextWhenOpened == true, "the old project was saved BEFORE Getting Started replaced it")
            #expect(try rig.snapshotCount() == before + 1, "the old project's automatic version was made (it used to be skipped)")
            #expect(try rig.snapshotPreviews().last?.contains("fresh Y paragraph.") == true, "made after FB: it holds the fresh text")
            #expect(projectClosedCalls == 0, "E9 posts nothing back to the picker: the app's own swap follows")
            #expect(recorder.posts.isEmpty, "Getting Started posts no project notification")
            #expect(!rig.entryEvents.contains(.safetyNetReleasedBarrier), "the tail retired the writer: nothing for the net")
            #expect(rig.editorState.activeLifecycle == nil, "no token left")
            #expect(rig.editorState.lifecycleBarrier == nil, "no barrier left")
            #expect(rig.writer?.enqueueBarrier() == nil, "the old writer was retired, so no barrier can be granted on it")
            #expect(rig.editorState.content.isEmpty, "the close tail reset the old editor state")
        }

        @Test("""
            Getting Started to Getting Started PASSES THROUGH: nothing is armed (the entry is never asked), nothing is \
            saved or backed up, no tail runs; Getting Started is reopened as it always was (t-d844594f is not fixed here)
            """)
        func gettingStartedToGettingStartedArmsNothing() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            var projectClosedCalls = 0
            rig.view.onProjectClosed = { projectClosedCalls += 1 }
            let recorder = ProjectCommandRecorder()
            recorder.isGettingStarted = true
            let before = try rig.snapshotCount()
            rig.backup.contentDidChange()
            var shown = 0
            var result: ProjectCommandResult?

            await rig.withEntry(isGettingStartedProvider: gettingStarted(recorder)) {
                result = await ProjectCommands.openGettingStarted(
                    showGettingStarted: { shown += 1 }, showPicker: {}, recorder.environment)
            }

            #expect(result == .gettingStartedPassedThrough)
            #expect(rig.entryEvents.isEmpty, "the entry was never asked: not armed, not even passed through; got \(rig.entryEvents)")
            #expect(rig.editorState.activeLifecycle == nil)
            #expect(rig.editorState.lifecycleBarrier == nil)
            #expect(LifecycleEntry.current == nil)
            #expect(recorder.gettingStartedOpens == 1, "it is reopened, as before")
            #expect(shown == 1)
            #expect(try rig.snapshotCount() == before, "nothing to back up: Getting Started is an ephemeral playground")
            #expect(projectClosedCalls == 0)
            #expect(rig.editorState.content == LifecycleTailRig.seed, "no tail ran on the editor")
        }

        @Test("Help > Getting Started with NO project open (the picker, first launch) runs straight through: nothing armed")
        func gettingStartedWithNothingOpenPassesThrough() async throws {
            await LifecycleEntryHarness.withWorld(hasOpenProject: false) { world in
                _ = world
                let recorder = ProjectCommandRecorder()
                var shown = 0

                let result = await ProjectCommands.openGettingStarted(
                    showGettingStarted: { shown += 1 }, showPicker: {}, recorder.environment)

                #expect(result == .lifecycle(.performed))
                #expect(LifecycleEntry.testEvents == [.passedThrough(.noOpenProject)])
                #expect(recorder.gettingStartedOpens == 1)
                #expect(shown == 1)
            }
        }

        @Test("""
            E9 with Getting Started failing to open (the bundled template cannot be copied): the app falls back to the \
            picker, and the old project was still saved and backed up first
            """)
        func gettingStartedFailureFallsBackToThePickerAfterTheSave() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            let recorder = ProjectCommandRecorder()
            recorder.gettingStartedError = GettingStartedBoom()
            let before = try rig.snapshotCount()
            rig.backup.contentDidChange()
            var shown = 0
            var pickers = 0
            var result: ProjectCommandResult?

            await rig.withEntry(isGettingStartedProvider: gettingStarted(recorder)) {
                result = await ProjectCommands.openGettingStarted(
                    showGettingStarted: { shown += 1 }, showPicker: { pickers += 1 }, recorder.environment)
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
            #expect(result == .lifecycle(.performed))
            #expect(shown == 0 && pickers == 1, "no Getting Started, the picker instead")
            #expect(try rig.snapshotCount() == before + 1, "DocumentManager closed the old project: it was saved and backed up first")
            #expect(rig.editorState.activeLifecycle == nil)
            #expect(rig.editorState.lifecycleBarrier == nil)
        }

        @Test("U5 for E9: a section operation that never clears CANCELS it -- Getting Started is not opened, the notice is shown")
        func gettingStartedIsCancelled_performNeverCalled() async throws {
            let rig = try LifecycleFlushHarness()
            rig.js.answer("flushPendingBlockChanges", true)
            rig.js.answer("hasBlockChanges", false)
            rig.fetchAnswer = "# Alpha\n\nfresh Y paragraph.\n\n# Beta\n\nfour five six.\n"
            let toasts = ToastCenter()
            rig.editorState.toastCenter = toasts
            rig.controller.testSetIsPerforming(true)
            defer { rig.controller.testSetIsPerforming(false) }
            let recorder = ProjectCommandRecorder()
            var shown = 0
            var result: ProjectCommandResult?

            await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.2)) {
                result = await ProjectCommands.openGettingStarted(
                    showGettingStarted: { shown += 1 }, showPicker: {}, recorder.environment)
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
            #expect(result == .lifecycle(.cancelled))
            #expect(recorder.gettingStartedOpens == 0 && shown == 0, "perform never called")
            #expect(toasts.current?.message == ToastFactory.lifecycleCancelled().message)
            #expect(rig.editorState.activeLifecycle == nil)
        }

        // MARK: - N2: the reverse swap

        @Test("""
            N2: Open Project FROM Getting Started runs the CLOSE tail on the old editor with the real tails: no automatic \
            version (it is the playground), no onProjectClosed, the undo history is left alone (the open tail would \
            invalidate it), the post is keyed, and nothing is left armed or held -- however DocumentManager looks by then
            """)
        func openFromGettingStartedRunsTheCloseTailOnTheOldState() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            var projectClosedCalls = 0
            rig.view.onProjectClosed = { projectClosedCalls += 1 }
            let undo = rig.view.unifiedUndoService
            let entry = StructuralEntry(kind: .restoreSectionReplace, title: "First", undoSnapshotId: "snap-1")
            undo.record(entry)
            let recorder = ProjectCommandRecorder()
            recorder.isGettingStarted = true
            recorder.onOpen = {
                recorder.isGettingStarted = false   // DocumentManager has already switched to the new regular project
            }
            let before = try rig.snapshotCount()
            rig.backup.contentDidChange()
            var result: ProjectCommandResult?

            await rig.withEntry(isGettingStartedProvider: gettingStarted(recorder)) {
                result = await ProjectCommands.open(url: url, recorder.environment)
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
            #expect(result == .lifecycle(.performed))
            #expect(recorder.order == ["open", "post:projectDidOpen"], "order: \(recorder.order)")
            #expect(recorder.posts.first?.keyedTokenId != nil, "keyed: the new ContentView opens the project on mount")
            #expect(try rig.snapshotCount() == before, "the close tail with wasGettingStarted makes no version (the open tail would)")
            #expect(undo.undoStack.map(\.id) == [entry.id], "the open tail's invalidateAll never ran on the discarded editor")
            #expect(projectClosedCalls == 0, "onProjectClosed would close the project the new view is opening")
            #expect(rig.editorState.content.isEmpty, "the discarded editor was reset, not reconfigured for the new project")
            #expect(!rig.entryEvents.contains(.safetyNetReleasedBarrier))
            #expect(rig.editorState.activeLifecycle == nil)
            #expect(rig.editorState.lifecycleBarrier == nil)
            #expect(rig.writer?.enqueueBarrier() == nil, "the old (Getting Started) writer was retired")
        }

        @Test("""
            N2 Import: from Getting Started the old editor gets the CLOSE tail, so nothing is seeded into it (a create tail \
            would put the imported text into the discarded editor); the content was saved into the new project's \
            database BEFORE the post, and rides on the keyed post
            """)
        func importFromGettingStartedSavesTheContentBeforeThePostAndSeedsNothingIntoTheOldEditor() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            var projectClosedCalls = 0
            rig.view.onProjectClosed = { projectClosedCalls += 1 }
            let recorder = ProjectCommandRecorder()
            recorder.isGettingStarted = true
            recorder.onNewProject = {
                recorder.isGettingStarted = false
            }
            let content = "# Imported\n\nImported from Getting Started.\n"
            let before = try rig.snapshotCount()
            rig.backup.contentDidChange()
            var result: ProjectCommandResult?

            await rig.withEntry(isGettingStartedProvider: gettingStarted(recorder)) {
                result = await ProjectCommands.importMarkdown(content, to: url, recorder.environment)
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
            #expect(result == .lifecycle(.performed))
            #expect(
                recorder.order == ["newProject", "saveContent", "post:projectDidCreate"],
                "the content is saved into the new project BEFORE the post (the new view loads it on mount): \(recorder.order)")
            #expect(recorder.savedContents == [content])
            let post = try #require(recorder.posts.first)
            #expect(post.keyedTokenId != nil)
            #expect(post.userInfo?["content"] as? String == content, "and it rides on the post")
            #expect(rig.editorState.content.isEmpty, "nothing was seeded into the discarded editor (the close tail ran, not the create tail)")
            #expect(try rig.snapshotCount() == before, "no version of Getting Started")
            #expect(projectClosedCalls == 0)
            #expect(rig.editorState.activeLifecycle == nil)
            #expect(rig.editorState.lifecycleBarrier == nil)
        }

        @Test("""
            N2 Import, the data path: a project made the way Import makes it (the content row written, NO blocks) is loaded \
            by a NEW ContentView's initial load: the editor gets the imported text and the content is parsed into blocks
            """)
        func importedContentReachesTheNewViewOnMount() throws {
            TestMode.clearTestState()
            let projectURL = URL(fileURLWithPath: "/tmp/claude/command-gs-import-\(UUID().uuidString).ff")
            TestFixtureCleanup.register(projectURL)
            defer { TestDatabaseTeardown.closeProjectThenCleanUp(projectURL) }
            let content = "# Imported\n\nImported from Getting Started.\n"

            // The two calls `ProjectCommandEnvironment.production` makes for Import, back to back with the new view's
            // load (nothing awaits in between).
            let dm = DocumentManager.shared
            try dm.newProject(at: projectURL, title: "Imported")
            try dm.saveContent(content)
            let db = try #require(dm.projectDatabase)
            let pid = try #require(dm.projectId)
            #expect(try db.fetchBlocks(projectId: pid).isEmpty, "precondition: a fresh project has a content row and no blocks")

            let newView = ContentView()   // what `.gettingStarted` -> `.editor` builds
            newView.loadInitialContent(db: db, pid: pid)

            #expect(newView.editorState.content.contains("Imported from Getting Started."), "the editor got the imported text")
            let blocks = try db.fetchBlocks(projectId: pid)
            #expect(blocks.contains { $0.textContent.contains("Imported from Getting Started.") }, "and it was parsed into blocks")
        }

        // MARK: - The Getting Started close

        @Test("""
            the Getting Started close (no lifecycle): resets the view, stops polling, makes NO automatic version and calls \
            onProjectClosed -- with no project open in DocumentManager (N7)
            """)
        func gettingStartedCloseNeedsNoLifecycleAndNoDocumentManager() async throws {
            let rig = try LifecycleTailRig()
            defer { rig.shutdown() }
            var projectClosedCalls = 0
            rig.view.onProjectClosed = { projectClosedCalls += 1 }
            let before = try rig.snapshotCount()
            rig.backup.contentDidChange()
            rig.sync.startPolling()
            #expect(rig.sync.testPollTimerIsArmed, "precondition: polling is running")

            await rig.view.closeGettingStartedProject()

            #expect(projectClosedCalls == 1, "back to the picker")
            #expect(try rig.snapshotCount() == before, "Getting Started is an ephemeral playground: no version")
            #expect(!rig.sync.testPollTimerIsArmed, "polling stopped (a managed lifecycle stops it at arm; this one has none)")
            #expect(rig.editorState.content.isEmpty, "resetForProjectSwitch ran")
            #expect(rig.editorState.activeLifecycle == nil)
            #expect(rig.editorState.lifecycleBarrier == nil)
            #expect(rig.writer?.enqueueBarrier() == nil, "the writer was retired")
        }
    }
}
