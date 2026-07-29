// Shared Hover Tooltip for Milkdown
// Singleton, JS-positioned hover tooltip shared by BOTH collapsed annotations
// (.ff-annotation-collapsed, decorated by annotation-display-plugin.ts) and
// footnote references (.ff-footnote-ref, footnote-plugin.ts).
//
// Replaces two prior per-feature tooltip mechanisms that both rendered too
// narrow in real WebKit:
//   - .ff-annotation-collapsed::after — a pure-CSS ::after pseudo-element using
//     `position: absolute; left: 50%; transform: translateX(-50%)` with no
//     explicit width. Per CSS 2.1 §10.4, max-width DOES apply to shrink-to-fit
//     boxes in general — the real problem was that this pseudo-element's
//     containing block was the collapsed annotation marker itself, only a
//     few pixels wide, so the shrink-to-fit algorithm resolved to its
//     min-content width (the longest unbreakable word) long before max-width
//     ever got a chance to bind (verified by direct measurement in real
//     WebKit, not a guess — two prior jsdom-passing "fixes" to that exact
//     rule were both wrong).
//   - .ff-footnote-tooltip — a real DOM child element with the identical
//     `left: 50%; transform: translateX(-50%)` positioning, appended into the
//     footnote-ref <sup> by footnote-plugin.ts, with the same tiny-
//     containing-block problem (the <sup> reference itself).
//
// Because neither an ::after pseudo-element nor an in-DOM child of a tiny
// inline anchor can be measured/positioned by JS, both are replaced here by a
// single `position: fixed` singleton <div> appended to document.body (mirrors
// annotation-edit-popup.ts's singleton pattern) and positioned via the shared
// positionPopup() helper, which clamps it to the viewport using its actual
// rendered size — exactly like the click-to-edit popups already do. The
// actual width fix is `width: max-content` on .ff-hover-tooltip (see
// styles.css), which gives the box an explicit width basis for max-width to
// clamp against no matter how tiny its containing block is; `position: fixed`
// is what makes the box JS-measurable/clampable, a separate concern.
//
// Delegated listeners: ProseMirror recreates node DOM constantly (NodeView
// re-render, decoration changes, source-mode toggles), so per-node hover
// listeners leak and go stale. Only ONE mouseover/mouseout pair is installed,
// on the editor root, matching anchors via .closest() on the event target —
// mirrors main.ts's `view.dom.addEventListener('beforeinput', ...)` pattern of
// attaching directly to the editor root DOM element.

import type { MilkdownPlugin } from '@milkdown/kit/ctx';
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { $prose } from '@milkdown/kit/utils';
import { positionPopup } from '../../shared/position-popup';
import { getAnnotationDisplayModes } from './annotation-display-plugin';
import type { AnnotationType } from './annotation-plugin';
import { getFootnoteDefinitions } from './footnote-plugin';
import { isSourceModeEnabled } from './source-mode-plugin';

const ANNOTATION_SELECTOR = '.ff-annotation-collapsed';
const FOOTNOTE_SELECTOR = '.ff-footnote-ref';

// --- Singleton tooltip DOM ---

let tooltipEl: HTMLDivElement | null = null;
let currentAnchor: HTMLElement | null = null;

function createTooltip(): HTMLDivElement {
  if (tooltipEl) return tooltipEl;

  const el = document.createElement('div');
  el.className = 'ff-hover-tooltip';
  // No inline display/opacity/visibility here — the base .ff-hover-tooltip
  // CSS rule already sets the default hidden state (opacity:0, visibility:
  // hidden) plus the fade transition. We deliberately never use
  // `display: none` for show/hide (unlike the edit popups): display changes
  // can't be transitioned, and this tooltip fades in/out like the CSS-only
  // bubble it replaced. `visibility: hidden` still keeps the element out of
  // the accessibility tree and non-interactive, and — unlike display:none —
  // it's still measurable via getBoundingClientRect(), which positionPopup()
  // relies on below.
  el.style.position = 'fixed';
  el.style.pointerEvents = 'none';

  document.body.appendChild(el);
  tooltipEl = el;
  return el;
}

