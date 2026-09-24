//
//  QuitFlushDuplicateInsertTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage — reproduction test for TLA+ Finding #8
//  (Calm_InsertThenQuit, docs/architecture/tla/DocSyncCurrent.tla): before
//  `EditorViewState.flushForQuit()` (EditorViewState+Quit.swift), quit never
//  stopped the 2s block-sync poll before flushing. A poll cycle already
//  running (or one whose timer simply hadn't been invalidated yet) could fire
//  after the quit-time flush had already written a freshly-typed paragraph to
//  the database via a full re-parse, and re-apply the editor's still-pending,
//  unconfirmed "insert" change for that same paragraph through the ordinary
//  incremental poll path — landing it a second time as a duplicate row.
//
//  `flushForQuit()` fixes this by calling `stopPollingAndDrain()` BEFORE
//  fetching fresh content and flushing (mirroring `performProjectClose()`),
//  so any poll cycle already in flight is drained (cancelled, for an unforced
//  cycle) before the flush ever writes anything — no later apply can land on
//  top of it.
//
//  WHY A SIMULATED POLL CYCLE, NOT A REAL TIMER: an earlier version of this
//  test called the real `sync.startPolling()` and waited on a `Task.sleep`
//  loop for its repeating `Timer` to fire naturally. That passed (1 row) even
//  with `stopPollingAndDrain()` disabled -- a vacuous pass, because a `Timer`
//  doesn't reliably fire while this test host's MainActor is busy inside a
//  `Task.sleep` loop rather than running the CFRunLoop that services it (the
//  same RunLoop-dependency failure mode documented in
//  `BibliographyHeaderNameWiringTests.swift`'s `NotificationWait` for a
//  `DispatchQueue.main.async`-deferred callback). `BlockSyncService.
//  testPollCycleHook` exists precisely so a test can hold a cycle
//  deterministically suspended mid-flight without racing real timers or
//  sleeping. This file follows that pattern (mirroring the
//  `SwitchGate`/`StartSignal` checked-continuation idiom in
//  `BlockSyncProjectSwitchDrainTests.swift`): it starts a real, UNFORCED poll
//  cycle via `pollBlockChangesForTest(force: false)` -- simulating exactly
//  what the real Timer's tick would invoke -- and parks it at the very top of
//  its cycle, registered in `BlockSyncService`'s private `inFlightPoll` slot,
//  via `testPollCycleHook`, so `stopPollingAndDrain()`'s `drainInFlightPoll()`
//  has a real in-flight cycle to cancel/await. `flushForQuit()` is called
//  INLINE (not spawned concurrently) while that cycle is parked: with the fix
//  restored, its own drain call cancels the parked cycle from the inside (see
//  `QuitPollGate` below) before `flushForQuit()` ever fetches or flushes
//  anything, so the inline `await` only returns once the parked cycle has
//  actually unwound.
//
//  Test 1's harness carries three safety nets, each guarding against a
//  specific false pass: the poll watchdog is pushed out to 60s
//  (`sync.testPollWatchdogSeconds`), well past `flushForQuit()`'s own worst
//  case, so only the fix's own drain cancellation or the test's 15s
//  safety-net task can unpark the cycle -- a watchdog firing first would look
//  identical to the fix working, so that is asserted against explicitly.
//  `QuitPollGate` is cancellation-aware so the fix's drain cancellation
//  resumes the parked continuation instead of hanging forever (see its own
//  doc comment for why it can't be a plain `@MainActor` class). The 15s
//  safety-net task fails loudly (`XCTFail`) rather than silently unwedging if
//  nothing ever releases the parked cycle, so a hang is reported as a
//  failure, not swallowed. See `placeCursorAtEndOfHeading`'s own doc comment
//  below for why the insert is anchored to the heading rather than the
//  trailing paragraph -- that anchor choice is itself load-bearing.
//
//  Drives the real editor -> block-sync -> DB chain with a real Milkdown
//  WKWebView, and types the reproducing edit via real NSEvent keyDown/keyUp
//  (not execCommand — this codebase's "execCommand doesn't replicate real
//  keyboard input" rule; see CAYWConcurrentInsertTests.swift /
//  LinkTrailingTextTests.swift for the same technique). `makeStack`,
//  `totalWordCount`-style DB helpers, and the rAF shim follow
//  ZoomWordCountSyncTests.swift's established Tier2 harness pattern.
//
//  Uses XCTest (not Swift Testing) because WKWebView requires a run loop —
//  same reasoning as ZoomWordCountSyncTests.swift.
//
//  Test 3 covers a SECOND, distinct trigger for the same duplicate-paragraph shape as
//  test 1 -- not the periodic-poll-drain race, but `flushForQuit()` forcing an
//  already-scheduled bibliography/Notes rebuild via
//  `flushPendingBibliographyAndFootnoteSync()`, whose notification handler
//  (`ContentView.handleNotesSectionChanged()` / `handleBibliographySectionChanged()`)
//  would otherwise spawn its own forced `pollBlockChangesNowForDatabaseRebuild()` and
//  re-apply the same still-pending insert a second time. Test 3 drives the Notes/
//  footnote half (the bibliography half needs a live Zotero connection -- see
//  `performBibliographyUpdate`'s `zoteroService.isConnected` guard -- so isn't a fit
//  for a self-contained unit test); see that test's own doc comment for the full
//  mechanism and why it needs no `QuitPollGate`-style hook the way test 1 does.
//

