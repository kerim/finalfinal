//
//  ProjectCommandsSaveAsTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C8a (slice-3a-1b-everyday.md sections 5.5 and 7.2 "C8a"): E4, Save As, in the command
//  layer (`ProjectCommands.saveAs`, Commands/ProjectCommands.swift).
//
//    - the copy is made INSIDE the lifecycle, in `perform`, after the save sequence: the order is copy, open the
//      copy, give it the new name, post (keyed with the running token), and the tail that follows is the OPEN tail
//    - must-fix #23: a title update that fails AFTER the copy was opened is NON-fatal. Aborting would re-push block
//      ids to the OLD project's editor while `DocumentManager` already has the copy open, so the command logs it,
//      still posts and returns `.performed`; the project stays open, no alert, no abort
//    - A3: Save As onto the open project's OWN path is refused before anything is armed: `copyProjectPackage` removes
//      the destination before copying, so it would delete the open project
//    - a copy that fails is a failure the user is told about ("Could Not Save Project"): nothing is opened or posted
//      and the abort routine restored the editor
//    - a quit that joined before `perform` ran means the copy is never made (N6)
//    - with nothing to protect (no mounted editor) `run` passes straight through and the post stays UNKEYED
//
//  Item 32: every test positively asserts that the guard path ran (the `.armed` event) or, for the pass-through case,
//  that it did not. The suite nests under `LifecycleEntryStatic`, the serialized parent of every suite that touches
//  `LifecycleEntry`'s static state.
//

import Foundation
import Testing
@testable import final_final

private typealias Harness = LifecycleEntryHarness
private struct SaveAsBoom: Error, Equatable {}

extension LifecycleEntryStatic {
    @Suite("ProjectCommands Save As (E4) — Tier 1 (t-94369a83 3a-1b C8a)", .serialized, .timeLimit(.minutes(1)))
    @MainActor
    struct ProjectCommandsSaveAsTests {

        private let source = URL(fileURLWithPath: "/tmp/save-as-source.ff")
        private let destination = URL(fileURLWithPath: "/tmp/save-as-folder/A copy.ff")

        @Test("""
            E4: the copy is made INSIDE the lifecycle (armed as a switch), after the save sequence: copy, open the copy, \
            rename it, then a post keyed with the running token; the tail that follows is the open tail
            """)
        func copyIsMadeInsidePerform() async throws {
            try await Harness.withWorld { world in
                Harness.mount(world)
                let recorder = ProjectCommandRecorder()
                var tokenSeenAtCopy: UUID?
                recorder.onCopy = { tokenSeenAtCopy = LifecycleEntry.current?.token.id }

                let result = await ProjectCommands.saveAs(from: source, to: destination, recorder.environment)

                #expect(result == .lifecycle(.performed))
                #expect(LifecycleEntry.testEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
                #expect(tokenSeenAtCopy != nil, "the copy ran while the lifecycle was armed, i.e. in perform, after the save sequence")
                #expect(recorder.order == ["copy", "open", "rename", "post:projectDidOpen"], "order: \(recorder.order)")
                #expect(recorder.copies.map(\.source) == [source])
                #expect(recorder.copies.map(\.destination) == [destination])
                #expect(recorder.openedURLs == [destination], "the copy is what gets opened")
                #expect(recorder.renamedTo == ["A copy"], "the new name is the destination's file name without the extension")
                let post = try #require(recorder.posts.first)
                #expect(post.name == .projectDidOpen)
                #expect(post.keyedTokenId != nil && post.keyedTokenId == post.tokenIdAtPost, "keyed with the running token")
                #expect(world.probe.log == ["open"], "the OPEN tail ran (Save As has no content to seed)")
                #expect(recorder.errorAlerts.isEmpty)
                #expect(world.editorState.activeLifecycle == nil)
                #expect(LifecycleEntry.current == nil)
            }
        }

