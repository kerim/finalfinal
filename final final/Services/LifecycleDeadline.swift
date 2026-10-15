//
//  LifecycleDeadline.swift
//  final final
//
//  t-94369a83 Phase 3a-1b, round C1 (slice-3a-1b-everyday.md §4.1 and §5.1 item 3): the time budget the
//  close / project-switch / quit save sequence runs against, and the two bounded waits it makes on the
//  poll side. Used by the save sequence (`EditorViewState.runLifecycleFlush`, round C3a onward).
//
//    - `LifecycleDeadline`: one wall-clock budget per lifecycle run. Every step asks it for its own
//      bound (`bound(own:floor:)`), which is the step's usual limit shrunk so that the steps still to
//      come keep at least `floor` seconds.
//    - `LifecycleBounds`: the production numbers (the §4.1 table), plus `scaled(_:)` so a test can run
//      the same sequence on a short clock.
//    - `BlockSyncService.raceDrain(bound:)` / `raceForcedPoll(webView:bound:)`: the drain of the
//      in-flight poll cycle and the forced poll ("F") raced against their bound with
//      `raceAgainstTimeout` (TimeoutRace.swift). When the bound wins, the drain or poll is NOT stopped
//      (a call wedged inside `evaluateJavaScript` cannot be): the work Task is left running and
//      accepted as an orphan (coder obligation 19), which is also why neither can ever hold a close
//      or quit open past its deadline.
//

import Foundation
import WebKit

// MARK: - Deadline

/// One shared wall-clock budget for a close, project switch or quit (§4.1). A reference type because the
/// sequence, the abort routine and a quit that joins the sequence all read and tighten the same budget.
@MainActor
final class LifecycleDeadline {
    private var end: ContinuousClock.Instant
    private let now: () -> ContinuousClock.Instant

    /// `now` is injectable so tests drive the clock by hand.
    init(total: TimeInterval, now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
        self.end = now().advanced(by: Self.duration(seconds: total))
    }

    /// Seconds left in the budget; never negative.
    var remaining: TimeInterval {
        max(0, Self.seconds(of: end - now()))
    }

    /// The bound a step may wait: its own limit, but never so long that the work still to come would
    /// have less than `floor` seconds left. `max(0, min(own, remaining - floor))`: never negative.
    func bound(own: TimeInterval, floor: TimeInterval) -> TimeInterval {
        max(0, min(own, remaining - floor))
    }

    /// Shrinks this budget to end no later than `other`'s (a quit that joins a close or a switch
    /// takes the smaller of the two remainders). Never extends it.
    func tighten(to other: LifecycleDeadline) {
        if other.end < end { end = other.end }
    }

    private static func seconds(of duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    /// `Duration.seconds(_: Double)` traps on a non-finite value, so clamp first (NaN -> 0, infinity ->
    /// one year, which is "never" for every purpose here).
    fileprivate static func duration(seconds: TimeInterval) -> Duration {
        guard !seconds.isNaN else { return .zero }
        return .seconds(min(max(seconds, -31_536_000), 31_536_000))
    }
}

// MARK: - Bounds

/// The lifecycle sequence's time limits, in seconds (§4.1). `production` holds the shipped values; a test
/// builds a short-clock copy with `scaled(_:)`.
struct LifecycleBounds: Sendable, Equatable {
    /// Whole-run budget of a close or project switch.
    var closeTotal: TimeInterval
    /// Whole-run budget of a quit.
    var quitTotal: TimeInterval
    /// How long a close or switch waits for a running section operation (delete, duplicate, restore).
    var sectionOperationWaitClose: TimeInterval
    /// The same wait for a quit.
    var sectionOperationWaitQuit: TimeInterval
    /// How long running bibliography / Notes / footnote rebuilds are awaited.
    var rebuildWait: TimeInterval
    /// The drain of the in-flight poll cycle.
    var drain: TimeInterval
    /// The forced poll (F).
    var forcedPoll: TimeInterval
    /// The fresh content fetch.
    var fetch: TimeInterval
    /// The race on the queued whole-document write (FB). Losing it is not a failure (E1).
    var fbRace: TimeInterval
    /// One bibliography or footnote refresh after FB.
    var bibliographyRefresh: TimeInterval
    /// Time always kept for the writer barrier.
    var barrierFloor: TimeInterval
    /// Time a quit keeps for its automatic version.
    var quitBackupReserve: TimeInterval
    /// The abort routine's own flat bounds (plan section 4.3 steps 4 and 5, each raced against this): the wait for
    /// a whole-document save (FB) still queued when a lifecycle gives up, and the re-push of block ids to the
    /// editor. Flat, not read from the deadline: a failed `perform` can leave the deadline nearly spent, and the
    /// editor must still get its ids back.
    var abortStep: TimeInterval
    /// N3: once a quit has joined a close or switch, that lifecycle's tail starts its automatic version only if at
    /// least this much of the (tightened) deadline remains, and races it against `min(quitBackupReserve, remaining)`.
    var joinedBackupMinimum: TimeInterval

