//
//  EscapeLadder.swift
//  final final
//
//  Esc-key layer-order policy (UX contract §6): "where you're typing wins" first (a focused
//  web editor, via WebKit's own layer stack, always gets first refusal on Esc), then a fixed
//  native ladder -- find bar, then the most-recently-opened annotation edit, then Focus Mode.
//  See `AppDelegate.setupEscapeKeyMonitor` for the NSEvent monitor that drives this, and
//  `EscapeLadderHost`/`EscapeLadderRegistry` for how a window's live state reaches it.
//

import AppKit
import Foundation
import WebKit

/// One rung of the Esc ladder, in innermost-first order. `.webOwned` is not itself "applied"
/// by Swift -- it means the keydown is left unconsumed for WebKit to handle. Swift only ever
/// decides `.webOwned` when it already knows, synchronously and in advance (`ctx.webPopupOpen`
/// -- see EscapeLadderContext), that a web-owned popup is open; a long last-resort watchdog
/// (see `EscapeLadderContext.armEscapeWatchdog`) guards only against a genuinely stuck web
/// layer that never reports back at all, not against ordinary reporting latency.
enum EscapeRung: Equatable {
    case webOwned
    case findBar
    case annotationEdit(id: String)
    case focusMode
    case none
}

/// Immutable snapshot of everything `decide`/`decideAfterWebDeclined` need to pick a rung.
/// Built fresh from live state each time Esc is pressed -- never cached, so it can never go
/// stale between keystrokes.
struct EscapeLadderSnapshot {
    var focusInWebView: Bool
    /// True the instant a web-owned popup/menu (slash menu, citation/math/link/annotation-edit
    /// popup, spellcheck menu/popover) is open in the focused web editor -- pushed
    /// synchronously by the web layer's `escapeWebPopupOpen` message the moment it opens OR
    /// closes, independent of any particular Escape keypress (t-784ff3aa fix round; mirrors
    /// `isComposing`'s shape). Consumed by `decide`: `focusInWebView` alone no longer implies
    /// `.webOwned` -- only a genuinely open popup does. Defaulted to `false` so every existing
    /// call site/test that predates this field keeps compiling unchanged.
    var webPopupOpen: Bool = false
    var findBarVisible: Bool
    /// True while a find-bar text field (search or replace) has genuine native keyboard focus
    /// right now -- distinct from `findBarVisible`, which is true whenever the bar is merely
    /// showing. Consumed by `decideAfterWebDeclined` to implement "where you're typing wins"
    /// for the find bar specifically (UX contract §6): a genuinely focused field wins over a
    /// merely-open annotation edit, ahead of the fixed find-bar-then-annotation-then-focus-mode
    /// ladder below it.
    var findBarFieldFocused: Bool
    var annotationEditIds: [String]
    /// The id of the annotation-card edit field that currently has genuine native keyboard
    /// focus, if any -- distinct from `annotationEditIds`, which lists every card merely in
    /// edit mode (open, not necessarily focused). Consumed by `decideAfterWebDeclined` to
    /// implement "where you're typing wins" for annotation cards (UX contract §6): a focused
    /// card wins over a merely-open find bar, ahead of the fixed ladder below it.
    var focusedAnnotationEditId: String?
    var focusModeEnabled: Bool
}

/// Pure decision functions -- no AppKit, fully unit-testable (see `EscapeLadderTests`).
enum EscapeLadder {
    /// Identity of a physical NSEvent keydown, used to detect WebKit's `doneWithKeyEvent` resend
    /// of an unhandled Escape (see `shouldConsiderCandidate`'s doc comment). `timestamp` is
    /// identical on the resent NSEvent because it's the same physical event object round-tripped
    /// through WebKit, not a freshly synthesized one -- this is what distinguishes a resend from
    /// a genuinely new, separate physical keypress (which will have a different `timestamp`).
    struct EscapeEventStamp: Equatable {
        var timestamp: TimeInterval
        var windowNumber: Int
    }

