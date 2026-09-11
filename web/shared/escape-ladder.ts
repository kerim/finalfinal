/**
 * Esc-key layer-order policy (UX contract §6): "where you're typing wins" first -- a single
 * bubble-phase `document` keydown listener is the ONE owner of Escape dismissal inside the
 * editor. It runs after every element-level popup handler (citation/math/link/annotation edit
 * popups, the CodeMirror image-caption popup) has already had its chance during the normal
 * bubble path up from the focused element -- those already call `preventDefault()` EARLIER,
 * before this listener runs, when they self-dismiss on Escape, which this listener reads via
 * `e.defaultPrevented` rather than re-implementing their dismissal here.
 *
 * `dismissTopLayer` (supplied per-editor by `milkdown/src/main.ts` / `codemirror/src/main.ts`)
 * is the ordered fallback for anything that does NOT already flow through `defaultPrevented` --
 * chiefly the slash-command menu, whose OLD Escape handling lived in a document-level CAPTURE
 * listener that called `stopPropagation()` (see each editor's slash-menu module), which would
 * otherwise stop this bubble-phase listener from ever seeing the event at all. That capture-
 * phase Escape branch has been removed; the slash menu is now dismissed from
 * `dismissTopLayer` instead, as the first, innermost check.
 *
 * This listener ALSO calls `preventDefault()` itself, unconditionally, the moment it starts
 * handling a non-composing Escape (t-784ff3aa fix round) -- see `handleEscapeKeydown`'s own
 * comment at that call for why: stopping WebKit's own default Escape handling (which otherwise
 * runs independently of, and can disagree with, whatever this listener and its popups decide)
 * is now this listener's job, not something left to "the web layer never calls
 * preventDefault()" as this file used to say. An element-level popup calling it first (above)
 * just makes this listener's own later call a no-op for that keypress.
 *
 * Native report to Swift (`escapeLadder`/`escapeComposition` WKScriptMessageHandlers,
 * EscapeLadder.swift): no generation number is threaded through here. Swift correlates a
 * report to its own single outstanding "pending escape" slot rather than an echoed id -- see
 * `EscapeLadderContext.resolvePendingEscape()`'s doc comment for the reasoning and its
 * accepted, narrow trade-off.
 */

interface FinalFinalWebkit {
  webkit?: {
    messageHandlers?: {
      escapeLadder?: { postMessage: (body: { handled: boolean }) => void };
      escapeComposition?: { postMessage: (body: { composing: boolean }) => void };
      escapeWebPopupOpen?: { postMessage: (body: { open: boolean }) => void };
    };
  };
}

function bridge(): FinalFinalWebkit {
  return window as unknown as FinalFinalWebkit;
}

/**
 * Reports whether SOMETHING in the web layer handled this Escape. Exported (not just used
 * internally) because `image-plugin.ts`'s caption editor calls `stopPropagation()` on every
 * key, including Escape, so it can never reach this module's own bubble-phase listener --
 * it must report directly after handling Escape itself.
 */
export function postEscapeLadder(handled: boolean): void {
  bridge().webkit?.messageHandlers?.escapeLadder?.postMessage({ handled });
}

/** Independent IME-composition signal Swift's `ctx.isComposing` guard reads -- see this
 * module's own top-of-file doc comment and `EscapeLadderContext.isComposing`. */
export function postEscapeComposition(composing: boolean): void {
  bridge().webkit?.messageHandlers?.escapeComposition?.postMessage({ composing });
}

/**
 * Independent "is a web-owned popup/menu currently open" signal (t-784ff3aa fix round) --
 * pushed to Swift's `EscapeLadderContext.webPopupOpen` the INSTANT any such popup opens or
 * closes, decoupled from any particular Escape keypress. Mirrors `postEscapeComposition`'s
 * shape exactly, and exists to close the same class of race `isComposing` already closes for
 * IME: before this signal existed, Swift could only learn whether the web layer would handle
 * an Escape by racing a fixed-deadline watchdog against the web side's own `escapeLadder`
 * report (see `postEscapeLadder`), which is a timing race by construction -- a large enough
 * document's block-sync serialization pass can delay that report past any fixed deadline,
 * however generous. Because this signal is pushed the moment a popup opens (well before any
 * Escape keypress, let alone the report that follows one), Swift already has the answer with
 * zero round trip by the time Escape-keydown reaches `AppDelegate.handleEscapeCandidate` --
 * see `EscapeLadderContext.webPopupOpen`'s doc comment on the Swift side.
 */
export function postEscapeWebPopupOpen(open: boolean): void {
  bridge().webkit?.messageHandlers?.escapeWebPopupOpen?.postMessage({ open });
}

