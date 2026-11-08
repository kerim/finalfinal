//
//  StructuralCommandGate.swift
//  final final
//
//  t-94369a83 Phase 4b, slice 2a (plan D1.1, D8, addenda A3, A5, A21): the one first-in-first-out queue every structural command
//  goes through -- Delete Section, Duplicate Section, a version restore, a drag-reorder, Cmd-Z and Cmd-Shift-Z -- so that a command
//  pressed while an earlier one is still finishing is HELD and run in turn, never refused and never run in parallel.
//
//  What it replaces: `StructuralUndoController`'s busy refusals (`guard !isPerforming else { return .refused }` and the in-flight
//  `.failed` reply). The two readers of "a structural sequence is running" (the lifecycle step-1 wait, the drag guards) still read
//  `isPerforming`, which now means "the gate is held".
//
//  Two small types:
//    - `StructuralCommandGate`: a FIFO async mutex with a cut-off. `acquire()` returns `.granted` (the caller now owns the gate and
//      must `release()` it, on every exit) or `.cancelled` (the lifecycle barrier is up, or the waiter was cancelled while it
//      waited: the command must NOT run). Nothing here observes Task cancellation; only `cancelWaiters()` and the barrier flag end
//      a wait early, so a queued command can never be dropped by accident.
//    - `DelayedProgressToast`: the "Finishing the last change..." / "Undoing..." progress toast that appears once something has
//      waited for a second, and is dismissed BY ID on every exit path (addendum A5).
//

import Foundation

/// How a gate wait ended.
enum StructuralGateResult: Equatable {
    /// The caller holds the gate and must release it.
    case granted
    /// The command is not to run: the lifecycle barrier is up, or the lifecycle cancelled the queue.
    case cancelled
}

@MainActor
final class StructuralCommandGate {

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<StructuralGateResult, Never>
    }

    private(set) var isHeld = false
    private var waiters: [Waiter] = []

    /// Once true (the lifecycle barrier is placed: addendum A21), `acquire()` cancels at once instead of queueing, except for a held
    /// press the allowance below covers. Commands already queued are NOT touched by setting it: they still run, inside the
    /// lifecycle's drain wait.
    ///
    /// Reopening the gate (the tails after they retire the old writer, `LifecycleEntry.finish` after a cancelled lifecycle) also
    /// forgets the allowance below, so no site that reopens the gate can leave an owed press behind.
    var isClosedToNewWork = false {
        didSet { if !isClosedToNewWork { preBarrierAllowance = 0 } }
    }

    /// How many Cmd-Z / Cmd-Shift-Z presses the editor was holding in its own queue when the barrier was placed and that Swift has
    /// not heard of yet (addendum A21, amended in fix round 5; judge ruling "allowance"). The editor holds a press that is made
    /// while an earlier undo is in flight and only sends it when that undo replies, so at Cmd-W such a press is neither queued here
    /// nor made after the barrier: it was made BEFORE it, and A1/A21 promise that presses made before the close still run. Each
    /// of them is let through the closed gate once (`acquire(heldPress: true)`), and `isIdle` stays false until the allowance is used
    /// up or reported settled (`settleHeldPresses`), so the lifecycle's step-1 wait keeps waiting for them. Zero outside a
    /// lifecycle. A press made AFTER the barrier finds the allowance spent (or `heldPress == false`) and is cancelled as before.
    var preBarrierAllowance = 0

    /// Nothing holds the gate, nothing waits for it, and no press the editor holds is still owed a turn.
    var isIdle: Bool { !isHeld && waiters.isEmpty && preBarrierAllowance == 0 }
    var waiterCount: Int { waiters.count }

    /// Takes the gate, or waits for it in arrival order. Returns synchronously (no suspension) when the gate is free and nobody
    /// waits ahead of the caller, so a command pressed on an idle app starts in the same MainActor turn.
    ///
    /// `heldPress`: the request is a Cmd-Z / Cmd-Shift-Z the editor held in its own queue (`held: true` in its message). With the
    /// gate closed to new work, such a request is let through while `preBarrierAllowance > 0`, which it then uses up. The decrement
    /// and the queueing below happen in the same synchronous stretch, so there is no moment when the press is neither counted in the
    /// allowance nor on the gate.
    func acquire(heldPress: Bool = false, onQueued: (() -> Void)? = nil) async -> StructuralGateResult {
        if isClosedToNewWork {
            guard heldPress, preBarrierAllowance > 0 else { return .cancelled }
            preBarrierAllowance -= 1
        }
        if !isHeld && waiters.isEmpty {
            isHeld = true
            return .granted
        }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            waiters.append(Waiter(id: id, continuation: continuation))
            onQueued?()
        }
    }

    /// Hands the gate to the oldest waiter, or frees it when there is none. Called exactly once per `.granted` acquire.
    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            // The gate stays held: ownership passes straight to the next waiter, so nothing can slip in between.
            waiters.removeFirst().continuation.resume(returning: .granted)
        }
    }

    /// Cancels every waiter that has not started (the lifecycle barrier: addendum A3/A21). The holder, if any, keeps the gate until
    /// it releases it. Returns how many were cancelled.
    ///
    /// Also forgets the allowance: a lifecycle that gives up (the quit's give-up path) owes nothing to presses the editor still holds.
    @discardableResult
    func cancelWaiters() -> Int {
        preBarrierAllowance = 0
        let cancelled = waiters
        waiters.removeAll()
        for waiter in cancelled { waiter.continuation.resume(returning: .cancelled) }
        return cancelled.count
    }

    /// `count` presses the editor held ended WITHOUT a request to Swift (a plain text undo took them, or they were dropped): they
    /// will never reach `acquire`, so they no longer count against the lifecycle's wait. Floors at zero.
    func settleHeldPresses(_ count: Int) {
        preBarrierAllowance = max(0, preBarrierAllowance - max(0, count))
    }
}

