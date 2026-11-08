//
//  ProjectCommandsRepairTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C8b (slice-3a-1b-everyday.md sections 5.5 "E6" and 7.2 "C8b", must-fix #16): Repair
//  and Open Anyway (E6) against the REAL save sequence, the REAL tails and the REAL abort routine, on a bare
//  `ContentView` wired to a temporary project database (`LifecycleTailRig`).
//
//  The repair loop runs INSIDE `perform` (`IntegrityResolution.repair` is async, so `perform` is too). Three outcomes:
//
//    - opened: the project that was open is saved FIRST (it already holds the fresh text when the repair runs) and
//      backed up (a real snapshot ROW), the post is KEYED, nothing is left armed or held
//    - stillBroken / failed: `perform` THROWS, so the abort routine restores the editor (block ids re-pushed after FB,
//      polling running again, writer not retired, token and barrier gone), no tail ran (no automatic version) and no
//      post was made; the outcome goes back to the sheet
//
//  Item 32: every test asserts the `.armed` entry event so a pass-through can never make one pass vacuously. The
//  sheet's own write-back (dismissed ONLY for `.opened`) is pinned separately in `ProjectOpenErrorStateApplyTests`.
//

import Foundation
import Testing
@testable import final_final

private struct RepairBoom: Error, Equatable {}

extension LifecycleEntryStatic {
    @Suite("ProjectCommands Repair and Open Anyway (E6) — Tier 2 (t-94369a83 3a-1b C8b)", .serialized, .timeLimit(.minutes(1)))
    @MainActor
    struct ProjectCommandsRepairTests {

        private let url = URL(fileURLWithPath: "/tmp/command-repair-b.ff")

        private func report(_ issues: [IntegrityIssue] = [.missingDatabase]) -> IntegrityReport {
            IntegrityReport(issues: issues, packageURL: url)
        }

        // MARK: - opened

        @Test("""
            E6 opened: Repair with a project open saves it FIRST (it already holds the fresh text when the repair runs), \
            posts the KEYED .projectDidOpen, runs the open tail (a real snapshot row of the old project) and leaves nothing \
            armed or held
            """)
        func repairOpenedSavesAndBacksUpTheOpenProject() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            let recorder = ProjectCommandRecorder()
            let before = try rig.snapshotCount()
            rig.backup.contentDidChange()
            var oldProjectHadFreshTextWhenRepairRan: Bool?
            recorder.onRepair = {
                oldProjectHadFreshTextWhenRepairRan = try? rig.paragraphTexts().contains("fresh Y paragraph.")
            }
            var outcome: ProjectRepairOutcome?

            await rig.withEntry {
                outcome = await ProjectCommands.repair(report: report(), url: url, recorder.environment)
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
            guard case .opened = outcome else {
                Issue.record("expected .opened, got \(String(describing: outcome))")
                return
            }
            #expect(recorder.order == ["repair", "post:projectDidOpen"], "order: \(recorder.order)")
            #expect(recorder.repairs.first?.url == url)
            let post = try #require(recorder.posts.first)
            #expect(post.keyedTokenId != nil, "the post is keyed: the managed tail does the job")
            #expect(post.keyedTokenId == post.tokenIdAtPost, "with the id of the lifecycle that was running")
            #expect(oldProjectHadFreshTextWhenRepairRan == true, "the old project was saved BEFORE the repair ran")
            #expect(try rig.snapshotCount() == before + 1, "the old project's automatic version was made")
            #expect(try rig.snapshotPreviews().last?.contains("fresh Y paragraph.") == true, "after FB, so it holds the fresh text")
            #expect(!rig.entryEvents.contains(.safetyNetReleasedBarrier), "the tail retired the writer: nothing for the net")
            #expect(rig.editorState.activeLifecycle == nil)
            #expect(rig.editorState.lifecycleBarrier == nil)
        }

        @Test("E6 Open Anyway opened: the same save, keyed post and open tail")
        func openAnywayOpenedSavesAndBacksUpTheOpenProject() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            let recorder = ProjectCommandRecorder()
            let before = try rig.snapshotCount()
            rig.backup.contentDidChange()
            var outcome: ProjectRepairOutcome?

