//
//  EditorFirstRestoreNoticeTests.swift
//  final finalTests
//
//  Tier 2 (t-18b7fa48 Phase 4b, final fix round, plan D11 and the floor rule "past one second the app shows it is working"): the three
//  Version History restores (Restore Entire Project, Replace Current Section, Restore as Duplicate / "Insert as New Section") show the
//  "Finishing the last change..." notice once the press has taken a second, and take it down again on every way out of the press.
//
//  The scripted editor holds the restore click's reply (the real editor's JavaScript call is what takes the time on a book), the notice's
//  delay is shortened for the test (`DelayedProgressToast.defaultDelay`, restored in a `defer`), and the test reads the toast center the
//  press was handed:
//    - while the click is held, the progress toast with the shared wording is on the slot;
//    - once the press has ended, the slot no longer holds a progress toast (dismissed by id: an owner that forgot `stop()` leaves it up
//      for good, a progress toast never fades);
//    - the same when the editor REFUSES the click and the press is handed to the old restore (the nil exit).
//  The scripted editor names no production symbol of the restore (EditorFirstRig+Restore.swift), so the file compiles with the fix taken
//  out and each test fails for the missing notice, not for a compile error.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

import Foundation
import GRDB
import Testing
@testable import final_final

@Suite("Version restore: the working notice (t-18b7fa48 final fix round, D11, Tier 2)", .serialized, .timeLimit(.minutes(6)))
@MainActor
struct EditorFirstRestoreNoticeTests: QuickUndoFixtures {

    /// Which of the three restores a test presses.
    private enum RestoreKind {
        case wholeProject
        case replaceSection
        case insertAsNewSection
    }

    // MARK: - The click shows the notice and takes it down

    @Test("Restore Entire Project: the notice shows while the click is held and is gone once the press has ended")
    func testWholeRestoreShowsTheWorkingNoticeThenDismissesIt() async throws {
        try await expectNoticeWhileHeldThenGone(.wholeProject)
    }

    @Test("Replace Current Section: the notice shows while the click is held and is gone once the press has ended")
    func testReplaceSectionRestoreShowsTheWorkingNoticeThenDismissesIt() async throws {
        try await expectNoticeWhileHeldThenGone(.replaceSection)
    }

    @Test("Insert as New Section: the notice shows while the click is held and is gone once the press has ended")
    func testInsertSectionRestoreShowsTheWorkingNoticeThenDismissesIt() async throws {
        try await expectNoticeWhileHeldThenGone(.insertAsNewSection)
    }

    // MARK: - A refused click leaves no notice behind

    @Test("Restore Entire Project: an editor that refuses the click leaves no notice behind when the old restore takes over")
    func testRefusedWholeRestoreLeavesNoNotice() async throws {
        try await expectNoNoticeLeftAfterARefusedClick(.wholeProject)
    }

    @Test("Replace Current Section: an editor that refuses the click leaves no notice behind when the old restore takes over")
    func testRefusedReplaceSectionRestoreLeavesNoNotice() async throws {
        try await expectNoNoticeLeftAfterARefusedClick(.replaceSection)
    }

    @Test("Insert as New Section: an editor that refuses the click leaves no notice behind when the old restore takes over")
    func testRefusedInsertSectionRestoreLeavesNoNotice() async throws {
        try await expectNoNoticeLeftAfterARefusedClick(.insertAsNewSection)
    }

    // MARK: - The shared bodies

