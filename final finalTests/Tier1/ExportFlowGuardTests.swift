//
//  ExportFlowGuardTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//
//  Coverage for the PURE STATE MACHINE behind `ExportViewModel`'s re-entrancy guard --
//  `beginExportFlowIfIdle()` / `endExportFlow()` toggling the private `isExportFlowActive`
//  flag -- as distinct from `isExporting`, which only covers the pandoc run itself. Before
//  this guard existed, a second Export command fired while the first export's (modeless) save
//  panel was still open could kick off a second, concurrent `savePanelDecision`/
//  `presentSavePanel` flow from the same shared `ExportViewModel` singleton -- two save
//  panels, two competing Zotero preflights, racing each other.
//
//  These are pure state-machine tests on a fresh `ExportViewModel()` -- no `NSSavePanel`,
//  `NSAlert`, `ExportService`, or Zotero network access, so nothing here shows a real window
//  or makes a real network call. That also means these tests can only prove the guard itself
//  is a correct claim/release state machine, NOT that every real code path through
//  `showExportPanel`/`presentSavePanel` actually calls `endExportFlow()` on every exit --
//  a missing release somewhere in that real UI flow (an early return that forgets to release,
//  say) would leave every subsequent Export command silently ignored, and no test here would
//  catch it, since none of them drive `showExportPanel`/`presentSavePanel` themselves.
//  Release-topology correctness across those real UI flow paths is verified by manual/e2e
//  testing instead, not by these unit tests.

import Testing
import Foundation
@testable import final_final

@Suite("Export flow re-entrancy guard — Tier 1: Silent Killers")
struct ExportFlowGuardTests {

    @Test("Second beginExportFlowIfIdle() call returns false while the flow is still claimed")
    @MainActor
    func secondClaimFailsWhileActive() {
        let viewModel = ExportViewModel()
        #expect(viewModel.beginExportFlowIfIdle())
        #expect(!viewModel.beginExportFlowIfIdle())
        // Still claimed, not merely false-then-true by accident -- a further call must also fail.
        #expect(!viewModel.beginExportFlowIfIdle())
    }

    @Test("A fresh claim succeeds again after endExportFlow() releases the guard")
    @MainActor
    func claimSucceedsAgainAfterRelease() {
        let viewModel = ExportViewModel()
        #expect(viewModel.beginExportFlowIfIdle())
        viewModel.endExportFlow()
        #expect(viewModel.beginExportFlowIfIdle())
    }

    @Test("endExportFlow() on an already-idle instance is a harmless no-op")
    @MainActor
    func endOnIdleInstanceIsNoOp() {
        let viewModel = ExportViewModel()
        // Never claimed -- releasing anyway must not crash or leave the guard in a state that
        // blocks a subsequent legitimate claim.
        viewModel.endExportFlow()
        #expect(viewModel.beginExportFlowIfIdle())
    }
}
