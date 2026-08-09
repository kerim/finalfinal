// Bibliography End Marker Plugin for Milkdown
// Renders invisibly in editor, serializes to <!-- ::auto-bibliography-end:: --> in markdown.
//
// Companion to bibliography-plugin.ts's opening `<!-- ::auto-bibliography:: -->` marker:
// this one closes the section instead of opening it. See BlockParser.bibliographyEndMarker
// (Swift side) for the full rationale — the auto-generated bibliography is always the LAST
// thing in the document with no closing heading, so a full reparse (Source Mode's debounced
// re-parse, and critically the reparse that runs immediately before every PDF export) has no
// way to tell "one more bibliography entry" apart from "the user's first paragraph typed
// below the references" without an explicit, position-independent terminator written into
// the document's own text.
//
// Simpler than bibliography-plugin.ts's remark visitor: the terminator is always its own
// blank-line-separated fragment (BlockParser+Splitting.swift's RawBlockSplitter splits it
// out on both sides even when hand-typed glued to neighboring content — see that file's
// consumeContentLine), never glued to preceding content the way the opening marker is glued
// to its heading. No "remainder" splitting is needed here.

import type { MilkdownPlugin } from '@milkdown/kit/ctx';
import { keymap } from '@milkdown/kit/prose/keymap';
import type { Node } from '@milkdown/kit/prose/model';
import type { EditorState } from '@milkdown/kit/prose/state';
import { TextSelection } from '@milkdown/kit/prose/state';
import { $node, $prose, $remark } from '@milkdown/kit/utils';
import type { Root } from 'mdast';
import { visit } from 'unist-util-visit';

const MARKER_TEXT = '<!-- ::auto-bibliography-end:: -->';
const NODE_NAME = 'auto_bibliography_end';

// Remark plugin to convert the terminator HTML comment to a custom node type.
// Runs during initial parse phase, before HTML filtering strips it.
const remarkPlugin = $remark('bibliography-end-marker', () => () => (tree: Root) => {
  visit(tree, 'html', (node: any) => {
    if (node.value?.trim() === MARKER_TEXT) {
      node.type = 'autoBibliographyEnd';
      delete node.value;
    }
  });
});

// Define the auto_bibliography_end node — invisible, non-interactive, atom (produces zero
// visible content and can't be entered/edited, matching how it produces ZERO Blocks on the
// Swift side — see BlockParser.parse()'s terminator handling).
const bibliographyEndMarkerNode = $node(NODE_NAME, () => ({
  group: 'block',
  atom: true,
  selectable: false,

  parseDOM: [{ tag: 'div.auto-bibliography-end-marker' }],

  toDOM: () =>
    [
      'div',
      {
        class: 'auto-bibliography-end-marker',
        style: 'display:none',
        contenteditable: 'false',
      },
      '',
    ] as const,

  parseMarkdown: {
    match: (node: any) => node.type === 'autoBibliographyEnd',
    runner: (state: any, _node: any, type: any) => {
      state.addNode(type);
    },
  },

  toMarkdown: {
    match: (node: Node) => node.type.name === NODE_NAME,
    runner: (state: any) => {
      state.addNode('html', undefined, MARKER_TEXT);
    },
  },
}));

