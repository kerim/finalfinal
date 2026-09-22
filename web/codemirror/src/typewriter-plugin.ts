// Typewriter scrolling for the Markdown source editor.
//
// Trigger rule (plan §2.4): a transaction that changes the document triggers; a
// selection-only change does not (but still cancels an in-flight glide). App-origin
// content pushes are suppressed by ORIGIN, not by guessing at annotations: every
// dispatch the app makes for itself goes through `withAppOrigin(() => view.dispatch(spec))`,
// whose body raises a module-scoped depth counter; a transaction extender registered by
// this module turns that counter into `appOrigin.of(true)` on the transaction. Dispatch
// is synchronous and the extender runs inside it, so the flag cannot leak into a later
// user transaction.
//
// Reason strings come from `Transaction.userEvent` — CodeMirror's own public
// classification of what caused a transaction (its keymap, input handlers, paste/drop
// handlers and the history commands all set it). A document change with no userEvent at
// all is `'unclassified'`: in this app the formatting commands dispatch without one, so
// they land there rather than being guessed at. `toggleBold` and friends are counted, not
// named.

import { Annotation, EditorState, Transaction } from '@codemirror/state';
import { type EditorView, ViewPlugin, type ViewUpdate } from '@codemirror/view';
import {
  BASE_PAD_BOTTOM,
  BASE_PAD_TOP,
  type CaretBox,
  cancelTypewriterGlide,
  handleTypewriterResize,
  REASON_COMMAND,
  REASON_CORRECTION,
  REASON_DELETE,
  REASON_HISTORY_REDO,
  REASON_HISTORY_UNDO,
  REASON_INPUT,
  REASON_PASTE,
  REASON_UNCLASSIFIED,
  RESERVE_CSS_VARIABLE,
  registerScrollHost,
  type ScrollHost,
  type ScrollRange,
  type TypewriterReason,
  triggerTypewriterScroll,
  unregisterScrollHost,
} from '../../shared/typewriter-scrolling';

/** Marks a transaction as dispatched by the application rather than by the user. */
export const appOrigin = Annotation.define<boolean>();

let appOriginDepth = 0;

/**
 * Runs `fn` — which must dispatch synchronously — with every transaction it produces
 * marked `appOrigin`. The `finally` clears the depth even if the dispatch throws.
 */
export function withAppOrigin<T>(fn: () => T): T {
  appOriginDepth++;
  try {
    return fn();
  } finally {
    appOriginDepth--;
  }
}

/**
 * Attaches `appOrigin` to every transaction dispatched inside a `withAppOrigin` window.
 * Registered as an extension of the editor so the extender runs inside `dispatch`.
 */
export const appOriginExtender = EditorState.transactionExtender.of((_tr) =>
  appOriginDepth > 0 ? { annotations: appOrigin.of(true) } : null
);

/** Maps CodeMirror's own `Transaction.userEvent` to the exported reason strings. */
export function classifyTypewriterReason(tr: Transaction): TypewriterReason {
  const ev = tr.annotation(Transaction.userEvent) ?? '';
  if (ev.includes('undo')) return REASON_HISTORY_UNDO;
  if (ev.includes('redo')) return REASON_HISTORY_REDO;
  if (ev.includes('paste') || ev.includes('drop')) return REASON_PASTE;
  if (ev.startsWith('delete')) return REASON_DELETE;
  if (ev.startsWith('input.replace')) return REASON_CORRECTION;
  if (ev.startsWith('input.')) return REASON_INPUT;
  if (ev.startsWith('select')) return REASON_UNCLASSIFIED;
  if (ev.length > 0) return REASON_COMMAND;
  return REASON_UNCLASSIFIED;
}

/* ----------------------------------------------------------- test geometry seam */

/**
 * Test-only geometry override. jsdom performs no layout, so `coordsAtPos` and
 * `lineBlockAt(...).height` are all zero there and a real trigger would (correctly)
 * abandon the write. The classifier tests need a non-degenerate line box to observe
 * `triggerCount` / `lastReason`, so they install one here. Never set in production.
 */
let testGeometry: { caret: CaretBox; range: ScrollRange } | null = null;

export function __setTypewriterTestGeometry(geometry: { caret: CaretBox; range: ScrollRange } | null): void {
  testGeometry = geometry;
}

/* ---------------------------------------------------------------------- host */

/**
 * The visible height, measured from an element the reserve CANNOT inflate. `view.dom` is the
 * `.cm-editor` wrapper; the reserve lives on `.cm-content`, one level inside the scroller, so
 * `scrollHeight - editorHeight` cannot feed back into the reserve the way
 * `scrollHeight - scroller.clientHeight` could. Falls back to the scroller only when the
 * wrapper reports no height at all.
 */
function visibleHeightOf(view: EditorView): number {
  const editorHeight = view.dom?.clientHeight ?? 0;
  if (editorHeight > 0) return editorHeight;
  return view.scrollDOM.clientHeight;
}

