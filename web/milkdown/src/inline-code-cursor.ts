// Inline-code cursor behavior: make the edges of a code span act as if the backticks
// were really there, with TWO cursor stops at each boundary.
//
// The problem: in WYSIWYG there are no visible backticks, so one document position at a
// code span's edge has to mean both "inside the code" and "outside it". ProseMirror's
// default (inclusive mark) picks "inside", which traps the cursor: typing after a span at
// the end of a line keeps extending the code. Flipping the mark to non-inclusive just
// inverts the trap (you can never extend). Runtime tracing (see docs/lessons) showed both
// failure modes in the real app.
//
// This plugin encodes the side in storedMarks instead:
//   - storedMarks null/with-code at the edge → INSIDE  (typing extends the code)
//   - storedMarks without code at the edge   → OUTSIDE (typing is plain text)
//
// Rules:
//   1. Fresh arrival at an edge (click, jump, or arriving from outside) defaults to
//      OUTSIDE — so the original "trapped at end of line" bug stays fixed.
//   2. Arriving at the right edge from inside the span (arrow/typing) keeps you INSIDE —
//      so extending the code while typing keeps working char after char.
//   3. ArrowLeft/ArrowRight at an edge toggle between the two stops without moving the
//      cursor, mirroring how the cursor would move across a literal backtick:
//        cod|e → code| (inside) → code`| (outside) → onward, and the reverse going left.
//
// The navigation semantics follow prosemirror-codemark's documented model (MIT, Curvenote;
// https://github.com/curvenote/editor) — but implemented without its fake-cursor
// decorations and click/appendTransaction machinery, which misrendered the caret and
// caused scroll jumps inside WKWebView.

import { schemaCtx } from '@milkdown/kit/core';
import type { Mark, MarkType, ResolvedPos } from '@milkdown/kit/prose/model';
import type { EditorState } from '@milkdown/kit/prose/state';
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import { Decoration, DecorationSet } from '@milkdown/kit/prose/view';
import { $prose } from '@milkdown/kit/utils';

/** Cursor sits just after the last character of a code run (nothing or plain text follows). */
function atRightEdge($pos: ResolvedPos, code: MarkType): boolean {
  const before = $pos.nodeBefore;
  const after = $pos.nodeAfter;
  return !!before && !!code.isInSet(before.marks) && (!after || !code.isInSet(after.marks));
}

/** Cursor sits just before the first character of a code run (nothing or plain text precedes). */
function atLeftEdge($pos: ResolvedPos, code: MarkType): boolean {
  const before = $pos.nodeBefore;
  const after = $pos.nodeAfter;
  return !!after && !!code.isInSet(after.marks) && (!before || !code.isInSet(before.marks));
}

/** The marks the next typed character would carry. */
function effectiveMarks(state: EditorState): readonly Mark[] {
  return state.storedMarks ?? state.selection.$from.marks();
}

function withoutCode(marks: readonly Mark[], code: MarkType): Mark[] {
  return marks.filter((m) => m.type !== code);
}

/**
 * The contiguous code run containing (or touching) the cursor, as [from, to] doc
 * positions, or null. Adjacent code-marked text nodes merge into one run.
 */
export function codeRunAround($pos: ResolvedPos, code: MarkType): [number, number] | null {
  const base = $pos.start();
  const runs: Array<[number, number]> = [];
  let current: [number, number] | null = null;
  $pos.parent.forEach((child, offset) => {
    if (code.isInSet(child.marks)) {
      const from = base + offset;
      const to = from + child.nodeSize;
      if (current && current[1] === from) {
        current[1] = to;
      } else {
        current = [from, to];
        runs.push(current);
      }
    } else {
      current = null;
    }
  });
  return runs.find(([from, to]) => $pos.pos >= from && $pos.pos <= to) ?? null;
}

export function buildInlineCodeCursorPlugin(code: MarkType | undefined): Plugin {
  return new Plugin({
    key: new PluginKey('inline-code-cursor'),
    props: {
      handleKeyDown(view, event) {
        if (!code) return false;
        if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return false;
        if (event.shiftKey || event.altKey || event.ctrlKey || event.metaKey) return false;
        if (view.composing) return false;
        const { state } = view;
        const { selection } = state;
        if (!selection.empty) return false;
        const $pos = selection.$from;
        const inside = !!code.isInSet(effectiveMarks(state));

        if (event.key === 'ArrowLeft') {
          if (atRightEdge($pos, code) && !inside) {
            // code`| → code|  (step inside the closing tick; cursor does not move)
            view.dispatch(state.tr.setStoredMarks([...$pos.marks()]));
            return true;
          }
          if (atLeftEdge($pos, code) && inside) {
            // `|code → |`code  (step outside the opening tick)
            view.dispatch(state.tr.setStoredMarks(withoutCode(effectiveMarks(state), code)));
            return true;
          }
        } else {
          if (atRightEdge($pos, code) && inside) {
            // code| → code`|  (step outside the closing tick)
            view.dispatch(state.tr.setStoredMarks(withoutCode(effectiveMarks(state), code)));
            return true;
          }
          if (atLeftEdge($pos, code) && !inside) {
            // |`code → `|code  (step inside the opening tick)
            view.dispatch(state.tr.setStoredMarks([code.create(), ...withoutCode(effectiveMarks(state), code)]));
            return true;
          }
        }
        return false;
      },

      // Visual "you are in code mode" signal: highlight the code run whenever the next
      // typed character would extend it. Derived from state on every render, so it can
      // never go stale — the highlight IS the inside/outside indicator at the boundary.
      decorations(state) {
        if (!code) return null;
        const sel = state.selection;
        if (!sel.empty) return null;
        if (!code.isInSet(effectiveMarks(state))) return null;
        const run = codeRunAround(sel.$from, code);
        if (!run) return null;
        return DecorationSet.create(state.doc, [Decoration.inline(run[0], run[1], { class: 'ff-code-inside' })]);
      },
    },

    // Default-to-OUTSIDE on fresh arrival at an edge. Without this, the inclusive mark
    // makes every edge position "inside" and the end-of-line trap returns.
    appendTransaction(_trs, oldState, newState) {
      if (!code) return null;
      const sel = newState.selection;
      if (!sel.empty) return null;
      // Explicit stored marks (set by the arrow handlers above, or by ⌘E) are a deliberate
      // choice of side — never override them.
      if (newState.storedMarks !== null) return null;
      const $pos = sel.$from;
      if (!code.isInSet($pos.marks())) return null; // typing here is already plain
      const before = $pos.nodeBefore;
      const after = $pos.nodeAfter;
      const strictlyInsideRun = !!before && !!code.isInSet(before.marks) && !!after && !!code.isInSet(after.marks);
      if (strictlyInsideRun) return null; // mid-span: code is correct
      // Moving ≤1 position while already "in code" is navigation/typing within the span
      // (cod|e → code|, or extending char by char) — keep the INSIDE state.
      const moved = Math.abs(sel.from - oldState.selection.from);
      const oldInside = !!code.isInSet(oldState.storedMarks ?? oldState.selection.$from.marks());
      if (moved <= 1 && oldInside) return null;
      return newState.tr.setStoredMarks(withoutCode($pos.marks(), code));
    },
  });
}

export const inlineCodeCursorPlugin = $prose((ctx) => buildInlineCodeCursorPlugin(ctx.get(schemaCtx).marks.inlineCode));
