//
//  ProjectCommandsTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C7a (slice-3a-1b-everyday.md sections 5.4 and 7.2 "C7a"): the command layer for the
//  first three lifecycle entry points, `ProjectCommands` (Commands/ProjectCommands.swift): E1 Close Project
//  (Cmd-W), E2 Open Project (Cmd-O), E3 Open Recent.
//
//    - E1 Getting Started: closes directly. No lifecycle is armed (no save, no automatic version), nothing runs
//      but the close and its post, and no `.gettingStartedEdited` toast is raised (must-fix #20 / B18)
//    - E3 (the judge's obligation): the Save / Don't Save / Cancel alert runs BEFORE `LifecycleEntry.run`; Cancel
//      returns without ever arming a token, so the close tail never runs on a project that stays open
//    - each command's `perform` posts its notification KEYED with the running token (`LifecycleEntry.keyedUserInfo`),
//      or unkeyed when `run` passed straight through, so the old ContentView handlers stand down only when the
//      managed tail does the job
//    - a `perform` that throws (a moved recent project, an integrity failure) is reported to the user after the abort
//      routine restored the editor, with the recent project's resolved URL
//    - every outcome `run` returns is handled: busy and duplicate never reach `perform`, a joined quit skips it
//      and shows nothing
//
//  Item 32: every test positively asserts that the guard path ran (the `.armed` event) or, for the pass-through
//  cases, that it did not (the world HAS an open, mounted editor, so only the command itself kept it out of `run`).
//  The suite nests under `LifecycleEntryStatic`, the serialized parent of every suite that touches `LifecycleEntry`.
//

import Foundation
import Testing
@testable import final_final

private typealias Harness = LifecycleEntryHarness
private struct CommandBoom: Error, Equatable {}

/// Counts `.gettingStartedEdited` posts on the real notification center while alive (the toast's only trigger).
@MainActor
private final class GettingStartedEditedWatcher {
    private(set) var count = 0
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(forName: .gettingStartedEdited, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.count += 1 }
        }
    }

    func stop() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }
}

extension LifecycleEntryStatic {
    @Suite("ProjectCommands: close, open, open recent — Tier 1 (t-94369a83 3a-1b C7a)", .serialized, .timeLimit(.minutes(1)))
    @MainActor
    struct ProjectCommandsTests {

        private let url = URL(fileURLWithPath: "/tmp/command-test-b.ff")

        // MARK: - E1: Getting Started passes through

        @Test("""
            E1 Getting Started: closes directly. No token is armed, the entry is never touched, no tail runs, the post is \
            unkeyed, and no .gettingStartedEdited toast trigger fires -- even in a world with an open, mounted editor
            """)
        func gettingStartedCloseIsNotAManagedLifecycle() async throws {
            let watcher = GettingStartedEditedWatcher()
            defer { watcher.stop() }
            await Harness.withWorld(isGettingStarted: true) { world in
                Harness.mount(world)   // an open project and a mounted editor: `run` WOULD arm if asked
                let recorder = ProjectCommandRecorder()
                recorder.isGettingStarted = true
                recorder.hasUnsavedChanges = true   // the alert must not appear for Getting Started either

                let result = await ProjectCommands.close(recorder.environment)

                #expect(result == .gettingStartedClosed)
                #expect(LifecycleEntry.testEvents.isEmpty, "the entry was never asked: not armed, not passed through")
                #expect(world.editorState.activeLifecycle == nil)
                #expect(LifecycleEntry.current == nil)
                #expect(world.probe.log.isEmpty, "no tail ran (no automatic version, no service stops)")
                #expect(recorder.alertsShown == 0)
                #expect(recorder.closes == 1)
                #expect(recorder.order == ["close", "post:projectDidClose"], "order: \(recorder.order)")
                #expect(recorder.posts.first?.keyedTokenId == nil, "not keyed: there is no token")
                guard let post = recorder.posts.first else {
                    Issue.record("the Getting Started close posted nothing")
                    return
                }
                let asNotification = Notification(name: post.name, object: nil, userInfo: post.userInfo)
                #expect(
                    LifecycleEntry.isGettingStartedClose(asNotification),
                    "marked as the Getting Started close: ContentView's handler runs the close; an unmarked post would be a missed call site")
                #expect(watcher.count == 0, "closing Getting Started must not raise the 'not saved' toast trigger")
                #expect(world.toasts.current == nil)
            }
        }

