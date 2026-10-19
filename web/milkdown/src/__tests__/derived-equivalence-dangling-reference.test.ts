// @vitest-environment jsdom
//
// Round F3b of t-18b7fa48: `docsEquivalentIgnoringDerived` (derived-equivalence.ts) and a reference whose definition is missing.
//
// The real-app finding (testTypeDuringUndoingNoticeAtPersonPace_book6): after a section delete, typing, the footnote renumber and the
// Notes push, taking the typing and the renumber back as text leaves the references on their OLD numbers while the Notes (already
// rebuilt for the new numbers) lack the definitions of some of them. The live document `a` then has references with NO definition
// where the saved copy `b` holds one, and the comparison said "different" for ever (`footnote text differs at reference N:
// a=no definition b=(size=..)`), so Cmd-Z never reached the section. These tests pin the rule on bare documents:
//   * a reference without a definition in the live document, whose definition the saved copy holds, is NOT a difference;
//   * everything else stays a difference: the reverse direction, two different texts, a typed word anywhere in the body, a label
//     defined twice, text in an orphan on both sides.
// (The end-to-end shape, with the real push and the real undo presses, is BS2 in structural-undo-derived-rewrites.test.ts.)

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { history as historyPlugin } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { Node } from '@milkdown/kit/prose/model';
import { Transform } from '@milkdown/kit/prose/transform';
import { afterEach, describe, expect, it } from 'vitest';
import { docsEquivalentIgnoringDerived, explainDerivedDifference } from '../derived-equivalence';
import { setEditorInstance } from '../editor-state';
import { footnotePlugin } from '../footnote-plugin';

let current: Editor | null = null;

afterEach(async () => {
  if (current) {
    await current.destroy();
    current = null;
  }
  setEditorInstance(null);
  delete (window as any).webkit;
});

const NOTES_DOC = [
  '# Alpha',
  'Alpha text with a note.[^1]',
  '# Beta',
  'Beta text with a note.[^2] And another.[^3]',
  '# Gamma',
  'Gamma plain text.',
  '# Notes',
  '[^1]: First note.',
  '[^2]: Second note.',
  '[^3]: Third note.',
].join('\n\n');

async function makeDoc(markdown: string = NOTES_DOC): Promise<Node> {
  (window as any).webkit = { messageHandlers: { errorHandler: { postMessage: () => {} } } };
  const div = document.createElement('div');
  document.body.appendChild(div);
  const editor = await Editor.make()
    .config((ctx) => {
      ctx.set(rootCtx, div);
      ctx.set(defaultValueCtx, markdown);
    })
    .use(footnotePlugin)
    .use(commonmark)
    .use(gfm)
    .use(historyPlugin)
    .create();
  current = editor;
  setEditorInstance(editor);
  return editor.ctx.get(editorViewCtx).state.doc;
}

type Edit = (t: Transform, d: Node) => void;
/** Applies `f` and asserts the document really changed: a no-op edit would make every check below pass for nothing. */
const edit = (doc: Node, f: Edit): Node => {
  const t = new Transform(doc);
  f(t, doc);
  expect(t.doc.eq(doc), 'premise: the edit changed the document').toBe(false);
  return t.doc;
};
const defParagraph = (text: string) => (n: Node) =>
  n.firstChild?.type.name === 'footnote_def' && n.textContent.includes(text);
function top(doc: Node, pred: (n: Node) => boolean): { node: Node; pos: number } {
  let hit: { node: Node; pos: number } | null = null;
  doc.forEach((node, pos) => {
    if (!hit && pred(node)) hit = { node, pos };
  });
  expect(hit).not.toBeNull();
  return hit as unknown as { node: Node; pos: number };
}
const withoutDefinition = (doc: Node, text: string): Node =>
  edit(doc, (t, d) => {
    const p = top(d, defParagraph(text));
    t.delete(p.pos, p.pos + p.node.nodeSize);
  });
const contentEnd = (h: { node: Node; pos: number }) => h.pos + h.node.nodeSize - 1;

