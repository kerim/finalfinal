//
//  BlockSyncProjectSwitchDrainTests.swift
//  final finalTests
//
//  Tier 2: reproduction test for race 1 (project-switch generation-capture ordering)
//  in `BlockSyncService.doPollBlockChanges` — see the block-sync-poll-races plan.
//
//  Before the fix, `BlockSyncService.reconfigure(database:projectId:)` was
//  synchronous and never touched `inFlightPoll`: it reassigned `projectDatabase`/
//  `projectId` immediately, with no regard for a poll cycle that might already be
//  running against the OLD project. A forced cycle (`pollBlockChangesNow()`) parked
//  mid-cycle — before it has captured ANY of its own `database`/`projectId`/
//  `generationAtPoll` locals — would, on release, resume and capture whatever
//  `projectDatabase`/`projectId` happened to be installed AT THAT MOMENT. If a
//  project switch's `reconfigure(...)` had already run (as it could, synchronously,
//  the instant it was called), the resumed cycle would silently capture the NEW
//  project's database/projectId and apply the OLD project's pending edit-batch
//  there — cross-project data corruption, with the old project silently missing an
//  edit the user believed had been saved.
//
//  After the fix, `reconfigure(...)` is `async` and calls `drainInFlightPoll()`
//  FIRST, which — for a FORCED in-flight cycle (MUST-FIX 2's chosen behavior:
//  forced cycles are awaited to completion, never cancelled, since their callers
//  rely on them as a completion guarantee) — awaits the parked cycle to finish
//  before reassigning anything. So the resumed cycle still sees the OLD
//  `projectDatabase`/`projectId` when it captures its locals, applies its batch
//  there correctly, and only once that's done does `reconfigure(...)` swap in the
//  new project.
//
//  Uses XCTest (not Swift Testing) because WKWebView requires a run loop — same
//  reasoning as ZoomWordCountSyncTests. Extension on `ZoomWordCountSyncTests` to
//  reuse its `makeStack()`/`editBetaParagraph()`/`totalWordCount()` helpers (all
//  declared `internal`, not `private`, on that class specifically so files like
//  this one can share them — see that file's header comment).
//
//  Coverage scope (block-sync-poll-races review round 2, MF3): this file proves
//  `reconfigure(database:projectId:)`'s drain-before-reassign ordering — the
//  parked forced cycle here is released from `testAfterGenerationCaptureHook`,
//  i.e. genuinely mid-`doPollBlockChanges`, past its own `database`/`projectId`/
//  `generationAtPoll` capture, not merely at the very top of `runPollCycle` — and
//  `sync.editorState` is wired (mirroring ZoomWordCountSyncTests.swift:457-458) so
//  that capture is a real value, not the inert `?? 0` default.
//
//  What this file does NOT independently prove: the RELATIVE ORDER of that
//  capture against `flushPendingJSChanges`'s `await` (i.e. that all three locals
//  are captured together, in one suspension-free window, rather than straddling
//  that await). `reconfigure(...)`'s own drain fully blocks on the WHOLE cycle
//  finishing before it reassigns anything, regardless of which internal point the
//  cycle happens to be parked at when the drain begins — so this scenario can't
//  distinguish the two capture orderings from each other. There is also no test
//  hook positioned literally between the `database`/`projectId` capture and the
//  `generationAtPoll` capture (they're adjacent statements with no `await`
//  between them in the fixed code), so a regression that reintroduced a
//  suspension there has no existing hook to park a test on. That specific
//  ordering is protected by code inspection (see `doPollBlockChanges`'s own doc
//  comment on the capture) plus the mid-flight rewrite scenario in
//  `ZoomWordCountSyncTests.testForcedFlush_abandonsStaleBatch_whenGenerationChangesMidFlight`,
//  which exercises the generation guard's rejection behavior once a stale
//  snapshot has already been captured -- not the ordering of the capture itself.
//

import XCTest
import WebKit
@testable import final_final

