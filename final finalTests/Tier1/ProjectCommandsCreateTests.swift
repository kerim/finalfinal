//
//  ProjectCommandsCreateTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C8a (slice-3a-1b-everyday.md sections 5.5 and 7.2 "C8a"): E7, New Project, and E8,
//  Import Markdown, in the command layer (`ProjectCommands.newProject` / `importMarkdown`).
//
//    - both run inside `LifecycleEntry.run(.projectSwitch)` and return a CREATE tail: `.create(content: nil)` for New
//      Project and `.create(content: <the imported Markdown>)` for Import, so the real create tail seeds the new
//      project's editor with that content (the seed itself is pinned in `LifecycleOpenTailTests`)
//    - the post is `.projectDidCreate`, KEYED with the running token (Import's also carries the `content`, which the
//      old ContentView handler would seed with when the post is unkeyed: the pass-through case)
//    - the new project is created only AFTER the save sequence (order: newProject, [saveContent], post)
//    - a creation that fails is reported with the alert it always had ("Could Not Create Project" / "Could Not Import
//      File") after the abort restored the editor; nothing is posted and no tail runs
//
//  Item 32: every test positively asserts that the guard path ran (the `.armed` event) or, for the pass-through cases,
//  that it did not. The suite nests under `LifecycleEntryStatic`.
//

import Foundation
import Testing
@testable import final_final

private typealias Harness = LifecycleEntryHarness
private struct CreateBoom: Error, Equatable {}

extension LifecycleEntryStatic {
    @Suite("ProjectCommands New Project and Import (E7, E8) — Tier 1 (t-94369a83 3a-1b C8a)", .serialized, .timeLimit(.minutes(1)))
    @MainActor
    struct ProjectCommandsCreateTests {

        private let url = URL(fileURLWithPath: "/tmp/command-create-c.ff")
        private let imported = "# Imported\n\nimported body.\n"

        // MARK: - E7 New Project

        @Test("""
            E7: New Project runs inside the lifecycle (armed as a switch); the project is created in perform, the post is \
            .projectDidCreate keyed with the running token and carries no content, and the create tail follows with none
            """)
        func newProjectThroughTheEntry() async throws {
            try await Harness.withWorld { world in
                Harness.mount(world)
                let recorder = ProjectCommandRecorder()

                let result = await ProjectCommands.newProject(at: url, title: "C", recorder.environment)

                #expect(result == .lifecycle(.performed))
                #expect(LifecycleEntry.testEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
                #expect(recorder.order == ["newProject", "post:projectDidCreate"], "order: \(recorder.order)")
                #expect(recorder.createdProjects.map(\.url) == [url])
                #expect(recorder.createdProjects.map(\.title) == ["C"])
                let post = try #require(recorder.posts.first)
                #expect(post.name == .projectDidCreate)
                #expect(post.keyedTokenId != nil && post.keyedTokenId == post.tokenIdAtPost, "keyed with the running token")
                #expect(post.userInfo?["content"] == nil, "a new project has no initial content to seed")
                #expect(world.probe.log == ["create:nil"], "the create tail ran, with no content")
                #expect(world.editorState.activeLifecycle == nil)
                #expect(LifecycleEntry.current == nil)
            }
        }

        @Test("E7 with NO project open (the picker): passes straight through and the post is UNKEYED")
        func newProjectWithNoOpenProjectPassesThroughUnkeyed() async throws {
            try await Harness.withWorld(hasOpenProject: false) { _ in
                let recorder = ProjectCommandRecorder()

                let result = await ProjectCommands.newProject(at: url, title: "C", recorder.environment)

                #expect(result == .lifecycle(.performed))
                #expect(LifecycleEntry.testEvents == [.passedThrough(.noOpenProject)])
                let post = try #require(recorder.posts.first)
                #expect(post.name == .projectDidCreate)
                #expect(post.userInfo == nil, "unkeyed: the old ContentView handler opens the new project")
            }
        }