        // MARK: - E1/E3: the alert runs before the entry

        @Test("close alert Cancel: no token is armed, nothing closes or posts, no tail runs (judge obligation E3)")
        func alertCancelNeverArmsAToken() async throws {
            await Harness.withWorld { world in
                Harness.mount(world)
                let recorder = ProjectCommandRecorder()
                recorder.hasUnsavedChanges = true
                recorder.choice = .cancel

                let result = await ProjectCommands.close(recorder.environment)

                #expect(result == .cancelledByUser)
                #expect(recorder.alertsShown == 1, "positive proof: the alert was reached")
                #expect(LifecycleEntry.testEvents.isEmpty, "Cancel must never reach LifecycleEntry.run, so nothing is armed")
                #expect(world.editorState.activeLifecycle == nil)
                #expect(LifecycleEntry.current == nil)
                #expect(world.probe.log.isEmpty, "the close tail must never run on a project that stays open")
                #expect(recorder.closes == 0)
                #expect(recorder.saves == 0)
                #expect(recorder.posts.isEmpty)
            }
        }

        @Test("close alert Save: the project is saved, THEN the close runs inside the lifecycle (armed, keyed post, close tail)")
        func alertSaveSavesThenCloses() async throws {
            await Harness.withWorld { world in
                Harness.mount(world)
                let recorder = ProjectCommandRecorder()
                recorder.hasUnsavedChanges = true
                recorder.choice = .save

                let result = await ProjectCommands.close(recorder.environment)

                #expect(result == .lifecycle(.performed))
                #expect(recorder.order == ["alert", "save", "close", "post:projectDidClose"], "order: \(recorder.order)")
                #expect(LifecycleEntry.testEvents.first == .armed(.close), "the close ran inside the lifecycle")
                #expect(world.probe.log == ["close:true"])
            }
        }

        @Test("close alert Don't Save: nothing is saved and the close runs inside the lifecycle")
        func alertDontSaveClosesWithoutSaving() async throws {
            await Harness.withWorld { world in
                Harness.mount(world)
                let recorder = ProjectCommandRecorder()
                recorder.hasUnsavedChanges = true
                recorder.choice = .dontSave

                let result = await ProjectCommands.close(recorder.environment)

                #expect(result == .lifecycle(.performed))
                #expect(recorder.saves == 0)
                #expect(recorder.order == ["alert", "close", "post:projectDidClose"], "order: \(recorder.order)")
                #expect(LifecycleEntry.testEvents.first == .armed(.close))
            }
        }

        // MARK: - Keyed posts

        @Test("""
            E1 close through the entry: the post is KEYED with the running token, made inside perform before the tail; \
            the old handler would ignore it
            """)
        func closeThroughTheEntryPostsAKeyedNotification() async throws {
            try await Harness.withWorld { world in
                Harness.mount(world)
                let recorder = ProjectCommandRecorder()

                let result = await ProjectCommands.close(recorder.environment)

                #expect(result == .lifecycle(.performed))
                #expect(LifecycleEntry.testEvents.first == .armed(.close), "the guard path ran (item 32)")
                let post = try #require(recorder.posts.first)
                #expect(post.name == .projectDidClose)
                #expect(post.tokenIdAtPost != nil, "the post was made while the lifecycle was running")
                #expect(post.keyedTokenId == post.tokenIdAtPost, "keyed with THAT token's id")
                #expect(LifecycleEntry.isKeyed(Notification(name: post.name, object: nil, userInfo: post.userInfo)))
                #expect(world.probe.tailTokens.first?.id == post.keyedTokenId, "the tail that followed is the same lifecycle")
                #expect(world.probe.log == ["close:true"])
                #expect(recorder.order == ["close", "post:projectDidClose"], "closeProject, then the post")
            }
        }