    private func expectNoticeWhileHeldThenGone(_ kind: RestoreKind) async throws {
        let savedDelay = DelayedProgressToast.defaultDelay
        DelayedProgressToast.defaultDelay = .milliseconds(20)
        defer { DelayedProgressToast.defaultDelay = savedDelay }
        let (rig, version) = try await makeRig(for: kind)
        defer { unpinAllVersions(rig) }
        let clickMayAnswer = LifecycleEntryHarness.Gate()
        defer { clickMayAnswer.open() }
        holdTheRestoreClick(rig, until: clickMayAnswer)

        let press = Task { @MainActor in await self.pressRestore(kind, rig: rig, version: version) }
        let shown = await gateWaitUntil({ Self.isTheWorkingNotice(rig.toasts.current) }, iterations: 400)
        #expect(shown, "no 'Finishing the last change...' notice while the click was held; the slot holds \(Self.describe(rig.toasts.current))")
        clickMayAnswer.open()
        let outcome = await press.value

        #expect(outcome == .performed, "the press did not end as performed: \(outcome)")
        _ = await rig.waitUntilSettled()
        #expect(restoreRanEditorFirst(rig), "the editor-first restore did not run: \(rig.persistedLog)")
        #expect(
            rig.toasts.current?.style != .progress,
            "the notice stayed up after the press ended; the slot holds \(Self.describe(rig.toasts.current))")
    }

    private func expectNoNoticeLeftAfterARefusedClick(_ kind: RestoreKind) async throws {
        let savedDelay = DelayedProgressToast.defaultDelay
        DelayedProgressToast.defaultDelay = .milliseconds(20)
        defer { DelayedProgressToast.defaultDelay = savedDelay }
        let (rig, version) = try await makeRig(for: kind)
        defer { unpinAllVersions(rig) }
        rig.forceEditorRefusal = true   // the editor answers ok:false and the press falls back to the old restore
        let clickMayAnswer = LifecycleEntryHarness.Gate()
        defer { clickMayAnswer.open() }
        holdTheRestoreClick(rig, until: clickMayAnswer)

        let press = Task { @MainActor in await self.pressRestore(kind, rig: rig, version: version) }
        let shown = await gateWaitUntil({ Self.isTheWorkingNotice(rig.toasts.current) }, iterations: 400)
        #expect(shown, "no 'Finishing the last change...' notice while the click was held; the slot holds \(Self.describe(rig.toasts.current))")
        clickMayAnswer.open()
        _ = await press.value
        _ = await rig.waitUntilSettled()

        let fellBack = rig.persistedLog.contains { $0.contains("fell back to the old path") }
        #expect(fellBack, "the editor's refusal was not taken: no fallback line in this rig's log: \(rig.persistedLog)")
        #expect(
            rig.toasts.current?.style != .progress,
            "the notice stayed up after the refused click was handed to the old restore; the slot holds \(Self.describe(rig.toasts.current))")
    }

    /// The rig and the saved version a restore of `kind` is pressed on, set up as the existing suites set theirs up
    /// (EditorFirstRestoreTests, EditorFirstSectionRestoreTests).
    private func makeRig(for kind: RestoreKind) async throws -> (EditorFirstRig, Snapshot) {
        switch kind {
        case .wholeProject:
            return try makeRigWithEditedBody()
        case .replaceSection:
            let (rig, version) = try await makeSectionRigWithVersion()
            let body = try blockWithText(rig, "The C body.")
            try rig.rewriteText(ofBlock: body.id, to: Self.editedBody)
            try await rig.fillSectionTable()   // the window syncs the table from the document when it opens
            return (rig, version)
        case .insertAsNewSection:
            return try await makeSectionRigWithVersion()
        }
    }

    private func pressRestore(
        _ kind: RestoreKind, rig: EditorFirstRig, version: Snapshot
    ) async -> StructuralUndoController.StructuralOpOutcome {
        switch kind {
        case .wholeProject:
            return await rig.performRestore("project", from: version)
        case .replaceSection:
            return await rig.performRestore("replace", from: version, section: "Section C")
        case .insertAsNewSection:
            return await rig.performRestore("duplicate", from: version, section: "Section A")
        }
    }

    /// The editor's reply to the restore click arrives only when `gate` opens (JavaScript on a book takes seconds); every other call the
    /// scripted editor answers as before.
    private func holdTheRestoreClick(_ rig: EditorFirstRig, until gate: LifecycleEntryHarness.Gate) {
        rig.sync.testJSEvaluator = { [weak rig] script in
            if script.contains("replaceRangeEditorFirst") { await gate.wait() }
            return try await rig?.answerScript(script)
        }
    }

    private static func isTheWorkingNotice(_ toast: Toast?) -> Bool {
        toast?.style == .progress && toast?.message == DelayedProgressToast.finishingMessage
    }

    private static func describe(_ toast: Toast?) -> String {
        toast.map { "a \($0.style) toast '\($0.message)'" } ?? "nothing"
    }
}
