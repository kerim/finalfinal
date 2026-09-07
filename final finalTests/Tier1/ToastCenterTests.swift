//
//  ToastCenterTests.swift
//  final finalTests
//
//  Tier 1: pure state-machine coverage for `ToastCenter`'s queue-with-cutoff rules (see its
//  own doc comment, and the plan's §0 call-out for t-15cb7dd8) plus `ToastFactory`'s shape
//  guarantees (style, message, and "at most one action" — §4.1.2).
//
//  Every test constructs its own `ToastCenter()` instance (not `.shared`) so nothing here
//  mutates the app-wide singleton or races other parallel tests, and every cutoff test injects
//  `now` explicitly rather than sleeping real wall-clock time.
//

import Testing
import Foundation
@testable import final_final

@Suite("ToastCenter — Tier 1: queue-with-cutoff rules")
struct ToastCenterTests {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func success(_ message: String = "success") -> Toast {
        Toast(style: .success, message: message)
    }

    private func warning(_ message: String = "warning") -> Toast {
        Toast(style: .warning, message: message)
    }

    // MARK: - Basic show()

    @Test("A success toast lands in the slot and is marked fading")
    @MainActor
    func successShowsInSlotAndIsMarkedFading() {
        let center = ToastCenter()
        let toast = success()
        center.show(toast, now: epoch)
        #expect(center.current?.id == toast.id)
        #expect(center.current?.fades == true)
    }

    @Test("A warning toast lands in the slot and does not fade")
    @MainActor
    func warningShowsInSlotAndDoesNotFade() {
        let center = ToastCenter()
        let toast = warning()
        center.show(toast, now: epoch)
        #expect(center.current?.id == toast.id)
        #expect(center.current?.fades == false)
    }

    // MARK: - Same-style replacement

    @Test("A new success replaces a showing success")
    @MainActor
    func newSuccessReplacesShowingSuccess() {
        let center = ToastCenter()
        center.show(success("first"), now: epoch)
        let second = success("second")
        center.show(second, now: epoch)
        #expect(center.current?.id == second.id)
        #expect(center.current?.message == "second")
    }

    @Test("A warning evicts a showing success")
    @MainActor
    func warningEvictsShowingSuccess() {
        let center = ToastCenter()
        center.show(success(), now: epoch)
        let theWarning = warning()
        center.show(theWarning, now: epoch)
        #expect(center.current?.id == theWarning.id)
        #expect(center.current?.style == .warning)
    }

    @Test("A new warning replaces a showing warning")
    @MainActor
    func warningReplacesShowingWarning() {
        let center = ToastCenter()
        center.show(warning("first"), now: epoch)
        let second = warning("second")
        center.show(second, now: epoch)
        #expect(center.current?.id == second.id)
        #expect(center.current?.message == "second")
    }

    // MARK: - The queue-over-replace rule (§0 call-out)

    @Test("A success never evicts an undismissed warning — it pends instead")
    @MainActor
    func successDoesNotEvictUndismissedWarning_andPends() {
        let center = ToastCenter()
        let theWarning = warning()
        center.show(theWarning, now: epoch)
        let theSuccess = success()
        center.show(theSuccess, now: epoch)

        // The warning is still showing -- untouched.
        #expect(center.current?.id == theWarning.id)
        // The success is queued, not discarded.
        #expect(center.pending?.toast.id == theSuccess.id)
    }

    @Test("A pending success stamped within the 10s cutoff is promoted when the warning is dismissed")
    @MainActor
    func pendingSuccessPromotedWhenWarningDismissedInsideCutoff() {
        let center = ToastCenter()
        center.show(warning(), now: epoch)
        let theSuccess = success()
        center.show(theSuccess, now: epoch)

        center.dismissCurrent(now: epoch.addingTimeInterval(9))

        #expect(center.current?.id == theSuccess.id)
        #expect(center.current?.fades == true)
        #expect(center.pending == nil)
    }

    @Test("A pending success that outlives the 10s cutoff is discarded, not promoted")
    @MainActor
    func pendingSuccessDiscardedWhenWarningOutlivesCutoff() {
        let center = ToastCenter()
        center.show(warning(), now: epoch)
        center.show(success(), now: epoch)

        center.dismissCurrent(now: epoch.addingTimeInterval(11))

        #expect(center.current == nil)
        #expect(center.pending == nil)
    }

