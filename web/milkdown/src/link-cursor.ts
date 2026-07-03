// Link cursor behavior: stop a freshly-created link's boundary from swallowing
// whatever the user types next.
//
// The problem: ProseMirror's `link` mark is inclusive by default (Milkdown's compiled
// preset-commonmark schema sets no `inclusive` flag), so a caret sitting right at a link's
// edge can inherit the link mark for the next typed character. Both link-creation code paths
// (autolink-plugin.ts for bare `https://...` URLs, markdown-link-input-rule.ts for
// `[text](url)` syntax) originally tried a one-shot `.removeStoredMark(link)` inside their own
// creating transaction. Live diagnostic logging (a temporary plugin, since removed) proved
// that fix unreliable: a stray `storedMarks` value can reappear on a transaction AFTER the one
// that created the link, so the one-shot clear doesn't always survive to the user's next
// keystroke — sometimes several consecutive characters get absorbed into the link before it
// self-corrects.
//
// This plugin is the single owner of link-boundary state. Its `appendTransaction` re-checks
// the EFFECTIVE marks (storedMarks if set, else the position-derived marks at the cursor)
// after every transaction — not just link-creation ones — and clears the link mark whenever
// the cursor sits at a boundary rather than strictly inside an existing link run. This mirrors
// the self-healing precedent set for inline code spans (inline-code-cursor.ts, fixed
// 2026-06-12) — a one-shot clear was tried and reverted there too, and only a persistent
// appendTransaction check held up.
//
// Unlike code spans, links have no invisible delimiter for the user to step into/out of, so
// there is no arrow-key handling and no "you are inside a link" decoration ring here — this
// plugin only fixes the boundary; it does not add a link "mode".

import { schemaCtx } from '@milkdown/kit/core';
import type { MarkType } from '@milkdown/kit/prose/model';
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import { $prose } from '@milkdown/kit/utils';

export function buildLinkCursorPlugin(link: MarkType | undefined): Plugin {
  return new Plugin({
    key: new PluginKey('link-cursor'),

    appendTransaction(_trs, _oldState, newState) {
      if (!link) return null;
      if (!newState.selection.empty) return null;
      const $pos = newState.selection.$from;
      const effective = newState.storedMarks ?? $pos.marks();
      if (!link.isInSet(effective)) return null; // next char already plain — nothing to fix

      const before = $pos.nodeBefore;
      const after = $pos.nodeAfter;
      const strictlyInside = !!before && !!link.isInSet(before.marks) && !!after && !!link.isInSet(after.marks);
      if (strictlyInside) return null; // editing link text mid-run — keep the mark

      return newState.tr.setStoredMarks(effective.filter((m) => m.type !== link));
    },
  });
}

export const linkCursorPlugin = $prose((ctx) => buildLinkCursorPlugin(ctx.get(schemaCtx).marks.link));
