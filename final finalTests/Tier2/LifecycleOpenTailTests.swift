//
//  LifecycleOpenTailTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C5b (slice-3a-1b-everyday.md sections 4.4 and 7.2 "C5b"): the OPEN tail
//  (`ContentView.runOpenTail`, a completed switch) and the CREATE tail (`runCreateTail`), driven directly on a
//  bare `ContentView` wired to a temporary project database (`LifecycleTailRig`).
//
//    - #12 / N31: after a managed switch the unified undo timeline is EMPTY (both stacks): it is per-project
//      in-memory state. It runs on every completed switch tail and never on an abort (see
//      `LifecycleTailEntryTests`, where an aborted switch leaves the stacks intact)
//    - the old project's automatic version is a real snapshot ROW, made before the service reset (N30)
//    - P6: the old writer is retired with the switch reason, retire first: a parked system write resumes `.skipped`
//    - a quit that joined stands the tail down before `invalidateAll`, retire and the reconfigure
//    - the create seed (`seedCreatedProjectContent`, shared with the old `.projectDidCreate` handler) puts the new
//      project's initial content into the editor state and parses it into the new project's database; the create
//      tail does not run it when the open tail stood down for a joined quit
//
//  These tests never open a project in `DocumentManager.shared` (other suites do, concurrently, so nothing here
//  may depend on it being empty or write through it): they pin what the tail does to the OLD project and its
//  state. What the new project's configure/push does is unchanged `handleProjectOpened` code and is covered by
//  its own suites.
//

import Foundation
import Testing
@testable import final_final

extension LifecycleEntryStatic {
    @Suite("LifecycleEntry open and create tails — Tier 2 (t-94369a83 3a-1b C5b)", .serialized, .timeLimit(.minutes(1)))
    @MainActor
    struct LifecycleOpenTailTests {

        private func recordUndoHistory(_ service: UnifiedUndoService) {
            let first = StructuralEntry(kind: .restoreSectionReplace, title: "First", undoSnapshotId: "snap-1")
            let second = StructuralEntry(kind: .restoreSectionReplace, title: "Second", undoSnapshotId: "snap-2")
            service.record(first)
            service.record(second)
            _ = service.performUndo(opId: second.id)   // one entry on each stack
        }

        // MARK: - #12 / N31

        @Test("#12 / N31: after a managed switch the undo and redo stacks are empty")
        func openTailEmptiesTheUndoTimeline() async throws {
            let rig = try LifecycleTailRig()
            defer { rig.shutdown() }
            let undo = rig.view.unifiedUndoService
            recordUndoHistory(undo)
            #expect(!undo.undoStack.isEmpty && !undo.redoStack.isEmpty, "precondition: both stacks hold an entry")
            let token = rig.arm(.projectSwitch)

            let completed = await rig.view.runOpenTail(token: token)

            #expect(completed)
            #expect(undo.undoStack.isEmpty, "the undo stack belongs to the project that is going away")
            #expect(undo.redoStack.isEmpty)
        }

        // MARK: - The old project's automatic version, N30

        @Test("the open tail makes the OLD project's automatic version (a real row) before the reset, and records it")
        func openTailBacksUpTheOldProject() async throws {
            let rig = try LifecycleTailRig()
            defer { rig.shutdown() }
            let before = try rig.snapshotCount()
            rig.backup.contentDidChange()
            let token = rig.arm(.projectSwitch)

            await rig.view.runOpenTail(token: token)

            #expect(try rig.snapshotCount() == before + 1, "the switch backup must have run before autoBackupService.reset()")
            #expect(rig.editorState.lifecycleBackupDoneFor == token.id)
            #expect(rig.backup.hasUnsavedChanges == false)
        }

        // MARK: - P6

        @Test("P6: the open tail retires the OLD writer with the switch reason, retire first: a parked system write resumes .skipped")
        func openTailRetiresTheOldWriterThenReleases() async throws {
            let rig = try LifecycleTailRig()
            defer { rig.shutdown() }
            let token = rig.arm(.projectSwitch)
            _ = try #require(await rig.holdBarrier())
            let oldWriter = try #require(rig.writer)
            let parked = await rig.parkSystemWrite()

            await rig.view.runOpenTail(token: token)

            guard case .refused(.skipped(let reason)) = await parked.value.outcome else {
                Issue.record("the parked write must resume .skipped, never .go")
                return
            }
            #expect(reason == .projectSwitch)
            #expect(oldWriter.ledger.barriersCancelled == 0)
            #expect(rig.editorState.lifecycleBarrier == nil)
            #expect(oldWriter.testOpenBarrierSeq == nil)
        }

        // MARK: - A joined quit

