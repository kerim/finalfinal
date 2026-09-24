//
//  AppDelegate+EscapeKeyMonitor.swift
//  final final
//
//  The Esc-key layer ladder (UX contract §6): "where you're typing wins" first, then a fixed
//  native ladder -- find bar, most-recently-opened annotation edit, Focus Mode. Split out of
//  AppDelegate.swift to keep that class body under SwiftLint's type_body_length limit; this is a
//  mechanical move, not a behavior change -- see EscapeLadder.swift for the pure decision logic
//  and EscapeLadderContext/EscapeLadderRegistry for how a window's live state reaches here.
//

import AppKit

extension AppDelegate {
    /// Set up NSEvent local monitor for the Esc-key layer ladder (UX contract §6): "where
    /// you're typing wins" first, then a fixed native ladder -- find bar, most-recently-opened
    /// annotation edit, Focus Mode. See `EscapeLadder.swift` for the pure decision logic and
    /// `EscapeLadderContext`/`EscapeLadderRegistry` for how a window's live state reaches here.
    func setupEscapeKeyMonitor() {
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // NOT `self?.handleEscapeCandidate(event) ?? event`: optional chaining flattens a
            // nil RESULT (a legitimate "consume this event") down to the same `nil` produced
            // when `self` itself is nil, which `?? event` would then wrongly turn back into
            // "pass through" -- collapsing every consumed Esc into a pass-through. Unwrap
            // `self` first so a genuine nil return from `handleEscapeCandidate` stays nil.
            guard let self else { return event }
            return self.handleEscapeCandidate(event)
        }
    }

    /// Body of the Esc monitor, split out for readability. Returns the event to pass it
    /// through untouched, or nil to consume it.
    private func handleEscapeCandidate(_ event: NSEvent) -> NSEvent? {
        // keyCode 53 = Esc. Bail fast on every other key before touching anything else -- and
        // before the ordinal/stamp bookkeeping below, which is scoped to Escape only.
        guard event.keyCode == 53 else { return event }

        escapeEventOrdinal += 1
        let ordinal = escapeEventOrdinal
        DebugLog.log(
            .escape,
            "[Escape#\(ordinal)] keydown timestamp=\(event.timestamp) isARepeat=\(event.isARepeat) windowNumber=\(event.windowNumber)"
        )

        // Auto-repeat guard, now extended with physical-event-identity dedup (see
        // EscapeLadder.shouldConsiderCandidate's doc comment for why both are needed: WebKit
        // re-sends the very same NSEvent through [NSApp sendEvent:] when Escape comes back
        // unhandled from the web layer, which re-runs this monitor a second time for one
        // physical keypress with isARepeat still false). Placed before both the registry lookup
        // and the isComposing check below so it covers the web-focused pass-through branch too.
        // CRITICAL: a rejected duplicate must still pass the event through (`return event`),
        // never consume it -- consuming a resent event breaks the responder chain for anything
        // else listening (Version History's own window-level Escape handling, or any other
        // legitimate native listener).
        let stamp = EscapeLadder.EscapeEventStamp(timestamp: event.timestamp, windowNumber: event.windowNumber)
        guard EscapeLadder.shouldConsiderCandidate(isRepeat: event.isARepeat, stamp: stamp, lastStamp: lastEscapeStamp) else {
            return event
        }
        lastEscapeStamp = stamp

        // No registered window, no registered ladder context, or a stale/recycled registry
        // entry (compared as non-optional references -- not the old nil-equality bug) all
        // pass the event through untouched. This is what keeps Version History, Settings, any
        // sheet, any NSAlert.runModal(), and any native .popover's own transient window fully
        // out of this monitor's reach -- they keep their own existing Esc handling untouched.
        guard let win = event.window,
              let ctx = EscapeLadderRegistry.shared.context(for: win),
              ctx.window === win else {
            return event
        }

        // IME/composition guard (must run before any ladder/watchdog logic): some IMEs swallow
        // the Escape keydown that dismisses composition before it ever reaches the document, so
        // this is a positive signal pushed from the web side (compositionstart/compositionend),
        // never inferred from the absence of a report.
        guard !ctx.isComposing else { return event }

        let isWebFocused = focusIsInWebView(ctx)
        if isWebFocused {
            // t-784ff3aa fix round: `ctx.webPopupOpen` is pushed synchronously by the web layer
            // the instant a popup opens or closes (EscapeLadderContext.webPopupOpen), well
            // before any Escape keypress -- so by this point Swift already knows, with zero
            // round trip, whether the web layer will handle this Escape. Timing at
            // Escape-keydown time can no longer affect which branch runs.
            if ctx.webPopupOpen {
                // A web-owned popup is open right now -- don't consume the event; let WebKit
                // see the key. Arm ONLY a long last-resort hang-protection watchdog (see
                // `armEscapeWatchdog`'s doc comment) for the pathological case where the web
                // layer's JS thread is genuinely stuck and never reports back at all -- this is
                // NOT what makes the common case correct, only a safety net for an already-broken
                // one; correctness comes entirely from `webPopupOpen` having been true here.
                DebugLog.log(.escape, "[Escape#\(ordinal)] focusIsInWebView=true webPopupOpen=true rung=webOwned (arming hang-protection watchdog)")
                ctx.armEscapeWatchdog { [weak self] in
                    self?.applyWebDeclinedFallback(ctx)
                }
                return event
            }
            // No web-owned popup is open right now -- also a synchronously pushed fact, not an
            // inference from an Escape-time report -- so there is nothing to wait for: skip the
            // round trip and the watchdog entirely, and apply the native ladder immediately,
            // consuming the event. Reuses `applyWebDeclinedFallback` (rather than duplicating
            // its snapshot-build-and-apply logic here) so this immediate-apply site and the
            // watchdog-fires/web-declined-report call sites can never drift apart.
            DebugLog.log(.escape, "[Escape#\(ordinal)] focusIsInWebView=true webPopupOpen=false applying native ladder immediately")
            applyWebDeclinedFallback(ctx)
            return nil
        }

        let snapshot = EscapeLadderSnapshot(
            focusInWebView: false,
            findBarVisible: ctx.findBarState?.isVisible ?? false,
            findBarFieldFocused: ctx.findBarFieldFocused,
            annotationEditIds: ctx.annotationEditOrder,
            focusedAnnotationEditId: ctx.focusedAnnotationEditId,
            focusModeEnabled: ctx.editorState?.focusModeEnabled ?? false
        )
        let rung = EscapeLadder.decide(snapshot)
        DebugLog.log(.escape, "[Escape#\(ordinal)] focusIsInWebView=false rung=\(rung)")
        guard rung != .none else { return event }  // Never a "consumed no-op".
        apply(rung, to: ctx)
        return nil
    }

    /// Walks up from the window's first responder looking for `ctx.activeWebView`. Returns
    /// false (not true-by-default) if there's no active web view or the first responder isn't
    /// an NSView -- `firstResponder` is `NSResponder`, not always `NSView`, so the `as? NSView`
    /// guard is load-bearing; do not force-cast it away.
    private func focusIsInWebView(_ ctx: EscapeLadderContext) -> Bool {
        guard let web = ctx.activeWebView, let first = ctx.window?.firstResponder as? NSView else { return false }
        var node: NSView? = first
        while let currentNode = node {
            if currentNode === web { return true }
            node = currentNode.superview
        }
        return false
    }

    /// Applies the native ladder starting at the find bar (skipping `.webOwned`, which no
    /// longer applies). Three call sites, all equally valid, none more "authoritative" than the
    /// others (t-784ff3aa fix round):
    ///   1. `handleEscapeCandidate`'s `isWebFocused` branch, immediately and synchronously, when
    ///      `ctx.webPopupOpen` is false -- the common case now that nothing web-owned needs to
    ///      be waited on. This is the call site that matters day to day.
    ///   2. The `escapeLadder` message handler (`handleEscapeLadderMessage`,
    ///      `EscapeLadder.swift`), when the web side's own report arrives with `handled == false`
    ///      -- the web layer had something open (`webPopupOpen` was true) but declined to act on
    ///      this specific Escape (e.g. `dismissTopLayer` found nothing left to close).
    ///   3. The hang-protection watchdog firing (`armEscapeWatchdog`'s fallback closure) -- only
    ///      reached if the web layer never reports back at all despite `webPopupOpen` being true;
    ///      a last resort for an already-pathological case, not a timing race with (1) or (2).
    /// Not private: called from both editors' `+MessageDispatch.swift` for site 2 above.
    func applyWebDeclinedFallback(_ ctx: EscapeLadderContext) {
        let snapshot = EscapeLadderSnapshot(
            focusInWebView: false,
            findBarVisible: ctx.findBarState?.isVisible ?? false,
            findBarFieldFocused: ctx.findBarFieldFocused,
            annotationEditIds: ctx.annotationEditOrder,
            focusedAnnotationEditId: ctx.focusedAnnotationEditId,
            focusModeEnabled: ctx.editorState?.focusModeEnabled ?? false
        )
        let rung = EscapeLadder.decideAfterWebDeclined(snapshot)
        apply(rung, to: ctx)
    }

    /// Applies a decided rung's native action. `.webOwned` and `.none` are no-ops here --
    /// `.webOwned` is handled by simply not consuming the event (see `handleEscapeCandidate`),
    /// and `.none` never reaches this function (guarded above / never produced meaningfully by
    /// the after-web-declined ladder needing a native action).
    private func apply(_ rung: EscapeRung, to ctx: EscapeLadderContext) {
        DebugLog.log(.escape, "[Escape] apply rung=\(rung)")
        switch rung {
        case .webOwned, .none:
            break
        case .findBar:
            ctx.findBarState?.hide()
        case .annotationEdit(let id):
            ctx.cancelAnnotationEdit(id: id)
        case .focusMode:
            // Synchronous, same reasoning as the previous implementation: this closure already
            // runs on the main actor, and calling directly (not deferring via Task) keeps a
            // rapid next keystroke ordered correctly behind this exit.
            ctx.editorState?.exitFocusMode()
        }
    }

    /// Remove Esc key monitor on termination
    func removeEscapeKeyMonitor() {
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }
    }
}
