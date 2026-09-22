// Typewriter scrolling — keeps the caret's line at a fixed height in the visible
// editor while the user types, with reserved blank space at both ends so the first
// and last lines can reach that height too.
//
// One module owns the arithmetic, the reserve, the glide, the remembered line, the
// cancellation listeners and the one registered scroll host. Each editor bundles its
// own copy (Vite inlines it; `web/shared/` is not a package), so module-level state
// is per-editor and never shared between editors.
//
// Coordinate model
// ----------------
//   contentY = viewportY - scrollerTop + scrollOffset
// One conversion, used by the caret, the first block and the last block alike, so
// their content coordinates are commensurate. `Hc` (the content block height) is the
// difference of the two converted block tops. The reserve, the rest and the scroll
// target all live in that coordinate.
//
// Scroll is absolute. `writeScroll(offset)` is the single setter; nothing accumulates
// a delta across frames. The only arithmetic between two absolutes is the glide's
// interpolation of `start` → `target`, which is bounded and self-correcting.
//
// The reserve:
//   R = max(0, rest - basePadTop, visibleHeight - lineHeight - basePadTop)
// It is a function of the visible height, the base padding and the clamped rest only —
// never of the content height — and the stylesheet `calc` adds it to BOTH ends.
//
// See `.claude/superdev/typewriter-scrolling/plan.md` §2.2 for the derivation and the
// frozen 45-row geometry table (encoded cell-for-cell in
// `shared/__tests__/typewriter-scrolling.test.ts`).

/* ------------------------------------------------------------------ constants */

/** Glide duration for a long move, in milliseconds. */
export const GLIDE_MS = 200;

/** Logical-line delta at or below which a write is instant instead of a glide. */
export const INSTANT_MAX_LINE_DELTA = 1;

/** Inclusive whole-line offset range, mirrored by Swift's own clamp. */
export const LINE_OFFSET_RANGE: readonly [number, number] = [-10, 10];

/** Line-box-independent top padding in force today, in px. */
export const BASE_PAD_TOP = 24;

/** Line-box-independent bottom padding in force today, in px. */
export const BASE_PAD_BOTTOM = 24;

/** The one CSS custom property the reserve is written through. */
export const RESERVE_CSS_VARIABLE = '--typewriter-reserve';

/* -------------------------------------------------------------------- reasons */

/**
 * The trigger reason list. One string per trigger-table row (plan §2.4.1), so no two
 * trigger paths share a label and a test can name the row it is checking.
 *
 * `'unclassified'` is the honest label for a document change the plugin could not
 * name; tests assert it only as a count, never as a named path.
 */
export const TYPEWRITER_REASONS = [
  'input',
  'delete',
  'paste',
  'correction',
  'command',
  'history-undo',
  'history-redo',
  'unclassified',
] as const;

export type TypewriterReason = (typeof TYPEWRITER_REASONS)[number];

/** Per-row exported labels — the public names tests assert against. */
export const REASON_INPUT: TypewriterReason = 'input';
export const REASON_DELETE: TypewriterReason = 'delete';
export const REASON_PASTE: TypewriterReason = 'paste';
export const REASON_CORRECTION: TypewriterReason = 'correction';
export const REASON_COMMAND: TypewriterReason = 'command';
export const REASON_HISTORY_UNDO: TypewriterReason = 'history-undo';
export const REASON_HISTORY_REDO: TypewriterReason = 'history-redo';
export const REASON_UNCLASSIFIED: TypewriterReason = 'unclassified';

/* --------------------------------------------------------------------- shapes */

export interface TypewriterConfig {
  enabled: boolean;
  lineOffset: number;
}

/**
 * A line box in **window-viewport** coordinates — `getBoundingClientRect()` values as
 * returned, never pre-adjusted. The shared conversion subtracts the scroller's top and
 * adds the scroll offset; a caller that pre-subtracts the scroller top subtracts it
 * twice.
 */