import XCTest
import WebKit
import os
@testable import final_final

/// Lock-protected state shared between `QuitPollGate.waitAtGate()`'s
/// continuation installer and its `withTaskCancellationHandler`'s `onCancel`
/// closure. `onCancel` may run from ANY execution context -- not necessarily
/// MainActor, and not necessarily after the continuation has even been
/// installed (a "cancel-before-park" race) -- so every field here is reached
/// only through `QuitPollGate`'s single `OSAllocatedUnfairLock`, never through
/// a bare `@MainActor` stored property.
private struct GateState: Sendable {
    var parkContinuation: CheckedContinuation<Void, Never>?
    var reachedContinuation: CheckedContinuation<Void, Never>?
    var reached = false
    var released = false
    var cancelled = false
}

/// Checked-continuation gate (no sleep) that lets a test hold an in-flight,
/// UNFORCED poll cycle deterministically suspended at the very top of its
/// cycle -- before it has read `contentState`, checked for changes, or fetched
/// anything -- via `BlockSyncService.testPollCycleHook`, confirm via
/// `waitUntilReached()` that it's genuinely stuck there (not merely about to
/// run), then release it with `open()`. File-private equivalent of
/// `BlockSyncProjectSwitchDrainTests.swift`'s `SwitchGate` (that one is
/// private to its own file and can't be reused directly from here).
///
/// CANCELLATION-AWARE: once `flushForQuit()`'s `stopPollingAndDrain()` call is
/// restored, quitting cancels this parked cycle's own work task WHILE it is
/// sitting inside `waitAtGate()` -- `BlockSyncService.runPollCycle`'s
/// `withTaskCancellationHandler` calls `work.cancel()` on it directly.
/// `waitAtGate()` installs its own `withTaskCancellationHandler` so that
/// cancellation resumes the parked continuation instead of hanging forever.
/// Because `onCancel` runs non-isolated and may run from a different
/// execution context than the parked task, this is deliberately NOT a plain
/// `@MainActor` class with unguarded stored properties -- every mutable field
/// lives behind a single `OSAllocatedUnfairLock<GateState>`, and the
/// continuation is resumed EXACTLY ONCE, whether via `open()` or via
/// cancellation, with a cancel-before-park race (cancellation observed before
/// the continuation is even installed) handled by checking the
/// cancelled/released flags inside the same locked section that installs it.
private final class QuitPollGate: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: GateState())

    /// Call from inside the poll cycle (via `testPollCycleHook`).
    func waitAtGate() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Extract the waiter under the lock, resume it AFTER releasing --
                // matching `open()` and `onCancel` below, neither of which ever calls
                // `.resume()` from inside `state.withLock { }`.
                let (reachedWaiter, resumeImmediately):
                    (CheckedContinuation<Void, Never>?, Bool) = state.withLock { gateState in
                    gateState.reached = true
                    let waiter = gateState.reachedContinuation
                    gateState.reachedContinuation = nil
                    guard !gateState.released, !gateState.cancelled else { return (waiter, true) }
                    gateState.parkContinuation = continuation
                    return (waiter, false)
                }
                reachedWaiter?.resume()
                if resumeImmediately {
                    continuation.resume()
                }
            }
        } onCancel: {
            let toResume: CheckedContinuation<Void, Never>? = state.withLock { gateState in
                guard !gateState.released, !gateState.cancelled else { return nil }
                gateState.cancelled = true
                defer { gateState.parkContinuation = nil }
                return gateState.parkContinuation
            }
            toResume?.resume()
        }
    }

    /// Suspends until some poll cycle has actually reached the gate.
    ///
    /// Supports exactly ONE waiter: a second call made before the gate is reached would
    /// overwrite `gateState.reachedContinuation` with its own continuation, silently
    /// leaking the first caller's (it would never be resumed). Not a concern for this
    /// file's own single-waiter usage, but not enforced by the type either -- callers
    /// must not call this a second time until the first call has returned.
    func waitUntilReached() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeImmediately: Bool = state.withLock { gateState in
                precondition(gateState.reachedContinuation == nil, "waitUntilReached() supports only one waiter")
                if gateState.reached { return true }
                gateState.reachedContinuation = continuation
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    /// Releases whatever is parked at the gate; future arrivals pass straight
    /// through. No-op if the gate was already released, or the parked cycle
    /// was already cancelled out from under it.
    func open() {
        let toResume: CheckedContinuation<Void, Never>? = state.withLock { gateState in
            guard !gateState.released, !gateState.cancelled else { return nil }
            gateState.released = true
            defer { gateState.parkContinuation = nil }
            return gateState.parkContinuation
        }
        toResume?.resume()
    }
}