describe('a reference with no definition in the live document (round F3b)', () => {
  it('D1 (FAILS before round F3b): the live document lacks the definition of a reference that the saved copy defines: equivalent', async () => {
    const saved = await makeDoc();
    const live = withoutDefinition(saved, 'Second note.');
    expect(docsEquivalentIgnoringDerived(live, saved)).toBe(true);
    expect(explainDerivedDifference(live, saved)).toBeNull();
  });

  it('D2: the reverse (the live document defines a reference the saved copy leaves without a definition) stays different', async () => {
    const saved = await makeDoc();
    const live = withoutDefinition(saved, 'Second note.');
    const reason = explainDerivedDifference(saved, live) ?? '';
    expect(docsEquivalentIgnoringDerived(saved, live)).toBe(false);
    expect(reason).toContain('footnote text differs at reference 1 of 3');
    expect(reason).toContain('a=(size=');
    expect(reason).toContain('b=no definition');
  });

  it('D3: two different texts for the same reference stay different, with or without another reference left undefined', async () => {
    const saved = await makeDoc();
    const edited = edit(saved, (t, d) =>
      t.insert(contentEnd(top(d, defParagraph('Third note.'))), saved.type.schema.text('X'))
    );
    expect(docsEquivalentIgnoringDerived(edited, saved), 'a footnote text the user changed').toBe(false);
    const edited2 = withoutDefinition(edited, 'Second note.');
    expect(docsEquivalentIgnoringDerived(edited2, saved), 'one definition missing AND another one edited').toBe(false);
    expect(explainDerivedDifference(edited2, saved)).toContain('footnote text differs at reference 2 of 3');
  });

  it('D4: a typed word anywhere in the body keeps the documents different even when a definition is missing', async () => {
    const saved = await makeDoc();
    const live = withoutDefinition(saved, 'Second note.');
    const typed = edit(live, (t, d) =>
      t.insert(contentEnd(top(d, (n) => n.textContent.startsWith('Gamma plain'))), saved.type.schema.text('X'))
    );
    expect(docsEquivalentIgnoringDerived(typed, saved)).toBe(false);
    expect(explainDerivedDifference(typed, saved)).toContain('body differs at body node');
  });

  it('D5: a deleted reference (the count differs) stays different', async () => {
    const saved = await makeDoc();
    const live = edit(withoutDefinition(saved, 'Second note.'), (t, d) => {
      let pos = -1;
      d.descendants((n, p) => {
        if (pos < 0 && n.type.name === 'footnote_ref' && String(n.attrs.label) === '2') pos = p;
      });
      t.delete(pos, pos + 1);
    });
    expect(docsEquivalentIgnoringDerived(live, saved)).toBe(false);
  });

  it('D6: a label defined twice stays ambiguous, and text typed into an orphan definition on both sides stays different', async () => {
    const saved = await makeDoc();
    const dup = edit(saved, (t, d) => {
      let pos = -1;
      d.descendants((n, p) => {
        if (pos < 0 && n.type.name === 'footnote_def' && String(n.attrs.label) === '1') pos = p;
      });
      t.setNodeMarkup(pos, undefined, { label: '2' });
    });
    expect(docsEquivalentIgnoringDerived(dup, saved)).toBe(false);
    expect(explainDerivedDifference(dup, saved)).toBe('a footnote label is defined twice in a');

    // An orphan on both sides (the reference to footnote 1 is gone from both), with different text in it.
    const noRef = (doc: Node): Node =>
      edit(doc, (t, d) => {
        let pos = -1;
        d.descendants((n, p) => {
          if (pos < 0 && n.type.name === 'footnote_ref' && String(n.attrs.label) === '1') pos = p;
        });
        t.delete(pos, pos + 1);
      });
    const orphanA = noRef(saved);
    const orphanB = edit(orphanA, (t, d) =>
      t.insert(contentEnd(top(d, defParagraph('First note.'))), saved.type.schema.text('X'))
    );
    expect(docsEquivalentIgnoringDerived(orphanB, orphanA), 'orphan text on both sides').toBe(false);
    expect(explainDerivedDifference(orphanB, orphanA)).toContain('orphan definitions differ');
    // ... and with a definition missing from the live side as well: still different, the orphan text is the user's.
    expect(docsEquivalentIgnoringDerived(withoutDefinition(orphanB, 'Second note.'), orphanA)).toBe(false);
  });

  // The judge's must-fix on round F3b: the rule "a reference with no definition in the live document is not a difference" must not
  // combine with the older rule "an orphan definition in the live document is ignored when the saved copy has none" into a data-loss
  // hole. Live: reference 2 has no definition (its definition was relabelled to 9, a label no reference carries) and that orphan
  // holds text the user typed; saved: reference 2 is defined, no orphan. Swapping to the saved copy would drop the typed text.
  it("D11 (FAILS before the judge's must-fix): an orphan with user-edited text in the live document, next to a reference that lacks its definition, is a difference; the same relabel without the typed text is not", async () => {
    const saved = await makeDoc();
    const relabelled = (typed: boolean): Node =>
      edit(saved, (t, d) => {
        const p = top(d, defParagraph('Second note.'));
        t.setNodeMarkup(p.pos + 1, undefined, { label: '9' }); // the footnote_def atom is the paragraph's first child
        if (typed) t.insert(contentEnd(p), saved.type.schema.text(' TYPED'));
      });
    const control = relabelled(false);
    expect(
      explainDerivedDifference(control, saved),
      'control: the relabelled definition, text unchanged, is in the saved copy: equivalent'
    ).toBeNull();
    const typedLive = relabelled(true);
    const reason = explainDerivedDifference(typedLive, saved) ?? '';
    expect(
      docsEquivalentIgnoringDerived(typedLive, saved),
      `the typed footnote text must keep the documents different (${reason})`
    ).toBe(false);
    expect(reason).toContain('orphan definition in a not in b while a reference lacks its definition');
    expect(reason, 'a reason never carries document text').not.toContain('TYPED');
  });
});