export interface CaretBox {
  top: number;
  bottom: number;
}

export interface ScrollRange {
  maxScroll: number;
  visibleHeight: number;
  lineHeight: number;
}

/**
 * The one registered scroll host. Extends the plan's surface with `readMaxScroll`,
 * `measureCaret`, `measureRange` and `measureLine` so a single place owns the reserve:
 * the module applies it, forces layout, then reads the POST-reserve max scroll and
 * measures freshly for activation/resize re-centring. Clamping to a pre-reserve
 * `maxScroll` would short-change the last-line write on long documents.
 */
export interface ScrollHost {
  /** Live scroll offset. */
  readOffset(): number;
  /** ABSOLUTE setter — the only way scroll is written. */
  writeScroll(offset: number): void;
  /** Writes the reserve custom property on `document.documentElement`. */
  applyReserve(px: number): void;
  /** Post-reserve maximum scroll offset. Read after `applyReserve` + a forced layout. */
  readMaxScroll(): number;
  /** The scroll container's bounding-rect top; `0` for a page-scrolled editor. */
  scrollerTop(): number;
  /** Line-box-independent top padding in force today: 24. */
  basePadTop: number;
  /** Line-box-independent bottom padding in force today: 24. */
  basePadBottom: number;
  /** Freshly measured caret line box, in window-viewport coords, or `null`. */
  measureCaret(): CaretBox | null;
  /** Freshly measured visible height + first-line fallback box, or `null`. */
  measureRange(): ScrollRange | null;
  /** Logical 1-based caret line, or `null` when unavailable. */
  measureLine(): number | null;
}

/* -------------------------------------------------------------- module state */

let config: TypewriterConfig = { enabled: false, lineOffset: 0 };
let host: ScrollHost | null = null;
let documentReady = false;

/** The logical line the previous trigger wrote; `null` forces an instant write. */
let lastLine: number | null = null;
/** The last reserve actually applied to `host` — feeds teardown compensation. */
let lastReserve = 0;
/** The measured line-box height the current reserve used (drift detection). */
let lastLineHeight = 0;
/**
 * The previous value of the activation triple `enabled && documentReady && host`. The
 * activation pass runs on the FALSE→TRUE edge of this value only (plan §2.6: "does
 * nothing unless the triple is true AND was not true before"), so a readiness
 * re-assertion from an app-origin content push cannot re-centre the page.
 */
let activationEdge = false;
/** The one live animation-frame id (a glide step or a deferred instant write), or `null`. */
let glideFrame: number | null = null;
/** True while a MULTI-FRAME glide is in flight; an instant write is a single frame. */
let glideInFlight = false;

let triggerCount = 0;
let lastReason: string | null = null;

/** Disposer for the cancellation listeners installed alongside the current host. */
let detachCancellationListeners: (() => void) | null = null;

/* -------------------------------------------------------------------- helpers */

/**
 * Clamp `value` into `[low, high]`, surviving `low > high` (returns `value`
 * unchanged) — a window shorter than two lines has no valid band.
 */
export function clampToRange(value: number, low: number, high: number): number {
  if (low > high) return value;
  if (value < low) return low;
  if (value > high) return high;
  return value;
}

/**
 * The one coordinate conversion. A page-scrolled editor passes `scrollerTop = 0`; an
 * inner-scroller editor passes the scroll container's bounding-rect top.
 */
export function toContentY(viewportY: number, scrollerTop: number, scrollOffset: number): number {
  return viewportY - scrollerTop + scrollOffset;
}

/**
 * The fixed viewport height the caret's line is held at.
 *
 * `V < 2L` leaves no valid band, so `rest = V/2` and the line box may be clipped by
 * the window — the accepted degenerate case (plan §2.2 clause c). The instant/glide
 * rule is unchanged by it: a tiny window still writes, it just writes `V/2`.
 */