        @Test("""
            a quit that JOINED the switch: the tail makes the old project's automatic version and the resets, then stands \
            down BEFORE invalidateAll, retire and the open (the new project is never set up, the barrier stays held)
            """)
        func joinedQuitStandsTheOpenTailDown() async throws {
            let rig = try LifecycleTailRig()
            defer { rig.shutdown() }
            let undo = rig.view.unifiedUndoService
            recordUndoHistory(undo)
            let before = try rig.snapshotCount()
            rig.backup.contentDidChange()
            let switchToken = rig.arm(.projectSwitch)
            let handle = try #require(await rig.holdBarrier())
            guard case .joined = rig.editorState.armLifecycle(.quit, wasGettingStarted: false) else {
                Issue.record("the quit must join the switch")
                return
            }

            let completed = await rig.view.runOpenTail(token: switchToken)

            #expect(!completed, "the tail did not run to the end")
            #expect(try rig.snapshotCount() == before + 1, "A is backed up before the check")
            #expect(!undo.undoStack.isEmpty && !undo.redoStack.isEmpty, "invalidateAll did not run")
            #expect(rig.editorState.lifecycleBarrier != nil, "the quit holds the barrier")
            #expect(rig.writer?.testOpenBarrierSeq == handle.seq)
            #expect(rig.editorState.content == LifecycleTailRig.seed, "no reset, no open sequence")
        }

        // MARK: - The structural gate (t-94369a83 Phase 4b slice 2a, fix round R1, addendum A21)

        @Test("R1: the open tail opens the structural gate right after it retires the old writer, so a Delete in the NEW project runs")
        func openTailOpensTheStructuralGateAfterTheRetire() async throws {
            let rig = try LifecycleTailRig()
            defer { rig.shutdown() }
            let gate = rig.editorState.structuralGate
            gate.isClosedToNewWork = true   // what step 1 of the save sequence does
            let token = rig.arm(.projectSwitch)
            _ = try #require(await rig.holdBarrier())
            #expect(gate.isClosedToNewWork, "precondition: the gate is closed while the old project is being saved")

            await rig.view.runOpenTail(token: token)

            #expect(rig.editorState.lifecycleBarrier == nil, "the tail retired the old writer")
            #expect(!gate.isClosedToNewWork, "the old writer is retired: the gate takes work again (LifecycleEntry.finish was not run)")
            let inTheNewProject = await gate.acquire()
            #expect(inTheNewProject == .granted, "a command in the new project is granted the gate")
            gate.release()
        }

        @Test("R1: a quit that joined the switch keeps the structural gate closed: the open tail stands down before it would open it")
        func joinedQuitKeepsTheStructuralGateClosedThroughTheOpenTail() async throws {
            let rig = try LifecycleTailRig()
            defer { rig.shutdown() }
            let gate = rig.editorState.structuralGate
            gate.isClosedToNewWork = true
            let switchToken = rig.arm(.projectSwitch)
            _ = try #require(await rig.holdBarrier())
            guard case .joined = rig.editorState.armLifecycle(.quit, wasGettingStarted: false) else {
                Issue.record("the quit must join the switch")
                return
            }

            let completed = await rig.view.runOpenTail(token: switchToken)

            #expect(!completed)
            #expect(gate.isClosedToNewWork, "the quit owns the project from here: nothing may be started in it")
            let lateCommand = await gate.acquire()
            #expect(lateCommand == .cancelled)
        }

        // MARK: - The create tail

        @Test("the create seed puts the initial content into the editor state AND parses it into the NEW project's database")
        func seedCreatedProjectContentWritesTheNewProjectsBlocks() async throws {
            let rig = try LifecycleTailRig(content: "# Placeholder\n")
            defer { rig.shutdown() }

            // The database and id are passed in (the tails pass DocumentManager's: the created project is the open one).
            await ContentView.seedCreatedProjectContent(
                "# Imported\n\nimported body.\n",
                editorState: rig.editorState,
                sectionSyncService: rig.view.sectionSyncService,
                database: rig.db,
                projectId: rig.pid
            )

            #expect(rig.editorState.content == "# Imported\n\nimported body.\n")
            #expect(try rig.paragraphTexts().contains("imported body."), "parsed into blocks in the new project's database")
        }

        @Test("the create tail does NOT seed when a quit joined and the open tail stood down (the new project was never set up)")
        func createTailDoesNotSeedAfterAJoinedQuit() async throws {
            let rig = try LifecycleTailRig()
            defer { rig.shutdown() }
            let token = rig.arm(.projectSwitch)
            guard case .joined = rig.editorState.armLifecycle(.quit, wasGettingStarted: false) else {
                Issue.record("the quit must join the create")
                return
            }

            await rig.view.runCreateTail(token: token, content: "# Imported\n")

            #expect(rig.editorState.content == LifecycleTailRig.seed, "nothing was seeded into the old project's editor state")
        }
    }
}