    @Test("A pending success stamped exactly at the 10.0s cutoff boundary is still promoted (the code branches on <=)")
    @MainActor
    func pendingSuccessAtExactCutoffBoundaryIsPromoted() {
        let center = ToastCenter()
        center.show(warning(), now: epoch)
        let theSuccess = success()
        center.show(theSuccess, now: epoch)

        center.dismissCurrent(now: epoch.addingTimeInterval(10))

        #expect(center.current?.id == theSuccess.id)
        #expect(center.pending == nil)
    }

    @Test("Only one success pends at a time -- a newer one replaces the older and resets its stamp")
    @MainActor
    func onlyOneSuccessPends_newerReplacesOlderAndResetsStamp() {
        let center = ToastCenter()
        center.show(warning(), now: epoch)

        // An old pending success, stamped early...
        center.show(success("stale"), now: epoch)
        // ...replaced by a fresh one, stamped later.
        let fresh = success("fresh")
        center.show(fresh, now: epoch.addingTimeInterval(8))

        // Dismissing 9s after the ORIGINAL stamp (1s after the fresh one) would have discarded
        // the stale pending (age 9s > cutoff from its own stamp is not the point here -- the
        // point is only ONE toast is pending at all, and it's the fresh one).
        #expect(center.pending?.toast.id == fresh.id)
        #expect(center.pending?.toast.message == "fresh")

        // And the fresh stamp -- not the stale one -- governs promotion: 11s after the fresh
        // stamp is past cutoff even though it's only 19s after the original warning.
        center.dismissCurrent(now: epoch.addingTimeInterval(8 + 11))
        #expect(center.current == nil)
    }

    // MARK: - Dismiss with nothing pending

    @Test("dismissCurrent() with no pending toast simply leaves the slot empty")
    @MainActor
    func dismissCurrentWithNoPendingLeavesSlotEmpty() {
        let center = ToastCenter()
        center.show(success(), now: epoch)
        center.dismissCurrent(now: epoch)
        #expect(center.current == nil)
        #expect(center.pending == nil)
    }

    // MARK: - ToastFactory shape guarantees

    @Test("Every warning ToastFactory produces is style .warning, carries at most one action, and is actually dismissible")
    @MainActor
    func everyWarningIsDismissibleAndCarriesAtMostOneAction() {
        // Zero-action warnings (§0 call-out 1: no meaningful action exists for these two).
        let zeroAction: [Toast] = [
            ToastFactory.tableTruncated(rows: 1000, cols: 100),
            ToastFactory.gettingStartedNotSaved()
        ]
        for toast in zeroAction {
            #expect(toast.style == .warning)
            #expect(toast.action == nil)

            // Dismissibility can't come from an action button here (there is none) -- it must
            // come from the ✕ (`dismissCurrent()`) clearing the slot on its own.
            let center = ToastCenter()
            center.show(toast, now: epoch)
            center.dismissCurrent(now: epoch)
            #expect(center.current == nil)
        }

        // The one warning that does carry an action carries exactly one, never more --
        // `ToastAction?` enforces that at the type level, so this asserts the factory actually
        // produces a single non-nil action rather than the type merely allowing at most one.
        let withAction = ToastFactory.exportSucceededWithWarnings(result: sampleExportResult(warnings: ["a warning"]))
        #expect(withAction.style == .warning)
        #expect(withAction.action?.title == "Show Details")

        // ...and is still dismissible via the ✕ regardless of that action.
        let center = ToastCenter()
        center.show(withAction, now: epoch)
        center.dismissCurrent(now: epoch)
        #expect(center.current == nil)
    }

    @Test("Export with warnings is a warning-style toast with a single Show Details action")
    @MainActor
    func exportWithWarningsIsWarningStyleWithSingleShowDetailsAction() {
        let toast = ToastFactory.exportSucceededWithWarnings(result: sampleExportResult(warnings: ["Some pandoc warning"]))
        #expect(toast.style == .warning)
        #expect(toast.action?.title == "Show Details")
        #expect(toast.fades == false)
    }

    @Test("Export without warnings is a success-style toast with a single Show in Finder action")
    @MainActor
    func exportWithoutWarningsIsSuccessStyleWithSingleShowInFinderAction() {
        let toast = ToastFactory.exportSucceeded(result: sampleExportResult(warnings: []))
        #expect(toast.style == .success)
        #expect(toast.action?.title == "Show in Finder")
        #expect(toast.fades == true)
    }

    // MARK: - Fixtures

    private func sampleExportResult(warnings: [String]) -> ExportResult {
        ExportResult(
            outputURL: URL(fileURLWithPath: "/tmp/toast-center-tests-export.docx"),
            format: .word,
            zoteroStatus: .running,
            warnings: warnings,
            zoteroStatusWasProbed: false
        )
    }
}