export function computeRestOffset(r: ScrollRange, lineOffset: number): number {
  const l = r.lineHeight;
  const v = r.visibleHeight;
  if (v < 2 * l) return v / 2;
  return clampToRange(v / 2 + lineOffset * l, l, v - l);
}

/**
 * The reserve added to BOTH ends.
 *
 * `R = max(0, rest - basePadTop, visibleHeight - lineHeight - basePadTop)`.
 * `basePadBottom` is deliberately not a term; the stylesheet `calc` adds it to both
 * ends and it reaches `maxScroll` through `P = basePad + R`.
 */
export function computeReserveHeight(
  visibleHeight: number,
  rest: number,
  lineHeight: number,
  basePadTop: number
): number {
  return Math.max(0, rest - basePadTop, visibleHeight - lineHeight - basePadTop);
}

/** The absolute scroll offset that puts a content-space caret top on `rest`. */
export function computeScrollTarget(caretContentTop: number, rest: number): number {
  return caretContentTop - rest;
}

function easeOutCubic(t: number): number {
  return 1 - (1 - t) ** 3;
}

function now(): number {
  return typeof performance !== 'undefined' && typeof performance.now === 'function' ? performance.now() : Date.now();
}

function requestFrame(cb: (time: number) => void): number {
  if (typeof requestAnimationFrame === 'function') return requestAnimationFrame(cb);
  return setTimeout(() => cb(now()), 16) as unknown as number;
}

function cancelFrame(id: number): void {
  if (typeof cancelAnimationFrame === 'function') {
    cancelAnimationFrame(id);
    return;
  }
  clearTimeout(id as unknown as ReturnType<typeof setTimeout>);
}

/* ----------------------------------------------------------------- public API */

export function getTypewriterConfig(): TypewriterConfig {
  return { ...config };
}

/**
 * Registers the one scroll host. Idempotent; replaces a stale host. Applies the stored
 * config, installs the cancellation listeners and runs the activation pass — so a
 * `setTypewriterConfig` that landed before the editor finished mounting is not dropped.
 */
export function registerScrollHost(next: ScrollHost): void {
  if (host && host !== next) unregisterScrollHost();
  host = next;
  lastReserve = 0;
  lastLineHeight = 0;
  installCancellationListeners(next);
  evaluateActivation();
}

/**
 * Cancels the glide, zeroes the reserve on the host it is dropping, and drops it. The
 * zero is a real write through `applyReserveOn`, so `lastReserve` ends at a value that is
 * genuinely in force — it is never forged, or a later teardown compensation would either
 * double-count it or turn into a no-op.
 */
export function unregisterScrollHost(): void {
  const previous = host;
  if (previous) cancelTypewriterGlide(previous);
  if (detachCancellationListeners) {
    detachCancellationListeners();
    detachCancellationListeners = null;
  }
  if (previous) applyReserveOn(previous, 0);
  host = null;
  activationEdge = false;
  lastLine = null;
  lastLineHeight = 0;
}

/**
 * Swift sends `focusMode && typewriterScrollingEnabled`. Turning the feature off
 * tears the reserve down synchronously and compensates the scroll so the line the
 * user is reading does not jump.
 */
export function setTypewriterEnabled(enabled: boolean): void {
  const wasEnabled = config.enabled;
  config = { ...config, enabled };
  if (!enabled) {
    if (wasEnabled && host) teardownTypewriter(host);
    activationEdge = false;
    lastLine = null;
    return;
  }
  evaluateActivation();
}

/**
 * Clamped to `LINE_OFFSET_RANGE`. Changing the offset while the feature is active
 * recomputes and re-centres immediately — otherwise the rest line would not move until
 * the next keystroke.
 */