// Enter-key placement fix (real bug, not optional — see the plan/task notes this shipped
// with). ProseMirror's default Enter behavior (splitBlock, bound by commonmark's own base
// keymap) inserts a new paragraph as the immediate next sibling of the block the cursor is
// in. Since the terminator is a top-level sibling atom positioned right after the last
// bibliography entry, pressing Enter at the end of that entry would insert the new paragraph
// BEFORE the terminator — still positionally inside the section on the next reparse,
// reproducing the exact bug this whole mechanism exists to fix on the single most natural
// way a user would type: Enter, then type.
//
// Registered as a `keymap()` plugin (not a bare `handleKeyDown` prop) and placed in main.ts's
// `.use()` chain BEFORE `.use(commonmark)` — the same registration technique
// citation-plugin.ts's `citationDeleteKeymap` uses (see that plugin's doc comment and
// main.ts's plugin-order comments). The precedence this actually relies on, though, is NOT
// `.use()` ordering: every `$prose`-defined plugin (this one and citationDeleteKeymap alike)
// is appended to Milkdown's own `prosePluginsCtx` array, and `editorState`
// (`@milkdown/core`) always assembles the final ProseMirror `plugins` list as `[...prosePlugins,
// stateTrackerPlugin, inputRules, keymap(km.build())]` — i.e. EVERY `$prose` plugin sits ahead
// of Milkdown's own single merged base+preset keymap plugin (the one holding commonmark's
// Enter→splitBlock binding) in that list regardless of which `.use()` call happened first.
// ProseMirror's `handleKeyDown` prop consults `state.plugins` in that fixed array order and
// stops at the first plugin that returns `true`, so this plugin's `keymap({ Enter: ... })`
// always gets first refusal on every Enter keypress — falling through (returning `false`) to
// commonmark's own binding for every case except the one this handles — even if a future
// reshuffle moved this plugin's `.use()` call after `.use(commonmark)`.
const bibliographyEndEnterKeymap = $prose(() => {
  return keymap({
    Enter: (state, dispatch) => {
      const { $from, empty } = state.selection;
      if (!empty) return false;
      // Cursor must sit at the very end of its enclosing textblock — otherwise this is an
      // ordinary mid-text or mid-document Enter, which must fall through to splitBlock.
      if ($from.parentOffset !== $from.parent.content.size) return false;

      // The node immediately following the cursor's enclosing block, at the SAME depth —
      // i.e. the top-level sibling right after the textblock the cursor is in.
      const afterPos = $from.after($from.depth);
      const nodeAfter = state.doc.nodeAt(afterPos);
      if (!nodeAfter || nodeAfter.type.name !== NODE_NAME) return false;

      const paragraphType = state.schema.nodes.paragraph;
      if (!paragraphType) return false;

      // Insert AFTER the terminator atom (not before it) — this is the actual fix.
      const insertPos = afterPos + nodeAfter.nodeSize;
      let tr = state.tr.insert(insertPos, paragraphType.create());
      tr = tr.setSelection(TextSelection.near(tr.doc.resolve(insertPos + 1)));
      if (dispatch) dispatch(tr.scrollIntoView());
      return true;
    },
  });
});

// Delete-key protection. Only bare `Backspace` got a custom handler above via Milkdown's own
// `overrideBaseKeymap` (`@milkdown/core`): it replaces `Backspace` with `joinTextblockBackward`,
// a strictly textblock-to-textblock join that never even looks at an adjacent atom. Every
// OTHER delete-family key stays bound to prosemirror-commands' original `backspace`/`del`
// chains (`deleteSelection` → `joinBackward`/`joinForward` → `selectNodeBackward`/
// `selectNodeForward`), and — confirmed by reading the bundled `prosemirror-commands` source
// directly, not assumed — both `joinBackward` and `joinForward` end with an unconditional "if
// the adjacent node is an atom, delete it" fallback that ignores this node's `selectable:
// false` entirely.
//
// The full reachable set, confirmed against the bundled `prosemirror-keymap` and
// `prosemirror-commands` `macBaseKeymap` (what actually runs at runtime on macOS, not the
// plain `baseKeymap`) — ten bindings in total, none overlapping:
//   - `Delete`, `Mod-Delete` (`del`), `Ctrl-d` (macOS alias for `Delete`) — forward, i.e.
//     `direction: 'after'`.
//   - `Mod-Backspace`, `Shift-Backspace` (`backspace`) — backward, i.e. `direction: 'before'`.
//   - `Alt-Backspace` — macOS's word-delete-backward gesture (Option+Backspace), extremely
//     common in everyday editing — bound by `macBaseKeymap` straight to `Mod-Backspace`'s
//     dangerous chain. NOT covered by the `Mod-Backspace` binding above: `prosemirror-keymap`
//     normalizes `"Mod-"` to `"Meta-"` (Cmd) on Mac, never to `"Alt-"`, so `Mod-Backspace` and
//     `Alt-Backspace` are two entirely different key combinations. Backward.
//   - `Ctrl-h` — `macBaseKeymap` binds this straight to the original unguarded `backspace`
//     chain too. Backward.
//   - `Ctrl-Alt-Backspace`, `Alt-Delete`, `Alt-d` — all three bound by `macBaseKeymap` to
//     `Mod-Delete`'s dangerous chain. Forward.
// Milkdown's own `overrideBaseKeymap` only ever reassigns bare `Backspace` — none of these
// other nine are touched by anything already in the app before this plugin runs.
//
// `isBibliographyEndMarkerAdjacent` is exported (not inlined in the `keymap()` call below) so
// it can be exercised directly in tests, mirroring how citation-plugin.ts's
// `citationDeleteKeymap` extracts its own shared logic into citation-delete.ts's
// `buildCitationDeleteTransaction` for the same reason.
/**
 * Whether the top-level document sibling immediately `direction` of the cursor's enclosing
 * block — i.e. the node a `joinBackward`/`joinForward`-family command would find and delete
 * under the atom fallback described above — is the terminator atom. `direction: 'after'`
 * mirrors the Enter handler's own `$from.after($from.depth)` / `nodeAt` lookup above;
 * `direction: 'before'` is its symmetric counterpart, using `$from.before($from.depth)` and
 * `.nodeBefore` on the resolved boundary position instead (the standard ProseMirror idiom for
 * "the sibling ending exactly at this position" — the same one prosemirror-commands' own
 * `findCutBefore`/`atBlockStart` machinery relies on internally).
 */