final class QuitFlushDuplicateInsertTests: XCTestCase {

    /// Distinctive marker text for the reproducing paragraph — never appears
    /// anywhere else in the fixture, so any row containing it must have come
    /// from either the quit-time flush's fresh parse or a late poll cycle
    /// re-applying the same still-pending insert.
    private static let marker = "zebra quokka marmot"

    private static let doc = """
    # Alpha

    one two three.
    """

    /// Keeps the WebView on-screen so requestAnimationFrame fires, and gives
    /// NSEvent-based typing a real key window to deliver into (mirrors
    /// CAYWConcurrentInsertTests.swift's makeHelper).
    private var hostWindow: NSWindow?

    @MainActor
    override func tearDown() async throws {
        hostWindow?.orderOut(nil)
        hostWindow = nil
    }

    // MARK: - Test 1: reproduction + regression

    /// Reproduction + regression test: typing a new paragraph, then quitting
    /// while the block-sync poll is running, must write that paragraph to the
    /// database exactly once — never twice.
    @MainActor
    func testQuitFlush_inFlightPollParkedBeforeEpochRead_doesNotDuplicateParagraph() async throws {
        let stack = try await makeStack()
        let (helper, db, pid, sync, editorState) = (stack.helper, stack.db, stack.pid, stack.sync, stack.editorState)
        guard let window = hostWindow else { throw XCTSkip("no host window") }

        defer {
            sync.stopPolling()
            sync.testPollCycleHook = nil
            sync.testPollWatchdogSeconds = nil
        }

        // Move the caret to the end of the heading (NOT the trailing paragraph —
        // see placeCursorAtEndOfHeading's doc comment for why that anchor choice
        // is load-bearing), press Return, and type a distinctive marker
        // paragraph via real NSEvents.
        try await placeCursorAtEndOfHeading(helper)
        try await Task.sleep(nanoseconds: 200_000_000)
        try pressEnter(window: window)
        try await Task.sleep(nanoseconds: 200_000_000)
        try typeViaNSEvents(Self.marker, window: window)

        // block-sync-plugin's detectChanges debounce is 100ms; leave generous headroom.
        try await Task.sleep(nanoseconds: 600_000_000)

        let contentAfterType = try await helper.getContent()
        let hasPending = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.hasBlockChanges()"
        ) as? Bool

        // A broken test harness (this precondition failing) must not silently and
        // permanently skip a regression test -- XCTFail, not XCTSkip: a skip here would
        // report green forever if the harness ever stopped exercising the race this
        // test exists to catch.
        guard hasPending == true, contentAfterType.contains(Self.marker) else {
            XCTFail(
                "the typed paragraph never became a pending, unconfirmed " +
                "block-sync insert -- hasBlockChanges()=\(String(describing: hasPending)), " +
                "content contains marker=\(contentAfterType.contains(Self.marker)); " +
                "content=\(contentAfterType)"
            )
            return
        }

        // Precondition: an unforced poll cycle SKIPS unless contentState == .idle
        // (see BlockSyncService.doPollBlockChanges's contentState guard) -- without
        // this, the test would "pass" because the cycle never even attempted to
        // apply anything, not because the fix worked.
        XCTAssertEqual(
            editorState.contentState, .idle,
            "precondition: an unforced poll cycle skips unless contentState == .idle"
        )

        // Push the watchdog well past both flushForQuit()'s worst case (up to one
        // poll watchdog period for stopPollingAndDrain()'s own drain wait --
        // BlockSyncService.defaultPollWatchdogSeconds, 8s by default -- plus a 2s
        // WebView fetch timeout plus a 3s bibliography/footnote flush bound) and the
        // 15s safety net below, so only the fix's own drain cancellation or that
        // safety net can unpark the poll cycle -- a watchdog firing first would
        // falsely look identical to the fix working.
        sync.testPollWatchdogSeconds = 60