    /// Auto-repeat guard (UX contract §6, "one press, one layer"): the old `.keyboardShortcut(
    /// .escape)` key-equivalents this NSEvent monitor replaced were never invoked by AppKit on
    /// auto-repeat, but the monitor IS -- so a held Esc (or a synthesized repeat under VM load)
    /// must be rejected before it ever reaches `decide`/`decideAfterWebDeclined`, or a single
    /// physical keypress could apply two or more ladder rungs (e.g. closing the find bar AND
    /// exiting Focus Mode) off repeats of what the user experienced as one press.
    ///
    /// One physical Escape can still reach the monitor twice in one narrow case (t-784ff3aa fix
    /// round): the web layer's shared bubble-phase listener (`web/shared/escape-ladder.ts`) now
    /// calls `preventDefault()` itself, unconditionally, the instant it starts handling a
    /// non-composing Escape -- which is what stops WebKit's own default handling from running at
    /// all, and with it, stops WebKit's resend of the same NSEvent through [NSApp sendEvent:] for
    /// every case that reaches that call. The one case that still skips it entirely is IME
    /// composition (that listener returns immediately, before touching `preventDefault()`,
    /// because some IMEs need the raw, unconsumed keydown) -- so a composing Escape can still come
    /// back through WebKit's own unhandled-key resend, re-running every local monitor.
    /// isARepeat is false on a resend, so it does not cover this -- hence the additional
    /// `stamp`/`lastStamp` comparison below, which catches it by physical event identity instead
    /// and is kept as general protection regardless of which case produced the resend.
    ///
    /// (Before the t-784ff3aa preventDefault() fix, this doc comment described a much broader
    /// version of the same resend: the web layer never called `preventDefault()` on Escape AT
    /// ALL, by design, so every non-composing Escape could double-fire this monitor too, not just
    /// a composing one. That was the actual root cause of a real bug -- Escape closing the
    /// slash-command menu AND independently exiting Focus Mode's native full screen off one
    /// keypress, confirmed via a captured diagnostic stack trace -- fixed by making the web layer
    /// call `preventDefault()` itself; see `escape-ladder.ts`'s own doc comment for the full
    /// mechanism.)
    ///
    /// Pure boolean check, factored out of `AppDelegate.handleEscapeCandidate` (its sole call
    /// site) purely for unit-testability -- see `EscapeLadderTests`.
    static func shouldConsiderCandidate(
        isRepeat: Bool,
        stamp: EscapeEventStamp,
        lastStamp: EscapeEventStamp?
    ) -> Bool {
        guard !isRepeat else { return false }
        return stamp != lastStamp
    }

    /// Full ladder, including the "where you're typing wins" web-focus check.
    ///
    /// `focusInWebView` alone is no longer sufficient for `.webOwned` (t-784ff3aa fix round):
    /// focus merely means the web layer WOULD get first refusal if something were open there,
    /// but if `webPopupOpen` is false, Swift already knows -- synchronously, pushed the instant
    /// it became false, not inferred from an Escape-time report -- that nothing web-owned is
    /// open to refuse, so this falls straight through to the fixed native ladder instead of
    /// returning `.webOwned` for a keypress the web layer would just no-op on. Production's
    /// real branch point for this decision is `AppDelegate.handleEscapeCandidate`'s
    /// `isWebFocused` branch, not this function -- see that method's doc comment for why (it
    /// needs to decide whether to consume the event at all, which this pure function has no
    /// say over). This function stays correct and unit-testable regardless.
    static func decide(_ snapshot: EscapeLadderSnapshot) -> EscapeRung {
        if snapshot.focusInWebView && snapshot.webPopupOpen {
            return .webOwned
        }
        return decideAfterWebDeclined(snapshot)
    }