// Round F3c of t-18b7fa48: the saved copy defined a label twice (the same footnote's definition, with the same text) after the later
// Notes push was rebased onto it, and "a footnote label is defined twice" made every comparison "different" for ever. The rule: a label
// is ambiguous only when a reference carries it and the definitions competing for it say different things.
describe('a footnote label defined twice (round F3c)', () => {
  /** `doc` with a copy of the definition paragraph containing `text` right after it (the same label, the same text). */
  const withCopyOfDefinition = (doc: Node, text: string): Node =>
    edit(doc, (t, d) => {
      const p = top(d, defParagraph(text));
      t.insert(p.pos + p.node.nodeSize, p.node);
    });
  /** `doc` with the references to footnote `label` removed (its definition becomes an orphan). */
  const withoutReferenceTo = (doc: Node, label: string): Node =>
    edit(doc, (t, d) => {
      let pos = -1;
      d.descendants((n, p) => {
        if (pos < 0 && n.type.name === 'footnote_ref' && String(n.attrs.label) === label) pos = p;
      });
      t.delete(pos, pos + 1);
    });

  it('D7 (FAILS before round F3c): a referenced label defined twice with the SAME text is the same footnote twice: equivalent, both ways', async () => {
    const saved = await makeDoc();
    const twice = withCopyOfDefinition(saved, 'Second note.');
    expect(explainDerivedDifference(twice, saved)).toBeNull();
    expect(explainDerivedDifference(saved, twice)).toBeNull();
    expect(docsEquivalentIgnoringDerived(twice, twice)).toBe(true);
  });

  it('D8: a referenced label defined twice with DIFFERENT texts stays ambiguous, whichever copy was edited', async () => {
    const saved = await makeDoc();
    const twice = withCopyOfDefinition(saved, 'Second note.');
    // The user types into one of the two copies: the texts now differ and the document cannot say which one the reference stands for.
    const edited = edit(twice, (t, d) => {
      let hit = -1;
      d.forEach((node, pos) => {
        if (hit < 0 && defParagraph('Second note.')(node)) hit = pos;
      });
      t.insert(hit + d.nodeAt(hit)!.nodeSize - 1, saved.type.schema.text(' TYPED'));
    });
    expect(explainDerivedDifference(edited, saved)).toBe('a footnote label is defined twice in a');
    expect(explainDerivedDifference(saved, edited)).toBe('a footnote label is defined twice in b');
    expect(docsEquivalentIgnoringDerived(edited, twice)).toBe(false);
  });

  it('D9 (FAILS before round F3c): a label no reference carries, defined twice with different texts, is two orphans: ignored when the other side has none, compared as a multiset when both have some', async () => {
    const base = await makeDoc();
    // Footnote 1's reference is gone, so its definition is an orphan; a second orphan definition of the same label with another text.
    const orphan = withoutReferenceTo(base, '1');
    const twoOrphans = edit(orphan, (t, d) => {
      const p = top(d, defParagraph('First note.'));
      const second = p.node.type.create(p.node.attrs, p.node.content.cut(0, p.node.content.size - 1), p.node.marks);
      t.insert(p.pos + p.node.nodeSize, second);
      t.insert(p.pos + p.node.nodeSize + second.nodeSize - 1, base.type.schema.text(' Other.'));
    });
    const noOrphans = withoutDefinition(orphan, 'First note.');
    expect(docsEquivalentIgnoringDerived(twoOrphans, noOrphans), 'the other side has no orphans: ignored').toBe(true);
    expect(docsEquivalentIgnoringDerived(noOrphans, twoOrphans)).toBe(true);
    // Both sides have orphans and the texts differ: the orphan text is the user's.
    expect(docsEquivalentIgnoringDerived(twoOrphans, orphan), 'both sides have orphans, different multisets').toBe(
      false
    );
    expect(explainDerivedDifference(twoOrphans, orphan)).toContain('orphan definitions differ');
  });

  it('D10: duplicates never hide a typed body word or an edit of a still-referenced footnote', async () => {
    const saved = await makeDoc();
    const twice = withCopyOfDefinition(saved, 'Second note.');
    const typed = edit(twice, (t, d) =>
      t.insert(contentEnd(top(d, (n) => n.textContent.startsWith('Gamma plain'))), saved.type.schema.text('X'))
    );
    expect(docsEquivalentIgnoringDerived(typed, saved)).toBe(false);
    expect(explainDerivedDifference(typed, saved)).toContain('body differs at body node');
    const editedThird = edit(twice, (t, d) =>
      t.insert(contentEnd(top(d, defParagraph('Third note.'))), saved.type.schema.text('X'))
    );
    expect(docsEquivalentIgnoringDerived(editedThird, saved)).toBe(false);
    expect(explainDerivedDifference(editedThird, saved)).toContain('footnote text differs at reference 2 of 3');
  });
});