        // Simulate "the poll is active, as it always is during normal editing" by
        // starting a real, UNFORCED poll cycle -- exactly what the real 2s Timer's
        // tick would invoke -- via the test-only entry point, and park it at the very
        // top of its cycle via `testPollCycleHook`. See this file's header comment for
        // why this replaces the real `sync.startPolling()` + wall-clock wait this test
        // used before: the real `Timer` does not reliably fire while this test host is
        // busy inside a `Task.sleep`-based wait loop.
        let gate = QuitPollGate()
        sync.testPollCycleHook = { await gate.waitAtGate() }
        let pollTask = Task { @MainActor in
            await sync.pollBlockChangesForTest(force: false)
        }

        // Fail loudly, don't silently unwedge, if nothing ever releases the parked
        // cycle within a generous bound. Created BEFORE `waitUntilReached()` below
        // (not after): that call is itself an unbounded `await` with nothing else
        // guarding it, so if the poll cycle somehow never reaches the gate at all,
        // this safety net is the only thing that can still fail the test instead of
        // hanging it forever.
        let safety = Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled {
                XCTFail("flushForQuit()/drain never released the parked poll cycle within 15s")
                gate.open()
            }
        }

        // Confirms the cycle is genuinely in flight (registered in BlockSyncService's
        // private `inFlightPoll` slot) and parked -- not merely about to run -- before
        // quit begins.
        await gate.waitUntilReached()
        XCTAssertFalse(sync.testInFlightPollIsNil, "the poll cycle must be genuinely in flight before quit begins")

        // Simulate quit while that poll cycle is still parked -- exactly the race
        // `flushForQuit()`'s `stopPollingAndDrain()` call exists to close. Called
        // INLINE (not spawned concurrently): once the fix is restored,
        // `stopPollingAndDrain()`'s drain cancels this parked cycle from the inside
        // (via `QuitPollGate`'s `withTaskCancellationHandler`) before `flushForQuit()`
        // ever fetches or flushes anything, so this `await` only returns once the
        // parked cycle has actually unwound. With the fix still disabled, this
        // returns immediately (the flush never waits on the poll at all), leaving the
        // cycle parked for `gate.open()` below to release afterward -- reproducing the
        // duplicate-insert race.
        await editorState.flushForQuit()

        // Direct assertion on the drain's own effect -- more robust than relying only on
        // the downstream row count below, which could still read 1 by coincidence (e.g.
        // if the parked cycle's batch happened to be empty) even if flushForQuit()
        // returned without actually draining it.
        XCTAssertTrue(sync.testInFlightPollIsNil, "flushForQuit must drain the in-flight poll before returning")

        safety.cancel()
        gate.open() // no-op if the fix's drain already resumed (or cancelled) the parked continuation
        await pollTask.value

        let markerRows = try countRows(containing: Self.marker, db: db, pid: pid)

        XCTAssertEqual(
            markerRows, 1,
            "Quit must write the new paragraph exactly once; found \(markerRows) rows " +
            "containing '\(Self.marker)' (2+ means a poll cycle re-inserted it after the " +
            "quit flush)"
        )
        XCTAssertTrue(
            sync.testPollTimeoutForceFlags.isEmpty,
            "the poll watchdog must never have fired in this test -- a watchdog race would " +
            "falsely look identical to the fix working; got \(sync.testPollTimeoutForceFlags)"
        )
    }

    // MARK: - Test 2: quit disarms the periodic timer

    /// Regression test for the OTHER half of the fix: quit must disarm the
    /// periodic poll Timer itself (`stopPolling()`, inside `stopPollingAndDrain()`),
    /// not just drain whatever cycle happens to be in flight at the moment of quit —
    /// otherwise a fresh tick could still fire and re-insert after the flush. No
    /// WebView or database wiring needed: `flushForQuit()` tolerates an unconfigured
    /// `BlockSyncService` gracefully (`fetchContentFromWebView` returns nil with no
    /// webView, and `flushContentToDatabase` no-ops on empty content / a nil
    /// database), so this can drive the real timer directly.
    @MainActor
    func testQuitFlush_disarmsPeriodicPollTimer() async throws {
        let sync = BlockSyncService()
        let editorState = EditorViewState()
        editorState.blockSyncService = sync
        defer { sync.stopPolling() }
        sync.startPolling()
        XCTAssertTrue(sync.testPollTimerIsArmed)
        await editorState.flushForQuit()
        XCTAssertFalse(sync.testPollTimerIsArmed,
            "quit must disarm the periodic poll so no fresh cycle can re-insert after the flush")
    }

    // MARK: - Test 3: forced Notes rebuild poll (the OTHER trigger flushForQuit's
    // suppressRebuildsForQuit guards against, distinct from the periodic-poll race
    // tests 1/2 cover)

    /// Reproduction + regression test for the fix's OTHER half: `flushForQuit()` ->
    /// `flushAllSync()` -> `flushPendingBibliographyAndFootnoteSync()` can force an
    /// already-scheduled, debounced Notes update to run immediately (the bibliography
    /// sibling needs a live Zotero connection -- see `performBibliographyUpdate`'s
    /// `zoteroService.isConnected` guard -- so this test drives the Notes/footnote path
    /// instead). That forced update writes to the database and posts
    /// `.notesSectionChanged`, which `ContentView.handleNotesSectionChanged()` handles
    /// by spawning its own untracked `Task` that calls
    /// `blockSyncService.pollBlockChangesNowForDatabaseRebuild()` with `force: true`,
    /// bypassing the contentState/generation guards entirely
    /// (`BlockSyncService.pollBlockChangesNow`'s own doc comment). Unsuppressed, that
    /// forced poll re-applies the still-pending, unconfirmed marker-paragraph insert a
    /// SECOND time on top of the row `flushAllSyncCore()`'s own full reparse already
    /// wrote moments earlier in the same `flushForQuit()` call.
    ///
    /// NO GATE/HOOK NEEDED HERE (unlike test 1's `QuitPollGate`): that test has to hold
    /// a poll cycle deterministically parked mid-flight because it races
    /// `stopPollingAndDrain()` against an *unforced* cycle that would otherwise skip
    /// unless caught at exactly the right moment. `force: true` here unconditionally
    /// bypasses those same guards, so once `handleNotesSectionChanged()`'s `Task` is
    /// spawned there is nothing left to synchronize against except that `Task`'s own
    /// ordinary completion, which the bounded poll loop below waits out (the same
    /// pattern `BibliographySectionFlagTests+DataIntegrity.swift`'s
    /// `handleBibliographySectionChangedSyncsSectionTableImmediately` uses for the
    /// sibling bibliography handler) -- not a real Timer, so the CFRunLoop-dependency
    /// hazard this file's header comment documents doesn't apply.
    ///
    /// `checkAndUpdateFootnotes`'s `footnoteRefs`/`fullContent` arguments are supplied
    /// directly here rather than derived from the live Milkdown document (in
    /// production they come from `onChange(of: editorState.content)`, a channel
    /// independent of block-sync's own pending-insert tracking, which the marker
    /// paragraph below still exercises for real via NSEvents) -- calling the trigger
    /// directly avoids the risk of typing a literal `[^1]` interacting with Milkdown's
    /// own footnote plugin, without weakening the test.
    @MainActor
    func testQuitFlush_forcedNotesRebuildPoll_doesNotDuplicateParagraph() async throws {
        let stack = try await makeContentViewStack()
        let (helper, db, pid, view) = (stack.helper, stack.db, stack.pid, stack.view)
        guard let window = hostWindow else { throw XCTSkip("no host window") }

        let priorDb = DocumentManager.shared.projectDatabase
        let priorPid = DocumentManager.shared.projectId
        DocumentManager.shared.projectDatabase = db
        DocumentManager.shared.projectId = pid

        defer {
            DocumentManager.shared.projectDatabase = priorDb
            DocumentManager.shared.projectId = priorPid
            view.blockSyncService.stopPolling()
        }

        // Schedule a debounced Notes update -- simulates a footnote reference typed a
        // moment earlier, still sitting inside FootnoteSyncService's 3s debounce when
        // quit happens. `flushForQuit()` below forces it to run NOW via
        // `flushPendingSync()` instead of waiting out that debounce.
        view.footnoteSyncService.checkAndUpdateFootnotes(
            footnoteRefs: ["1"], projectId: pid, fullContent: "# Alpha\n\n[^1]\n\none two three."
        )

        // Anchor to the heading, NOT the trailing paragraph -- see
        // placeCursorAtEndOfHeading's doc comment: an anchor on the paragraph would be
        // invalidated by flushContentToDatabase's own full reparse before the forced
        // rebuild poll ever ran, silently absorbing the race regardless of whether
        // suppressRebuildsForQuit works.
        try await placeCursorAtEndOfHeading(helper)
        try await Task.sleep(nanoseconds: 200_000_000)
        try pressEnter(window: window)
        try await Task.sleep(nanoseconds: 200_000_000)
        try typeViaNSEvents(Self.marker, window: window)
        try await Task.sleep(nanoseconds: 600_000_000)

        let contentAfterType = try await helper.getContent()
        let hasPending = try await helper.webView.evaluateJavaScript(
            "window.FinalFinal.hasBlockChanges()"
        ) as? Bool
        guard hasPending == true, contentAfterType.contains(Self.marker) else {
            XCTFail(
                "the typed paragraph never became a pending, unconfirmed block-sync insert -- " +
                "hasBlockChanges()=\(String(describing: hasPending)), " +
                "content contains marker=\(contentAfterType.contains(Self.marker)); " +
                "content=\(contentAfterType)"
            )
            return
        }

        // Wires the SAME NotificationCenter delivery SwiftUI's
        // `.onReceive(publisher(for: .notesSectionChanged))` provides in production --
        // `view` is never installed in a live view hierarchy here, so nothing delivers
        // this notification unless wired by hand (same reason the precedent
        // `handleBibliographySectionChangedSyncsSectionTableImmediately` calls its
        // handler directly instead). Delivered with `queue: nil` -- synchronous
        // delivery on the posting thread, matching production: the post happens from
        // `FootnoteSyncService.performFootnoteUpdate`, itself `@MainActor`, so this
        // closure runs on the main thread and `MainActor.assumeIsolated` is a true
        // isolation match, not a hop that would change the timing being tested.
        let observer = NotificationCenter.default.addObserver(
            forName: .notesSectionChanged, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                view.handleNotesSectionChanged()
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // The real quit path: arms suppressRebuildsForQuit, drains (a no-op here -- no
        // poll was ever started in this test), fetches fresh WebView content (includes
        // the typed marker), then flushAllSync() -> flushAllSyncCore()'s
        // flushContentToDatabase() writes the marker via a full reparse (1 row) before
        // flushPendingBibliographyAndFootnoteSync() forces the footnote update scheduled
        // above to run now -- which posts .notesSectionChanged synchronously from
        // inside this same call stack, exactly as production's debounce-fire path would.
        await view.editorState.flushForQuit()

        // Bounded poll (not a fixed sleep-and-hope): gives handleNotesSectionChanged()'s
        // fire-and-forget Task time to actually run its forced
        // pollBlockChangesNowForDatabaseRebuild() call and land (or not) a second row.
        var markerRows = try countRows(containing: Self.marker, db: db, pid: pid)
        let deadline = Date().addingTimeInterval(3)
        while markerRows == 1, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            markerRows = try countRows(containing: Self.marker, db: db, pid: pid)
        }

        XCTAssertEqual(
            markerRows, 1,
            "Quit must write the footnote-triggering paragraph exactly once; found \(markerRows) " +
            "rows containing '\(Self.marker)' (2+ means handleNotesSectionChanged()'s forced " +
            "rebuild poll re-inserted the still-pending edit after suppressRebuildsForQuit should " +
            "have blocked the handler from ever starting its Task)"
        )
    }
}

