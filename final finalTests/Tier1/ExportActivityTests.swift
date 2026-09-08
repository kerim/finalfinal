//
//  ExportActivityTests.swift
//  final finalTests
//
//  Tier 1: pure state-machine coverage for `ExportActivity` (UX contract §4.2 / D7) -- the
//  depth-counted begin/end pair that drives the export/print progress toast and the
//  disabled-while-running menu state in `FileCommands.swift`.
//
//  Every test builds its own `ToastCenter()` and `ExportActivity(toastCenter:)` (never
//  `.shared`) so nothing here mutates the app-wide singletons or races other parallel tests --
//  matching `ToastCenterTests.swift`'s own discipline.
//

import Testing
import Foundation
@testable import final_final

@Suite("ExportActivity — Tier 1: begin/end depth counting and toast lifecycle")
struct ExportActivityTests {

    private enum SampleError: Error {
        case boom
    }

    // MARK: - Basic begin/end

    @Test("begin(message:) sets isRunning and shows a .progress toast")
    @MainActor
    func beginSetsRunningAndShowsProgressToast() {
        let center = ToastCenter()
        let activity = ExportActivity(toastCenter: center)

        activity.begin(message: "Exporting to PDF…")

        #expect(activity.isRunning == true)
        #expect(center.current?.style == .progress)
        #expect(center.current?.message == "Exporting to PDF…")
    }

    @Test("end() clears isRunning and dismisses the progress toast")
    @MainActor
    func endClearsRunningAndDismissesToast() {
        let center = ToastCenter()
        let activity = ExportActivity(toastCenter: center)

        activity.begin(message: "Exporting to PDF…")
        activity.end()

        #expect(activity.isRunning == false)
        #expect(center.current == nil)
    }

    // MARK: - Nesting (depth counter)

    @Test("Nested begin/end pairs only flip state on the outermost pair")
    @MainActor
    func nestedBeginEndOnlyFlipsOnOutermostPair() {
        let center = ToastCenter()
        let activity = ExportActivity(toastCenter: center)

        activity.begin(message: "Outer")
        activity.begin(message: "Inner") // nested -- a no-op past the depth counter
        activity.end() // matches the inner begin -- still one outstanding

        #expect(activity.isRunning == true)
        #expect(center.current?.style == .progress)
        // The outer message is what's still showing -- the inner begin never replaced it.
        #expect(center.current?.message == "Outer")

        activity.end() // matches the outer begin -- now fully unwound

        #expect(activity.isRunning == false)
        #expect(center.current == nil)
    }

    // MARK: - Toast-less begin/end (nil message)

    @Test("begin(message: nil) still sets isRunning but shows no toast")
    @MainActor
    func beginWithNilMessageSetsRunningWithNoToast() {
        let center = ToastCenter()
        let activity = ExportActivity(toastCenter: center)

        activity.begin(message: nil)

        #expect(activity.isRunning == true)
        #expect(center.current == nil)

        activity.end()

        #expect(activity.isRunning == false)
        #expect(center.current == nil)
    }

    // MARK: - Preempting an undismissed warning (review fix: a progress toast used to queue
    // behind a warning in `pending` and simply never show, greying out the export/print menu
    // with zero visible explanation -- see `ToastCenter.show(_:now:)`'s rule 2)

    @Test("begin(message:) preempts a showing warning outright, and a plain end() with nothing else queued leaves no toast behind")
    @MainActor
    func beginPreemptsShowingWarningAndEndLeavesCurrentEmpty() {
        let center = ToastCenter()
        let activity = ExportActivity(toastCenter: center)

        let warning = Toast(style: .warning, message: "Couldn't save version.")
        center.show(warning)

        activity.begin(message: "Exporting to PDF…")

        // The progress toast takes over `current` immediately -- it is NOT queued in `pending`
        // behind the warning the way a success/info toast still is.
        #expect(center.current?.style == .progress)
        #expect(center.current?.id != warning.id)
        #expect(center.pending == nil)

        activity.end()

        // Nothing was queued behind the warning (it was simply preempted, not preserved), so
        // ending the export leaves the toast slot empty rather than restoring the warning.
        #expect(activity.isRunning == false)
        #expect(center.current == nil)
        #expect(center.pending == nil)
    }