    /// The ladder starting at the find bar -- used both when focus is genuinely outside the
    /// web view, AND as the fallback when `webPopupOpen` is false (Swift already knows nothing
    /// web-owned is open, applied immediately -- see `AppDelegate.handleEscapeCandidate`), AND
    /// once in a while as the true last-resort path when a stuck web layer's hang-protection
    /// watchdog fires (see `EscapeLadderContext.armEscapeWatchdog`).
    ///
    /// "Where you're typing wins" (UX contract §6) applies to native surfaces too, not just the
    /// web editor: a genuinely FOCUSED find-bar field or annotation-card field is checked first,
    /// ahead of the fixed find-bar-then-annotation-then-focus-mode ladder that follows. Only one
    /// of the two focus signals can ever be true at once (AppKit gives a window at most one
    /// first responder), so the order between them doesn't matter -- find bar is checked first
    /// only to mirror the fixed ladder's own ordering below.
    static func decideAfterWebDeclined(_ snapshot: EscapeLadderSnapshot) -> EscapeRung {
        if snapshot.findBarFieldFocused {
            return .findBar
        }
        if let focusedAnnotationEditId = snapshot.focusedAnnotationEditId {
            return .annotationEdit(id: focusedAnnotationEditId)
        }
        if snapshot.findBarVisible {
            return .findBar
        }
        if let lastAnnotationEditId = snapshot.annotationEditIds.last {
            return .annotationEdit(id: lastAnnotationEditId)
        }
        if snapshot.focusModeEnabled {
            return .focusMode
        }
        return .none
    }
}

/// Per-window live state the ladder reads from and mutates. One instance lives on
/// `ContentView` (`@State private var escapeLadder = EscapeLadderContext()`) and is registered
/// against its window by `EscapeLadderHost`.
@Observable
@MainActor
final class EscapeLadderContext {
    weak var window: NSWindow?
    weak var activeWebView: WKWebView?
    weak var findBarState: FindBarState?
    weak var editorState: EditorViewState?

    /// True while an IME composition session is live in the web editor (set/cleared by the
    /// `escapeComposition` message, itself driven by the web side's `compositionstart`/
    /// `compositionend` listeners -- see `web/shared/escape-ladder.ts`). MUST be checked before
    /// any ladder/watchdog logic runs: some IMEs swallow the Escape keydown that dismisses
    /// composition before it ever reaches the document, so a report-based signal alone
    /// (silence != composing) can't be trusted here -- this flag is a positive, independently
    /// pushed signal, not an inference from the absence of a report.
    var isComposing = false

    /// True the instant a web-owned popup/menu (slash menu, citation/math/link/annotation-edit
    /// popup, spellcheck menu/popover -- the exact same set each editor's own `dismissTopLayer`
    /// checks) is open in the focused web editor -- set/cleared by the `escapeWebPopupOpen`
    /// message the moment it opens OR closes (t-784ff3aa fix round), itself driven by the web
    /// side's `recomputeAndPushWebPopupState()` calls at every popup's own show/hide site --
    /// see `web/shared/escape-ladder.ts`. Mirrors `isComposing`'s shape exactly: a positive,
    /// independently pushed signal, decoupled from any particular Escape keypress -- NOT
    /// inferred from an Escape-time report. This is what lets `AppDelegate.handleEscapeCandidate`
    /// know, with zero round trip, whether the web layer will handle the next Escape, closing
    /// the timing race the old fixed-deadline watchdog design could never fully close (raising
    /// the deadline only ever moved the goalpost -- see `armEscapeWatchdog`'s doc comment).
    var webPopupOpen = false

    /// Ordered registry of in-progress annotation-card edits, most-recently-registered last
    /// (`registerAnnotationEdit` re-registering an id moves it to the end). LIFO among these is
    /// resolved by `EscapeLadder.decideAfterWebDeclined` reading `.last`.
    private(set) var annotationEditOrder: [String] = []
    private var annotationEditCancels: [String: () -> Void] = [:]

    /// The id of the annotation-card edit field that currently has genuine native keyboard
    /// focus, if any -- set/cleared by `setAnnotationEditFocused` (driven by the card's own
    /// `@FocusState` on its `TextEditor`, see `AnnotationCardView`). Distinct from
    /// `annotationEditOrder`, which tracks every card merely in edit mode (open, not
    /// necessarily focused); this is what lets `EscapeLadder.decideAfterWebDeclined` implement
    /// "where you're typing wins" for annotation cards (UX contract §6).
    private(set) var focusedAnnotationEditId: String?