// MARK: - Harness
//
// Split into an extension (rather than left inline in the class above) purely to keep
// the class body itself under SwiftLint's type_body_length limit -- extensions are
// excluded from that count by this project's .swiftlint.yml (`excluded_types:
// [extension, protocol]`). `private` members declared here remain visible to the class
// above because Swift shares `private` access across same-file extensions of a type; no
// behavior, logic, or access level changes as a result of this split.

extension QuitFlushDuplicateInsertTests {
    private struct EditorStack {
        let helper: EditorTestHelper
        let db: ProjectDatabase
        let pid: String
        let sync: BlockSyncService
        let editorState: EditorViewState
    }

    @MainActor
    private func makeStack() async throws -> EditorStack {
        let db = try TestFixtureFactory.createTemporary(content: Self.doc)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let helper = EditorTestHelper(editorType: .milkdown)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = helper.webView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(helper.webView)
        hostWindow = window

        try await helper.loadAndWaitForReady(timeout: 15)

        // Harness shim: WKWebView under xcodebuild never fires requestAnimationFrame,
        // which block-sync's deferredSnapshotAndUnpause() depends on — without this,
        // sync stays paused forever and no edit ever registers (pure test artifact;
        // see ZoomWordCountSyncTests.swift's makeStack for the same shim).
        _ = try await helper.webView.evaluateJavaScript(
            "window.requestAnimationFrame = (cb) => setTimeout(() => cb(performance.now()), 16); true"
        )

        let sync = BlockSyncService()
        sync.configure(database: db, projectId: pid, webView: helper.webView)

        // Wire a real EditorViewState the way the app does (ContentView+ProjectLifecycle
        // .swift's configureSyncServices): editorState.blockSyncService for
        // flushForQuit()'s own calls, sync.editorState so the poll's block-change
        // application has one, and projectDatabase/currentProjectId so
        // flushAllSync()'s flushContentToDatabase() can actually write (see
        // SnapshotBackupFlushTests.swift for the same direct-assignment pattern).
        let editorState = EditorViewState()
        editorState.blockSyncService = sync
        sync.editorState = editorState
        editorState.projectDatabase = db
        editorState.currentProjectId = pid

        let blocks = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        let ids = BlockParser.idsForProseMirrorAlignment(blocks)
        let content = BlockParser.assembleMarkdown(from: blocks)
        await sync.setContentWithBlockIds(markdown: content, blockIds: ids)
        try await Task.sleep(nanoseconds: 500_000_000)
        editorState.content = content

        return EditorStack(helper: helper, db: db, pid: pid, sync: sync, editorState: editorState)
    }