/** An editor's own aggregate "is ANY web-owned popup/menu open" check -- the same OR of
 * predicates its own `dismissTopLayer` checks (`isSlashMenuOpen() || isCitationEditPopupOpen()
 * || ...`), without the dismiss side effects. */
export type WebPopupOpenCheck = () => boolean;

let webPopupOpenCheck: WebPopupOpenCheck | null = null;

/**
 * Registers the current editor's aggregate popup-open check (call once from each editor's
 * main.ts, alongside `installEscapeLadder`). Kept here, in this shared leaf module, rather than
 * imported directly from main.ts by every popup module below -- main.ts already imports every
 * popup module to build its own `dismissTopLayer`, so a popup module importing a function back
 * out of main.ts would create a circular dependency between them. Routing the registration
 * through this shared module (which nothing else depends on) keeps the dependency direction
 * one-way: popup modules -> this module <- main.ts.
 */
export function registerWebPopupOpenCheck(check: WebPopupOpenCheck): void {
  webPopupOpenCheck = check;
}

/**
 * Recomputes "is any web-owned popup open" via the registered check and pushes the result to
 * Swift. Call at every point where a popup/menu's open/closed state might have changed -- each
 * popup module's own show/cancel/dismiss functions, and slash-commands.ts's several
 * `filteredCommands` reassignment sites (see each call site's own comment). Safe to call before
 * `registerWebPopupOpenCheck` has run (reports `false`) -- shouldn't happen in practice, since
 * main.ts registers its check before any popup can open, but a defensive default costs nothing.
 */
export function recomputeAndPushWebPopupState(): void {
  postEscapeWebPopupOpen(webPopupOpenCheck?.() ?? false);
}

/**
 * Test-only artificial delay (milliseconds), applied to this module's own Escape-report path
 * below (the gap between an Escape keydown and this module calling `dismissTopLayer()`/
 * `postEscapeLadder(...)`) -- exists ONLY to prove the t-784ff3aa fix is genuinely
 * timing-independent, not to change any production behavior (default 0, a no-op). With this
 * set large enough to defeat any plausible fixed watchdog value, the slash menu must still
 * close correctly and Focus Mode/the find bar must stay untouched throughout, because Swift's
 * `ctx.webPopupOpen` (pushed synchronously at popup-open time, well before this delay ever
 * starts) already told it nothing native should run for this keypress -- it never had to wait
 * on anything this module does. Set via `setTestEscapeReportDelayMs`, called from Swift only
 * when `TestMode.isUITesting` (see `MilkdownCoordinator.performBatchInitialize`) -- this
 * project's existing pattern for test-only behavior switches, e.g.
 * `FF_UI_TESTING_FORCE_DIAGNOSTIC_LOGGING`.
 */
let testEscapeReportDelayMs = 0;

/** Test-only hook for `testEscapeReportDelayMs` above -- exported for
 * `window.FinalFinal.__testSetEscapeReportDelayMs` in each editor's main.ts. Never called in
 * production. */
export function setTestEscapeReportDelayMs(ms: number): void {
  testEscapeReportDelayMs = ms;
}

/** Ordered "close the innermost open thing" check, supplied by each editor's main.ts. Returns
 * true if it dismissed something, false if there was nothing open to dismiss. */
export type DismissTopLayer = () => boolean;

