//
//  FootnoteSyncService+Diagnostics.swift
//  final final
//
//  t-94369a83 Phase 3a-2 Step 5 (diagnostic round): `[FN-DIAG]` lines for the footnote delete / undo path, to find
//  out why a deleted footnote's text sometimes takes far too long to disappear (user report: more than 10 s, a
//  second deletion in a row never going away). Category `.footnotes`; with Settings > Diagnostics > "Enable
//  diagnostic logging" on, `DebugLog.log` writes every line to
//  `~/Library/Application Support/com.kerim.final-final/Diagnostics/diagnostic.log` in any build, behind the
//  usual `[footnotes]` prefix and an ISO timestamp.
//
//  Rules: only events around reference changes, writes and rebuilds, never the plain equal-refs keystroke path;
//  reference COUNTS and labels (digits) only, durations, intervals and generation numbers; NEVER document or
//  definition text and no text hashes. Every line carries `t=<ms>` from a monotonic clock so gaps can be computed
//  between lines (and between this service, `handleContentChange` and `handleNotesSectionChanged`).
//
//  Logging only: nothing here changes behaviour. The helpers live in this extension so the class body grows by
//  one-line calls. Read the log with:
//    grep -F '[FN-DIAG]' ~/Library/Application\ Support/com.kerim.final-final/Diagnostics/diagnostic.log
//

import Foundation

/// Shared by every `[FN-DIAG]` call site, inside and outside the service.
enum FootnoteDiag {
    /// Monotonic milliseconds (not wall-clock): differences between two lines are real elapsed time.
    static func nowMs() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }

    /// The message stays an autoclosure so nothing is built while logging is off.
    @inline(__always)
    static func log(_ event: @autoclosure () -> String) {
        DebugLog.log(.footnotes, "[FN-DIAG] t=\(nowMs()) \(event())")
    }

    /// "2[1,2]": count and labels (digits only).
    static func labels(_ refs: [String]) -> String { "\(refs.count)[" + refs.joined(separator: ",") + "]" }

    /// Milliseconds from now until `deadline` (negative once it has passed); 0 when there is none.
    static func msUntil(_ deadline: ContinuousClock.Instant?) -> Int {
        guard let deadline else { return 0 }
        let parts = (deadline - ContinuousClock.now).components
        return Int(parts.seconds) * 1000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}

/// When the current burst of reference changes started and was last touched, to report how long a write took to get going.
struct FootnoteDiagState {
    /// The FIRST change of the current burst (the one that fixed the deadline).
    var firstScheduledAt: UInt64?
    /// The latest change of the burst.
    var lastScheduledAt: UInt64?
    /// The burst's fixed deadline, nil when no burst is waiting.
    var deadline: ContinuousClock.Instant?
    /// t-f1a22aa7: the persisted `[FN-STANDASIDE]` line has been written for the current burst. Cleared by `fnDiagDeadlineFixed`,
    /// which runs exactly when a burst starts (`scheduleBurst`, nothing waiting), so every way a burst can end (it wrote, it was
    /// cancelled by an equal-refs check, an undo restore, an immediate insertion, a resync, a lifecycle suspension or `reset()`) is
    /// followed by a fresh burst that logs once again.
    var standAsideLogged = false
}

/// One system write's clock: created just before the call (`start`), `set()` by the first statement of the write's
/// body on the writer's queue (another thread), read after the call returns.
final class FootnoteDiagMark: @unchecked Sendable {
    let start = FootnoteDiag.nowMs()
    private let lock = NSLock()
    private var startedAt: UInt64?

    func set() {
        lock.lock()
        defer { lock.unlock() }
        if startedAt == nil { startedAt = FootnoteDiag.nowMs() }
    }

    /// When the body started, nil if it never ran.
    var bodyStart: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return startedAt
    }
}

extension FootnoteSyncService {
    // MARK: - checkAndUpdateFootnotes

    /// A check that did not get to schedule anything (deferred by a lifecycle, or dropped while a write runs).
    func fnDiagCheck(_ what: String, refs: [String]) {
        FootnoteDiag.log("check \(what) state=\(state) inFlight=\(inFlightCount) " +
            "known=\(FootnoteDiag.labels(lastKnownRefs)) new=\(FootnoteDiag.labels(refs))")
    }

    func fnDiagRefsChanged(_ refs: [String]) {
        FootnoteDiag.log("refs changed old=\(FootnoteDiag.labels(lastKnownRefs)) new=\(FootnoteDiag.labels(refs)) pending=\(pendingUpdate != nil)")
    }

    /// The FIRST change of a burst: the deadline is fixed (the interval is the whole wait, never extended).
    func fnDiagDeadlineFixed(refs: [String], generation: Int, deadline: ContinuousClock.Instant) {
        let now = FootnoteDiag.nowMs()
        fnDiag.firstScheduledAt = now
        fnDiag.lastScheduledAt = now
        fnDiag.deadline = deadline
        fnDiag.standAsideLogged = false   // a new burst: its first stand-aside is logged again (t-f1a22aa7)
        FootnoteDiag.log("deadline fixed interval=\(Int(debounceInterval * 1000))ms generation=\(generation) " +
            "refs=\(FootnoteDiag.labels(refs))")
    }

    /// A LATER change inside the burst: only the waiting snapshot is replaced; the timer and the deadline stay.
    func fnDiagBurstReplaced(refs: [String], generation: Int) {
        let now = FootnoteDiag.nowMs()
        fnDiag.lastScheduledAt = now
        FootnoteDiag.log("burst: snapshot replaced generation=\(generation) refs=\(FootnoteDiag.labels(refs)) " +
            "msSinceFirstSchedule=\(now - (fnDiag.firstScheduledAt ?? now)) msUntilDeadline=\(FootnoteDiag.msUntil(fnDiag.deadline))")
    }