    /// Mirrors whether a find-bar text field (search or replace) currently has native focus.
    /// Consumed by `EscapeLadder.decide`/`decideAfterWebDeclined` to implement "where you're
    /// typing wins" for the find bar (UX contract §6): a genuinely focused field wins over a
    /// merely-open annotation edit, ahead of find-bar VISIBILITY's own place in the fixed
    /// ladder order.
    private(set) var findBarFieldFocused = false

    // MARK: - Escape watchdog (web-declined fallback correlation)

    /// Single-slot pending-escape token: at most one watchdog is ever outstanding per context.
    /// Arming a new one immediately cancels whatever was previously pending, so a second fast
    /// Escape can never let an earlier press's stale fallback fire after the fact. A JS report
    /// (`escapeLadder` message) that arrives while a watchdog is pending resolves it directly,
    /// without needing an echoed generation number from the web side -- see
    /// `resolvePendingEscape()`'s doc comment for the reasoning and its accepted trade-off.
    private var pendingEscapeGeneration: UInt64?
    private var nextEscapeGeneration: UInt64 = 0
    private var escapeWatchdogItem: DispatchWorkItem?
    /// When the currently-pending watchdog (if any) was armed -- diagnostic only, read by
    /// `resolvePendingEscape`'s logging to report elapsed time. Not part of the correlation
    /// logic itself.
    private var escapeWatchdogArmedAt: Date?

    init() {}

    // MARK: - Annotation-edit registry

    /// Registers (or re-registers, moving it to the end -- most-recent-wins) an in-progress
    /// annotation-card edit. `cancel` is the card's own real `cancelEdit()` method: the ladder
    /// drives the card out of edit mode by invoking the card's actual state mutation, never an
    /// external flag.
    func registerAnnotationEdit(id: String, cancel: @escaping () -> Void) {
        annotationEditOrder.removeAll { $0 == id }
        annotationEditOrder.append(id)
        annotationEditCancels[id] = cancel
    }

    func unregisterAnnotationEdit(id: String) {
        annotationEditOrder.removeAll { $0 == id }
        annotationEditCancels.removeValue(forKey: id)
        if focusedAnnotationEditId == id {
            focusedAnnotationEditId = nil
        }
    }

    /// Invokes the registered cancel closure for the given annotation edit id, if still
    /// registered. Does not itself unregister -- the card's own `cancelEdit()` is expected to
    /// unregister via `.onChange`/`.onDisappear`, same as a user-initiated cancel would.
    func cancelAnnotationEdit(id: String) {
        annotationEditCancels[id]?()
    }

    // MARK: - Annotation-card field focus

    /// Mirrors whether the annotation-card edit field for `id` currently has genuine native
    /// keyboard focus. Called from `AnnotationCardView`'s `.onChange(of: isTextEditorFocused)`.
    /// A `false` report only clears `focusedAnnotationEditId` when it still names THIS id --
    /// guards against an out-of-order report (e.g. the old card's focus-lost report arriving
    /// after a new card has already reported focus-gained) clobbering a newer focus.
    func setAnnotationEditFocused(id: String, focused: Bool) {
        if focused {
            focusedAnnotationEditId = id
        } else if focusedAnnotationEditId == id {
            focusedAnnotationEditId = nil
        }
    }

    // MARK: - Find-bar field focus

    func setFindBarFieldFocused(_ focused: Bool) {
        findBarFieldFocused = focused
    }

    func clearFindBarFocus() {
        findBarFieldFocused = false
    }

    // MARK: - Escape watchdog

