// Image Node Rewrite Plugin for Milkdown
//
// Replaces the built-in `image` node schema (from
// @milkdown/preset-commonmark@7.18.0) to fix the plain (non-figure) inline
// image never getting the media/... -> projectmedia://... display-URL
// rewrite that makes it actually render in WKWebView — verified directly
// against the installed package source
// (node_modules/.pnpm/@milkdown+preset-commonmark@7.18.0/node_modules/@milkdown/preset-commonmark/src/node/image.ts):
//
// - Upstream `toDOM` writes `node.attrs.src` (the raw, unrewritten
//   `media/...` path) directly into the rendered `<img src>` attribute — a
//   `media/...` path is not a resolvable URL scheme for WKWebView, so the
//   image never loads; it renders as a permanent broken-image icon. Fixed by
//   applying the same `rewriteMediaUrl` helper `FigureNodeView` already uses
//   for its own `<img>` (see image-plugin.ts).
// - Upstream `parseDOM` reads `dom.getAttribute('src')` — the *rendered*
//   (possibly display-rewritten) value — straight back into `node.attrs.src`
//   as if it were canonical. Since this node has no NodeView (see rejection
//   note below), it has no `ignoreMutation` hook to stop a native WebKit DOM
//   mutation near it from reaching ProseMirror's `readDOMChange`
//   reconciliation, which uses `parseDOM` — so an unrewritten upstream
//   `parseDOM` risks silently overwriting the real `media/...` reference
//   with the rewritten `projectmedia://...` display value, permanently
//   losing it on the next save. Fixed by rendering the canonical value into
//   a separate `data-src` attribute (mirroring, but not literally copying,
//   `figureNode`'s own `data-src` — see the divergence note on `parseDOM`
//   below) and reading `data-src` back in preference to `src`.
//
// `attrs`/`parseMarkdown`/`toMarkdown` are copied verbatim from upstream,
// byte-for-byte unchanged — only `toDOM`/`parseDOM` (live-rendering-only
// concerns) diverge. Do NOT let a future edit "helpfully" re-sync `toDOM`/
// `parseDOM` back to upstream to look more consistent with the rest of the
// file — that would silently reintroduce both the unrenderable-image bug and
// the DOM-readback data-loss risk this file exists to fix.
//
// `parseDOM`'s `dom.getAttribute('data-src') ?? dom.getAttribute('src') ?? ''`
// fallback chain is a deliberate divergence from `figureNode`'s own
// `parseDOM` (`image-plugin.ts`), which reads `data-src` with no `|| src`
// fallback at all: `figure[data-image]` is an app-exclusive tag/attribute
// combination that never matches real external HTML, so it never needs a
// fallback. `img[src]` is different — it legitimately matches genuinely
// external content (e.g. an `<img>` copied from a webpage), which will never
// carry a `data-src`, so this schema's `parseDOM` needs the `|| src`
// fallback that figure's doesn't.
//
// Registered by id via $node('image', ...): Milkdown's node registry
// (nodesCtx) replaces any existing entry sharing an id, so this REPLACES the
// built-in schema wholesale rather than extending it — same mechanism, and
// same rationale for rejecting $NodeSchema's extendSchema(), as
// ordered-list-order-plugin.ts's own header comment explains for
// `ordered_list`.
//
// Must be `.use()`d AFTER `.use(commonmark)` (see main.ts) so this
// replacement wins over commonmark's own later registration of the built-in
// `image` schema — registering before commonmark would have commonmark's
// `.use(commonmark)` call silently re-register the built-in schema and undo
// this override.
//
// Alternative considered: a NodeView for `image` (like FigureNodeView) was
// rejected. `image` is `inline: true, group: 'inline', selectable: true,
// draggable: true, marks: '', defining: true, isolating: true` — a
// hand-rolled NodeView would need to correctly reproduce all of that
// inline-atom behavior (native cursor movement stepping over it,
// backspace-select, native drag vs. drag-selecting adjacent text, IME
// composition boundaries) to avoid regressing default inline editing around
// every plain image in every document, for zero functional benefit this
// schema-only fix doesn't already provide — `rewriteMediaUrl` is a pure,
// stateless string transform with no async work, no retry, no external
// state, so `toDOM` alone (no lifecycle management) is sufficient.

import { imageAttr } from '@milkdown/kit/preset/commonmark';
import type { Node as ProsemirrorNode } from '@milkdown/kit/prose/model';
import { $node } from '@milkdown/kit/utils';
import { rewriteMediaUrl } from './image-plugin';

export const imageNodeRewritePlugin = $node('image', (ctx) => ({
  inline: true,
  group: 'inline',
  selectable: true,
  draggable: true,
  marks: '',
  atom: true,
  defining: true,
  isolating: true,
  attrs: {
    src: { default: '', validate: 'string' },
    alt: { default: '', validate: 'string' },
    title: { default: '', validate: 'string' },
  },
  toDOM: (node: ProsemirrorNode) => {
    const attrs: Record<string, string> = {
      ...ctx.get(imageAttr.key)(node),
      ...node.attrs,
      src: rewriteMediaUrl(node.attrs.src || ''),
    };
    attrs['data-src'] = node.attrs.src || ''; // canonical value, always
    return ['img', attrs];
  },
  parseDOM: [
    {
      tag: 'img[src]',
      getAttrs: (dom: HTMLElement) => ({
        // data-src wins for our own rendered nodes; fall back to src for
        // genuinely external HTML (e.g. an <img> copied from a webpage),
        // matching upstream's original unconditional-src behavior for that case.
        src: dom.getAttribute('data-src') ?? dom.getAttribute('src') ?? '',
        alt: dom.getAttribute('alt') || '',
        title: dom.getAttribute('title') || dom.getAttribute('alt') || '',
      }),
    },
  ],
  parseMarkdown: {
    match: ({ type }: any) => type === 'image',
    runner: (state: any, node: any, type: any) => {
      const url = node.url as string;
      const alt = node.alt as string;
      const title = node.title as string;
      state.addNode(type, {
        src: url,
        alt,
        title,
      });
    },
  },
  toMarkdown: {
    match: (node: ProsemirrorNode) => node.type.name === 'image',
    runner: (state: any, node: ProsemirrorNode) => {
      state.addNode('image', undefined, undefined, {
        title: node.attrs.title,
        url: node.attrs.src,
        alt: node.attrs.alt,
      });
    },
  },
}));
