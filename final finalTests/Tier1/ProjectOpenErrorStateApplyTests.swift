//
//  ProjectOpenErrorStateApplyTests.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C8b (slice-3a-1b-everyday.md section 5.5 "E6", must-fix #16): the error sheet's
//  write-back once a Repair or Open Anyway has finished (`ProjectOpenErrorState.apply`).
//
//    - The sheet is dismissed ONLY when the project opened. A Repair that is still broken keeps it up with the UPDATED
//      report; one that failed keeps it up with the error; a lifecycle that never ran `perform` (cancelled, busy, a
//      repeated click, a quit) leaves it exactly as it was. A failed Repair is never silent.
//    - Nothing is written unless the sheet still shows the failure the action was launched against (the user could
//      press Cancel, or another failure could arrive, while the repair ran).
//
//  Each test builds its own isolated `ProjectOpenErrorState` (its initializer is internal for exactly this).
//

import Foundation
import Testing
@testable import final_final

private struct SheetBoom: LocalizedError {
    var errorDescription: String? { "the repair blew up" }
}

@Suite("ProjectOpenErrorState.apply: the sheet's write-back after Repair (E6) — Tier 1 (t-94369a83 3a-1b C8b)")
@MainActor
struct ProjectOpenErrorStateApplyTests {

    private let url = URL(fileURLWithPath: "/tmp/sheet-broken-b.ff")
    private let otherURL = URL(fileURLWithPath: "/tmp/sheet-other-c.ff")

    private func report(_ issues: [IntegrityIssue] = [.missingDatabase], at packageURL: URL? = nil) -> IntegrityReport {
        IntegrityReport(issues: issues, packageURL: packageURL ?? url)
    }

    /// A state showing the integrity sheet the Repair button was pressed on.
    private func stateShowingTheBrokenProject() -> (state: ProjectOpenErrorState, expectedId: String) {
        let state = ProjectOpenErrorState()
        state.pending = .integrity(report: report(), url: url, blockedOpen: true)
        return (state, url.path)
    }

    @Test("opened: the ONLY outcome that dismisses the sheet")
    func openedDismissesTheSheet() {
        let (state, id) = stateShowingTheBrokenProject()

        state.apply(.opened, expectedId: id, url: url, blockedOpen: true)

        #expect(state.pending == nil)
    }

    @Test("stillBroken: the sheet stays up and shows the UPDATED report")
    func stillBrokenKeepsTheSheetWithTheNewReport() {
        let (state, id) = stateShowingTheBrokenProject()

        state.apply(.stillBroken(report([.missingProjectRecord])), expectedId: id, url: url, blockedOpen: true)

        guard case .integrity(let shown, let shownURL, let blockedOpen)? = state.pending else {
            Issue.record("the integrity sheet must stay up, got \(String(describing: state.pending))")
            return
        }
        #expect(shown.issues == [.missingProjectRecord], "the updated report, not the one the user already saw")
        #expect(shownURL == url)
        #expect(blockedOpen == true)
    }

    @Test("failed: the sheet stays up and shows the error (the .other view), so a failed Repair is never silent")
    func failedKeepsTheSheetWithTheError() {
        let (state, id) = stateShowingTheBrokenProject()

        state.apply(.failed(SheetBoom()), expectedId: id, url: url, blockedOpen: true)

        guard case .other(let message, let shownURL)? = state.pending else {
            Issue.record("the sheet must stay up with the error, got \(String(describing: state.pending))")
            return
        }
        #expect(message == "the repair blew up")
        #expect(shownURL == url)
    }

    @Test("not run (cancelled, held then replaced by a later command, duplicate, a quit took over): the sheet is left exactly as it was")
    func notRunLeavesTheSheetAlone() {
        for ran in [LifecycleRunOutcome.cancelled, .superseded, .duplicate, .skippedForQuit] {
            let (state, id) = stateShowingTheBrokenProject()

            state.apply(.notRun(ran), expectedId: id, url: url, blockedOpen: true)

            guard case .integrity(let shown, _, _)? = state.pending else {
                Issue.record("\(ran): the sheet must stay up unchanged, got \(String(describing: state.pending))")
                continue
            }
            #expect(shown.issues == [.missingDatabase], "\(ran): the report is untouched")
        }
    }

    @Test("a sheet that no longer shows this failure (another failure arrived) is never overwritten, whatever the outcome")
    func aDifferentFailureIsNeverOverwritten() {
        let outcomes: [ProjectRepairOutcome] = [
            .opened, .stillBroken(report([.missingProjectRecord])), .failed(SheetBoom()), .notRun(.cancelled)
        ]
        for outcome in outcomes {
            let state = ProjectOpenErrorState()
            state.pending = .other(message: "something else", url: otherURL)

            state.apply(outcome, expectedId: url.path, url: url, blockedOpen: true)

            guard case .other(let message, let shownURL)? = state.pending else {
                Issue.record("the unrelated failure must stay, got \(String(describing: state.pending))")
                continue
            }
            #expect(message == "something else")
            #expect(shownURL == otherURL)
        }
    }

    @Test("a sheet the user already cancelled stays closed: nothing re-opens it")
    func aCancelledSheetStaysClosed() {
        let state = ProjectOpenErrorState()
        state.pending = nil

        state.apply(.stillBroken(report([.missingProjectRecord])), expectedId: url.path, url: url, blockedOpen: true)
        state.apply(.failed(SheetBoom()), expectedId: url.path, url: url, blockedOpen: true)

        #expect(state.pending == nil)
    }
}