    /// Default deadline for `armEscapeWatchdog` -- deliberately generous (seconds, not
    /// milliseconds) because, since t-784ff3aa's fix round, this watchdog is no longer the
    /// correctness mechanism for the web-owned rung; it is purely a last-resort hang-protection
    /// net. See `armEscapeWatchdog`'s doc comment for the full history and reasoning.
    ///
    /// `nonisolated`: a plain `Sendable` constant, safe from any context -- needed because a
    /// default-argument expression is evaluated as if written by the caller, not the callee, so
    /// referencing a `@MainActor`-isolated static property here would be a Swift 6 error despite
    /// `armEscapeWatchdog` itself being an instance method of this `@MainActor` class.
    nonisolated static let hangProtectionWatchdogDelay: TimeInterval = 5.0

    /// Arms a LAST-RESORT hang-protection fallback -- NOT the correctness mechanism for the
    /// web-owned rung. Correctness now comes entirely from `webPopupOpen` above, pushed
    /// synchronously by the web layer the instant a popup opens or closes, independent of any
    /// particular Escape keypress: by the time an Escape keydown reaches
    /// `AppDelegate.handleEscapeCandidate`, Swift already knows for certain whether the web
    /// layer will handle it, with zero round trip -- see that method's `isWebFocused` branch.
    /// This watchdog only still exists to protect against a genuinely stuck web layer (e.g. a
    /// hung JS thread) that reported `webPopupOpen = true` and then never recovers to report
    /// anything else, ever -- an already-pathological case, not the happy path this used to
    /// race against. Cancels any previously-armed watchdog first, so at most one is ever
    /// outstanding. `delay` defaults to `hangProtectionWatchdogDelay`; overridable only for
    /// tests that need to observe a firing without waiting out the real production deadline.
    ///
    /// HISTORY (do not re-derive): an earlier version of this file used this same watchdog as
    /// the actual correctness mechanism -- Swift guessed natively whenever the web side's own
    /// `escapeLadder` report didn't arrive within a fixed deadline (first 150ms, then 1000ms,
    /// both t-784ff3aa). That was a timing race by construction: raising the deadline only ever
    /// moved the goalpost, since ANY document large enough to make the web layer's block-sync
    /// serialization pass slower than whatever number was chosen would still reproduce the same
    /// bug (confirmed live: Esc inside the slash menu closed Focus Mode instead, destroying the
    /// slash menu as a side effect). The `webPopupOpen` signal above removes the race entirely
    /// by not depending on Escape-time timing at all -- see `EscapeLadderE2ETests.swift`'s
    /// timing-independence proof test for how this is verified without relying on a
    /// coincidentally-fast round trip the way the old regression test unwittingly did.
    func armEscapeWatchdog(delay: TimeInterval = hangProtectionWatchdogDelay, fallback: @escaping () -> Void) {
        escapeWatchdogItem?.cancel()
        let generation = nextEscapeGeneration
        nextEscapeGeneration += 1
        pendingEscapeGeneration = generation
        escapeWatchdogArmedAt = Date()
        DebugLog.log(.escape, "[EscapeWatchdog] armed generation=\(generation)")
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.pendingEscapeGeneration == generation else { return }
            self.pendingEscapeGeneration = nil
            self.escapeWatchdogItem = nil
            DebugLog.log(.escape, "[EscapeWatchdog] fired generation=\(generation)")
            fallback()
        }
        escapeWatchdogItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Resolves (and cancels) whatever escape watchdog is currently pending, if any. Called by
    /// the `escapeLadder` message handler when a web-side report arrives.
    ///
    /// Correlation design note: this does NOT match against an echoed generation number from
    /// JS -- it resolves whichever single watchdog is currently outstanding. This is safe
    /// against the primary race (two fast Escapes) because `armEscapeWatchdog` cancels any
    /// prior watchdog the instant a new Escape is armed, so a stale watchdog can never fire
    /// after a newer press superseded it. The one residual, deliberately accepted risk: if a
    /// SECOND Escape is armed before the FIRST press's own web report has finished its round
    /// trip, that late report would resolve the second press's slot instead. `handleEscapeLadderMessage`
    /// runs synchronously in the WKScriptMessageHandler callback (via `MainActor.assumeIsolated`
    /// at each editor's `+MessageDispatch.swift` call site -- no `Task { @MainActor in }` hop, by
    /// this project's design mandate for that path), so the round trip is just the JS-to-native
    /// message dispatch latency itself, not that PLUS queuing behind whatever else happened to be
    /// running on the main actor. That's still not sub-millisecond in practice (WKScriptMessage
    /// delivery crosses a process/IPC-adjacent boundary), so the residual risk below is still
    /// real, just narrower than it would be with an added queuing delay. The accepted trade-off
    /// is real, not theoretical: a fast second
    /// Escape can resolve the wrong slot. What keeps it harmless is that BOTH presses are
    /// heading for the same rung of the ladder in the overwhelmingly common case (the same
    /// surface is still open/focused a beat later), so resolving the "wrong" slot still applies
    /// the same fallback action the correct slot would have -- a full generation-echo protocol
    /// would close this gap but was judged not worth the added complexity for a mismatch this
    /// narrow in consequence.
    @discardableResult
    func resolvePendingEscape() -> Bool {
        let generation = pendingEscapeGeneration
        let elapsedMs = escapeWatchdogArmedAt.map { Date().timeIntervalSince($0) * 1000 }
        guard pendingEscapeGeneration != nil else {
            DebugLog.log(.escape, "[EscapeWatchdog] resolvePendingEscape generation=none resolved=false")
            return false
        }
        DebugLog.log(.escape, "[EscapeWatchdog] resolvePendingEscape generation=\(String(describing: generation)) resolved=true elapsedMs=\(String(describing: elapsedMs))")
        pendingEscapeGeneration = nil
        escapeWatchdogItem?.cancel()
        escapeWatchdogItem = nil
        return true
    }
}

