// Typewriter scrolling for the Rich Text (Milkdown) editor.
//
// Trigger rule (plan §2.4): a transaction that changes the document triggers; a
// selection-only change does not (but still cancels an in-flight glide). App-origin
// content pushes are suppressed by ORIGIN, not by guessing at annotations: the app's own
// content entry points call `withSettingContent(() => view.dispatch(spec))`, which raises
// the existing `setIsSettingContent` flag for the duration of a synchronous dispatch. The
// plugin's `state.apply` runs inside that dispatch, so the flag cannot cover a later user
// transaction.
//
// Reason strings (plan §2.4.1) come from public ProseMirror/Milkdown sources:
//   - `'paste'`        — `tr.getMeta('uiEvent')` is `'paste'` or `'drop'`
//   - `'correction'`   — `tr.getMeta('derivedCorrection')`, this app's own marker for an
//                        automatic correction competing with the user's edit
//   - `'history-undo'` / `'history-redo'` — `isHistoryTransaction(tr)` plus the
//                        `undoDepth` / `redoDepth` delta between the two states
//   - `'command'`      — `tr.getMeta('addToHistory') === false` with no flag window: a
//                        programmatic document change the app made deliberately
//   - `'input'`        — any other document change that reached us outside the flag window
//   - `'unclassified'` — never produced here; kept in the shared list as the catch-all
// `'delete'` has no public ProseMirror provenance on the transaction (Backspace and
// Delete are indistinguishable from any other `input`-class edit at this layer), so that
// row is asserted as a count, not by name — see the classifier test.

import { isHistoryTransaction, redoDepth, undoDepth } from '@milkdown/kit/prose/history';
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { $prose } from '@milkdown/kit/utils';
import {
  BASE_PAD_BOTTOM,
  BASE_PAD_TOP,
  type CaretBox,
  cancelTypewriterGlide,
  handleTypewriterResize,
  REASON_COMMAND,
  REASON_CORRECTION,
  REASON_INPUT,
  REASON_PASTE,
  RESERVE_CSS_VARIABLE,
  registerScrollHost,
  type ScrollHost,
  type ScrollRange,
  type TypewriterReason,
  triggerTypewriterScroll,
  unregisterScrollHost,
} from '../../shared/typewriter-scrolling';
import { getIsSettingContent, setIsSettingContent } from './editor-state';

export const typewriterPluginKey = new PluginKey<TypewriterPluginState>('typewriter-scrolling');

interface TypewriterPluginState {
  docChanged: boolean;
  reason: TypewriterReason;
  /**
   * The document the trigger was recorded for. The view hook fires once per distinct
   * document, which is what keeps a preserved trigger from re-firing on a later
   * selection-only transaction in the same state.
   */
  triggeredFor: unknown;
}

const IDLE: TypewriterPluginState = { docChanged: false, reason: 'unclassified', triggeredFor: null };

/**
 * Runs `spec`'s dispatch with the app-origin flag raised, clearing it in a `finally`
 * before returning. ProseMirror's `dispatch` is synchronous and the typewriter plugin's
 * `state.apply` runs inside it, so the flag is read and cleared within one call frame.
 */
let settingContentDepth = 0;

export function withSettingContent<T>(fn: () => T): T {
  // A DEPTH counter, not a boolean set/clear: a nested window must not clear the outer
  // one's flag early when its own `finally` runs. The existing direct
  // `setIsSettingContent(true/false)` call sites in this app are outside these windows and
  // are unaffected.
  settingContentDepth += 1;
  setIsSettingContent(true);
  try {
    return fn();
  } finally {
    settingContentDepth = Math.max(0, settingContentDepth - 1);
    if (settingContentDepth === 0) setIsSettingContent(false);
  }
}

/** Public-source classification of a document-changing transaction. */
export function classifyTypewriterReason(
  tr: import('@milkdown/kit/prose/state').Transaction,
  oldState: import('@milkdown/kit/prose/state').EditorState,
  newState: import('@milkdown/kit/prose/state').EditorState
): TypewriterReason {
  const uiEvent = tr.getMeta('uiEvent');
  if (uiEvent === 'paste' || uiEvent === 'drop') return REASON_PASTE;
  if (tr.getMeta('derivedCorrection') === true) return REASON_CORRECTION;
  if (isHistoryTransaction(tr)) {
    if (undoDepth(newState) < undoDepth(oldState)) return 'history-undo';
    if (redoDepth(newState) < redoDepth(oldState)) return 'history-redo';
  }
  if (tr.getMeta('addToHistory') === false) return REASON_COMMAND;
  return REASON_INPUT;
}