        @Test("with NO open project the close passes straight through and its post is UNKEYED (the old handlers do the job)")
        func closeWithNoOpenProjectPassesThroughUnkeyed() async throws {
            try await Harness.withWorld(hasOpenProject: false) { _ in
                let recorder = ProjectCommandRecorder()

                let result = await ProjectCommands.close(recorder.environment)

                #expect(result == .lifecycle(.performed))
                #expect(LifecycleEntry.testEvents == [.passedThrough(.noOpenProject)])
                #expect(recorder.closes == 1)
                let post = try #require(recorder.posts.first)
                #expect(post.name == .projectDidClose)
                #expect(post.userInfo == nil)
                #expect(!LifecycleEntry.isKeyed(Notification(name: post.name, object: nil, userInfo: post.userInfo)))
            }
        }

        // MARK: - E2 / E3

        @Test("E2 Open Project: the open runs inside the lifecycle (armed as a switch), the post is keyed, the open tail follows")
        func openThroughTheEntry() async throws {
            try await Harness.withWorld { world in
                Harness.mount(world)
                let recorder = ProjectCommandRecorder()

                let result = await ProjectCommands.open(url: url, recorder.environment)

                #expect(result == .lifecycle(.performed))
                #expect(LifecycleEntry.testEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
                #expect(recorder.openedURLs == [url])
                let post = try #require(recorder.posts.first)
                #expect(post.name == .projectDidOpen)
                #expect(post.keyedTokenId != nil && post.keyedTokenId == post.tokenIdAtPost)
                #expect(world.probe.log == ["open"])
                #expect(recorder.reported.isEmpty)
                #expect(recorder.order == ["open", "post:projectDidOpen"])
            }
        }

        @Test("E3 Open Recent: same as Open Project, for the chosen entry")
        func openRecentThroughTheEntry() async throws {
            try await Harness.withWorld { world in
                Harness.mount(world)
                let recorder = ProjectCommandRecorder()
                let entry = ProjectCommandRecorder.recentEntry(id: "recent-xyz")

                let result = await ProjectCommands.openRecent(entry, recorder.environment)

                #expect(result == .lifecycle(.performed))
                #expect(LifecycleEntry.testEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
                #expect(recorder.openedRecentIds == ["recent-xyz"])
                let post = try #require(recorder.posts.first)
                #expect(post.name == .projectDidOpen)
                #expect(post.keyedTokenId != nil && post.keyedTokenId == post.tokenIdAtPost)
                #expect(world.probe.log == ["open"])
            }
        }

        @Test("E2 / E3 with NO open project (the picker): pass straight through, unkeyed post, nothing armed")
        func opensWithNoOpenProjectPassThroughUnkeyed() async throws {
            await Harness.withWorld(hasOpenProject: false) { _ in
                let recorder = ProjectCommandRecorder()

                let openResult = await ProjectCommands.open(url: url, recorder.environment)
                let recentResult = await ProjectCommands.openRecent(ProjectCommandRecorder.recentEntry(), recorder.environment)

                #expect(openResult == .lifecycle(.performed))
                #expect(recentResult == .lifecycle(.performed))
                #expect(LifecycleEntry.testEvents == [.passedThrough(.noOpenProject), .passedThrough(.noOpenProject)])
                #expect(recorder.posts.count == 2)
                #expect(recorder.posts.allSatisfy { $0.userInfo == nil })
            }
        }

        // MARK: - perform throws