function handleEscapeKeydown(e: KeyboardEvent, dismissTopLayer: DismissTopLayer): void {
  if (e.key !== 'Escape') return;
  // Composition owns this key while it's live -- say nothing here at all; Swift's isComposing
  // guard (fed by the compositionstart/compositionend listeners below) is the source of truth
  // for whether Escape should be intercepted natively, independent of what happens to this
  // specific keydown (some IMEs never even dispatch it to the document).
  if (e.isComposing || e.keyCode === 229) return;
  // Snapshot BEFORE this listener calls its own preventDefault() below -- `Event.preventDefault()`
  // sets the DOM's "canceled flag" synchronously and unconditionally (per spec), so
  // `e.defaultPrevented` itself would read `true` from that point on regardless of whether an
  // earlier element-level handler (citation/math/link/annotation edit, image caption) had
  // already called it. This snapshot is the only way to still tell "someone dismissed themselves
  // upstream, before this listener ran" apart from "this listener is the one calling it" once
  // both facts are true on the same event object.
  const wasAlreadyPreventedUpstream = e.defaultPrevented;
  // Unconditional preventDefault() (t-784ff3aa fix round, root-caused via a captured diagnostic
  // stack trace): this shared listener is now the ONE thing that decides whether WebKit's own
  // default Escape handling ever runs. Left unhandled at the DOM level, WebKit resolves Escape
  // through the standard macOS key-binding table (`cancelOperation:`) and forwards THAT,
  // synchronously and independently of anything this listener does, straight to the native side
  // (WKWebView -> WebPageProxy::executeSavedCommandBySelector -> the responder chain ->
  // AppKitWindow.exitFullScreenMode) -- a completely different channel from this listener's own
  // `postEscapeLadder`/`dismissTopLayer` reporting. Before this call existed, a single Escape
  // keypress could produce TWO independent actions: this listener correctly closing (say) the
  // slash menu, AND WebKit's own default handling independently telling SwiftUI to exit Focus
  // Mode's native full screen -- confirmed live via a captured stack trace showing exactly that
  // chain. Placed here -- before the repeat guard, the `wasAlreadyPreventedUpstream` branch, and
  // the delay-testing branch below, i.e. unconditionally and synchronously on the original event
  // dispatch -- because by the time any of those later branches run (especially the `setTimeout`
  // in the delay-testing branch), WebKit's own default handling has ALREADY run on this same
  // synchronous dispatch; calling preventDefault() after that point is too late to stop it.
  // Calling it when `e.defaultPrevented` is already true (an element-level popup handler already
  // called it before this listener ran) is a harmless no-op, so doing this unconditionally, ahead
  // of all branching, is safe regardless of which branch runs afterward.
  e.preventDefault();
  // Auto-repeat guard: a held Escape (or a synthesized repeat under load) fires this listener
  // once per repeat, not once per physical keypress. Posting nothing here means a repeated
  // keydown can't resolve Swift's single outstanding "pending escape" watchdog slot for a
  // DIFFERENT press than the one that armed it (EscapeLadderContext.resolvePendingEscape()),
  // and can't ask dismissTopLayer to dismiss a second layer off one held key.
  if (e.repeat) return;

  if (wasAlreadyPreventedUpstream) {
    // An element-level popup handler (citation/math/link/annotation edit, image caption)
    // already dismissed itself and called preventDefault(), before this listener ran -- nothing
    // left for dismissTopLayer to do.
    //
    // No diagnostic log here on purpose (must-fix, acceptance review of t-784ff3aa): this
    // used to be an unconditional console.log firing on every Escape keypress, unlike the
    // Swift side's own Esc diagnostics (AppDelegate.swift, EscapeLadder.swift), which are
    // deliberately gated behind DebugLog's `.escape` category and excluded from
    // `DebugLog.enabled` so they stay silent in normal development use. This module's only
    // existing bridge to Swift's DebugLog (the `errorHandler` message handler, `type:
    // 'debug'`, as used by table-tools-plugin.ts/spellcheck-plugin.ts) routes to the
    // `.editor` category, which IS enabled by default -- reusing it here would not match
    // the Swift side's off-by-default behavior, so the lines are removed rather than routed
    // through a bridge that doesn't actually achieve parity. `postEscapeLadder`/
    // `postEscapeComposition` below remain unchanged -- those are the real IPC to Swift, not
    // diagnostic logging.
    postEscapeLadder(true);
    return;
  }
  // Test-only hang simulation (see `testEscapeReportDelayMs`'s doc comment) -- zero (the
  // production default) makes this branch dead code, identical to the unconditional call
  // below. A non-zero value delays BOTH the actual dismissal and the report to Swift by that
  // many ms, standing in for a genuinely slow web-layer round trip without depending on real
  // main-thread contention to reproduce one.
  if (testEscapeReportDelayMs > 0) {
    setTimeout(() => {
      const dismissed = dismissTopLayer();
      postEscapeLadder(dismissed);
    }, testEscapeReportDelayMs);
    return;
  }
  const dismissed = dismissTopLayer();
  postEscapeLadder(dismissed);
}

/** Installs the one bubble-phase Escape owner plus the IME composition signal. Call once from
 * each editor's main.ts, after that editor's own `dismissTopLayer` is ready to call. Returns a
 * dispose function (removes all three listeners) -- unused in production, where the editor's
 * document lives for the page's whole lifetime, but lets tests install a fresh instance per
 * case without leaking listeners into the next test. */
export function installEscapeLadder(dismissTopLayer: DismissTopLayer): () => void {
  const onKeydown = (e: KeyboardEvent) => handleEscapeKeydown(e, dismissTopLayer);
  const onCompositionStart = () => postEscapeComposition(true);
  const onCompositionEnd = () => postEscapeComposition(false);

  document.addEventListener('keydown', onKeydown);
  document.addEventListener('compositionstart', onCompositionStart);
  document.addEventListener('compositionend', onCompositionEnd);

  return () => {
    document.removeEventListener('keydown', onKeydown);
    document.removeEventListener('compositionstart', onCompositionStart);
    document.removeEventListener('compositionend', onCompositionEnd);
  };
}