    /// The deadline arrived and the latest snapshot is about to run: `lateness` is how long after the deadline the
    /// timer actually woke (reported, not corrected).
    func fnDiagBurstFired(deadline: ContinuousClock.Instant, generation: Int) {
        let now = FootnoteDiag.nowMs()
        FootnoteDiag.log("debounce fired generation=\(generation) latenessMs=\(-FootnoteDiag.msUntil(deadline)) " +
            "msSinceFirstSchedule=\(now - (fnDiag.firstScheduledAt ?? now)) msSinceLastSchedule=\(now - (fnDiag.lastScheduledAt ?? now))")
        fnDiag.deadline = nil
    }

    /// t-f1a22aa7: a burst's deadline arrived (`fireBurst`). Does nothing unless `unfinished` (a section command still had work
    /// to do). Then it counts the check (DEBUG counter, EVERY re-check, which tests wait on) and writes the always-on
    /// `[FN-STANDASIDE]` line ONCE PER BURST, on its first stand-aside (`fnDiag.standAsideLogged`, cleared when the next burst
    /// starts): a settle that lasts four seconds re-checks sixteen times, and sixteen persisted lines per command would drown the log.
    /// The line is `alwaysPersisted`, not the `.footnotes` category (off by default) and not `StructuralTrace` (which depends on `.undo`),
    /// so a real-app test can find it in the ordinary diagnostic log. Digits and counts only, never document text.
    ///
    /// It is called with the check's result instead of being wrapped in an `if` at the call site, so the one `if workUnfinished {` in
    /// `fireBurst` is the re-arm and a break patch can switch that off alone (the line still gets written).
    func noteBurstDueDuringStructuralWork(_ latest: PendingFootnoteUpdate, unfinished: Bool) {
        guard unfinished else { return }
        #if DEBUG
        testBurstDueDuringStructuralWorkCount += 1
        #endif
        guard !fnDiag.standAsideLogged else { return }
        fnDiag.standAsideLogged = true
        DebugLog.alwaysPersisted(
            "[FN-STANDASIDE] footnote burst due while structural work unfinished gen=\(latest.generation) " +
            "refs=\(FootnoteDiag.labels(latest.refs)) recheckMs=\(Int(standAsideRecheck * 1000))")
    }

    /// The equal-refs branch cancelled a waiting update.
    func fnDiagPendingDropped() {
        let now = FootnoteDiag.nowMs()
        FootnoteDiag.log("equal-refs branch cancelled the pending update known=\(FootnoteDiag.labels(lastKnownRefs)) " +
            "msSinceFirstSchedule=\(now - (fnDiag.firstScheduledAt ?? now))")
    }

    // MARK: - performFootnoteUpdate / removeNotesBlock

    func fnDiagPerformRefused(generation: Int) {
        FootnoteDiag.log("perform refused: cancelled=\(Task.isCancelled) generation=\(generation) current=\(syncGeneration) state=\(state)")
    }

    func fnDiagPerformStart(refs: [String], generation: Int, allowRenumber: Bool) {
        let now = FootnoteDiag.nowMs()
        FootnoteDiag.log("perform start generation=\(generation) refs=\(FootnoteDiag.labels(refs)) known=\(FootnoteDiag.labels(lastKnownRefs)) " +
            "allowRenumber=\(allowRenumber) msSinceLastSchedule=\(fnDiag.lastScheduledAt.map { Int(now) - Int($0) } ?? -1) " +
            "msSinceFirstSchedule=\(fnDiag.firstScheduledAt.map { Int(now) - Int($0) } ?? -1)")
    }

    func fnDiagPerformSkipped(_ why: String, refs: [String]) {
        FootnoteDiag.log("perform returned early: \(why) refs=\(FootnoteDiag.labels(refs)) known=\(FootnoteDiag.labels(lastKnownRefs))")
    }

    /// Logs one system write after it returned: the queue wait (call to the first statement of its body), the time
    /// from there to the result, the total, and the outcome (`applied`, or `refused(reason)` / `failed`).
    func fnDiagWriteDone<R: Sendable>(_ label: String, _ mark: FootnoteDiagMark, _ result: SystemWriteResult<R>) {
        let end = FootnoteDiag.nowMs()
        let bodyStart = mark.bodyStart
        let wait = bodyStart.map { "\($0 - mark.start)ms" } ?? "n/a(body did not run)"
        let afterBody = bodyStart.map { "\(end - $0)ms" } ?? "n/a"
        FootnoteDiag.log("system write \(label) outcome=\(Self.fnDiagOutcomeName(result.outcome)) prepareRan=\(result.prepareRan) " +
            "queueWait=\(wait) fromBodyStartToResult=\(afterBody) total=\(end - mark.start)ms")
    }

    nonisolated static func fnDiagOutcomeName<R: Sendable>(_ outcome: SystemWriteOutcome<R>) -> String {
        switch outcome {
        case .applied: return "applied"
        case .refused(let reason): return "refused(\(reason))"
        case .failed(let error): return "failed(\(type(of: error)))"
        }
    }

    // MARK: - lifecycle

    func fnDiagLifecycle(_ what: String) {
        FootnoteDiag.log("lifecycle \(what) pending=\(pendingUpdate != nil) deferredCheck=\(deferredCheck != nil) state=\(state)")
    }
}