/// Checked-continuation gate (no sleep) that lets a test hold an in-flight poll
/// cycle deterministically suspended at the very top of its cycle — before it has
/// captured ANY of `database`/`projectId`/`generationAtPoll` — via
/// `testPollCycleHook`, confirm via `waitUntilReached()` that it's genuinely stuck
/// there (not merely about to run), then release it with `open()`. File-private
/// equivalent of ZoomWordCountSyncTests.swift's `PollGate` (that one is private to
/// its own file and can't be reused directly from here).
@MainActor
private final class SwitchGate {
    private var reached = false
    private var released = false
    private var reachedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    /// Call from inside the poll cycle (via `testPollCycleHook`).
    func waitAtGate() async {
        reached = true
        reachedContinuation?.resume()
        reachedContinuation = nil
        if released { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    /// Suspends until some poll cycle has actually reached the gate.
    func waitUntilReached() async {
        if reached { return }
        await withCheckedContinuation { reachedContinuation = $0 }
    }

    /// Releases whatever is parked at the gate; future arrivals pass straight through.
    func open() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

/// MainActor-isolated one-shot checked-continuation signal. `wait()` suspends
/// until `fire()` is called (or returns immediately if `fire()` already
/// happened). Because both this type and its callers are @MainActor, calls into
/// it never hop actors — they're synchronous when the caller is already on
/// MainActor — which is what makes the event-ordering test below deterministic
/// rather than a race against the scheduler. File-private equivalent of
/// ZoomWordCountSyncTests.swift's `Signal`.
@MainActor
private final class StartSignal {
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func fire() {
        guard !fired else { return }
        fired = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if fired { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

/// Records a happens-before-ordered sequence of named events. @MainActor (not a
/// true `actor`) so `record()` is a synchronous call from any MainActor context —
/// no suspension point that could reorder events relative to other synchronous
/// MainActor work. File-private equivalent of ZoomWordCountSyncTests.swift's
/// `EventLog`.
@MainActor
private final class OrderLog {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

extension ZoomWordCountSyncTests {

    /// Regression test for race 1 (block-sync-poll-races plan): a project switch
    /// (`BlockSyncService.reconfigure(database:projectId:)`) must drain any
    /// in-flight poll cycle BEFORE reassigning `projectDatabase`/`projectId` —
    /// otherwise a cycle already running against the OLD project could resume
    /// (after the switch) and capture the NEW project's database/projectId for its
    /// own `database`/`projectId` locals, applying the OLD project's pending
    /// edit-batch to the NEW project.
    ///
    /// Forces the exact interleaving deterministically, with no sleep race: parks
    /// a FORCED poll cycle (`pollBlockChangesNow()`, the completion guarantee
    /// callers like footnote insertion / bibliography rebuild rely on) via
    /// `testAfterGenerationCaptureHook` — i.e. just past its own `database`/
    /// `projectId`/`generationAtPoll` capture, with a real `editorState` wired so
    /// that capture is a genuine value (see this file's header comment for why,
    /// and for the narrower claim this specific park point does and doesn't
    /// prove) — makes a real edit to the OLD project's content while it's parked,
    /// then concurrently calls `reconfigure(...)` to a second temporary project
    /// and records a happens-before-ordered event sequence: `.switchCalled` when
    /// `reconfigure(...)` starts, `.gateReleased` when the parked cycle is
    /// released, `.switchReturned` when `reconfigure(...)` returns.
    ///
    /// The assertion is on that recorded ORDER, not on timing — see
    /// `testForcedFlush_waitsForInFlightPoll_thenFlushesFreshEdit`'s doc comment
    /// in ZoomWordCountSyncTests.swift for why an ordering assertion (derived from
    /// actual continuation-resume order) can't false-pass regardless of machine
    /// speed, unlike a fixed-sleep-based one. Under the pre-fix code (synchronous
    /// `reconfigure`, no drain) the order would be `switchCalled, switchReturned,
    /// gateReleased` — `reconfigure` returns instantly, before the gate is even
    /// opened, and reassigns `projectDatabase`/`projectId` to the NEW project well
    /// before the parked cycle ever resumes; under the fix it's `switchCalled,
    /// gateReleased, switchReturned` (reconfigure awaits the parked forced cycle
    /// to completion — MUST-FIX 2's chosen behavior: a forced cycle is drained by
    /// being AWAITED, never cancelled — before swapping in the new project).
    ///
    /// Then verifies via direct word-count reads on BOTH databases: the edit made
    /// while parked lands in the OLD project (the forced cycle already captured
    /// the OLD `database`/`projectId`/`generationAtPoll` before it ever parked,
    /// and `reconfigure(...)` cannot reassign anything until this whole cycle —
    /// park included — finishes, which is strictly before `reconfigure` returns),
    /// and the NEW project's word count is completely unchanged — the pre-switch
    /// batch never crosses over.
    @MainActor
    func testReconfigure_drainsInFlightForcedPoll_beforeSwitchingProject() async throws {
        let stack = try await makeStack()
        let (helper, oldDb) = (stack.helper, stack.db)
        let (oldPid, sync) = (stack.pid, stack.sync)

        // Wire a real EditorViewState (mirrors ZoomWordCountSyncTests.swift:457-458).
        // makeStack()'s BlockSyncService never assigns `editorState`, and without one
        // `generationAtPoll` stays at its `?? 0` default -- the mid-flight generation
        // guard is inert throughout the test, silently measuring nothing (MF3, review
        // round 2).
        let editorState = EditorViewState()
        sync.editorState = editorState

        let blocks = try TestFixtureFactory.fetchBlocks(from: oldDb)
            .sorted { $0.sortOrder < $1.sortOrder }
        let ids = BlockParser.idsForProseMirrorAlignment(blocks)
        let content = BlockParser.assembleMarkdown(from: blocks)
        await sync.setContentWithBlockIds(markdown: content, blockIds: ids)
        try await Task.sleep(nanoseconds: 500_000_000)

        let oldBefore = try totalWordCount(oldDb, oldPid)

        // A second, independent temporary project to switch to. Different content
        // so a word-count mismatch would be obvious if the pre-switch batch ever
        // crossed over into it.
        let newDb = try TestFixtureFactory.createTemporary(content: "# Gamma\n\nseven eight nine.\n")
        let newPid = try TestFixtureFactory.getProjectId(from: newDb)
        let newBefore = try totalWordCount(newDb, newPid)

        let gate = SwitchGate()
        let log = OrderLog()
        // Parks past the cycle's own `database`/`projectId`/`generationAtPoll`
        // capture (MF3, review round 2) -- not `testPollCycleHook`, which fires at
        // the very top of `runPollCycle`, before that capture, and so would never
        // observe anything inside the reordered capture window. See this file's
        // header comment for exactly what is and isn't proven by parking here.
        sync.testAfterGenerationCaptureHook = { await gate.waitAtGate() }

        // Start a FORCED poll cycle and let it hang just past its own capture of
        // `database`/`projectId`/`generationAtPoll` — simulating a bibliography-
        // rebuild-style forced flush that happens to be in flight exactly when a
        // rapid project switch races it.
        let pollTask = Task { @MainActor in
            await sync.pollBlockChangesForTest(force: true)
        }
        await gate.waitUntilReached()

        // Make a real edit to the OLD project's content AFTER the forced cycle is
        // already parked just past its own capture (and therefore before it has
        // run `flushPendingJSChanges`/read the JS-side pending queue), so there's
        // a genuine pending batch for it to discover once released.
        try await editBetaParagraph(helper.webView)

        // Start the project switch and deterministically confirm it has begun
        // running (past its own synchronous prefix, including reconfigure's
        // entry into `drainInFlightPoll()`'s await) before we open the gate —
        // same technique as `testForcedFlush_waitsForInFlightPoll_thenFlushesFreshEdit`.
        let switchStarted = StartSignal()
        let switchTask = Task { @MainActor in
            switchStarted.fire()
            log.record("switchCalled")
            await sync.reconfigure(database: newDb, projectId: newPid)
            log.record("switchReturned")
        }
        await switchStarted.wait()

        log.record("gateReleased")
        gate.open()

        await pollTask.value
        await switchTask.value

        let recorded = log.events
        XCTAssertEqual(
            recorded, ["switchCalled", "gateReleased", "switchReturned"],
            "reconfigure(...) must drain the parked forced poll cycle before returning " +
                "(and before swapping in the new project) — got order \(recorded)"
        )

        let oldAfter = try totalWordCount(oldDb, oldPid)
        XCTAssertGreaterThan(
            oldAfter, oldBefore,
            "the edit made while the forced cycle was parked must still land in the " +
                "OLD project — the cycle resumes with the OLD database/projectId locals " +
                "because reconfigure(...) doesn't swap them in until after draining " +
                "(before=\(oldBefore), after=\(oldAfter))"
        )

        let newAfter = try totalWordCount(newDb, newPid)
        XCTAssertEqual(
            newAfter, newBefore,
            "the pre-switch batch must never land in the NEW project — its word " +
                "count must be exactly what it was before the switch " +
                "(before=\(newBefore), after=\(newAfter))"
        )
    }

    /// Regression test for the OTHER call site of the drain primitive:
    /// `performProjectClose()` in `ContentView+ProjectLifecycle.swift` calls
    /// `blockSyncService.stopPollingAndDrain()` BEFORE `editorState.flushAllSync()`
    /// (drain-then-flush order — MF2, block-sync-poll-races review round 2: this
    /// used to run the other way around, which meant a poll cycle already in
    /// flight when the user clicked close could resume and land a stale write
    /// AFTER the close-time flush had just landed the user's real, current
    /// content — silently reverting their last edit with no error surfaced
    /// anywhere). `testReconfigure_drainsInFlightForcedPoll_beforeSwitchingProject`
    /// above proves the drain primitive as exercised by `reconfigure(...)`; this
    /// proves the SAME underlying primitive (`drainInFlightPoll()`, reached here
    /// via `stopPollingAndDrain()` rather than `reconfigure`) as exercised by the
    /// close path — i.e. that `stopPollingAndDrain()` itself does not return
    /// until a forced in-flight poll cycle has genuinely finished. That guarantee
    /// is exactly what `performProjectClose()`'s drain-then-flush ordering
    /// depends on: the ordering fix in the caller is only load-bearing if the
    /// callee it awaits first actually blocks until the in-flight cycle is done.
    /// (`performProjectClose()` itself is not exercised end-to-end here — it
    /// reaches into `ContentView`'s other services, editorState, and
    /// notification plumbing, which is impractical to stand up at this unit
    /// level; this test instead isolates and proves the lower-level primitive
    /// that call's correctness reduces to.)
    ///
    /// Same technique as `testReconfigure_...` above: parks a FORCED poll cycle
    /// (`pollBlockChangesForTest(force: true)`) at `testAfterGenerationCaptureHook`
    /// — past its own `database`/`projectId`/`generationAtPoll` capture, with a
    /// real `editorState` wired so that capture is a genuine value — makes a real
    /// edit to the project's content while it's parked, then concurrently calls
    /// `stopPollingAndDrain()` and records a happens-before-ordered event
    /// sequence: `.drainCalled` when `stopPollingAndDrain()` starts,
    /// `.gateReleased` when the parked cycle is released, `.drainReturned` when
    /// `stopPollingAndDrain()` returns.
    ///
    /// The assertion is on that recorded ORDER, not on timing — see
    /// `testForcedFlush_waitsForInFlightPoll_thenFlushesFreshEdit`'s doc comment
    /// in ZoomWordCountSyncTests.swift for why an ordering assertion derived from
    /// actual continuation-resume order can't false-pass regardless of machine
    /// speed. If `stopPollingAndDrain()` ever regressed to return early (e.g. lost
    /// its `drainInFlightPoll()` call entirely, or only drained unforced cycles),
    /// the order here would collapse to `drainCalled, drainReturned, gateReleased`
    /// — `stopPollingAndDrain()` returning before the gate is even opened — the
    /// same failure shape `testReconfigure_...` uses for the pre-fix
    /// `reconfigure(...)`.
    ///
    /// Also verifies via a direct word-count read that the edit made while
    /// parked has actually reached the database by the time
    /// `stopPollingAndDrain()` returns — proving the drain didn't just happen to
    /// finish in the right order by chance, but actually waited for the cycle's
    /// real work (including its DB write) to complete, which is what makes it
    /// safe for a caller to run its own database write immediately afterward
    /// (exactly what `performProjectClose()` does with `flushAllSync()`).
    @MainActor
    func testStopPollingAndDrain_waitsForInFlightForcedPoll_beforeReturning() async throws {
        let stack = try await makeStack()
        let (helper, db) = (stack.helper, stack.db)
        let (pid, sync) = (stack.pid, stack.sync)

        // Wire a real EditorViewState (mirrors ZoomWordCountSyncTests.swift:457-458
        // and testReconfigure_... above) so `generationAtPoll` captures a genuine
        // value rather than the inert `?? 0` default.
        let editorState = EditorViewState()
        sync.editorState = editorState

        let blocks = try TestFixtureFactory.fetchBlocks(from: db)
            .sorted { $0.sortOrder < $1.sortOrder }
        let ids = BlockParser.idsForProseMirrorAlignment(blocks)
        let content = BlockParser.assembleMarkdown(from: blocks)
        await sync.setContentWithBlockIds(markdown: content, blockIds: ids)
        try await Task.sleep(nanoseconds: 500_000_000)

        let before = try totalWordCount(db, pid)

        let gate = SwitchGate()
        let log = OrderLog()
        // Parks past the cycle's own `database`/`projectId`/`generationAtPoll`
        // capture — same park point as `testReconfigure_...` above; see this
        // file's header comment for exactly what is and isn't proven by parking
        // here.
        sync.testAfterGenerationCaptureHook = { await gate.waitAtGate() }

        // Start a FORCED poll cycle and let it hang just past its own capture --
        // simulating a poll cycle that happens to be in flight exactly when the
        // user clicks close.
        let pollTask = Task { @MainActor in
            await sync.pollBlockChangesForTest(force: true)
        }
        await gate.waitUntilReached()

        // Make a real edit AFTER the forced cycle is already parked, so there's
        // a genuine pending batch for it to discover once released -- this is
        // the edit `performProjectClose()`'s drain-then-flush ordering exists to
        // protect.
        try await editBetaParagraph(helper.webView)

        // Start the drain and deterministically confirm it has begun running
        // (past its own synchronous prefix, including entry into
        // `drainInFlightPoll()`'s await) before we open the gate -- same
        // technique as `testReconfigure_...` above.
        let drainStarted = StartSignal()
        let drainTask = Task { @MainActor in
            drainStarted.fire()
            log.record("drainCalled")
            await sync.stopPollingAndDrain()
            log.record("drainReturned")
        }
        await drainStarted.wait()

        log.record("gateReleased")
        gate.open()

        await pollTask.value
        await drainTask.value

        let recorded = log.events
        XCTAssertEqual(
            recorded, ["drainCalled", "gateReleased", "drainReturned"],
            "stopPollingAndDrain() must not return until the parked forced poll " +
                "cycle has finished — got order \(recorded)"
        )

        let after = try totalWordCount(db, pid)
        XCTAssertGreaterThan(
            after, before,
            "the edit made while the forced cycle was parked must have reached " +
                "the database by the time stopPollingAndDrain() returns -- " +
                "proving the drain actually waited for the cycle's write, not " +
                "just for events to happen to line up (before=\(before), after=\(after))"
        )
    }
}
