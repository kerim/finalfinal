// Cmd-click-a-heading-to-zoom-into-that-section.
//
// ALWAYS ON — no Focus Mode gate, no preference gate, anywhere in this file or
// on the Swift side that receives the `zoomHeadingClicked` message. The only
// gate is `contentState == .idle`, enforced natively by
// HeadingZoomClickRouter.decide (final final/ViewState/HeadingZoomClickRouter.swift).
//
// ProseMirror makes its own node selection on `mousedown` (not `click`) for a
// Cmd-click on a block node, so overriding that requires a capture-phase
// `mousedown` listener in addition to the `click` listener that actually
// sends the zoom request — a `click`-only override would still let PM select
// the heading node first.
//
// No silent failures: every drop path here is either a resolved, intentional
// no-op (plain click, non-heading target — nothing to report) or a logged one
// (missing message handler, block id still temporary after the retry window).
// The previous, rejected attempt at this feature silently did nothing for
// some users because it used a bare `?.postMessage` optional-chain-to-nothing
// when the Swift-side handler wasn't registered — see postZoomRequest below.

import { hideHoverTooltip } from './hover-tooltip';
import { dismissMenu } from './spellcheck-menu';

const HEADING_TAGS = new Set(['H1', 'H2', 'H3', 'H4', 'H5', 'H6']);

const TEMP_ID_RETRY_MS = 8000;
const TEMP_ID_POLL_INTERVAL_MS = 100;

/**
 * Walks up from `event.target` to the nearest ancestor carrying `[data-block-id]`,
 * returning it only when that ancestor is a heading AND the click was a Cmd-click.
 * Ctrl is deliberately excluded — Ctrl-click is the macOS right-click/context-menu
 * gesture, not a modifier for this feature.
 */
export function headingZoomTargetFor(event: MouseEvent): HTMLElement | null {
  if (!event.metaKey) return null;
  const target = event.target as HTMLElement | null;
  if (!target || typeof target.closest !== 'function') return null;
  const blockEl = target.closest('[data-block-id]') as HTMLElement | null;
  if (!blockEl || !HEADING_TAGS.has(blockEl.tagName)) return null;
  return blockEl;
}

/**
 * Sends the zoom request to Swift. Deliberately does NOT use a bare
 * `?.postMessage` optional-chain-to-nothing — that pattern is exactly how the
 * previous attempt at this feature silently did nothing when the Swift-side
 * handler wasn't registered (a compound gate elsewhere masked the bug for
 * most users, but not all). Reads the handler first and, if it's missing,
 * logs loudly on both sides of the bridge instead of swallowing the failure.
 */
function postZoomRequest(blockId: string): void {
  const handler = window.webkit?.messageHandlers?.zoomHeadingClicked;
  if (!handler) {
    console.error(
      '[ZoomClick] zoomHeadingClicked message handler is not registered on the Swift side — ' +
        'Cmd-click zoom will do nothing. Check registerMilkdownMessageHandlers in MilkdownEditor.swift.'
    );
    window.webkit?.messageHandlers?.errorHandler?.postMessage({
      type: 'plugin-error',
      message: 'zoomHeadingClicked handler missing',
    });
    return;
  }
  handler.postMessage({ blockId });
}

// Capture phase, and BEFORE any click handling: ProseMirror's own node-selection
// logic runs on `mousedown`, so `click`-only prevention would be too late.
document.addEventListener(
  'mousedown',
  (event) => {
    // Left-button only — a Cmd+middle-click (or any other button) is not a zoom
    // trigger and shouldn't be swallowed here.
    if (event.button !== 0) return;
    if (!headingZoomTargetFor(event)) return;
    event.preventDefault();
    event.stopImmediatePropagation();
  },
  true
);

document.addEventListener(
  'click',
  (event) => {
    const el = headingZoomTargetFor(event);
    console.log('[ZoomClick] click captured, target:', event.target, 'metaKey:', event.metaKey, 'matchedHeading:', el);
    if (!el) return;

    // hover-tooltip.ts and spellcheck-menu.ts each register their own
    // bubble-phase document click/mousedown listeners to dismiss themselves on
    // an outside click. The stopImmediatePropagation() below prevents those
    // from ever firing for this event, which would otherwise leave an open
    // tooltip/spellcheck menu on screen after the zoom. Dismiss them directly
    // instead of relying on the event we're about to suppress. Both are
    // idempotent — safe to call when nothing is open.
    hideHoverTooltip();
    dismissMenu();

    event.preventDefault();
    event.stopImmediatePropagation();

    const blockId = el.getAttribute('data-block-id');
    if (!blockId) {
      console.warn('[ZoomClick] heading element has no data-block-id attribute; dropping Cmd-click');
      return;
    }

    if (!blockId.startsWith('temp-')) {
      postZoomRequest(blockId);
      return;
    }

    // The block id hasn't been confirmed by Swift yet (new heading, still mid-sync).
    // block-id-plugin.ts rewrites `data-block-id` in place on this same DOM node once
    // the permanent id lands, so re-read the attribute off `el` at retry time rather
    // than trusting the id captured now. This does NOT mirror image-plugin.ts's exact
    // temp-id-retry mechanism — that's a ProseMirror NodeView and re-derives the id via
    // `this.getPos()` -> `getBlockIdAtPos(currentPos)`, which survives the DOM node
    // itself being replaced. This is a bare `document`-level listener with no NodeView
    // to re-resolve a position through, so it polls the same DOM node instead and
    // treats the node being replaced/removed out from under it (e.g. by a full-document
    // resync during undo/version-restore/zoom) as its own distinct failure case below.
    // Same intent (don't act on a stale temp id), different re-derivation strategy.
    let elapsedMs = 0;
    const intervalId = setInterval(() => {
      if (!el.isConnected) {
        clearInterval(intervalId);
        console.warn(
          '[ZoomClick] heading DOM node was replaced before the block id resolved; dropping Cmd-click on heading'
        );
        return;
      }

      const retryId = el.getAttribute('data-block-id');
      if (retryId && !retryId.startsWith('temp-')) {
        clearInterval(intervalId);
        postZoomRequest(retryId);
        return;
      }

      elapsedMs += TEMP_ID_POLL_INTERVAL_MS;
      if (elapsedMs >= TEMP_ID_RETRY_MS) {
        clearInterval(intervalId);
        console.warn('[ZoomClick] block id still temporary after 8s; dropping Cmd-click on heading');
      }
    }, TEMP_ID_POLL_INTERVAL_MS);
  },
  true
);