/** Show the shared hover tooltip for `anchorEl`, positioned via positionPopup(). */
function showHoverTooltip(anchorEl: HTMLElement, text: string, variant?: 'footnote'): void {
  const tooltip = createTooltip();
  tooltip.textContent = text;
  tooltip.classList.toggle('ff-hover-tooltip--footnote', variant === 'footnote');
  // Set visible before positioning so getBoundingClientRect() in positionPopup()
  // returns accurate measurements (same convention as the edit popups, which
  // do the equivalent with `display`).
  tooltip.style.visibility = 'visible';
  tooltip.style.opacity = '1';
  currentAnchor = anchorEl;

  positionPopup(tooltip, anchorEl.getBoundingClientRect());
}

/** Hide the shared hover tooltip (idempotent — safe to call when already hidden). */
export function hideHoverTooltip(): void {
  if (tooltipEl) {
    tooltipEl.style.visibility = 'hidden';
    tooltipEl.style.opacity = '0';
  }
  currentAnchor = null;
}

/** Exposed for tests. */
export function isHoverTooltipVisible(): boolean {
  return tooltipEl !== null && tooltipEl.style.visibility !== 'hidden';
}

/** Exposed for tests. */
export function getHoverTooltipElement(): HTMLDivElement | null {
  return tooltipEl;
}

// --- Anchor resolution ---

interface ResolvedAnchor {
  anchor: HTMLElement;
  text: string;
  variant?: 'footnote';
}

// Determine which anchor (if any) under `target` should show a tooltip, and
// what text it should show. Returns null when nothing matches, or a matched
// anchor has no text to show (e.g. an unresolved footnote definition).
function resolveAnchor(target: EventTarget | null): ResolvedAnchor | null {
  if (!(target instanceof Element)) return null;

  const annotationEl = target.closest(ANNOTATION_SELECTOR) as HTMLElement | null;
  if (annotationEl) {
    // Belt-and-suspenders: the .ff-annotation-collapsed class is only ever
    // applied by annotation-display-plugin.ts's decoration when the type's
    // display mode is 'collapsed' (see its if/else-if chain) — but
    // setAnnotationDisplayModes() mutates the module-level displayModes map
    // directly without forcing a synchronous decoration recompute, so there's
    // a real (if narrow) window where the DOM still carries a stale
    // 'collapsed' decoration after the mode has flipped. Re-check the live
    // mode here the same way the accessibility fix in annotation-plugin.ts
    // does, rather than trusting the class alone.
    //
    // `data-type` is set by the NodeView's own dom (annotation-plugin.ts),
    // NOT by this decoration, so — unlike `data-text` below, which the
    // decoration sets directly and is therefore guaranteed on whatever
    // element `.closest()` matched — it isn't guaranteed to live on that same
    // element in every ProseMirror version. Decoration.node() has, in a
    // version this project once ran, wrapped the NodeView's DOM in a
    // separate element rather than merging attrs into it (see
    // docs/lessons/prosemirror/decorations.md); the current version doesn't,
    // but fall back to a descendant lookup so this keeps working either way.
    const type = (annotationEl.dataset.type ?? annotationEl.querySelector<HTMLElement>('[data-type]')?.dataset.type) as
      | AnnotationType
      | undefined;
    if (!type || getAnnotationDisplayModes()[type] !== 'collapsed') return null;

    const text = annotationEl.dataset.text || '';
    if (!text) return null;
    return { anchor: annotationEl, text };
  }

  const footnoteEl = target.closest(FOOTNOTE_SELECTOR) as HTMLElement | null;
  if (footnoteEl) {
    // Source mode shows raw `[^N]` syntax on the same element — no tooltip
    // there, matching the old per-node showTooltip()'s own guard.
    if (isSourceModeEnabled()) return null;

    const label = footnoteEl.dataset.label;
    const text = label ? getFootnoteDefinitions().get(label) : undefined;
    if (!text) return null;
    return { anchor: footnoteEl, text, variant: 'footnote' };
  }

  return null;
}