function makeHost(view: EditorView): ScrollHost {
  return {
    readOffset: () => view.scrollDOM.scrollTop,
    writeScroll: (offset: number) => {
      view.scrollDOM.scrollTop = offset;
    },
    applyReserve: (px: number) => {
      document.documentElement.style.setProperty(RESERVE_CSS_VARIABLE, `${px}px`);
    },
    // The scrollable height grows with the reserve (it is a margin inside the scroller);
    // the visible height is read from the reserve-free wrapper, so the max does not shrink
    // as the reserve grows.
    readMaxScroll: () => Math.max(0, view.scrollDOM.scrollHeight - visibleHeightOf(view)),
    scrollerTop: () => view.scrollDOM.getBoundingClientRect().top,
    basePadTop: BASE_PAD_TOP,
    basePadBottom: BASE_PAD_BOTTOM,
    measureCaret: () => {
      if (testGeometry) return testGeometry.caret;
      const head = view.state.selection.main.head;
      // `coordsAtPos` is already in window-viewport coordinates, which is exactly what
      // the shared conversion expects: the scroller top is subtracted there, so it must
      // NOT be pre-subtracted here.
      const coords = view.coordsAtPos(head, 1);
      if (coords && coords.bottom - coords.top > 0) return { top: coords.top, bottom: coords.bottom };
      // Zero-height but present: fall back to the first content line's OWN box, measured
      // through the same `coordsAtPos` source so its `top` is a true viewport coordinate.
      const firstLine = view.coordsAtPos(view.state.doc.line(1).from, 1);
      if (firstLine && firstLine.bottom - firstLine.top > 0) {
        return { top: firstLine.top, bottom: firstLine.bottom };
      }
      // Every measure failed. `null` makes the caller ABANDON the trigger and leave the
      // reserve alone rather than guess a literal (plan §2.1) — fabricating a caret at the
      // viewport top would write a target roughly `rest` px away from the truth.
      return null;
    },
    measureRange: () => {
      if (testGeometry) return testGeometry.range;
      const firstLine = view.state.doc.line(1);
      const firstBlock = view.lineBlockAt(firstLine.from);
      return {
        maxScroll: Math.max(0, view.scrollDOM.scrollHeight - visibleHeightOf(view)),
        // Never the scroller's own clientHeight: that box can include the reserve.
        visibleHeight: visibleHeightOf(view),
        lineHeight: firstBlock?.height ?? 0,
      };
    },
    measureLine: () => {
      const head = view.state.selection.main.head;
      try {
        return view.state.doc.lineAt(head).number;
      } catch {
        return null;
      }
    },
  };
}

/* -------------------------------------------------------------------- plugin */

/**
 * The typewriter-scrolling CodeMirror extension: registers the scroll host for the
 * view's lifetime, classifies each transaction, and drives the shared module.
 *
 * The app-origin extender is part of this extension, so any editor that installs the
 * typewriter plugin automatically gets working `withAppOrigin` semantics.
 */
export const typewriterPlugin = ViewPlugin.fromClass(
  class {
    private host: ScrollHost;
    private resizeObserver: ResizeObserver | null = null;
    private onWindowResize: (() => void) | null = null;
    /** Set in `destroy()` so a deferred trigger queued before teardown cannot run after it. */
    private destroyed = false;

    constructor(view: EditorView) {
      this.host = makeHost(view);
      registerScrollHost(this.host);

      // Viewport elements only: `scrollDOM` is the visible scroller. Observing the
      // document root or the content element would fire on every keystroke and
      // pre-empt the glide.
      if (typeof ResizeObserver !== 'undefined') {
        this.resizeObserver = new ResizeObserver(() => handleTypewriterResize(this.host));
        this.resizeObserver.observe(view.scrollDOM);
      }
      if (typeof window !== 'undefined') {
        this.onWindowResize = () => handleTypewriterResize(this.host);
        window.addEventListener('resize', this.onWindowResize);
      }
    }

    update(update: ViewUpdate) {
      // A selection-only change is not a trigger, but still cancels any in-flight glide.
      if (update.selectionSet && !update.docChanged) {
        cancelTypewriterGlide(this.host);
      }
      if (!update.docChanged) return;

      // Any transaction that actually changed the document and was not dispatched by
      // the app is a trigger.
      const triggering = update.transactions.filter((tr) => tr.docChanged && !tr.annotation(appOrigin));
      if (triggering.length === 0) return;

      const last = triggering[triggering.length - 1];
      // The reason is classified SYNCHRONOUSLY: `Transaction.userEvent` is only valid on the
      // transaction being classified, and this list is not retained past the update.
      const reason = classifyTypewriterReason(last);
      const host = this.host;

      // THE MEASUREMENT MUST NOT HAPPEN IN THIS UPDATE WINDOW, and this deferral is therefore
      // mandatory, not a style choice. `measureCaret` calls `view.coordsAtPos`, and CodeMirror
      // FORBIDS layout reads during an update: `readMeasured()` throws "Reading the editor
      // layout isn't allowed during an update" while `updateState == Updating`, because plugin
      // updates run BEFORE the document view is updated, so the DOM is still the pre-edit
      // document. `PluginInstance.update` CATCHES that throw, logs "CodeMirror plugin crashed",
      // then calls this plugin's `destroy()` and deactivates it PERMANENTLY — which unregisters
      // the host and zeroes the reserve, leaving the feature inert for the rest of the session.
      //
      // Do NOT "simplify" this back into the synchronous body, and do NOT wrap the measurement
      // in a try/catch: catching would hide the illegal read and leave the recorded reserve
      // stale, which is a worse bug than the crash. A microtask runs after the whole dispatch
      // (document view included) has completed, so all three reads — caret box, scroller top and
      // scroll offset — still happen together, in one frame, with `updateState == Idle`.
      queueMicrotask(() => {
        if (this.destroyed) return;
        triggerTypewriterScroll(host, host.measureCaret(), host.measureRange(), host.measureLine(), reason);
      });
    }

    destroy() {
      this.destroyed = true;
      if (this.resizeObserver) {
        this.resizeObserver.disconnect();
        this.resizeObserver = null;
      }
      if (this.onWindowResize && typeof window !== 'undefined') {
        window.removeEventListener('resize', this.onWindowResize);
        this.onWindowResize = null;
      }
      unregisterScrollHost();
    }
  }
);

/** The extensions this module contributes to `main.ts`'s extension list. */
export const typewriterExtension = [appOriginExtender, typewriterPlugin];