export function setTypewriterLineOffset(lines: number): void {
  const lo = LINE_OFFSET_RANGE[0];
  const hi = LINE_OFFSET_RANGE[1];
  const clamped = Math.round(clampToRange(Number.isFinite(lines) ? lines : 0, lo, hi));
  if (config.lineOffset === clamped) return;
  config = { ...config, lineOffset: clamped };
  if (isTypewriterActive() && host) {
    recentreTypewriter(host, lastReason ?? REASON_UNCLASSIFIED);
  }
}

/** `enabled && host !== null && documentReady`. */
export function isTypewriterActive(): boolean {
  return config.enabled && host !== null && documentReady;
}

/**
 * Marks the current document loaded. Called from a microtask scheduled inside each load's
 * own dispatch callback, so it is true only after that load's transaction has applied.
 * Re-asserting readiness while the triple is already true is a no-op — it is not an edge.
 */
export function markDocumentReady(): void {
  documentReady = true;
  evaluateActivation();
}

/**
 * Unconditional teardown for a genuine new document. Cancels any in-flight glide,
 * zeroes the reserve on the registered host (when one exists), nulls the remembered
 * line and clears the ready bit. Called BEFORE that load's own dispatch.
 */
export function clearDocumentReadiness(): void {
  if (host) cancelTypewriterGlide(host);
  if (host) applyReserveOn(host, 0);
  lastLine = null;
  lastLineHeight = 0;
  documentReady = false;
  activationEdge = false;
}

/**
 * Runs one instant re-centre the moment the triple `enabled && documentReady && host`
 * becomes true, and never again while it stays true. This is the relaunch-with-the-
 * setting-already-persisted path: the config arrives before the load, the load's
 * `markDocumentReady()` completes the triple, and the pass runs on that microtask rather
 * than on the first keystroke — while a later app-origin content push, which only
 * re-asserts readiness, does nothing.
 */
function evaluateActivation(): void {
  const active = isTypewriterActive();
  if (!active) {
    activationEdge = false;
    return;
  }
  if (activationEdge) return;
  activationEdge = true;
  const h = host;
  if (!h) return;
  triggerTypewriterScroll(
    h,
    h.measureCaret(),
    h.measureRange(),
    h.measureLine(),
    lastReason ?? REASON_UNCLASSIFIED,
    true
  );
}