// --- Delegated listener installation ---

/**
 * Install the delegated mouseover/mouseout pair (plus the scroll/click/
 * mousedown/blur/resize dismissal listeners) on `root` — the editor's DOM
 * element. Returns a cleanup function that removes everything.
 *
 * Exported directly (not only reachable via the $prose plugin below) so it
 * can be unit-tested against a plain element without needing a full Milkdown
 * Editor/ProseMirror EditorView instance.
 */
export function installHoverTooltipListeners(root: HTMLElement): () => void {
  const handleMouseOver = (e: MouseEvent) => {
    const resolved = resolveAnchor(e.target);
    if (!resolved) return;
    showHoverTooltip(resolved.anchor, resolved.text, resolved.variant);
  };

  const handleMouseOut = (e: MouseEvent) => {
    if (!currentAnchor) return;

    // Must-fix: moving between two child nodes of the SAME anchor fires
    // mouseout/mouseover pairs that must NOT hide the tooltip — only hide when
    // truly leaving the anchor (relatedTarget is outside it, or there is no
    // relatedTarget at all, e.g. the pointer left the window).
    const related = e.relatedTarget;
    if (related instanceof Node && currentAnchor.contains(related)) return;

    hideHoverTooltip();
  };

  const hideOnDismiss = () => hideHoverTooltip();

  root.addEventListener('mouseover', handleMouseOver);
  root.addEventListener('mouseout', handleMouseOut);
  // blur doesn't bubble, but it fires directly on the element that lost focus —
  // listening directly on root (not delegating from an ancestor) is correct.
  root.addEventListener('blur', hideOnDismiss);
  // Capture phase: scrolling inside any nested scrollable ancestor still
  // invalidates the tooltip's clamped position (mirrors spellcheck-menu.ts's
  // document.addEventListener('scroll', dismissMenu, true)).
  document.addEventListener('scroll', hideOnDismiss, true);
  document.addEventListener('click', hideOnDismiss);
  document.addEventListener('mousedown', hideOnDismiss);
  window.addEventListener('resize', hideOnDismiss);
  // The old CSS-hover tooltips moved with their anchor and died with it, so
  // they could never go stale-positioned. This position: fixed tooltip is
  // pinned at the coordinates captured when it was shown — if the user types
  // elsewhere without moving the mouse and text reflow shifts the anchor's
  // on-screen position, the tooltip is left pointing at the wrong place.
  // Dismiss on any keydown while visible, same as the other dismiss triggers.
  document.addEventListener('keydown', hideOnDismiss);

  return () => {
    root.removeEventListener('mouseover', handleMouseOver);
    root.removeEventListener('mouseout', handleMouseOut);
    root.removeEventListener('blur', hideOnDismiss);
    document.removeEventListener('scroll', hideOnDismiss, true);
    document.removeEventListener('click', hideOnDismiss);
    document.removeEventListener('mousedown', hideOnDismiss);
    window.removeEventListener('resize', hideOnDismiss);
    document.removeEventListener('keydown', hideOnDismiss);
  };
}

// --- ProseMirror plugin (installs listeners on the real editor root) ---

const hoverTooltipPluginKey = new PluginKey('ff-hover-tooltip');

const hoverTooltipProsePlugin = $prose(() => {
  return new Plugin({
    key: hoverTooltipPluginKey,
    view(editorView: EditorView) {
      const cleanup = installHoverTooltipListeners(editorView.dom as HTMLElement);
      return {
        destroy() {
          cleanup();
          hideHoverTooltip();
        },
      };
    },
  });
});

export const hoverTooltipPlugin: MilkdownPlugin[] = [hoverTooltipProsePlugin].flat();