        @Test("""
            E2: an open that throws is reported with the URL the user picked, AFTER the abort restored the editor; no post, \
            no tail, nothing left armed
            """)
        func openFailureIsReportedAfterTheAbort() async throws {
            await Harness.withWorld { world in
                Harness.mount(world)
                let recorder = ProjectCommandRecorder()
                recorder.openError = CommandBoom()

                let result = await ProjectCommands.open(url: url, recorder.environment)

                #expect(result == .failed)
                #expect(LifecycleEntry.testEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
                #expect(recorder.reported.count == 1)
                #expect(recorder.reported.first?.url == url)
                #expect((recorder.reported.first?.error as? CommandBoom) != nil)
                #expect(recorder.posts.isEmpty, "a failed open posts nothing")
                #expect(world.probe.log.isEmpty, "no tail runs after an abort")
                #expect(world.editorState.activeLifecycle == nil, "the abort cleared the token")
                #expect(LifecycleEntry.current == nil)
            }
        }

        @Test("E3: an Open Recent that throws is reported with the entry's display URL (the resolved bookmark)")
        func openRecentFailureUsesTheDisplayURL() async throws {
            await Harness.withWorld { world in
                Harness.mount(world)
                let recorder = ProjectCommandRecorder()
                recorder.openError = CommandBoom()
                recorder.recentDisplayURL = URL(fileURLWithPath: "/tmp/moved-project.ff")

                let result = await ProjectCommands.openRecent(ProjectCommandRecorder.recentEntry(), recorder.environment)

                #expect(result == .failed)
                #expect(LifecycleEntry.testEvents.first == .armed(.projectSwitch))
                #expect(recorder.reported.map(\.url) == [URL(fileURLWithPath: "/tmp/moved-project.ff")])
                #expect(recorder.posts.isEmpty)
                #expect(world.editorState.activeLifecycle == nil)
            }
        }

        @Test("a failed open from the picker (no project open) is reported the same way")
        func openFailureWithNoOpenProjectIsReported() async throws {
            await Harness.withWorld(hasOpenProject: false) { _ in
                let recorder = ProjectCommandRecorder()
                recorder.openError = CommandBoom()

                let result = await ProjectCommands.open(url: url, recorder.environment)

                #expect(result == .failed)
                #expect(LifecycleEntry.testEvents == [.passedThrough(.noOpenProject)])
                #expect(recorder.reported.map(\.url) == [url])
            }
        }

        // MARK: - Outcomes

        @Test("""
            a close pressed while a switch is saving is HELD, not refused (t-eb07cd67): nothing shows, perform waits, and \
            it runs after the switch, with no warning
            """)
        func aCloseDuringASwitchIsHeldThenRuns() async throws {
            try await Harness.withWorld { world in
                Harness.mount(world)
                let gate = Harness.Gate()
                let first = Task { @MainActor in
                    try await LifecycleEntry.run(kind: .projectSwitch) {
                        await gate.wait()
                        return .open
                    }
                }
                await Harness.waitUntil("the first lifecycle to arm") { world.editorState.activeLifecycle != nil }
                #expect(world.editorState.activeLifecycle?.kind == .projectSwitch, "positive proof: a switch is running")
                let recorder = ProjectCommandRecorder()

                let closing = Task { @MainActor in await ProjectCommands.close(recorder.environment) }
                await Harness.waitUntil("the close to be held") {
                    LifecycleEntry.testEvents.contains(.held(requested: .close, behind: .projectSwitch))
                }
                #expect(recorder.closes == 0, "perform waits for the switch")
                #expect(recorder.posts.isEmpty)
                #expect(world.toasts.current == nil, "no refusal, nothing in the first second")

                gate.open()
                _ = try await first.value
                let result = await closing.value
                #expect(result == .lifecycle(.performed))
                #expect(recorder.closes == 1, "the held close ran once the switch had finished")
                #expect(recorder.posts.map(\.name) == [.projectDidClose])
                #expect(world.toasts.current?.style != .warning, "never a warning")
                #expect(LifecycleEntry.current == nil)
            }
        }