export function isBibliographyEndMarkerAdjacent(state: EditorState, direction: 'before' | 'after'): boolean {
  const { $from, empty } = state.selection;
  if (!empty) return false;

  if (direction === 'after') {
    // Cursor must sit at the very end of its enclosing textblock, or there is no "next
    // sibling" to check yet — this is ordinary mid-text deletion.
    if ($from.parentOffset !== $from.parent.content.size) return false;
    const nodeAfter = state.doc.nodeAt($from.after($from.depth));
    return !!nodeAfter && nodeAfter.type.name === NODE_NAME;
  }

  // Cursor must sit at the very start of its enclosing textblock.
  if ($from.parentOffset !== 0) return false;
  const nodeBefore = state.doc.resolve($from.before($from.depth)).nodeBefore;
  return !!nodeBefore && nodeBefore.type.name === NODE_NAME;
}

// Each binding returns `true` WITHOUT dispatching a transaction exactly when the keystroke
// would otherwise reach the atom-delete fallback — a deliberate no-op, matching what bare
// Backspace already does for this same adjacency (see the doc comment above) — and `false`
// everywhere else, falling through to normal editing untouched.
const bibliographyEndDeleteKeymap = $prose(() => {
  return keymap({
    Delete: (state) => isBibliographyEndMarkerAdjacent(state, 'after'),
    'Mod-Delete': (state) => isBibliographyEndMarkerAdjacent(state, 'after'),
    'Ctrl-d': (state) => isBibliographyEndMarkerAdjacent(state, 'after'),
    'Ctrl-Alt-Backspace': (state) => isBibliographyEndMarkerAdjacent(state, 'after'),
    'Alt-Delete': (state) => isBibliographyEndMarkerAdjacent(state, 'after'),
    'Alt-d': (state) => isBibliographyEndMarkerAdjacent(state, 'after'),
    'Mod-Backspace': (state) => isBibliographyEndMarkerAdjacent(state, 'before'),
    'Shift-Backspace': (state) => isBibliographyEndMarkerAdjacent(state, 'before'),
    'Alt-Backspace': (state) => isBibliographyEndMarkerAdjacent(state, 'before'),
    'Ctrl-h': (state) => isBibliographyEndMarkerAdjacent(state, 'before'),
  });
});

export const bibliographyEndMarkerPlugin: MilkdownPlugin[] = [
  remarkPlugin,
  bibliographyEndMarkerNode,
  bibliographyEndEnterKeymap,
  bibliographyEndDeleteKeymap,
].flat();
