// Ordered List Order Plugin for Milkdown
//
// Replaces the built-in `ordered_list` node schema (from
// @milkdown/preset-commonmark@7.18.0) to fix two upstream bugs that make the
// node's `order` attribute (the list's starting number) never actually show
// up in the rendered DOM or in serialized markdown — verified directly
// against the installed package source
// (node_modules/@milkdown/preset-commonmark/src/node/ordered-list.ts):
//
// - `toDOM` did `...(node.attrs.order === 1 ? {} : node.attrs.order)` —
//   spreading a bare JS number into an object contributes nothing, so a
//   `start` DOM attribute was never emitted regardless of `order`'s value.
//   Fixed to spread `{ start: node.attrs.order }` instead.
// - `toMarkdown` hardcoded `start: 1` unconditionally. Fixed to serialize
//   `node.attrs.order` (still defaulting sensibly if unset).
// - `parseMarkdown`'s runner never read mdast's `node.start` (the real
//   starting number CommonMark parsed, e.g. `2.` → start: 2) into the
//   `order` attr, so `order` silently reset to the schema default of 1 on
//   every re-parse. Fixed to read `node.start` when present.
//
// All three bugs previously swallowed (or, for parseMarkdown, would silently
// re-swallow on reload) the fix in api-content.ts's insertImage(), which
// needs a *real* `order` attribute to continue a split ordered list's
// numbering correctly (see the "split vs. deliberate restart" logic there).
//
// Registered by id via $node('ordered_list', ...): Milkdown's node registry
// (nodesCtx) replaces any existing entry sharing an id, so this REPLACES the
// built-in schema wholesale rather than extending it — $NodeSchema's
// `extendSchema()` was considered and rejected, since it produces a new
// $nodeSchema plugin with a different identity than the one preset-commonmark
// registers, and would not actually override the built-in registration.
//
// Must be `.use()`d AFTER `.use(commonmark)` (see main.ts) so the built-in
// `orderedListAttr` context slice this schema still relies on for its HTML
// attributes is already populated by the time our replacement's `toDOM` runs.
//
// content/attrs/parseDOM below are copied verbatim from the built-in schema;
// toDOM/toMarkdown/parseMarkdown all deliberately diverge from upstream (the
// three bug fixes above) — do NOT "helpfully" re-sync parseMarkdown with
// upstream (which drops `start` entirely) to look more like the other two
// blocks; that would silently reintroduce the reload-resets-numbering bug.

import { orderedListAttr } from '@milkdown/kit/preset/commonmark';
import type { Node as ProsemirrorNode } from '@milkdown/kit/prose/model';
import { $node } from '@milkdown/kit/utils';

export const orderedListOrderPlugin = $node('ordered_list', (ctx) => ({
  content: 'listItem+',
  group: 'block',
  attrs: {
    order: {
      default: 1,
      validate: 'number',
    },
    spread: {
      default: false,
      validate: 'boolean',
    },
  },
  parseDOM: [
    {
      tag: 'ol',
      getAttrs: (dom: HTMLElement) => ({
        spread: dom.dataset.spread,
        order: dom.hasAttribute('start') ? Number(dom.getAttribute('start')) : 1,
      }),
    },
  ],
  toDOM: (node: ProsemirrorNode) => [
    'ol',
    {
      ...ctx.get(orderedListAttr.key)(node),
      ...(node.attrs.order === 1 ? {} : { start: node.attrs.order }),
      'data-spread': node.attrs.spread,
    },
    0,
  ],
  parseMarkdown: {
    match: ({ type, ordered }: any) => type === 'list' && !!ordered,
    runner: (state: any, node: any, type: any) => {
      const spread = node.spread != null ? `${node.spread}` : 'true';
      // mdast's `node.start` is the actual starting number CommonMark parsed
      // (e.g. `2.` → start: 2). Without reading it here, `order` silently
      // falls back to the schema default of 1 on every re-parse — undoing
      // insertImage()'s split-continuation fix (api-content.ts) the moment a
      // document with a continued list is closed and reopened.
      const order = typeof node.start === 'number' ? node.start : 1;
      state.openNode(type, { spread, order }).next(node.children).closeNode();
    },
  },
  toMarkdown: {
    match: (node: ProsemirrorNode) => node.type.name === 'ordered_list',
    runner: (state: any, node: ProsemirrorNode) => {
      state.openNode('list', undefined, {
        ordered: true,
        start: node.attrs.order ?? 1,
        spread: node.attrs.spread === 'true',
      });
      state.next(node.content);
      state.closeNode();
    },
  },
}));