    @Test("A toast already queued behind a warning survives the warning being preempted by begin(message:), and is promoted once end() dismisses the progress toast")
    @MainActor
    func beginPreemptsWarningAndEndPromotesPreviouslyQueuedPending() {
        let center = ToastCenter()
        let activity = ExportActivity(toastCenter: center)

        let warning = Toast(style: .warning, message: "Couldn't save version.")
        center.show(warning)

        // A success toast queued behind the still-current warning, exactly as it would before
        // any export ever started.
        let queuedSuccess = Toast(style: .success, message: "Version saved.")
        center.show(queuedSuccess)
        #expect(center.current?.id == warning.id)
        #expect(center.pending?.toast.id == queuedSuccess.id)

        // The progress toast preempts the warning (rule 2), but must not disturb `pending` --
        // that queued success is still waiting for its turn, unrelated to this export.
        activity.begin(message: "Exporting to PDF…")
        #expect(center.current?.style == .progress)
        #expect(activity.isRunning == true)
        #expect(center.pending?.toast.id == queuedSuccess.id)

        activity.end()

        // Ending the export dismisses ITS OWN progress toast (via `ToastCenter.dismiss(id:)`),
        // which promotes whatever was waiting in `pending` -- the success queued behind the
        // original warning, not the warning itself (which was never preserved).
        #expect(activity.isRunning == false)
        #expect(center.current?.id == queuedSuccess.id)
        #expect(center.pending == nil)
    }

    // MARK: - Unbalanced end()

    @Test("end() on a fresh ExportActivity with no prior begin() is safe and leaves isRunning false")
    @MainActor
    func unbalancedEndAtZeroDepthIsSafe() {
        let center = ToastCenter()
        let activity = ExportActivity(toastCenter: center)

        activity.end()

        #expect(activity.isRunning == false)
        #expect(center.current == nil)

        // A follow-up begin/end pair still works correctly afterward -- the stray end() above
        // didn't leave `depth` negative or otherwise corrupt the counter.
        activity.begin(message: "Exporting to PDF…")
        #expect(activity.isRunning == true)
        activity.end()
        #expect(activity.isRunning == false)
    }

    // MARK: - run(_:operation:)

    @Test("run(_:operation:) clears isRunning and the toast when the operation throws, and propagates the error")
    @MainActor
    func runClearsStateWhenOperationThrows() async {
        let center = ToastCenter()
        let activity = ExportActivity(toastCenter: center)

        await #expect(throws: SampleError.self) {
            // Explicit `Void` return type on the operation closure -- `run<T>` is generic and
            // this closure only ever throws (no `return`), which leaves nothing for the
            // compiler to infer `T` from otherwise.
            try await activity.run("Exporting to PDF…") { () async throws -> Void in
                #expect(activity.isRunning == true)
                #expect(center.current?.style == .progress)
                throw SampleError.boom
            }
        }

        #expect(activity.isRunning == false)
        #expect(center.current == nil)
    }

    @Test("run(_:operation:) clears isRunning and the toast, and returns the operation's value, on success")
    @MainActor
    func runClearsStateAndReturnsValueOnSuccess() async throws {
        let center = ToastCenter()
        let activity = ExportActivity(toastCenter: center)

        let value = try await activity.run("Exporting to PDF…") {
            #expect(activity.isRunning == true)
            #expect(center.current?.style == .progress)
            return 42
        }

        #expect(value == 42)
        #expect(activity.isRunning == false)
        #expect(center.current == nil)
    }

    // MARK: - ToastCenter.dismiss(id:) direct coverage

    @Test("ToastCenter.dismiss(id:) with an id matching neither slot is a no-op")
    @MainActor
    func dismissWithUnmatchedIDIsNoOp() {
        let center = ToastCenter()
        let showing = Toast(style: .success, message: "Version saved.")
        center.show(showing)

        center.dismiss(id: UUID())

        #expect(center.current?.id == showing.id)
        #expect(center.pending == nil)
    }
}