/// Esc-ladder bridge (UX contract §6) -- see `EscapeLadder.decide`/`decideAfterWebDeclined` for
/// the policy this drives. Routes by `message.webView` identity (never a singleton), mirroring
/// `routeStructuralRequest`'s webview-identity pattern in `StructuralUndoController.swift`. A
/// free function, not a per-editor extension method: `MilkdownEditor.Coordinator` and
/// `CodeMirrorEditor.Coordinator` both need byte-identical dispatch here and neither
/// implementation ever touches `self` -- shared here instead of duplicated across
/// `MilkdownCoordinator+MessageDispatch.swift` and `CodeMirrorCoordinator+MessageDispatch.swift`,
/// each of which calls this unqualified (same pattern as their existing unqualified calls to
/// `routeStructuralRequest`).
///
/// Runs synchronously, with no `Task { @MainActor in }` hop -- both call sites already invoke
/// this via `MainActor.assumeIsolated` from their `nonisolated` `userContentController(_:didReceive:)`
/// delegate method, which is this project's design mandate for this path (see
/// `resolvePendingEscape()`'s doc comment for why the round-trip latency this removes matters).
@MainActor
func handleEscapeLadderMessage(_ message: WKScriptMessage) -> Bool {
    switch message.name {
    case "escapeLadder":
        guard let body = message.body as? [String: Any], let handled = body["handled"] as? Bool else { return true }
        // This is the ONE point where the web layer's own Escape report reaches Swift -- for a
        // popup dismissed via `dismissTopLayer()`, that report can be delayed arbitrarily (e.g.
        // a slow block-sync pass, or the test-only `setTestEscapeReportDelayMs` hook) relative to
        // the original keydown. Logging its arrival here, unconditionally, is what
        // `EscapeLadderE2ETests.testEscClosesSlashMenuCorrectlyEvenWithAnArtificiallyHugeWebLayerReportDelay`
        // asserts on directly to prove the delayed report actually ran, rather than re-scanning
        // the accessibility tree for the menu's visible text.
        DebugLog.log(.escape, "[Escape] escapeLadder report handled=\(handled)")
        guard let ctx = EscapeLadderRegistry.shared.context(forWebView: message.webView) else { return true }
        guard ctx.resolvePendingEscape(), !handled else { return true }
        // REVERTED (2026-09-10): a prior round of this task wrapped this call in
        // `Task { @MainActor in }`, reasoning by analogy from FullScreenManager.swift's own
        // "deferred hop" comment (which exists to avoid re-entering `toggleFullScreen` from
        // *inside AppKit's own full-screen did*-notification dispatch* -- a narrow, specific
        // hazard). A WKScriptMessageHandler callback is not that dispatch context, and the
        // analogy doesn't hold. The Task hop instead reintroduced the exact bug already fixed
        // and documented in the wiki (`fix-focus-mode-entry-pause-and-fullscreen-wedge.md`,
        // 2026-08-03): `enterFocusMode`/`exitFocusMode` must run synchronously, with no `Task`
        // wrapper, or Focus Mode's panel-hide/full-screen transition visibly desyncs (the
        // sidebar animates on a later, separate beat instead of together with the window).
        // Confirmed live: the user reported exactly that symptom after this hop landed.
        // `FullScreenManager.request(...)` already does its own safe internal deferral where one
        // is genuinely needed (see its own "Deferred hop" comment) -- callers are meant to call
        // it synchronously, not defer around it. Back to a direct, synchronous call.
        AppDelegate.shared?.applyWebDeclinedFallback(ctx)
        return true

    case "escapeComposition":
        guard let body = message.body as? [String: Any], let composing = body["composing"] as? Bool else { return true }
        EscapeLadderRegistry.shared.context(forWebView: message.webView)?.isComposing = composing
        return true

    case "escapeWebPopupOpen":
        // t-784ff3aa fix round: pushed the instant a web-owned popup/menu opens OR closes,
        // independent of any particular Escape keypress -- see `EscapeLadderContext.webPopupOpen`'s
        // doc comment. Mirrors the `escapeComposition` case above exactly.
        guard let body = message.body as? [String: Any], let open = body["open"] as? Bool else { return true }
        EscapeLadderRegistry.shared.context(forWebView: message.webView)?.webPopupOpen = open
        return true

    default:
        return false
    }
}