        @Test("""
            E7: a creation that throws is reported ("Could Not Create Project") after the abort restored the editor -- no post, \
            no tail, nothing left armed
            """)
        func newProjectFailureIsReported() async throws {
            await Harness.withWorld { world in
                Harness.mount(world)
                let recorder = ProjectCommandRecorder()
                recorder.newProjectError = CreateBoom()

                let result = await ProjectCommands.newProject(at: url, title: "C", recorder.environment)

                #expect(result == .failed)
                #expect(LifecycleEntry.testEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
                #expect(recorder.errorAlerts.map(\.title) == ["Could Not Create Project"])
                #expect((recorder.errorAlerts.first?.error as? CreateBoom) != nil)
                #expect(recorder.posts.isEmpty)
                #expect(!world.probe.log.contains("create:nil"), "no tail runs after an abort; log: \(world.probe.log)")
                #expect(world.editorState.activeLifecycle == nil, "the abort cleared the token")
                #expect(LifecycleEntry.current == nil)
            }
        }

        // MARK: - E8 Import Markdown

        @Test("""
            E8: Import creates the project, saves the imported Markdown into it, and posts .projectDidCreate keyed with the \
            running token AND carrying the content; the create tail receives the same content to seed
            """)
        func importThroughTheEntry() async throws {
            try await Harness.withWorld { world in
                Harness.mount(world)
                let recorder = ProjectCommandRecorder()

                let result = await ProjectCommands.importMarkdown(imported, to: url, recorder.environment)

                #expect(result == .lifecycle(.performed))
                #expect(LifecycleEntry.testEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
                #expect(recorder.order == ["newProject", "saveContent", "post:projectDidCreate"], "order: \(recorder.order)")
                #expect(recorder.createdProjects.map(\.title) == ["command-create-c"], "the title is the file name without the extension")
                #expect(recorder.savedContents == [imported])
                let post = try #require(recorder.posts.first)
                #expect(post.name == .projectDidCreate)
                #expect(post.keyedTokenId != nil && post.keyedTokenId == post.tokenIdAtPost)
                #expect(post.userInfo?["content"] as? String == imported, "the content rides on the post as it always did")
                #expect(world.probe.log == ["create:\(imported)"], "the create tail was handed the imported content to seed")
                #expect(world.editorState.activeLifecycle == nil)
            }
        }

        @Test("""
            E8 with NO project open (the picker): passes straight through; the post is UNKEYED but still carries the content, \
            which the old ContentView handler seeds
            """)
        func importWithNoOpenProjectKeepsTheContentOnTheUnkeyedPost() async throws {
            try await Harness.withWorld(hasOpenProject: false) { _ in
                let recorder = ProjectCommandRecorder()

                let result = await ProjectCommands.importMarkdown(imported, to: url, recorder.environment)

                #expect(result == .lifecycle(.performed))
                #expect(LifecycleEntry.testEvents == [.passedThrough(.noOpenProject)])
                let post = try #require(recorder.posts.first)
                #expect(post.keyedTokenId == nil, "no token: the old handler must not stand down")
                #expect(post.userInfo?["content"] as? String == imported)
            }
        }

        @Test("E8: an import whose save fails is reported (\"Could Not Import File\") after the abort; no post, no tail")
        func importFailureIsReported() async throws {
            await Harness.withWorld { world in
                Harness.mount(world)
                let recorder = ProjectCommandRecorder()
                recorder.saveContentError = CreateBoom()

                let result = await ProjectCommands.importMarkdown(imported, to: url, recorder.environment)

                #expect(result == .failed)
                #expect(LifecycleEntry.testEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
                #expect(recorder.order == ["newProject", "saveContent", "errorAlert"], "order: \(recorder.order)")
                #expect(recorder.errorAlerts.map(\.title) == ["Could Not Import File"])
                #expect(recorder.posts.isEmpty)
                #expect(!world.probe.log.contains { $0.hasPrefix("create:") })
                #expect(world.editorState.activeLifecycle == nil)
            }
        }

        // MARK: - Busy, duplicate and a joined quit