        @Test("""
            a quit that joined before perform ran: the command returns .skippedForQuit, perform never ran (the other \
            project is not opened) and nothing is shown
            """)
        func skippedForQuitShowsNothing() async throws {
            let controller = StructuralUndoController()
            await Harness.withWorld(controller: controller) { world in
                Harness.mount(world)
                controller.testSetIsPerforming(true)   // holds step 1 so the quit can join while the sequence waits
                let recorder = ProjectCommandRecorder()
                let command = Task { @MainActor in await ProjectCommands.open(url: url, recorder.environment) }
                await Harness.waitUntil("the switch to arm") { world.editorState.activeLifecycle?.kind == .projectSwitch }

                guard case .joined(let quit) = world.editorState.armLifecycle(.quit, wasGettingStarted: false) else {
                    Issue.record("the quit did not join the running switch")
                    controller.testSetIsPerforming(false)
                    _ = await command.value
                    return
                }
                controller.testSetIsPerforming(false)   // the section operation clears: the sequence goes on, flushed
                let result = await command.value

                #expect(LifecycleEntry.testEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
                #expect(result == .lifecycle(.skippedForQuit))
                #expect(recorder.openedURLs.isEmpty, "perform was skipped: the other project is not opened")
                #expect(recorder.posts.isEmpty)
                #expect(recorder.reported.isEmpty)
                #expect(world.toasts.current == nil, "nothing happened, show nothing")
                #expect(world.probe.log.isEmpty, "no tail ran for the skipped switch")
                _ = world.editorState.clearLifecycle(quit.id)
            }
        }
    }
}

// t-eb07cd67's second held-command test is in an extension, so the struct body stays under the project's type-body-length limit.
extension LifecycleEntryStatic.ProjectCommandsTests {

    @Test("""
        a second Open of the project the running switch is opening is HELD, then does nothing: its already-open check \
        is made after the wait (t-eb07cd67), so the project is opened exactly once
        """)
    func aSecondOpenOfTheProjectBeingOpenedIsHeldThenDoesNothing() async throws {
        let controller = StructuralUndoController()
        await Harness.withWorld(controller: controller) { world in
            Harness.mount(world)
            controller.testSetIsPerforming(true)   // holds the first switch inside its save sequence (step 1)
            let recorder = ProjectCommandRecorder()
            // The recorder has no project open; follow the opens the way `DocumentManager.projectURL` does.
            recorder.onOpen = { [unowned recorder] in recorder.currentProjectURL = url }
            let first = Task { @MainActor in await ProjectCommands.open(url: url, recorder.environment) }
            await Harness.waitUntil("the first switch to arm") { world.editorState.activeLifecycle?.kind == .projectSwitch }
            let second = Task { @MainActor in await ProjectCommands.open(url: url, recorder.environment) }
            await Harness.waitUntil("the second open to be held") {
                LifecycleEntry.testEvents.contains(.held(requested: .projectSwitch, behind: .projectSwitch))
            }
            #expect(recorder.openedURLs.isEmpty, "nothing is opened while the first switch is still saving")
            #expect(world.toasts.current == nil)

            controller.testSetIsPerforming(false)   // the section operation clears: the first switch goes on
            #expect(await first.value == .lifecycle(.performed))
            #expect(await second.value == .sameProjectAlreadyOpen, "checked after the wait: that project is now open")
            #expect(recorder.openedURLs == [url], "opened exactly once")
            #expect(LifecycleEntry.testEvents.filter { $0 == .armed(.projectSwitch) }.count == 1, "the held open armed nothing")
            #expect(LifecycleEntry.testEvents.contains(.admitted(.projectSwitch)))
            #expect(world.toasts.current?.style != .warning)
        }
    }
}