/// A progress toast that shows only after `delay` (the plan's one second) and is dismissed BY ID when `stop()` is called (addendum
/// A5: progress toasts never fade, so every exit path of whatever showed one must dismiss it, or it stays for good).
@MainActor
final class DelayedProgressToast {
    /// Production value; a test shortens it.
    static var defaultDelay: Duration = .seconds(1)

    private let toastCenter: ToastCenter
    private let message: String
    private var task: Task<Void, Never>?
    private(set) var toastId: UUID?
    private var stopped = false

    /// `delay` nil means `defaultDelay`, read here inside the MainActor initializer (a default argument expression is evaluated in the
    /// caller's nonisolated context and cannot read a MainActor static).
    ///
    /// The ids of the delayed progress toasts that are on screen right now (any window). A delayed toast replaces another delayed
    /// toast as usual, but yields to a progress toast whose id is not in here: that one belongs to another operation.
    private static var shownIds: Set<UUID> = []

    /// EVERY delayed progress toast ("Finishing the last change...", "Undoing...", the held mode switch's notice, the lifecycle's
    /// wait) yields to a running progress toast of ANOTHER operation (fix round 2a, items 5 and R3): when an export's "Exporting to
    /// Word..." is on screen at the moment this one would appear, this one does not show. Replacing that toast and then dismissing
    /// this one by id would leave the slot empty while the export goes on (UX contract 4.1: one toast at a time).
    ///
    /// It does NOT yield to another delayed toast: several commands held one behind another each show their own notice in turn
    /// (the second replaces the first, whose `stop()` then dismisses nothing because it dismisses by id), so the command that runs
    /// last is never left without one.
    init(toastCenter: ToastCenter, message: String, delay: Duration? = nil) {
        self.toastCenter = toastCenter
        self.message = message
        let wait = delay ?? DelayedProgressToast.defaultDelay
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, !self.stopped else { return }
            if let running = self.toastCenter.current, running.style == .progress, !DelayedProgressToast.shownIds.contains(running.id) {
                return
            }
            let toast = Toast(style: .progress, message: self.message)
            self.toastId = toast.id
            DelayedProgressToast.shownIds.insert(toast.id)
            self.toastCenter.show(toast)
        }
    }

    /// Dismisses the toast if it was shown, and makes sure it never shows afterwards. Idempotent.
    func stop() {
        stopped = true
        task?.cancel()
        task = nil
        if let toastId {
            DelayedProgressToast.shownIds.remove(toastId)
            toastCenter.dismiss(id: toastId)
            self.toastId = nil
        }
    }

    /// The shared text of the held-command and wait toasts.
    static let finishingMessage = "Finishing the last change\u{2026}"
    static let undoingMessage = "Undoing\u{2026}"
    static let redoingMessage = "Redoing\u{2026}"
    /// The carried switch between Rich Text and Markdown, shown once it has taken a second (Phase 5 jobs A9 and A10: the old editor stays
    /// on screen and typeable until the new one has its text, so nothing else on screen says the switch is under way).
    static let switchingToMarkdownMessage = "Switching to Markdown\u{2026}"
    static let switchingToRichTextMessage = "Switching to Rich Text\u{2026}"
}