/// Per-window registry so the single app-wide NSEvent monitor (`AppDelegate`) can find the
/// right `EscapeLadderContext` for whichever window the keydown targeted. Windows come and go
/// (project close/reopen, secondary windows); `context(for:)` and every mutator sweep dead
/// entries (context whose `window` has been deallocated) so the registry never accumulates
/// stale rows.
@MainActor
final class EscapeLadderRegistry {
    static let shared = EscapeLadderRegistry()

    private var entries: [ObjectIdentifier: EscapeLadderContext] = [:]

    private init() {}

    func register(_ context: EscapeLadderContext, for window: NSWindow) {
        context.window = window
        entries[ObjectIdentifier(window)] = context
        sweepDeadEntries()
    }

    func unregister(for window: NSWindow) {
        entries.removeValue(forKey: ObjectIdentifier(window))
        sweepDeadEntries()
    }

    /// Returns the context registered for `window`, or nil if there is none (or `window` is
    /// nil) -- the AppDelegate monitor passes the event through untouched in that case.
    func context(for window: NSWindow?) -> EscapeLadderContext? {
        defer { sweepDeadEntries() }
        guard let window else { return nil }
        return entries[ObjectIdentifier(window)]
    }

    /// Finds the context whose `activeWebView` matches `webView` -- used by the `escapeLadder`/
    /// `escapeComposition` WKScriptMessageHandler dispatch, which only has `message.webView` to
    /// go on (mirrors the existing `structuralUndoRequested` pattern of routing by webview
    /// identity, never a singleton). Linear scan: the registry holds at most one entry per open
    /// window, never a hot path.
    func context(forWebView webView: WKWebView?) -> EscapeLadderContext? {
        defer { sweepDeadEntries() }
        guard let webView else { return nil }
        return entries.values.first { $0.activeWebView === webView }
    }

    /// Drops any entry whose context's own `window` reference has already gone nil (the
    /// context outlived its window, e.g. torn down before `unregister` ran) or whose key no
    /// longer matches a live context -- keeps the registry from accumulating stale rows across
    /// repeated window open/close cycles.
    private func sweepDeadEntries() {
        entries = entries.filter { $0.value.window != nil }
    }
}