/** The trigger the plugins call once they have classified a document change. */
export function triggerTypewriterScroll(
  targetHost: ScrollHost,
  caret: CaretBox | null,
  r: ScrollRange | null,
  lineNumber: number | null = null,
  reason: string = REASON_UNCLASSIFIED,
  forceInstant = false
): void {
  if (!isTypewriterActive() || targetHost !== host) return;

  const resolvedCaret = caret ?? targetHost.measureCaret();
  const resolvedRange = r ?? targetHost.measureRange();
  if (!resolvedCaret || !resolvedRange) return;

  const measured = resolvedCaret.bottom - resolvedCaret.top;
  const lineHeight = measured > 0 ? measured : resolvedRange.lineHeight;
  if (!(lineHeight > 0)) {
    // Every measure failed. Abandon the trigger and leave the reserve alone rather
    // than guess a literal.
    return;
  }

  const range: ScrollRange = { ...resolvedRange, lineHeight };
  const rest = computeRestOffset(range, config.lineOffset);

  const reserve = computeReserveHeight(range.visibleHeight, rest, lineHeight, targetHost.basePadTop);
  const reserveDelta = reserve - lastReserve;

  // Frame discipline (plan §2.3): the scroll offset and the scroller's top are read
  // BEFORE the reserve write, in the same frame as the caret box, so all three describe
  // one layout. Reading the offset after the write would mix frames — the forced layout
  // can clamp the offset when the reserve shrinks near the document end.
  const scrollerTop = targetHost.scrollerTop();
  const scrollOffset = targetHost.readOffset();

  // (1) apply the reserve, force layout, then (2) read the POST-reserve max scroll.
  // A single place owns the reserve: the module.
  applyReserveOn(targetHost, reserve);
  const maxScroll = targetHost.readMaxScroll();

  // The caret box was measured before the reserve write; shift it by the reserve delta
  // to get its post-write content position. No caret box is measured after the change.
  const caretContentTop = toContentY(resolvedCaret.top + reserveDelta, scrollerTop, scrollOffset);
  const target = clampToRange(computeScrollTarget(caretContentTop, rest), 0, maxScroll);

  triggerCount += 1;
  lastReason = reason;
  lastLineHeight = lineHeight;

  const resolvedLine = lineNumber;
  // A window shorter than two line boxes has no valid band: every trigger is an instant
  // write there, never a glide (plan §2.2 clause c). The write still happens, with
  // `rest = V/2` and the line box possibly clipped by the window.
  const degenerate = range.visibleHeight < 2 * lineHeight;
  const instant =
    forceInstant || degenerate || lastLine === null || resolvedLine === null
      ? true
      : Math.abs(resolvedLine - lastLine) <= INSTANT_MAX_LINE_DELTA;

  cancelTypewriterGlide(targetHost);
  // `lastLine` is written on every trigger, before the deferred write lands.
  lastLine = resolvedLine;

  if (instant) {
    glideInFlight = false;
    // Deferred, not synchronous: in the inner-scroller editor the editor's own
    // scroll-into-view for the very transaction being classified can run after this
    // returns and overwrite a synchronous write.
    glideFrame = requestFrame(() => {
      glideFrame = null;
      if (!isTypewriterActive() || targetHost !== host) return;
      writeAbsolute(targetHost, target);
    });
  } else {
    const start = targetHost.readOffset();
    const begin = now();
    const step = () => {
      const t = Math.min(1, (now() - begin) / GLIDE_MS);
      writeAbsolute(targetHost, start + (target - start) * easeOutCubic(t));
      if (t < 1) {
        glideFrame = requestFrame(step);
      } else {
        glideFrame = null;
        glideInFlight = false;
      }
    };
    glideInFlight = true;
    glideFrame = requestFrame(step);
  }
}

/** Applies a reserve on the given host and records it. */
function applyReserveOn(targetHost: ScrollHost, px: number): void {
  targetHost.applyReserve(px);
  lastReserve = px;
  // Forced layout read so the padding the reserve just wrote is reflected in the
  // scrollable height before `readMaxScroll()` is asked for it.
  if (typeof document !== 'undefined' && document.documentElement) void document.documentElement.offsetHeight;
}

function writeAbsolute(targetHost: ScrollHost, offset: number): void {
  const max = targetHost.readMaxScroll();
  targetHost.writeScroll(clampToRange(offset, 0, max));
}

/** Measures freshly and runs one instant write. Used by activation, resize and a
 *  line-offset change while the feature is active. */
export function recentreTypewriter(targetHost: ScrollHost, reason: string = REASON_UNCLASSIFIED): void {
  if (!isTypewriterActive() || targetHost !== host) return;
  triggerTypewriterScroll(
    targetHost,
    targetHost.measureCaret(),
    targetHost.measureRange(),
    targetHost.measureLine(),
    reason,
    true
  );
}

/** Recomputes the reserve from a freshly measured caret box and re-centres instantly.
 *  The resize entry point. */
export function handleTypewriterResize(targetHost: ScrollHost): void {
  recentreTypewriter(targetHost, lastReason ?? REASON_UNCLASSIFIED);
}

/**
 * Cancels any in-flight glide for the host. The one entry point for every cancellation
 * source, and deliberately NOT gated on `isTypewriterActive()` — the listeners are
 * installed for the editor's lifetime so a glide begun while the feature was active can
 * always be stopped.
 */
export function cancelTypewriterGlide(targetHost?: ScrollHost): void {
  if (targetHost && host && targetHost !== host) return;
  if (glideFrame !== null) {
    cancelFrame(glideFrame);
    glideFrame = null;
  }
  glideInFlight = false;
}