        @Test("""
            must-fix #23: a title update that fails AFTER the copy was opened is non-fatal -- the post is still made (keyed), \
            the open tail still runs, no alert is shown and nothing is aborted
            """)
        func titleUpdateFailureAfterTheOpenIsNonFatal() async throws {
            try await Harness.withWorld { world in
                Harness.mount(world)
                let recorder = ProjectCommandRecorder()
                recorder.renameError = SaveAsBoom()

                let result = await ProjectCommands.saveAs(from: source, to: destination, recorder.environment)

                #expect(result == .lifecycle(.performed), "not a failure: the copy is open")
                #expect(LifecycleEntry.testEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
                #expect(
                    recorder.order == ["copy", "open", "rename", "post:projectDidOpen"],
                    "the rename was attempted and the post was made anyway: \(recorder.order)")
                #expect(recorder.openedURLs == [destination])
                let post = try #require(recorder.posts.first)
                #expect(post.keyedTokenId != nil && post.keyedTokenId == post.tokenIdAtPost)
                #expect(world.probe.log == ["open"], "the open tail ran and no abort restored the OLD editor (no repost, no reparse)")
                #expect(recorder.errorAlerts.isEmpty, "non-fatal: the user is not shown an error for a stale title")
                #expect(recorder.reported.isEmpty)
                #expect(world.editorState.activeLifecycle == nil)
                #expect(LifecycleEntry.current == nil)
            }
        }

        @Test("""
            a copy that fails is reported ("Could Not Save Project") after the abort restored the editor: the copy is never \
            opened, nothing is posted, no tail runs
            """)
        func copyFailureIsReportedAfterTheAbort() async throws {
            await Harness.withWorld { world in
                Harness.mount(world)
                let recorder = ProjectCommandRecorder()
                recorder.copyError = SaveAsBoom()

                let result = await ProjectCommands.saveAs(from: source, to: destination, recorder.environment)

                #expect(result == .failed)
                #expect(LifecycleEntry.testEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
                #expect(recorder.order == ["copy", "errorAlert"], "nothing opened, nothing posted: \(recorder.order)")
                #expect(recorder.errorAlerts.map(\.title) == ["Could Not Save Project"])
                #expect((recorder.errorAlerts.first?.error as? SaveAsBoom) != nil)
                #expect(recorder.posts.isEmpty)
                #expect(!world.probe.log.contains("open"), "no tail runs after an abort; log: \(world.probe.log)")
                #expect(world.editorState.activeLifecycle == nil, "the abort cleared the token")
                #expect(LifecycleEntry.current == nil)
            }
        }

        @Test("a copy whose open throws (the copy is damaged) is reported the same way; the failure is not an open-error sheet")
        func openFailureOfTheCopyIsReportedAsASaveFailure() async throws {
            await Harness.withWorld { world in
                Harness.mount(world)
                let recorder = ProjectCommandRecorder()
                recorder.openError = SaveAsBoom()

                let result = await ProjectCommands.saveAs(from: source, to: destination, recorder.environment)

                #expect(result == .failed)
                #expect(recorder.order == ["copy", "open", "errorAlert"], "order: \(recorder.order)")
                #expect(recorder.errorAlerts.map(\.title) == ["Could Not Save Project"])
                #expect(recorder.reported.isEmpty, "Save As keeps its own alert, as it always did")
                #expect(recorder.posts.isEmpty)
                #expect(world.editorState.activeLifecycle == nil)
            }
        }