            await rig.withEntry {
                outcome = await ProjectCommands.openAnyway(url: url, recorder.environment)
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
            guard case .opened = outcome else {
                Issue.record("expected .opened, got \(String(describing: outcome))")
                return
            }
            #expect(recorder.order == ["openAnyway", "post:projectDidOpen"], "order: \(recorder.order)")
            #expect(recorder.posts.first?.keyedTokenId != nil)
            #expect(try rig.snapshotCount() == before + 1)
            #expect(rig.editorState.activeLifecycle == nil)
            #expect(rig.editorState.lifecycleBarrier == nil)
        }

        // MARK: - stillBroken and failed: perform throws, the abort restores

        /// What a restored editor looks like after an abort that followed an applied FB: the ids went back to the
        /// editor, its reports flow again (Phase 5 B4: it was the poll's restart), the writer was NOT retired (the project stays open),
        /// nothing is armed or held and
        /// no tail ran (no automatic version, no post).
        private func expectRestored(
            _ rig: LifecycleTailRig,
            recorder: ProjectCommandRecorder,
            pushes: [[String]],
            snapshotsBefore: Int,
            sourceLocation: SourceLocation = #_sourceLocation
        ) async throws {
            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)", sourceLocation: sourceLocation)
            #expect(pushes.count == 1, "FB applied, so the abort re-pushed the block ids once; got \(pushes)", sourceLocation: sourceLocation)
            #expect(await rig.reportHoldReleased(), "the editor's reports flow again", sourceLocation: sourceLocation)
            #expect(rig.editorState.activeLifecycle == nil, sourceLocation: sourceLocation)
            #expect(rig.editorState.lifecycleBarrier == nil, sourceLocation: sourceLocation)
            #expect(LifecycleEntry.current == nil, sourceLocation: sourceLocation)
            #expect(!rig.entryEvents.contains(.safetyNetReleasedBarrier), sourceLocation: sourceLocation)
            #expect(try rig.snapshotCount() == snapshotsBefore, "no tail ran: no automatic version", sourceLocation: sourceLocation)
            #expect(recorder.posts.isEmpty, "no .projectDidOpen was posted", sourceLocation: sourceLocation)
            let grant = rig.writer?.enqueueBarrier()
            #expect(grant != nil, "the writer was NOT retired: it still grants a barrier", sourceLocation: sourceLocation)
            grant?.release()
        }

        @Test("""
            E6 stillBroken: Repair that leaves critical issues THROWS out of perform, so the abort routine restores the \
            editor; the updated report goes back to the sheet; no post, no automatic version
            """)
        func repairStillBrokenRestoresTheEditorAndReturnsTheReport() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            var pushes: [[String]] = []
            rig.sync.testPushBlockIdsHook = { ids in pushes.append(ids) }
            let recorder = ProjectCommandRecorder()
            recorder.repairOutcome = .stillBroken(report([.missingProjectRecord]))
            rig.backup.contentDidChange()
            let before = try rig.snapshotCount()
            var outcome: ProjectRepairOutcome?

            await rig.withEntry {
                outcome = await ProjectCommands.repair(report: report(), url: url, recorder.environment)
            }