/**
 * Synchronous teardown: cancel, zero the reserve, force layout, then compensate the
 * offset so the line the user is reading does not jump. Compensation is clamped and
 * can be partial near the top.
 */
export function teardownTypewriter(targetHost: ScrollHost): void {
  cancelTypewriterGlide(targetHost);
  const prev = lastReserve;
  // Same frame discipline as the trigger: the offset is read before the reserve write.
  const offsetBefore = targetHost.readOffset();
  applyReserveOn(targetHost, 0);
  const max = targetHost.readMaxScroll();
  const compensated = clampToRange(offsetBefore - prev, 0, max);
  targetHost.writeScroll(compensated);
  lastLine = null;
  lastLineHeight = 0;
}

/* ------------------------------------------------- cancellation listeners */

/**
 * The shared module installs the cancellation listeners itself, on `window`, in
 * capture phase — so they exist for the editor's lifetime regardless of which DOM node
 * each editor scrolls, and a synthetic ScrollHost needs no DOM of its own. Capture
 * phase `wheel` / `touchstart` / `pointerdown` / `mousedown`, plus `keydown` of an
 * arrow / Page / Home / End key (a caret move, not typing). A selection-only
 * transaction cancels from the plugin before it is classified. `scroll` events are NOT
 * a cancellation source while a glide is active: the glide's own writes are
 * indistinguishable from a trackpad flick at that granularity.
 */
function installCancellationListeners(targetHost: ScrollHost): void {
  if (typeof window === 'undefined') return;
  const cancel = () => cancelTypewriterGlide(targetHost);
  const onKeyDown = (e: Event) => {
    const key = (e as KeyboardEvent).key;
    if (
      key === 'ArrowUp' ||
      key === 'ArrowDown' ||
      key === 'ArrowLeft' ||
      key === 'ArrowRight' ||
      key === 'PageUp' ||
      key === 'PageDown' ||
      key === 'Home' ||
      key === 'End'
    ) {
      cancel();
    }
  };
  const events = ['wheel', 'touchstart', 'pointerdown', 'mousedown'] as const;
  for (const name of events) window.addEventListener(name, cancel, true);
  window.addEventListener('keydown', onKeyDown, true);
  detachCancellationListeners = () => {
    for (const name of events) window.removeEventListener(name, cancel, true);
    window.removeEventListener('keydown', onKeyDown, true);
  };
}

/* ------------------------------------------------------------------ test hooks */

export function getTypewriterTestState(): {
  active: boolean;
  triggerCount: number;
  lastReason: string | null;
  reserve: number;
  rest: number;
  lastLine: number | null;
  gliding: boolean;
} {
  const r = host ? host.measureRange() : null;
  const lineHeight = lastLineHeight > 0 ? lastLineHeight : (r?.lineHeight ?? 0);
  const rest = r ? computeRestOffset({ ...r, lineHeight }, config.lineOffset) : 0;
  return {
    active: isTypewriterActive(),
    triggerCount,
    lastReason,
    reserve: lastReserve,
    rest,
    lastLine,
    // Whether a glide is in flight. Exposed so a test can OBSERVE an instant-versus-glide
    // decision and a cancellation, instead of inferring them from a trigger count.
    gliding: glideInFlight,
  };
}

export function resetTypewriterForTests(): void {
  if (host) cancelTypewriterGlide(host);
  if (detachCancellationListeners) {
    detachCancellationListeners();
    detachCancellationListeners = null;
  }
  if (glideFrame !== null) {
    cancelFrame(glideFrame);
    glideFrame = null;
  }
  glideInFlight = false;
  config = { enabled: false, lineOffset: 0 };
  host = null;
  documentReady = false;
  lastLine = null;
  lastReserve = 0;
  lastLineHeight = 0;
  activationEdge = false;
  triggerCount = 0;
  lastReason = null;
}