        @Test("N6: a quit that joined before perform ran -- the copy is never made, nothing is opened or posted, nothing is shown")
        func aJoinedQuitMeansNoCopy() async throws {
            let controller = StructuralUndoController()
            await Harness.withWorld(controller: controller) { world in
                Harness.mount(world)
                controller.testSetIsPerforming(true)   // holds step 1 so the quit can join while the sequence waits
                let recorder = ProjectCommandRecorder()
                let command = Task { @MainActor in
                    await ProjectCommands.saveAs(from: source, to: destination, recorder.environment)
                }
                await Harness.waitUntil("the Save As to arm") { world.editorState.activeLifecycle?.kind == .projectSwitch }

                guard case .joined(let quit) = world.editorState.armLifecycle(.quit, wasGettingStarted: false) else {
                    Issue.record("the quit did not join the running Save As")
                    controller.testSetIsPerforming(false)
                    _ = await command.value
                    return
                }
                controller.testSetIsPerforming(false)
                let result = await command.value

                #expect(LifecycleEntry.testEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
                #expect(result == .lifecycle(.skippedForQuit))
                #expect(recorder.order.isEmpty, "perform was skipped: no copy, no open, no post, no alert; got \(recorder.order)")
                #expect(world.toasts.current == nil)
                #expect(world.probe.log.isEmpty, "no tail ran for the skipped Save As")
                _ = world.editorState.clearLifecycle(quit.id)
            }
        }

        @Test("""
            A3: Save As onto the open project's OWN path is refused before anything runs -- the package is never copied (the \
            copy would delete the destination, i.e. the open project), nothing is armed, opened or posted, and "Could Not \
            Save Project" is shown once with the reason
            """)
        func saveAsOntoTheOpenProjectIsRefused() async throws {
            await Harness.withWorld { world in
                Harness.mount(world)   // an open project and a mounted editor: `run` WOULD arm if it were asked
                let recorder = ProjectCommandRecorder()

                let result = await ProjectCommands.saveAs(from: source, to: source, recorder.environment)

                #expect(result == .failed)
                #expect(recorder.copies.isEmpty, "copyProjectPackage must not be called: it removes the destination first")
                #expect(LifecycleEntry.testEvents.isEmpty, "nothing was armed (and so no `.armed` event); got \(LifecycleEntry.testEvents)")
                #expect(recorder.order == ["errorAlert"], "only the alert; got \(recorder.order)")
                #expect(recorder.errorAlerts.map(\.title) == ["Could Not Save Project"], "shown exactly once")
                #expect(
                    recorder.errorAlerts.first?.error.localizedDescription
                        == "Choose a different name or folder: this is the project that's open.")
                #expect(world.probe.log.isEmpty, "no tail ran")
                #expect(world.editorState.activeLifecycle == nil)
                #expect(LifecycleEntry.current == nil)
            }
        }

        @Test("A3: the same project spelled differently (a trailing slash on the package directory) is still refused")
        func saveAsOntoTheOpenProjectIsRefusedWhateverTheSpelling() async throws {
            await Harness.withWorld { world in
                Harness.mount(world)
                let recorder = ProjectCommandRecorder()
                let withTrailingSlash = URL(fileURLWithPath: source.path, isDirectory: true)

                let result = await ProjectCommands.saveAs(from: withTrailingSlash, to: source, recorder.environment)

                #expect(result == .failed)
                #expect(recorder.copies.isEmpty)
                #expect(LifecycleEntry.testEvents.isEmpty)
                #expect(recorder.order == ["errorAlert"], "only the alert; got \(recorder.order)")
                #expect(world.editorState.activeLifecycle == nil)
            }
        }

        @Test("with NO mounted editor (nothing to save) Save As passes straight through and its post is UNKEYED")
        func passThroughPostsUnkeyed() async throws {
            try await Harness.withWorld { world in
                let recorder = ProjectCommandRecorder()   // the world has an open project but no mounted host

                let result = await ProjectCommands.saveAs(from: source, to: destination, recorder.environment)

                #expect(result == .lifecycle(.performed))
                #expect(LifecycleEntry.testEvents == [.passedThrough(.noHost)])
                #expect(recorder.order == ["copy", "open", "rename", "post:projectDidOpen"])
                let post = try #require(recorder.posts.first)
                #expect(post.userInfo == nil, "unkeyed: the old ContentView handler does the open")
                #expect(world.editorState.activeLifecycle == nil)
            }
        }
    }
}