/* ----------------------------------------------------------- test geometry seam */

/**
 * Test-only geometry override. jsdom performs no layout, so `coordsAtPos` and every
 * `getBoundingClientRect()` are zero there and a real trigger would (correctly) abandon
 * the write. The classifier tests need a non-degenerate line box to observe
 * `triggerCount` / `lastReason`, so they install one here. Never set in production.
 */
let testGeometry: { caret: CaretBox; range: ScrollRange } | null = null;

export function __setTypewriterTestGeometry(geometry: { caret: CaretBox; range: ScrollRange } | null): void {
  testGeometry = geometry;
}

/* ---------------------------------------------------------------------- host */

/**
 * The first content block's real viewport rect, or `null`. Used only as the fallback when
 * the caret box itself measures zero height (a collapsed placeholder, an IME state): the
 * returned `top` is a true viewport coordinate, never a fabricated zero.
 */
function firstBlockRect(view: EditorView): { top: number; bottom: number } | null {
  const candidates: Element[] = [];
  const editor = document.getElementById('editor');
  if (editor?.firstElementChild) candidates.push(editor.firstElementChild);
  if (view.dom.firstElementChild) candidates.push(view.dom.firstElementChild);
  for (const el of candidates) {
    const rect = el.getBoundingClientRect();
    if (rect.height > 0) return { top: rect.top, bottom: rect.bottom };
  }
  return null;
}

function makeHost(view: EditorView): ScrollHost {
  return {
    readOffset: () => window.scrollY,
    writeScroll: (offset: number) => {
      window.scrollTo(0, offset);
    },
    applyReserve: (px: number) => {
      document.documentElement.style.setProperty(RESERVE_CSS_VARIABLE, `${px}px`);
    },
    readMaxScroll: () => Math.max(0, document.documentElement.scrollHeight - window.innerHeight),
    // Page-scrolled editor: the page top is the scroller top.
    scrollerTop: () => 0,
    basePadTop: BASE_PAD_TOP,
    basePadBottom: BASE_PAD_BOTTOM,
    measureCaret: () => {
      if (testGeometry) return testGeometry.caret;
      const head = view.state.selection.head;
      // `coordsAtPos` is already in window-viewport coordinates, which is exactly what
      // the shared conversion expects: the scroller top is subtracted there (0 here), so
      // it must NOT be pre-subtracted.
      const coords = view.coordsAtPos(head);
      if (coords && coords.bottom - coords.top > 0) return { top: coords.top, bottom: coords.bottom };
      // Zero-height but present: fall back to the first content block's own rect.
      // Null coordinates: `null`, which makes the caller ABANDON the trigger (plan §2.1:
      // "only if every measure fails does it abandon the trigger and leave the reserve
      // alone rather than guess a literal"). Fabricating a caret at the viewport top would
      // write a target roughly `rest` px away from the truth.
      return firstBlockRect(view);
    },
    measureRange: () => {
      if (testGeometry) return testGeometry.range;
      const first = firstBlockRect(view);
      return {
        maxScroll: Math.max(0, document.documentElement.scrollHeight - window.innerHeight),
        // Never a padded content height: the visible height is the window's.
        visibleHeight: window.innerHeight,
        lineHeight: first ? first.bottom - first.top : 0,
      };
    },
    measureLine: () => {
      try {
        return view.state.doc.resolve(view.state.selection.head).index(0) + 1;
      } catch {
        return null;
      }
    },
  };
}

/* -------------------------------------------------------------------- plugin */

/** The raw ProseMirror plugin. Exported so the classifier test can install it on a bare
 *  `EditorView` without standing up a whole Milkdown editor. */