            guard case .stillBroken(let newReport) = outcome else {
                Issue.record("expected .stillBroken, got \(String(describing: outcome))")
                return
            }
            #expect(newReport.issues == [.missingProjectRecord], "the sheet gets the UPDATED report")
            #expect(recorder.order == ["repair"], "order: \(recorder.order)")
            try await expectRestored(rig, recorder: recorder, pushes: pushes, snapshotsBefore: before)
        }

        @Test("""
            E6 failed: a Repair that throws is never silent: perform THROWS, the abort routine restores the editor, and \
            the error goes back to the sheet
            """)
        func repairFailedRestoresTheEditorAndReturnsTheError() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            var pushes: [[String]] = []
            rig.sync.testPushBlockIdsHook = { ids in pushes.append(ids) }
            let recorder = ProjectCommandRecorder()
            recorder.repairOutcome = .failed(RepairBoom())
            rig.backup.contentDidChange()
            let before = try rig.snapshotCount()
            var outcome: ProjectRepairOutcome?

            await rig.withEntry {
                outcome = await ProjectCommands.repair(report: report(), url: url, recorder.environment)
            }

            guard case .failed(let error) = outcome else {
                Issue.record("expected .failed, got \(String(describing: outcome))")
                return
            }
            #expect(error as? RepairBoom == RepairBoom(), "the sheet gets the error")
            #expect(recorder.order == ["repair"], "order: \(recorder.order)")
            try await expectRestored(rig, recorder: recorder, pushes: pushes, snapshotsBefore: before)
        }

        @Test("E6 Open Anyway failed: the same restore, and the error goes back to the sheet")
        func openAnywayFailedRestoresTheEditor() async throws {
            let rig = try LifecycleTailRig(mountedEditor: true)
            defer { rig.shutdown() }
            var pushes: [[String]] = []
            rig.sync.testPushBlockIdsHook = { ids in pushes.append(ids) }
            let recorder = ProjectCommandRecorder()
            recorder.openAnywayOutcome = .failed(RepairBoom())
            rig.backup.contentDidChange()
            let before = try rig.snapshotCount()
            var outcome: ProjectRepairOutcome?

            await rig.withEntry {
                outcome = await ProjectCommands.openAnyway(url: url, recorder.environment)
            }

            guard case .failed(let error) = outcome else {
                Issue.record("expected .failed, got \(String(describing: outcome))")
                return
            }
            #expect(error as? RepairBoom == RepairBoom())
            #expect(recorder.order == ["openAnyway"], "order: \(recorder.order)")
            try await expectRestored(rig, recorder: recorder, pushes: pushes, snapshotsBefore: before)
        }

        // MARK: - not run

        @Test("""
            U5 for Repair: a section operation that never clears CANCELS it -- the repair never runs, the sheet is told \
            nothing was done (it stays), and the cancel notice is shown
            """)
        func repairIsCancelled_performNeverCalled() async throws {
            let rig = try LifecycleFlushHarness()
            rig.js.answer("flushPendingBlockChanges", true)
            rig.fetchAnswer = "# Alpha\n\nfresh Y paragraph.\n\n# Beta\n\nfour five six.\n"
            let toasts = ToastCenter()
            rig.editorState.toastCenter = toasts
            rig.controller.testSetIsPerforming(true)
            defer { rig.controller.testSetIsPerforming(false) }
            let recorder = ProjectCommandRecorder()
            var outcome: ProjectRepairOutcome?

            await rig.withEntry(bounds: LifecycleBounds.production.scaled(0.2)) {
                outcome = await ProjectCommands.repair(report: report(), url: url, recorder.environment)
            }

            #expect(rig.entryEvents.first == .armed(.projectSwitch), "the guard path ran (item 32)")
            guard case .notRun(let ran) = outcome else {
                Issue.record("expected .notRun, got \(String(describing: outcome))")
                return
            }
            #expect(ran == .cancelled)
            #expect(recorder.order.isEmpty, "the repair never ran; got \(recorder.order)")
            #expect(toasts.current?.message == ToastFactory.lifecycleCancelled().message, "the user is told")
            #expect(rig.editorState.activeLifecycle == nil)
        }

        @Test("E6 with nothing open (the picker): the repair runs straight through and the post is unkeyed (no editor to receive it)")
        func repairWithNothingOpenPassesThrough() async throws {
            await LifecycleEntryHarness.withWorld(hasOpenProject: false) { world in
                _ = world
                let recorder = ProjectCommandRecorder()

                let outcome = await ProjectCommands.repair(report: report(), url: url, recorder.environment)

                guard case .opened = outcome else {
                    Issue.record("expected .opened, got \(outcome)")
                    return
                }
                #expect(LifecycleEntry.testEvents == [.passedThrough(.noOpenProject)])
                #expect(recorder.order == ["repair", "post:projectDidOpen"], "order: \(recorder.order)")
                #expect(recorder.posts.first?.userInfo == nil, "unkeyed: nothing is mounted to receive it")
            }
        }
    }
}