        @Test("""
            a New Project pressed while a close is saving is HELD and created after the close (t-eb07cd67), with no refusal \
            notice; a second Import to a DIFFERENT file while an Import runs is held too and runs after it
            """)
        func aCommandDuringACloseOrAnImportIsHeldThenRuns() async throws {
            try await Harness.withWorld { world in
                Harness.mount(world)
                let gate = Harness.Gate()
                let first = Task { @MainActor in
                    try await LifecycleEntry.run(kind: .close) {
                        await gate.wait()
                        return .close
                    }
                }
                await Harness.waitUntil("the close to arm") { world.editorState.activeLifecycle != nil }
                let recorder = ProjectCommandRecorder()

                let creating = Task { @MainActor in
                    await ProjectCommands.newProject(at: url, title: "C", recorder.environment)
                }
                await Harness.waitUntil("the New Project to be held") {
                    LifecycleEntry.testEvents.contains(.held(requested: .projectSwitch, behind: .close))
                }
                #expect(recorder.order.isEmpty, "perform waits: nothing created while the close is saving")
                #expect(world.toasts.current == nil, "no refusal notice")

                gate.open()
                _ = try await first.value
                #expect(await creating.value == .lifecycle(.performed))
                #expect(recorder.createdProjects.map(\.title) == ["C"], "created once the close had finished")
                #expect(world.probe.log == ["close:true", "create:nil"], "the close tail, then the create tail")
                #expect(LifecycleEntry.current == nil)

                // An Import is running; an Import of a DIFFERENT file is held and runs after it (it used to be dropped silently).
                let parked = Harness.Gate()
                let importing = Task { @MainActor in
                    try await LifecycleEntry.run(kind: .projectSwitch) {
                        await parked.wait()
                        return .create(content: nil)
                    }
                }
                await Harness.waitUntil("the first import to arm") { world.editorState.activeLifecycle?.kind == .projectSwitch }
                let otherURL = URL(fileURLWithPath: "/tmp/command-create-other.ff")
                let secondRecorder = ProjectCommandRecorder()
                let second = Task { @MainActor in
                    await ProjectCommands.importMarkdown(imported, to: otherURL, secondRecorder.environment)
                }
                await Harness.waitUntil("the second import to be held") {
                    LifecycleEntry.testEvents.contains(.held(requested: .projectSwitch, behind: .projectSwitch))
                }
                #expect(secondRecorder.order.isEmpty, "the second import waits for the first")
                #expect(world.toasts.current == nil)
                parked.open()
                _ = try await importing.value
                #expect(await second.value == .lifecycle(.performed))
                #expect(secondRecorder.createdProjects.map(\.url) == [otherURL], "the held import ran after the first")
                #expect(secondRecorder.order == ["newProject", "saveContent", "post:projectDidCreate"], "order: \(secondRecorder.order)")
            }
        }

        @Test("N6: a quit that joined before perform ran -- New Project creates nothing, shows nothing")
        func aJoinedQuitMeansNoNewProject() async throws {
            let controller = StructuralUndoController()
            await Harness.withWorld(controller: controller) { world in
                Harness.mount(world)
                controller.testSetIsPerforming(true)
                let recorder = ProjectCommandRecorder()
                let command = Task { @MainActor in
                    await ProjectCommands.newProject(at: url, title: "C", recorder.environment)
                }
                await Harness.waitUntil("the New Project to arm") { world.editorState.activeLifecycle?.kind == .projectSwitch }
                guard case .joined(let quit) = world.editorState.armLifecycle(.quit, wasGettingStarted: false) else {
                    Issue.record("the quit did not join")
                    controller.testSetIsPerforming(false)
                    _ = await command.value
                    return
                }
                controller.testSetIsPerforming(false)
                let result = await command.value

                #expect(LifecycleEntry.testEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
                #expect(result == .lifecycle(.skippedForQuit))
                #expect(recorder.order.isEmpty, "perform was skipped: no project created")
                #expect(world.toasts.current == nil)
                #expect(world.probe.log.isEmpty)
                _ = world.editorState.clearLifecycle(quit.id)
            }
        }
    }
}