export function createTypewriterPlugin(): Plugin<TypewriterPluginState> {
  return new Plugin<TypewriterPluginState>({
    key: typewriterPluginKey,

    state: {
      init: () => IDLE,
      apply(tr, value, oldState, newState): TypewriterPluginState {
        if (!tr.docChanged) {
          // PRESERVE whatever an earlier transaction in this same update recorded. This
          // app's own `appendTransaction` plugins (inline-code-cursor.ts, link-cursor.ts)
          // append a stored-marks transaction carrying no document change, and returning an
          // idle value here silently discarded the keystroke's trigger at exactly the link
          // and inline-code boundaries those plugins exist for.
          return value;
        }
        // The app-origin flag window. `state.apply` runs synchronously inside the same
        // `dispatch` the flag was raised for, so this cannot cover a later transaction.
        if (getIsSettingContent()) return IDLE;
        return {
          docChanged: true,
          reason: classifyTypewriterReason(tr, oldState, newState),
          triggeredFor: newState.doc,
        };
      },
    },

    view: () => {
      let host: ScrollHost | null = null;
      let detach: (() => void) | null = null;
      /** The document the current trigger state has already fired for. */
      let lastHandled: unknown = null;
      return {
        update(view: EditorView, prevState: import('@milkdown/kit/prose/state').EditorState) {
          // The `view()` factory has no EditorView; the first update does. Registering
          // here keeps registration inside the plugin's own lifecycle.
          if (!host) {
            host = makeHost(view);
            detach = attachTypewriterHost(host);
          }
          const flags = typewriterPluginKey.getState(view.state);
          // `triggeredFor === lastHandled` matters: M6 makes a non-document transaction
          // PRESERVE the recorded trigger so an appendTransaction (this app's stored-marks
          // plugins) cannot discard it, which means the same trigger would otherwise fire
          // again on the next selection-only transaction in that state.
          if (!flags?.docChanged || flags.triggeredFor === lastHandled) {
            // Not a trigger: either a selection-only change — which still cancels an
            // in-flight glide before returning — or a trigger already fired for this state.
            if (!view.state.selection.eq(prevState.selection)) cancelTypewriterGlide(host);
            return;
          }
          lastHandled = flags.triggeredFor;
          // The plan's measurement sources. `triggerTypewriterScroll` abandons the trigger
          // outright when the caret box cannot be measured (M7) — it never fabricates one.
          triggerTypewriterScroll(host, host.measureCaret(), host.measureRange(), host.measureLine(), flags.reason);
        },
        destroy() {
          if (detach) {
            detach();
            detach = null;
          }
          unregisterScrollHost();
          host = null;
        },
      };
    },
  });
}

/** The `$prose` plugin `main.ts` registers. */
export const typewriterPlugin = $prose(() => createTypewriterPlugin());

/**
 * The element whose box tracks the WINDOW, used as the resize observer's target.
 *
 * Walks up from `#editor` and returns the first ancestor with a non-`visible` vertical
 * overflow (the actual viewport scroller). It deliberately never returns
 * `documentElement` or `body`: their boxes grow with the content, so an observer on them
 * fires on every keystroke and would pre-empt the glide. When there is no such ancestor —
 * a genuinely page-scrolled editor — the caller falls back to the window's own `resize`
 * event, which is the viewport signal for that layout.
 */
function viewportElement(): Element | null {
  if (typeof document === 'undefined' || typeof getComputedStyle !== 'function') return null;
  let el: Element | null = document.getElementById('editor')?.parentElement ?? null;
  while (el && el !== document.body && el !== document.documentElement) {
    const overflowY = getComputedStyle(el).overflowY;
    if (overflowY && overflowY !== 'visible') return el;
    el = el.parentElement;
  }
  return null;
}

/**
 * Registers a host and installs the resize signals: a `ResizeObserver` on the viewport
 * element plus the window's own `resize` event. Returns a disposer. Idempotent, and the
 * shared module keeps a single host slot, so a second call replaces the first.
 */
export function attachTypewriterHost(host: ScrollHost): () => void {
  registerScrollHost(host);
  if (typeof window === 'undefined') return () => unregisterScrollHost();
  const onResize = () => handleTypewriterResize(host);
  window.addEventListener('resize', onResize);
  let observer: ResizeObserver | null = null;
  const target = viewportElement();
  if (target && typeof ResizeObserver !== 'undefined') {
    observer = new ResizeObserver(() => handleTypewriterResize(host));
    observer.observe(target);
  }
  return () => {
    window.removeEventListener('resize', onResize);
    if (observer) {
      observer.disconnect();
      observer = null;
    }
    unregisterScrollHost();
  };
}