    /// Number of blocks whose markdown contains `marker` — 1 is correct (the quit
    /// flush's own fresh parse); 2+ means a poll cycle re-inserted it.
    private func countRows(containing marker: String, db: ProjectDatabase, pid: String) throws -> Int {
        try db.read { database in
            try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM block
                WHERE projectId = ? AND markdownFragment LIKE ?
                """, arguments: [pid, "%\(marker)%"]) ?? 0
        }
    }

    /// Collapses the native DOM selection to the end of the document's first
    /// heading ("# Alpha") — NOT the trailing paragraph ("one two three."),
    /// which a prior version of this test used (`placeCursorAtDocumentEnd`).
    ///
    /// WHY THE HEADING, NOT THE PARAGRAPH: anchoring the typed insert after the
    /// trailing PARAGRAPH made an earlier version of this test pass (1 row) even
    /// with `flushForQuit()`'s fix disabled — not because the fix was
    /// unnecessary, but because an entirely unrelated, pre-existing guard
    /// silently absorbed the race regardless. `flushForQuit()`'s own
    /// `flushAllSync()` → `flushContentToDatabase()` calls `replaceBlocks()`
    /// (EditorViewState+Zoom.swift), a FULL document re-parse that deletes every
    /// row and reinserts fresh ones, "preserving heading IDs and metadata by
    /// title match" but reassigning brand-new ids to every other block type (see
    /// that file's own `flushLiveContentToDatabase` doc comment: "flushContentTo
    /// Database()'s full re-parse reassigns fresh ids to most non-heading block
    /// types"). With the insert anchored to the paragraph, THAT anchor's id was
    /// always invalidated by this same flush before the parked poll cycle ever
    /// resumed — so `processEditorInserts`'s pre-existing stale-anchor guard
    /// (t-3904c457, `Database+BlocksInsert.swift`: "If the anchor resolves to
    /// nothing in the DB, this diff was computed against rows a structural
    /// rewrite ... has since replaced ... Reject it") silently `continue`d past
    /// the insert on every run, fix enabled or not — never reaching the
    /// (epoch, generation, chain) guards `flushForQuit()`'s fix actually
    /// targets. Anchoring to the HEADING instead survives `replaceBlocks()`'s
    /// reparse (its id is unchanged by title match), so the insert reaches
    /// those guards for real: with the fix disabled it now writes a genuine
    /// second row; with the fix restored, the drain cancels the parked cycle
    /// (via `Task.checkCancellation()` at the very top of `doPollBlockChanges`)
    /// before it ever gets that far.
    ///
    /// Real-world equivalent: "the user's cursor was on a blank line right
    /// after a heading when they hit Cmd+Q" — an ordinary place to type, not a
    /// contrived one. Confirmed against this same Milkdown editor by
    /// `HeadingParagraphExportOrderTests.swift`, which types a heading, presses
    /// a real Enter, and asserts the resulting block type is `"paragraph"` (not
    /// a second heading) — the same technique this helper relies on.
    @MainActor
    private func placeCursorAtEndOfHeading(_ helper: EditorTestHelper) async throws {
        let result = try await helper.webView.evaluateJavaScript(
            """
            (() => {
                const pm = document.querySelector('.ProseMirror');
                if (!pm) return 'no-prosemirror-root';
                const heading = pm.querySelector('h1');
                if (!heading) return 'no-heading';
                pm.focus();
                const range = document.createRange();
                range.selectNodeContents(heading);
                range.collapse(false);
                const sel = window.getSelection();
                sel.removeAllRanges();
                sel.addRange(range);
                return 'ok';
            })()
            """
        ) as? String
        XCTAssertEqual(result, "ok", "failed to place cursor at end of heading (diagnostic: \(String(describing: result)))")
    }

    /// Real Return keypress (keyCode 36) via NSEvent — splits off a new paragraph.
    /// Same technique as CAYWConcurrentInsertTests.swift's pressEnter.
    @MainActor
    private func pressEnter(window: NSWindow) throws {
        let now = ProcessInfo.processInfo.systemUptime
        guard
            let down = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: now, windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36
            ),
            let keyUp = NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: [],
                timestamp: now, windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36
            )
        else {
            throw NSError(domain: "quit-flush-duplicate-test", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not build Enter NSEvent"])
        }
        window.sendEvent(down)
        window.sendEvent(keyUp)
    }

    /// Real keyDown/keyUp NSEvent pair per character — execCommand does not
    /// replicate real keyboard input in this app's editors (project rule; see
    /// CAYWConcurrentInsertTests.swift's typeViaNSEvents).
    @MainActor
    private func typeViaNSEvents(_ text: String, window: NSWindow) throws {
        for character in text {
            let charString = String(character)
            let now = ProcessInfo.processInfo.systemUptime
            guard
                let down = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: now, windowNumber: window.windowNumber, context: nil,
                    characters: charString, charactersIgnoringModifiers: charString,
                    isARepeat: false, keyCode: 0
                ),
                let keyUp = NSEvent.keyEvent(
                    with: .keyUp, location: .zero, modifierFlags: [],
                    timestamp: now, windowNumber: window.windowNumber, context: nil,
                    characters: charString, charactersIgnoringModifiers: charString,
                    isARepeat: false, keyCode: 0
                )
            else {
                throw NSError(
                    domain: "quit-flush-duplicate-test", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "could not build NSEvent for '\(charString)'"]
                )
            }
            window.sendEvent(down)
            window.sendEvent(keyUp)
        }
    }

    /// Harness for test 3: needs a real `ContentView` instance, not just a bare
    /// `EditorViewState`/`BlockSyncService` pair, because the mechanism under test --
    /// `ContentView.handleNotesSectionChanged()` -- lives on `ContentView`. A bare,
    /// never-rendered `ContentView()` with its services wired by hand (mirroring the
    /// private `configureSyncServices()` this file can't call directly) is sufficient,
    /// the same way `ProjectSwitchStaleContentPushTests.makeContentViewFixture` and
    /// `BibliographySectionFlagTests+DataIntegrity.swift`'s
    /// `handleBibliographySectionChangedSyncsSectionTableImmediately` already rely on:
    /// its unused `@Environment` properties are never read by the handler under test.
    private struct ContentViewStack {
        let helper: EditorTestHelper
        let db: ProjectDatabase
        let pid: String
        let view: ContentView
    }

    @MainActor
    private func makeContentViewStack() async throws -> ContentViewStack {
        let db = try TestFixtureFactory.createTemporary(content: Self.doc)
        let pid = try TestFixtureFactory.getProjectId(from: db)
        let helper = EditorTestHelper(editorType: .milkdown)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = helper.webView
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(helper.webView)
        hostWindow = window

        try await helper.loadAndWaitForReady(timeout: 15)

        // Same rAF shim as makeStack() -- see that function's comment.
        _ = try await helper.webView.evaluateJavaScript(
            "window.requestAnimationFrame = (cb) => setTimeout(() => cb(performance.now()), 16); true"
        )

        let view = ContentView()
        // Mirrors ContentView+ProjectLifecycle.swift's private configureSyncServices():
        // the same BlockSyncService instance must back both flushForQuit()'s
        // drain/fetch calls and handleNotesSectionChanged()'s forced rebuild poll, so
        // the forced poll sees the pending insert flushForQuit() itself never consumed.
        view.blockSyncService.configure(database: db, projectId: pid, webView: helper.webView)
        view.editorState.blockSyncService = view.blockSyncService
        view.blockSyncService.editorState = view.editorState
        view.editorState.projectDatabase = db
        view.editorState.currentProjectId = pid
        view.footnoteSyncService.configure(database: db, projectId: pid)
        view.editorState.footnoteSyncService = view.footnoteSyncService

        let blocks = try TestFixtureFactory.fetchBlocks(from: db).sorted { $0.sortOrder < $1.sortOrder }
        let ids = BlockParser.idsForProseMirrorAlignment(blocks)
        let content = BlockParser.assembleMarkdown(from: blocks)
        await view.blockSyncService.setContentWithBlockIds(markdown: content, blockIds: ids)
        try await Task.sleep(nanoseconds: 500_000_000)
        view.editorState.content = content

        return ContentViewStack(helper: helper, db: db, pid: pid, view: view)
    }
}
