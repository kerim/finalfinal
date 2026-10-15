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

    // MARK: - dismissIfCurrent (AutoBackupService's own-toast retraction)

    @Test("dismissIfCurrent clears the slot when the id matches the current toast")
    @MainActor
    func dismissIfCurrentClearsMatchingToast() {
        let center = ToastCenter()
        let toast = warning()
        center.show(toast, now: epoch)

        center.dismissIfCurrent(id: toast.id, now: epoch)

        #expect(center.current == nil)
    }

    @Test("dismissIfCurrent is a no-op for a stale id once a different toast has taken the slot")
    @MainActor
    func dismissIfCurrentIgnoresStaleId() {
        let center = ToastCenter()
        let firstWarning = warning("first")
        center.show(firstWarning, now: epoch)

        let secondWarning = warning("second")
        center.show(secondWarning, now: epoch)

        // The id of the toast that no longer occupies the slot.
        center.dismissIfCurrent(id: firstWarning.id, now: epoch)

        #expect(center.current?.id == secondWarning.id, "a stale id must not touch a newer, unrelated toast")
    }

    // MARK: - A progress toast never permanently replaces a standing warning (addendum A5, t-94369a83)

    private func progress(_ message: String = "progress") -> Toast {
        Toast(style: .progress, message: message)
    }

    @Test("A warning a progress toast displaced is shown again when that progress toast is dismissed by id")
    @MainActor
    func testWarningReturnsAfterProgressDismissed() {
        let center = ToastCenter()
        let theWarning = warning()
        center.show(theWarning, now: epoch)
        let working = progress("Finishing the last change…")
        center.show(working, now: epoch)
        #expect(center.current?.id == working.id, "a progress toast still takes the slot over a warning")

        center.dismiss(id: working.id, now: epoch)

        #expect(center.current?.id == theWarning.id, "the displaced warning comes back; it was not evicted for good")
        #expect(center.displacedWarning == nil)
    }

    @Test("A newer warning replaces the displaced one: dismissing the progress toast then restores nothing")
    @MainActor
    func testNewerWarningReplacesDisplacedWarning() {
        let center = ToastCenter()
        center.show(warning("old"), now: epoch)
        let working = progress()
        center.show(working, now: epoch)
        let newer = warning("newer")
        center.show(newer, now: epoch)
        #expect(center.current?.id == newer.id)

        center.dismiss(id: working.id, now: epoch)   // already replaced: a no-op

        #expect(center.current?.id == newer.id)
        center.dismissCurrent(now: epoch)
        #expect(center.current == nil, "the older warning was replaced by the newer one and does not come back")
    }

    @Test("A success shown while a progress toast covers a warning waits behind that warning")
    @MainActor
    func testSuccessDuringProgressWaitsBehindDisplacedWarning() {
        let center = ToastCenter()
        let theWarning = warning()
        center.show(theWarning, now: epoch)
        center.show(progress(), now: epoch)
        let done = success("done")

        center.show(done, now: epoch)

        #expect(center.current?.id == theWarning.id, "a success never evicts an undismissed warning, even a displaced one")
        #expect(center.pending?.toast.id == done.id)
    }

    @Test("A progress toast over a success or an empty slot restores nothing when dismissed")
    @MainActor
    func testProgressWithoutWarningRestoresNothing() {
        let center = ToastCenter()
        center.show(success(), now: epoch)
        let working = progress()
        center.show(working, now: epoch)

        center.dismiss(id: working.id, now: epoch)

        #expect(center.current == nil)
        #expect(center.displacedWarning == nil)
    }

    // MARK: - The app-log lines (`[toast] show` / `[toast] dismiss`)

    /// A UI test confirms a toast from these lines (a 3 s toast can be gone before the accessibility tree is read on a book-length
    /// document), so the prefix `[toast] show ` and the field order are a contract. Read through the instance's own `logSink`, which
    /// receives exactly the text `DebugLog` gets, so no process-global log is involved.
    @MainActor
    private func centerLoggingTo(_ lines: ToastLogLines) -> ToastCenter {
        let center = ToastCenter()
        center.logSink = { lines.items.append($0) }
        return center
    }

    @Test("A result toast writes a show line, and a dismiss line with the reason it left")
    @MainActor
    func resultToastWritesShowThenDismissLine() {
        let lines = ToastLogLines()
        let center = centerLoggingTo(lines)

        center.show(Toast(style: .success, message: "Version saved."), now: epoch)
        #expect(lines.items == ["[toast] show style=success message=Version saved."])

        center.dismissCurrent(now: epoch, reason: .faded)
        #expect(lines.items == [
            "[toast] show style=success message=Version saved.",
            "[toast] dismiss message=Version saved. reason=faded"
        ])

        // Another way out: the ✕ button (the default reason), with a message that has a line break in it.
        center.show(Toast(style: .warning, message: "Two\nlines\r\nhere."), now: epoch)
        center.dismissCurrent(now: epoch)
        #expect(Array(lines.items.suffix(2)) == [
            "[toast] show style=warning message=Two lines here.",
            "[toast] dismiss message=Two lines here. reason=dismissed"
        ], "the message is logged whole, with line breaks made spaces: \(lines.items)")
    }

    @Test("A progress toast replaced by its result writes a dismiss line (replaced) for the progress and a show line for the result")
    @MainActor
    func progressReplacedByResultWritesDismissThenShowLine() {
        let lines = ToastLogLines()
        let center = centerLoggingTo(lines)

        center.show(progress("Exporting to Word…"), now: epoch)
        center.show(Toast(style: .success, message: "Exported."), now: epoch)

        #expect(lines.items == [
            "[toast] show style=progress message=Exporting to Word…",
            "[toast] dismiss message=Exporting to Word… reason=replaced",
            "[toast] show style=success message=Exported."
        ])
    }

    @Test("A progress toast its owner takes down (ended) and a warning it covered: dismiss, replaced, then the warning shows again")
    @MainActor
    func progressOverWarningWritesReplacedThenEndedThenShowLines() {
        let lines = ToastLogLines()
        let center = centerLoggingTo(lines)
        let working = progress("Finishing the last change…")

        center.show(warning("Couldn't save version."), now: epoch)
        center.show(working, now: epoch)
        center.dismiss(id: working.id, now: epoch)

        #expect(lines.items == [
            "[toast] show style=warning message=Couldn't save version.",
            "[toast] dismiss message=Couldn't save version. reason=replaced",
            "[toast] show style=progress message=Finishing the last change…",
            "[toast] dismiss message=Finishing the last change… reason=ended",
            "[toast] show style=warning message=Couldn't save version."
        ])
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

/// The lines a `ToastCenter` wrote to its `logSink`, in order.
@MainActor
private final class ToastLogLines {
    var items: [String] = []
}