    static let production = LifecycleBounds(
        closeTotal: 15,
        quitTotal: 18,
        sectionOperationWaitClose: 3,
        sectionOperationWaitQuit: 10,
        rebuildWait: 8,
        drain: 8,
        forcedPoll: 8,
        fetch: 2,
        fbRace: 2,
        bibliographyRefresh: 3,
        barrierFloor: 1,
        quitBackupReserve: 3,
        abortStep: 2,
        joinedBackupMinimum: 0.5
    )

    /// Every bound multiplied by `factor` (so the floors, which are sums of bounds, scale with it). For
    /// tests that run the real sequence on a short clock.
    func scaled(_ factor: Double) -> LifecycleBounds {
        LifecycleBounds(
            closeTotal: closeTotal * factor,
            quitTotal: quitTotal * factor,
            sectionOperationWaitClose: sectionOperationWaitClose * factor,
            sectionOperationWaitQuit: sectionOperationWaitQuit * factor,
            rebuildWait: rebuildWait * factor,
            drain: drain * factor,
            forcedPoll: forcedPoll * factor,
            fetch: fetch * factor,
            fbRace: fbRace * factor,
            bibliographyRefresh: bibliographyRefresh * factor,
            barrierFloor: barrierFloor * factor,
            quitBackupReserve: quitBackupReserve * factor,
            abortStep: abortStep * factor,
            joinedBackupMinimum: joinedBackupMinimum * factor
        )
    }

    /// What the steps before FB must leave in the budget: FB itself plus the barrier, and for a quit
    /// also the automatic version. 3 (close / switch) or 6 (quit) in production.
    func floorBeforeFB(quit: Bool) -> TimeInterval {
        fbRace + floorAfterFB(quit: quit)
    }

    /// What the steps after FB must leave: the barrier, and for a quit also the automatic version.
    /// 1 (close / switch) or 4 (quit) in production.
    func floorAfterFB(quit: Bool) -> TimeInterval {
        quit ? barrierFloor + quitBackupReserve : barrierFloor
    }
}

// MARK: - Poll-side races

extension BlockSyncService {
    /// Races `drainInFlightPoll()` against `bound` seconds (obligation 19). `.finished(hitWatchdog)`
    /// carries the drain's watchdog-hit flag (obligation 20: true when any cycle it waited for ended at its
    /// own poll watchdog, so the editor just proved wedged). `.timedOut` means the bound passed first: the
    /// drain Task is left running and accepted as an orphan; it ends by itself when the cycle it waits for
    /// does (at the latest at that cycle's poll watchdog).
    func raceDrain(bound: TimeInterval) async -> TimeoutRaceOutcome<Bool> {
        await raceAgainstTimeout(LifecycleDeadline.duration(seconds: bound)) {
            await self.drainInFlightPoll()
        }
    }

    /// Races a forced poll of `webView` (F) against `bound` seconds (obligation 19). `.finished(result)`
    /// carries that cycle's `PollCycleResult` (`hitWatchdog` is true when its own poll watchdog ended
    /// it). `.timedOut`: the poll is left running as an orphan, and `webView` stays alive until it ends.
    func raceForcedPoll(webView: WKWebView, bound: TimeInterval) async -> TimeoutRaceOutcome<PollCycleResult> {
        await raceAgainstTimeout(LifecycleDeadline.duration(seconds: bound)) {
            await self.pollBlockChanges(force: true, webView: webView)
        }
    }
}
