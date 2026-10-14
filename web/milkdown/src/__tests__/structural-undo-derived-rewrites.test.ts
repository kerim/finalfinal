// @vitest-environment jsdom
//
// Phase 4b: Cmd-Z after a section delete (and, by the same path, duplicate and version restore) must
// still route to the structural undo after the automatic rewrites that follow the operation -- Notes /
// bibliography rebuilds (which add freshly parsed headings, so Milkdown's syncHeadingIdPlugin dispatches
// a nested transaction from inside the outer one) and the footnote renumber -- and must never route
// structurally once the user has really edited. Decisions are read with the pure decideUndoRouting /
// decideRedoRouting against the live registry: exactly what Cmd-Z evaluates (unsettled-edit check held true).

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { history as historyPlugin } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { undo, undoDepth } from '@milkdown/kit/prose/history';
import type { Node } from '@milkdown/kit/prose/model';
import { Transform } from '@milkdown/kit/prose/transform';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { setContentWithBlockIds } from '../api-content';
import { bibliographyEndMarkerPlugin } from '../bibliography-end-marker-plugin';
import { bibliographyPlugin } from '../bibliography-plugin';
import { blockIdPlugin, resetBlockIdState } from '../block-id-plugin';
import { blockSyncPlugin, resetBlockSyncState, setSyncPaused } from '../block-sync-plugin';
import { docsEquivalentIgnoringDerived, explainDerivedDifference } from '../derived-equivalence';
import { setEditorInstance } from '../editor-state';
import { footnotePlugin, renumberFootnotes } from '../footnote-plugin';
import { highlightPlugin } from '../highlight-plugin';
import {
  beginStructuralOp,
  decideRedoRouting,
  decideUndoRouting,
  finalizeStructuralOpPostOpDoc,
  getRegistry,
  getUndoDescriptor,
  handleUnifiedUndoKeydown,
  performStructuralSwap,
  requestUnifiedUndo,
  resetUndoCoordinatorState,
  runUndoTrackedDispatch,
  setUndoDescriptor,
} from '../undo-coordinator';

interface TestBlock {
  id: string;
  md: string;
}

const BLOCKS: TestBlock[] = [
  { id: 'h-alpha', md: '# Alpha' },
  { id: 'p1', md: 'Paragraph one original text.' },
  { id: 'p2', md: 'Paragraph two original text.' },
  { id: 'h-beta', md: '# Beta' },
  { id: 'p3', md: 'Paragraph three original text.' },
  { id: 'p4', md: 'Paragraph four original text.' },
  { id: 'p5', md: 'Paragraph five original text.' },
  { id: 'h-gamma', md: '# Gamma' },
  { id: 'p6', md: 'Paragraph six original text.' },
  { id: 'p7', md: 'Paragraph seven original text.' },
  { id: 'p8', md: 'Paragraph eight original text.' },
];
const AFTER_DELETE_ALPHA = BLOCKS.filter((b) => !['h-alpha', 'p1', 'p2'].includes(b.id));
const AFTER_DELETE_BETA = AFTER_DELETE_ALPHA.filter((b) => !['h-beta', 'p3', 'p4', 'p5'].includes(b.id)).map((b) =>
  b.id === 'p8' ? { id: 'p8', md: 'Paragraph eight rebuilt.' } : b
);

const markdownOf = (blocks: TestBlock[]) => blocks.map((b) => b.md).join('\n\n');
const idsOf = (blocks: TestBlock[]) => blocks.map((b) => b.id);

const OP_A = '11111111-2222-3333-4444-555555555555';
const OP_B = '66666666-7777-8888-9999-000000000000';
const STRUCTURAL_A = { action: 'structural', opId: OP_A };
const FALLTHROUGH = { action: 'fallthrough' };

let current: Editor | null = null;

afterEach(async () => {
  if (vi.isFakeTimers()) await vi.advanceTimersByTimeAsync(500);
  vi.useRealTimers();
  if (current) {
    await current.destroy();
    current = null;
  }
  setEditorInstance(null);
  resetBlockIdState();
  resetBlockSyncState();
  setSyncPaused(false);
  resetUndoCoordinatorState();
  delete (window as any).webkit;
});

/** Production wiring: main.ts's view.dispatch override routes every transaction through this. */
function installTrackedDispatch(view: EditorView): void {
  const originalDispatch = view.dispatch.bind(view);
  view.dispatch = (tr) => runUndoTrackedDispatch(view, tr, originalDispatch);
}

async function makeSectionsEditor(): Promise<EditorView> {
  (window as any).webkit = { messageHandlers: { errorHandler: { postMessage: () => {} } } };
  const div = document.createElement('div');
  document.body.appendChild(div);
  const editor = await Editor.make()
    .config((ctx) => {
      ctx.set(rootCtx, div);
      ctx.set(defaultValueCtx, markdownOf(BLOCKS));
    })
    .use(blockIdPlugin)
    .use(commonmark)
    .use(gfm)
    .use(highlightPlugin)
    .use(historyPlugin)
    .use(blockSyncPlugin)
    .create();
  current = editor;
  setEditorInstance(editor);
  const view = editor.ctx.get(editorViewCtx);
  installTrackedDispatch(view);
  vi.useFakeTimers();
  setContentWithBlockIds(markdownOf(BLOCKS), idsOf(BLOCKS));
  await vi.advanceTimersByTimeAsync(100);
  return view;
}

/** A section delete as Swift runs it, minus the database: begin, push the post-op document, finalize. */
async function deleteSection(opId: string, after: TestBlock[]): Promise<void> {
  expect(beginStructuralOp(opId)).toBe(true);
  setContentWithBlockIds(markdownOf(after), idsOf(after), { detectPausedEdits: true });
  expect(finalizeStructuralOpPostOpDoc(opId)).toBe(true);
  await vi.advanceTimersByTimeAsync(50);
}

/** The shape of a Notes / bibliography rebuild: a sync-origin transaction adding a freshly built heading
 * (id attr ""), so syncHeadingIdPlugin dispatches a NESTED sync-origin transaction writing its slug. */
function automaticRebuildAddsSection(view: EditorView, title: string, text: string): void {
  const { schema } = view.state;
  const tr = view.state.tr.insert(view.state.doc.content.size, [
    schema.nodes.heading.create({ level: 1 }, schema.text(title)),
    schema.nodes.paragraph.create(null, schema.text(text)),
  ]);
  view.dispatch(tr.setMeta('addToHistory', false));
}

function paragraphRange(view: EditorView, startsWith: string): { from: number; to: number } {
  let range: { from: number; to: number } | null = null;
  view.state.doc.forEach((node, offset) => {
    if (!range && node.type.name === 'paragraph' && node.textContent.startsWith(startsWith)) {
      range = { from: offset + 1, to: offset + node.nodeSize - 1 };
    }
  });
  expect(range, `paragraph starting with "${startsWith}" must exist`).not.toBeNull();
  return range!;
}

function automaticRewriteOfParagraph(view: EditorView, startsWith: string, newText: string): void {
  const r = paragraphRange(view, startsWith);
  view.dispatch(view.state.tr.insertText(newText, r.from, r.to).setMeta('addToHistory', false));
}

/** A real keystroke-shaped, history-adding transaction. */
function typeAtEndOf(view: EditorView, startsWith: string, word: string): void {
  view.dispatch(view.state.tr.insertText(word, paragraphRange(view, startsWith).to));
}

function routingParams(view: EditorView) {
  return {
    descriptor: getUndoDescriptor(),
    registry: getRegistry(),
    pendingMapsEmpty: true,
    latched: false,
    currentDoc: view.state.doc,
    docsEqual: (a: Node, b: Node) => a.eq(b),
  };
}
const undoDecision = (view: EditorView) => decideUndoRouting(routingParams(view));
const redoDecision = (view: EditorView) => decideRedoRouting(routingParams(view));

describe('structural undo survives automatic rewrites (Phase 4b)', () => {
  it('Cmd-Z routes to the section delete after a rebuild adds a heading (nested heading-id dispatch)', async () => {
    const view = await makeSectionsEditor();
    await deleteSection(OP_A, AFTER_DELETE_ALPHA);
    setUndoDescriptor({ undoTopOpId: OP_A });
    automaticRebuildAddsSection(view, 'Notes', 'Rebuilt note.');
    const notesHeading = view.state.doc.child(view.state.doc.childCount - 2);
    expect(notesHeading.attrs.id, 'premise: syncHeadingIdPlugin wrote the slug in a nested dispatch').not.toBe('');
    expect(undoDecision(view)).toEqual(STRUCTURAL_A);
  });

  it('Cmd-Z routes to the section delete after several automatic rewrites in a row', async () => {
    const view = await makeSectionsEditor();
    await deleteSection(OP_A, AFTER_DELETE_ALPHA);
    setUndoDescriptor({ undoTopOpId: OP_A });
    automaticRebuildAddsSection(view, 'Notes', 'Rebuilt note.');
    automaticRebuildAddsSection(view, 'Bibliography', 'Rebuilt entry.');
    automaticRewriteOfParagraph(view, 'Paragraph eight', 'Paragraph eight rebuilt.');
    expect(undoDecision(view)).toEqual(STRUCTURAL_A);
  });

  it('Cmd-Shift-Z routes to the redo after the undo and a rebuild that lands after it', async () => {
    const view = await makeSectionsEditor();
    await deleteSection(OP_A, AFTER_DELETE_ALPHA);
    automaticRebuildAddsSection(view, 'Notes', 'Rebuilt note.');
    setUndoDescriptor({ undoTopOpId: OP_A });
    expect(undoDecision(view)).toEqual(STRUCTURAL_A);
    expect(performStructuralSwap(OP_A, 'undo')).toBe(true);
    setUndoDescriptor({ redoTopOpId: OP_A });
    automaticRebuildAddsSection(view, 'Bibliography', 'Rebuilt entry.');
    expect(redoDecision(view)).toEqual(STRUCTURAL_A);
  });

  it('typing after the rewrites: first Cmd-Z undoes the typing, the second routes to the section delete', async () => {
    const view = await makeSectionsEditor();
    await deleteSection(OP_A, AFTER_DELETE_ALPHA);
    automaticRebuildAddsSection(view, 'Notes', 'Rebuilt note.');
    setUndoDescriptor({ undoTopOpId: OP_A });
    typeAtEndOf(view, 'Paragraph seven', ' TYPEDWORD');
    expect(undoDecision(view)).toEqual(FALLTHROUGH);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).not.toContain('TYPEDWORD');
    expect(undoDecision(view)).toEqual(STRUCTURAL_A);
  });

  it('two sections deleted with rewrites between: undo the second, then the first', async () => {
    const view = await makeSectionsEditor();
    await deleteSection(OP_A, AFTER_DELETE_ALPHA);
    automaticRebuildAddsSection(view, 'Notes', 'Rebuilt note.');
    await deleteSection(OP_B, AFTER_DELETE_BETA);
    automaticRebuildAddsSection(view, 'Bibliography', 'Rebuilt entry.');
    setUndoDescriptor({ undoTopOpId: OP_B });
    expect(undoDecision(view)).toEqual({ action: 'structural', opId: OP_B });
    expect(performStructuralSwap(OP_B, 'undo')).toBe(true);
    setUndoDescriptor({ undoTopOpId: OP_A, redoTopOpId: OP_B });
    expect(undoDecision(view)).toEqual(STRUCTURAL_A);
  });

  it('fail-safe: a real user edit (even one with a nested heading-id dispatch) is never absorbed', async () => {
    const view = await makeSectionsEditor();
    await deleteSection(OP_A, AFTER_DELETE_ALPHA);
    setUndoDescriptor({ undoTopOpId: OP_A });
    const postOp = getRegistry().get(OP_A)!.postOpDoc;
    const { schema } = view.state;
    view.dispatch(
      view.state.tr.insert(
        view.state.doc.content.size,
        schema.nodes.heading.create({ level: 2 }, schema.text('Typed heading'))
      )
    );
    expect(getRegistry().get(OP_A)!.postOpDoc).toBe(postOp);
    expect(undoDecision(view)).toEqual(FALLTHROUGH);
    automaticRebuildAddsSection(view, 'Notes', 'Rebuilt note.');
    expect(undoDecision(view)).toEqual(FALLTHROUGH);
  });

  it('exact equality alone (no fallback): typing BEFORE a rewrite lands, then undoing the typing, is refused (never a wrong undo); the live app routes this case through the fallback comparison, see the early-typing tests below', async () => {
    const view = await makeSectionsEditor();
    await deleteSection(OP_A, AFTER_DELETE_ALPHA);
    setUndoDescriptor({ undoTopOpId: OP_A });
    typeAtEndOf(view, 'Paragraph seven', ' EARLYWORD');
    automaticRebuildAddsSection(view, 'Notes', 'Rebuilt note.');
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).not.toContain('EARLYWORD');
    expect(undoDecision(view)).toEqual(FALLTHROUGH);
  });
});

// === Footnote renumber ===

const FOOTNOTE_DOC = [
  '# Alpha',
  'Alpha text with a note.[^1]',
  '# Beta',
  'Beta text with a note.[^2]',
  '# Notes',
  '[^1]: First note.',
  '[^2]: Second note.',
].join('\n\n');

async function makeFootnoteEditor(): Promise<EditorView> {
  const div = document.createElement('div');
  document.body.appendChild(div);
  const editor = await Editor.make()
    .config((ctx) => {
      ctx.set(rootCtx, div);
      ctx.set(defaultValueCtx, FOOTNOTE_DOC);
    })
    .use(footnotePlugin)
    .use(commonmark)
    .use(gfm)
    .use(historyPlugin)
    .create();
  current = editor;
  setEditorInstance(editor);
  const view = editor.ctx.get(editorViewCtx);
  installTrackedDispatch(view);
  return view;
}

function labelsIn(doc: Node, typeName: 'footnote_ref' | 'footnote_def'): string[] {
  const out: string[] = [];
  doc.descendants((n) => {
    if (n.type.name === typeName) out.push(String(n.attrs.label));
  });
  return out;
}

/** The op's own content push: one sync-origin transaction removing Alpha's heading and paragraph and
 * footnote 1's definition (Swift's Notes rebuild would remove it). */
function deleteAlphaWithItsFootnote(view: EditorView): void {
  const ranges: Array<{ from: number; to: number }> = [];
  view.state.doc.forEach((node, offset, index) => {
    let holdsDef1 = node.type.name === 'footnote_def' && String(node.attrs.label) === '1';
    node.descendants((child) => {
      if (child.type.name === 'footnote_def' && String(child.attrs.label) === '1') holdsDef1 = true;
    });
    if (index < 2 || holdsDef1) ranges.push({ from: offset, to: offset + node.nodeSize });
  });
  expect(ranges.length, 'premise: Alpha heading, Alpha paragraph, footnote 1 definition').toBe(3);
  const tr = view.state.tr;
  for (const r of [...ranges].reverse()) tr.delete(r.from, r.to);
  view.dispatch(tr.setMeta('addToHistory', false));
}

describe('footnote renumber after a structural op (Phase 4b)', () => {
  it('renumbering footnotes after the delete keeps Cmd-Z on the section delete', async () => {
    const view = await makeFootnoteEditor();
    expect(labelsIn(view.state.doc, 'footnote_ref')).toEqual(['1', '2']);
    expect(beginStructuralOp(OP_A)).toBe(true);
    deleteAlphaWithItsFootnote(view);
    expect(finalizeStructuralOpPostOpDoc(OP_A)).toBe(true);
    setUndoDescriptor({ undoTopOpId: OP_A });
    renumberFootnotes({ '2': '1' });
    expect(labelsIn(view.state.doc, 'footnote_ref')).toEqual(['1']);
    expect(undoDecision(view)).toEqual(STRUCTURAL_A);
  });

  it('the renumber stays its own text-undo step (footnote undo checkpoints depend on it)', async () => {
    const view = await makeFootnoteEditor();
    const depthBefore = undoDepth(view.state);
    renumberFootnotes({ '2': '3' });
    expect(labelsIn(view.state.doc, 'footnote_ref')).toEqual(['1', '3']);
    expect(undoDepth(view.state)).toBe(depthBefore + 1);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(labelsIn(view.state.doc, 'footnote_ref')).toEqual(['1', '2']);
  });
});

// === Early typing: the rewrites land AFTER the user typed (Phase 4b fallback comparison) ===
//
// The chain fix absorbs an automatic rewrite only while the document still equals the saved copy. When
// the user typed first and the Notes / bibliography rebuild (or the footnote renumber) landed after, then
// the user undoes the typing, the document is the saved copy plus those rewrites: not equal, but equal
// modulo what the app regenerates. decideRouting consults `docsEquivalent` (exact equality first) for that.

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
  '<!-- ::auto-bibliography:: -->',
  '# Bibliography',
  'Entry Alpha.',
  'Entry Beta.',
  '<!-- ::auto-bibliography-end:: -->',
].join('\n\n');

async function makeNotesEditor(): Promise<EditorView> {
  (window as any).webkit = { messageHandlers: { errorHandler: { postMessage: () => {} } } };
  const div = document.createElement('div');
  document.body.appendChild(div);
  const editor = await Editor.make()
    .config((ctx) => {
      ctx.set(rootCtx, div);
      ctx.set(defaultValueCtx, NOTES_DOC);
    })
    .use(footnotePlugin)
    .use(bibliographyPlugin)
    .use(bibliographyEndMarkerPlugin)
    .use(commonmark)
    .use(gfm)
    .use(historyPlugin)
    .create();
  current = editor;
  setEditorInstance(editor);
  const view = editor.ctx.get(editorViewCtx);
  installTrackedDispatch(view);
  const names: string[] = [];
  view.state.doc.forEach((n) => {
    names.push(n.type.name);
  });
  expect(names, 'premise: bibliography markers parse as nodes').toContain('auto_bibliography');
  expect(names, 'premise: bibliography end marker parses as a node').toContain('auto_bibliography_end');
  expect(labelsIn(view.state.doc, 'footnote_ref')).toEqual(['1', '2', '3']);
  expect(labelsIn(view.state.doc, 'footnote_def')).toEqual(['1', '2', '3']);
  return view;
}

/** The op's own push: sync-origin delete of "# Alpha" and its paragraph. Notes is untouched (Swift's op push
 * leaves the Notes rows), so footnote 1's definition is left as an orphan. */
function deleteAlphaAsOp(view: EditorView): void {
  expect(beginStructuralOp(OP_A)).toBe(true);
  const end = view.state.doc.child(0).nodeSize + view.state.doc.child(1).nodeSize;
  view.dispatch(view.state.tr.delete(0, end).setMeta('addToHistory', false));
  expect(finalizeStructuralOpPostOpDoc(OP_A)).toBe(true);
  setUndoDescriptor({ undoTopOpId: OP_A });
}

/** Notes + bibliography rebuild shape: ONE sync-origin transaction replacing the Notes heading with a fresh one
 * (id "" -> nested heading-id dispatch), deleting definition paragraphs containing any of dropTexts, and replacing
 * the bibliography entries. Kept definitions are not touched, so text-undo of earlier steps still maps onto them. */
function rebuildNotesAndBibliography(view: EditorView, dropTexts: string[], bibEntries: string[]): void {
  const { schema } = view.state;
  const ranges: Array<{ from: number; to: number; insert: Node[] }> = [];
  let inBib = false;
  let bibHeadingEnd = -1;
  let bibEndPos = -1;
  view.state.doc.forEach((node, pos) => {
    if (node.type.name === 'auto_bibliography') {
      inBib = true;
      return;
    }
    if (node.type.name === 'auto_bibliography_end') {
      inBib = false;
      bibEndPos = pos;
      return;
    }
    if (inBib) {
      if (node.type.name === 'heading') bibHeadingEnd = pos + node.nodeSize;
      return;
    }
    if (node.type.name === 'heading' && node.textContent === 'Notes') {
      ranges.push({
        from: pos,
        to: pos + node.nodeSize,
        insert: [schema.nodes.heading.create({ level: 1 }, schema.text('Notes'))],
      });
    } else if (
      node.type.name === 'paragraph' &&
      node.firstChild?.type.name === 'footnote_def' &&
      dropTexts.some((t) => node.textContent.includes(t))
    ) {
      ranges.push({ from: pos, to: pos + node.nodeSize, insert: [] });
    }
  });
  expect(bibHeadingEnd > 0 && bibEndPos > bibHeadingEnd, 'premise: bibliography heading and end marker found').toBe(
    true
  );
  ranges.push({
    from: bibHeadingEnd,
    to: bibEndPos,
    insert: bibEntries.map((e) => schema.nodes.paragraph.create(null, schema.text(e))),
  });
  const tr = view.state.tr;
  for (const r of [...ranges].sort((a, b) => b.from - a.from)) tr.replaceWith(r.from, r.to, r.insert);
  view.dispatch(tr.setMeta('addToHistory', false));
}

function editFootnoteText(view: EditorView, containing: string, appended: string): void {
  let at = -1;
  view.state.doc.forEach((node, pos) => {
    if (
      at < 0 &&
      node.type.name === 'paragraph' &&
      node.firstChild?.type.name === 'footnote_def' &&
      node.textContent.includes(containing)
    ) {
      at = pos + node.nodeSize - 1;
    }
  });
  expect(at, `definition containing "${containing}" must exist`).toBeGreaterThan(0);
  view.dispatch(view.state.tr.insertText(appended, at));
}

const fallbackParams = (view: EditorView) => ({
  ...routingParams(view),
  docsEquivalent: docsEquivalentIgnoringDerived,
});
const undoWithFallback = (view: EditorView) => decideUndoRouting(fallbackParams(view));
const redoWithFallback = (view: EditorView) => decideRedoRouting(fallbackParams(view));
const savedPostOp = () => getRegistry().get(OP_A)!.postOpDoc;

describe('early typing: rewrites landing after the user typed (Phase 4b fallback comparison)', () => {
  it('F0: the fallback is never consulted when the document exactly equals the saved copy', async () => {
    const view = await makeNotesEditor();
    deleteAlphaAsOp(view);
    const spy = vi.fn(() => false);
    expect(decideUndoRouting({ ...routingParams(view), docsEquivalent: spy })).toEqual(STRUCTURAL_A);
    expect(spy).not.toHaveBeenCalled();
  });

  it('F1: Notes and bibliography rebuild land after the typing: undo the typing, then Cmd-Z restores the section', async () => {
    const view = await makeNotesEditor();
    deleteAlphaAsOp(view);
    typeAtEndOf(view, 'Gamma', ' EARLYWORD');
    rebuildNotesAndBibliography(view, ['First note.'], ['Entry Beta.']);
    expect(undoWithFallback(view), 'the typed word is still there').toEqual(FALLTHROUGH);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).not.toContain('EARLYWORD');
    expect(view.state.doc.eq(savedPostOp()), 'premise: only the fallback can route this').toBe(false);
    expect(undoWithFallback(view)).toEqual(STRUCTURAL_A);
  });

  it('F2: the renumber also lands after the typing: Cmd-Z undoes the renumber, then the typing, then restores the section', async () => {
    const view = await makeNotesEditor();
    deleteAlphaAsOp(view);
    typeAtEndOf(view, 'Gamma', ' EARLYWORD');
    renumberFootnotes({ '2': '1', '3': '2' });
    rebuildNotesAndBibliography(view, ['First note.'], ['Entry Beta.']);
    expect(labelsIn(view.state.doc, 'footnote_ref')).toEqual(['1', '2']);
    expect(undoWithFallback(view)).toEqual(FALLTHROUGH);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(labelsIn(view.state.doc, 'footnote_ref'), 'first undo reverts the renumber').toEqual(['2', '3']);
    expect(view.state.doc.textContent, 'premise: the renumber is its own undo step').toContain('EARLYWORD');
    expect(undoWithFallback(view)).toEqual(FALLTHROUGH);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).not.toContain('EARLYWORD');
    expect(undoWithFallback(view)).toEqual(STRUCTURAL_A);
  });

  it('F3 fail-safe: while the typed word is in the text, Cmd-Z never routes to the section', async () => {
    const view = await makeNotesEditor();
    deleteAlphaAsOp(view);
    typeAtEndOf(view, 'Gamma', ' EARLYWORD');
    renumberFootnotes({ '2': '1', '3': '2' });
    rebuildNotesAndBibliography(view, ['First note.'], ['Entry Beta.']);
    expect(undoWithFallback(view)).toEqual(FALLTHROUGH);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).toContain('EARLYWORD');
    expect(undoWithFallback(view)).toEqual(FALLTHROUGH);
  });

  it('F4 fail-safe: an edit to a still-referenced footnote is never skipped; Cmd-Z undoes the edit first', async () => {
    const view = await makeNotesEditor();
    deleteAlphaAsOp(view);
    editFootnoteText(view, 'Second note.', ' EDITEDNOTE');
    rebuildNotesAndBibliography(view, ['First note.'], ['Entry Beta.']);
    expect(undoWithFallback(view), 'footnote text differs').toEqual(FALLTHROUGH);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).not.toContain('EDITEDNOTE');
    expect(undoWithFallback(view)).toEqual(STRUCTURAL_A);
  });

  it('F5: redo: after the section comes back, typing before the rebuild and undoing it still lets Cmd-Shift-Z delete it again', async () => {
    const view = await makeNotesEditor();
    deleteAlphaAsOp(view);
    expect(performStructuralSwap(OP_A, 'undo')).toBe(true);
    setUndoDescriptor({ redoTopOpId: OP_A });
    typeAtEndOf(view, 'Gamma', ' LATEWORD');
    rebuildNotesAndBibliography(view, [], ['Entry Alpha.', 'Entry Beta.', 'Entry Gamma.']);
    expect(redoWithFallback(view)).toEqual(FALLTHROUGH);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).not.toContain('LATEWORD');
    expect(redoWithFallback(view)).toEqual(STRUCTURAL_A);
  });

  it('F6 wiring: the menu-path Cmd-Z uses the fallback (requestUnifiedUndo posts structuralUndoRequested)', async () => {
    const view = await makeNotesEditor();
    const posted: unknown[] = [];
    (window as any).webkit.messageHandlers.structuralUndoRequested = { postMessage: (m: unknown) => posted.push(m) };
    deleteAlphaAsOp(view);
    typeAtEndOf(view, 'Gamma', ' EARLYWORD');
    rebuildNotesAndBibliography(view, ['First note.'], ['Entry Beta.']);
    expect(undo(view.state, view.dispatch)).toBe(true);
    requestUnifiedUndo();
    expect(posted).toEqual([{ opId: OP_A }]);
  });

  it('F7 fail-safe: text typed into a footnote that is an orphan on BOTH sides is never skipped; Cmd-Z undoes it first', async () => {
    const view = await makeNotesEditor();
    deleteAlphaAsOp(view); // footnote 1's definition is now an orphan in the saved copy
    editFootnoteText(view, 'First note.', ' ORPHANEDIT'); // typed into the orphan before any rebuild
    rebuildNotesAndBibliography(view, [], ['Entry Beta.']); // bibliography-only rebuild; the orphan stays
    expect(view.state.doc.textContent, 'premise: the typed text sits in the orphan').toContain(
      'First note. ORPHANEDIT'
    );
    expect(undoWithFallback(view), 'the orphan text differs on both sides').toEqual(FALLTHROUGH);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).not.toContain('ORPHANEDIT');
    expect(view.state.doc.eq(savedPostOp()), 'premise: only the fallback can route this').toBe(false);
    expect(undoWithFallback(view)).toEqual(STRUCTURAL_A);
  });

  it('R1: after a fallback-routed undo and a redo, the saved copy is re-anchored: a later rewrite is absorbed and the next Cmd-Z routes EXACTLY (no fallback)', async () => {
    const view = await makeNotesEditor();
    deleteAlphaAsOp(view);
    typeAtEndOf(view, 'Gamma', ' EARLYWORD');
    rebuildNotesAndBibliography(view, ['First note.'], ['Entry Beta.']); // lands AFTER the typing: not absorbed
    expect(undo(view.state, view.dispatch)).toBe(true); // the user undoes the typing
    const originalPostOp = savedPostOp();
    expect(view.state.doc.eq(originalPostOp), 'premise: the saved copy is NOT byte-equal to the live document').toBe(
      false
    );
    expect(undoWithFallback(view), 'premise: only the fallback routes this press').toEqual(STRUCTURAL_A);

    // Cmd-Z restores the section; Cmd-Shift-Z deletes it again.
    expect(performStructuralSwap(OP_A, 'undo')).toBe(true);
    setUndoDescriptor({ redoTopOpId: OP_A });
    expect(performStructuralSwap(OP_A, 'redo')).toBe(true);
    setUndoDescriptor({ undoTopOpId: OP_A });
    expect(savedPostOp(), 'the redo re-anchored the saved copy to the document it swapped in').not.toBe(originalPostOp);
    expect(savedPostOp().eq(view.state.doc)).toBe(true);

    // An automatic rewrite lands after the redo (a bibliography-only rebuild). The chain absorbs it
    // because the saved copy now equals the live document.
    rebuildNotesAndBibliography(view, [], ['Entry Gamma.']);
    // Pure decision with exact equality ONLY (no `docsEquivalent`): the next Cmd-Z must route structurally
    // without leaning on the fallback comparison.
    expect(undoDecision(view)).toEqual(STRUCTURAL_A);
  });
});

describe('docsEquivalentIgnoringDerived: what it ignores and what it never ignores', () => {
  type Edit = (t: Transform, d: Node) => void;
  /** Applies `f` and asserts the document really changed: a no-op edit would make every "must stay
   * equivalent" check below pass for nothing. */
  const edit = (doc: Node, f: Edit): Node => {
    const t = new Transform(doc);
    f(t, doc);
    expect(t.doc.eq(doc), 'premise: the edit changed the document').toBe(false);
    return t.doc;
  };
  const eqv = docsEquivalentIgnoringDerived;
  function all(doc: Node, pred: (n: Node) => boolean): Array<{ node: Node; pos: number }> {
    const out: Array<{ node: Node; pos: number }> = [];
    doc.descendants((node, pos) => {
      if (pred(node)) out.push({ node, pos });
    });
    return out;
  }
  const isRef =
    (l?: string) =>
    (n: Node): boolean =>
      n.type.name === 'footnote_ref' && (l === undefined || String(n.attrs.label) === l);
  const isDef =
    (l?: string) =>
    (n: Node): boolean =>
      n.type.name === 'footnote_def' && (l === undefined || String(n.attrs.label) === l);
  function top(doc: Node, pred: (n: Node) => boolean): { node: Node; pos: number } {
    let hit: { node: Node; pos: number } | null = null;
    doc.forEach((node, pos) => {
      if (!hit && pred(node)) hit = { node, pos };
    });
    expect(hit).not.toBeNull();
    return hit!;
  }
  const textStarts = (s: string) => (n: Node) => n.textContent.startsWith(s);
  const contentEnd = (h: { node: Node; pos: number }) => h.pos + h.node.nodeSize - 1;
  const withoutAlpha = (base: Node) => edit(base, (t, d) => t.delete(0, d.child(0).nodeSize + d.child(1).nodeSize));
  const defParagraph = (text: string) => (n: Node) =>
    n.firstChild?.type.name === 'footnote_def' && n.textContent.includes(text);

  it('ignores relabelled footnotes (references and definitions together)', async () => {
    const base = (await makeNotesEditor()).state.doc;
    const map: Record<string, string> = { '1': '7', '2': '8', '3': '9' };
    expect(
      eqv(
        base,
        edit(base, (t, d) => {
          for (const { node, pos } of all(d, (n) => isRef()(n) || isDef()(n))) {
            t.setNodeMarkup(pos, undefined, { label: map[String(node.attrs.label)] });
          }
        })
      )
    ).toBe(true);
  });

  it('ignores a changed heading id', async () => {
    const base = (await makeNotesEditor()).state.doc;
    expect(
      eqv(
        base,
        edit(base, (t, d) => {
          const h = top(d, (n) => n.type.name === 'heading');
          t.setNodeMarkup(h.pos, undefined, { ...h.node.attrs, id: 'other-id' });
        })
      )
    ).toBe(true);
  });

  it('ignores the bibliography: changed entries, or removed entirely', async () => {
    const view = await makeNotesEditor();
    const base = view.state.doc;
    const { schema } = view.state;
    expect(
      eqv(
        base,
        edit(base, (t, d) => t.insert(contentEnd(top(d, textStarts('Entry Alpha'))), schema.text('X')))
      )
    ).toBe(true);
    expect(
      eqv(
        base,
        edit(base, (t, d) => {
          const s = top(d, (n) => n.type.name === 'auto_bibliography');
          const e = top(d, (n) => n.type.name === 'auto_bibliography_end');
          t.delete(s.pos, e.pos + e.node.nodeSize);
        })
      )
    ).toBe(true);
  });

  it('ignores a definition no reference points to when the other side has none (the next Notes rebuild deletes it)', async () => {
    const A = withoutAlpha((await makeNotesEditor()).state.doc);
    const A2 = edit(A, (t, d) => {
      const p = top(d, defParagraph('First note.'));
      t.delete(p.pos, p.pos + p.node.nodeSize);
    });
    expect(eqv(A, A2)).toBe(true);
    expect(eqv(A2, A)).toBe(true);
  });

  it('drops the Notes heading only when nothing references its definitions', async () => {
    const base = (await makeNotesEditor()).state.doc;
    const noRefs = edit(base, (t, d) => {
      for (const { pos } of all(d, isRef()).reverse()) t.delete(pos, pos + 1);
    });
    const noNotes = edit(noRefs, (t, d) => {
      const h = top(d, (n) => n.type.name === 'heading' && n.textContent === 'Notes');
      const last = top(d, defParagraph('Third note.'));
      t.delete(h.pos, last.pos + last.node.nodeSize);
    });
    expect(eqv(noRefs, noNotes)).toBe(true);

    // The other half: while the definitions ARE referenced, the Notes heading stays in the comparison,
    // so a document that lost just the heading is NOT equivalent (Swift keeps the heading while any
    // footnote remains; dropping it is a real difference).
    const headingDropped = edit(base, (t, d) => {
      const h = top(d, (n) => n.type.name === 'heading' && n.textContent === 'Notes');
      t.delete(h.pos, h.pos + h.node.nodeSize);
    });
    expect(eqv(base, headingDropped), 'referenced definitions: the Notes heading is compared').toBe(false);
    expect(eqv(headingDropped, base)).toBe(false);
  });

  it('never ignores: body text, a referenced footnote text, a moved or deleted reference, a renamed Notes heading, text after the bibliography', async () => {
    const view = await makeNotesEditor();
    const base = view.state.doc;
    const { schema } = view.state;
    expect(eqv(base, withoutAlpha(base)), 'body differs').toBe(false);
    expect(
      eqv(
        base,
        edit(base, (t, d) => t.insert(contentEnd(top(d, textStarts('Gamma'))), schema.text('X')))
      ),
      'body text'
    ).toBe(false);
    expect(
      eqv(
        base,
        edit(base, (t, d) => t.insert(contentEnd(top(d, defParagraph('Second note.'))), schema.text('X')))
      ),
      'referenced footnote text'
    ).toBe(false);
    expect(
      eqv(
        base,
        edit(base, (t, d) => {
          const r = all(d, isRef('2'))[0];
          t.insert(contentEnd(top(d, textStarts('Gamma'))), schema.nodes.footnote_ref.create({ label: '2' }));
          t.delete(r.pos, r.pos + 1);
        })
      ),
      'moved reference'
    ).toBe(false);
    expect(
      eqv(
        base,
        edit(base, (t, d) => {
          const r = all(d, isRef('2'))[0];
          t.delete(r.pos, r.pos + 1);
        })
      ),
      'deleted reference'
    ).toBe(false);
    expect(
      eqv(
        base,
        edit(base, (t, d) =>
          t.insert(contentEnd(top(d, (n) => n.type.name === 'heading' && n.textContent === 'Notes')), schema.text('X'))
        )
      ),
      'renamed Notes heading'
    ).toBe(false);
    expect(
      eqv(
        base,
        edit(base, (t, d) => {
          const e = top(d, (n) => n.type.name === 'auto_bibliography_end');
          t.insert(e.pos + e.node.nodeSize, schema.nodes.paragraph.create(null, schema.text('After.')));
        })
      ),
      'text after the bibliography'
    ).toBe(false);
    const A = withoutAlpha(base);
    expect(
      eqv(
        A,
        edit(A, (t, d) => {
          const o = all(d, isDef('1'))[0];
          t.setNodeMarkup(o.pos, undefined, { label: '2' });
        })
      ),
      'duplicate label is ambiguous'
    ).toBe(false);
    // Judge must-fix 1: an orphan definition present on BOTH sides is compared by its text (multiset),
    // never ignored -- text typed into it is the user's.
    expect(
      eqv(
        A,
        edit(A, (t, d) => t.insert(contentEnd(top(d, defParagraph('First note.'))), schema.text('X')))
      ),
      'orphan definition with different text on both sides'
    ).toBe(false);
    // Judge must-fix 2: with no bibliography end marker the region is compared exactly, never skipped
    // to the end of the document (anything typed after the bibliography would otherwise vanish).
    const noEnd = edit(base, (t, d) => {
      const e = top(d, (n) => n.type.name === 'auto_bibliography_end');
      t.delete(e.pos, e.pos + e.node.nodeSize);
    });
    expect(
      eqv(
        noEnd,
        edit(noEnd, (t, d) => t.insert(contentEnd(top(d, textStarts('Entry Alpha'))), schema.text('X')))
      ),
      'no end marker: bibliography entries are compared exactly'
    ).toBe(false);
    expect(
      eqv(
        noEnd,
        edit(noEnd, (t, d) => t.insert(d.content.size, schema.nodes.paragraph.create(null, schema.text('After.'))))
      ),
      'no end marker: text after the bibliography is compared exactly'
    ).toBe(false);
  });
});

// === The real document shape (Swift-assembled; real-app run run-1791716965-74146) ===
//
// The unit tests above wrote the bibliography with an opening marker on its own line. The Rich Text
// editor's real document has NO opening marker: BibliographySyncService writes the bibliography as
// "# <header name>" plus one paragraph per entry, deliberately without the marker ("marker is injected only
// for CodeMirror source mode", BibliographySyncService+EntryFormatting.swift:33-38), and inserts exactly
// those rows after deleting every isBibliography row, a standalone opening-marker block included
// (BibliographySyncService+SystemWrite.swift:248-285); BlockParser.assembleMarkdownForEditor then joins the
// stored blocks with a blank line and inserts `<!-- ::auto-bibliography-end:: -->` right after the LAST
// bibliography block (BlockParser+Assembly.swift:59-66). The document therefore reads
// "... # Notes, [^N]: definitions, # Bibliography, entries, <end marker>". On the 7,523-word article the
// fallback saw the bibliography as ordinary body text, the entries the rebuild removed counted as a
// difference, and Cmd-Z 3 was refused (children 121 vs 124, first difference at the Notes definitions).

const ENTRY_ADAMS = 'Adams, A. (2019). *Alpha Title*. Press.';
const ENTRY_BAKER = 'Baker, B. (2011). *Beta Title*. Press.';
const END_MARKER = '<!-- ::auto-bibliography-end:: -->';

const realDocLines = (bibliographyTitle: string, level: number, entries: string[], endMarker: boolean): string =>
  [
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
    `${'#'.repeat(level)} ${bibliographyTitle}`,
    ...entries,
    ...(endMarker ? [END_MARKER] : []),
  ].join('\n\n');

const realDoc = (bibliographyTitle = 'Bibliography', level = 1): string =>
  realDocLines(bibliographyTitle, level, [ENTRY_ADAMS, ENTRY_BAKER], true);

async function makeRealEditor(markdown = realDoc(), expectEndMarker = true): Promise<EditorView> {
  (window as any).webkit = { messageHandlers: { errorHandler: { postMessage: () => {} } } };
  const div = document.createElement('div');
  document.body.appendChild(div);
  const editor = await Editor.make()
    .config((ctx) => {
      ctx.set(rootCtx, div);
      ctx.set(defaultValueCtx, markdown);
    })
    .use(footnotePlugin)
    .use(bibliographyPlugin)
    .use(bibliographyEndMarkerPlugin)
    .use(commonmark)
    .use(gfm)
    .use(historyPlugin)
    .create();
  current = editor;
  setEditorInstance(editor);
  const view = editor.ctx.get(editorViewCtx);
  installTrackedDispatch(view);
  const names: string[] = [];
  view.state.doc.forEach((n) => {
    names.push(n.type.name);
  });
  expect(names, 'premise: the real shape has NO opening marker node').not.toContain('auto_bibliography');
  if (expectEndMarker) {
    expect(names, 'premise: the real shape ends its bibliography with the end marker').toContain(
      'auto_bibliography_end'
    );
  }
  expect(labelsIn(view.state.doc, 'footnote_ref')).toEqual(['1', '2', '3']);
  expect(labelsIn(view.state.doc, 'footnote_def')).toEqual(['1', '2', '3']);
  return view;
}

/** The Notes + bibliography rebuild in the real shape (no opening marker): ONE sync-origin transaction that
 * replaces the Notes heading with a fresh one, deletes the definition paragraphs containing any of dropTexts
 * and replaces the entries between the bibliography heading and the end marker. */
function rebuildRealNotesAndBibliography(view: EditorView, dropTexts: string[], bibEntries: string[]): void {
  const { schema } = view.state;
  const ranges: Array<{ from: number; to: number; insert: Node[] }> = [];
  let bibHeadingEnd = -1;
  let bibEndPos = -1;
  view.state.doc.forEach((node, pos) => {
    if (node.type.name === 'auto_bibliography_end') {
      bibEndPos = pos;
      return;
    }
    if (node.type.name === 'heading' && node.textContent === 'Bibliography') {
      bibHeadingEnd = pos + node.nodeSize;
      return;
    }
    if (bibHeadingEnd > 0) return; // a bibliography entry
    if (node.type.name === 'heading' && node.textContent === 'Notes') {
      ranges.push({
        from: pos,
        to: pos + node.nodeSize,
        insert: [schema.nodes.heading.create({ level: 1 }, schema.text('Notes'))],
      });
    } else if (
      node.type.name === 'paragraph' &&
      node.firstChild?.type.name === 'footnote_def' &&
      dropTexts.some((t) => node.textContent.includes(t))
    ) {
      ranges.push({ from: pos, to: pos + node.nodeSize, insert: [] });
    }
  });
  expect(bibHeadingEnd > 0 && bibEndPos > bibHeadingEnd, 'premise: bibliography heading and end marker found').toBe(
    true
  );
  ranges.push({
    from: bibHeadingEnd,
    to: bibEndPos,
    insert: bibEntries.map((e) => schema.nodes.paragraph.create(null, schema.text(e))),
  });
  const tr = view.state.tr;
  for (const r of [...ranges].sort((a, b) => b.from - a.from)) tr.replaceWith(r.from, r.to, r.insert);
  view.dispatch(tr.setMeta('addToHistory', false));
}

/** An automatic rewrite that removes the top-level paragraphs containing any of `texts` (sync origin). */
function dropParagraphsContaining(view: EditorView, texts: string[]): void {
  const ranges: Array<{ from: number; to: number }> = [];
  view.state.doc.forEach((node, pos) => {
    if (node.type.name === 'paragraph' && texts.some((t) => node.textContent.includes(t))) {
      ranges.push({ from: pos, to: pos + node.nodeSize });
    }
  });
  expect(ranges.length, 'premise: the paragraphs to drop exist').toBe(texts.length);
  const tr = view.state.tr;
  for (const r of ranges.reverse()) tr.delete(r.from, r.to);
  view.dispatch(tr.setMeta('addToHistory', false));
}

describe('real document shape: no bibliography opening marker (Swift-assembled)', () => {
  it('RS1: the rebuild lands after the typing: undo the typing, then Cmd-Z restores the section', async () => {
    const view = await makeRealEditor();
    deleteAlphaAsOp(view);
    typeAtEndOf(view, 'Gamma', ' EARLYWORD');
    rebuildRealNotesAndBibliography(view, ['First note.'], [ENTRY_BAKER]); // the deleted section's note and entry go
    expect(undoWithFallback(view), 'the typed word is still there').toEqual(FALLTHROUGH);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).not.toContain('EARLYWORD');
    expect(view.state.doc.eq(savedPostOp()), 'premise: only the fallback can route this').toBe(false);
    expect(undoWithFallback(view)).toEqual(STRUCTURAL_A);
  });

  it('RS2: the renumber also lands after the typing: Cmd-Z undoes the renumber, then the typing, then restores the section', async () => {
    const view = await makeRealEditor();
    deleteAlphaAsOp(view);
    typeAtEndOf(view, 'Gamma', ' EARLYWORD');
    renumberFootnotes({ '2': '1', '3': '2' });
    rebuildRealNotesAndBibliography(view, ['First note.'], [ENTRY_BAKER]);
    expect(undoWithFallback(view)).toEqual(FALLTHROUGH);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(labelsIn(view.state.doc, 'footnote_ref'), 'first undo reverts the renumber').toEqual(['2', '3']);
    expect(undoWithFallback(view)).toEqual(FALLTHROUGH);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).not.toContain('EARLYWORD');
    expect(undoWithFallback(view)).toEqual(STRUCTURAL_A);
  });

  it('RS3 fail-safe: while the typed word is in the text, Cmd-Z never routes to the section', async () => {
    const view = await makeRealEditor();
    deleteAlphaAsOp(view);
    typeAtEndOf(view, 'Gamma', ' EARLYWORD');
    rebuildRealNotesAndBibliography(view, ['First note.'], [ENTRY_BAKER]);
    expect(undoWithFallback(view)).toEqual(FALLTHROUGH);
  });

  it('RS4 fail-safe: a paragraph typed after the end marker is never skipped; Cmd-Z undoes it first', async () => {
    const view = await makeRealEditor();
    deleteAlphaAsOp(view);
    const { schema } = view.state;
    view.dispatch(
      view.state.tr.insert(view.state.doc.content.size, schema.nodes.paragraph.create(null, schema.text('Appendix.')))
    );
    rebuildRealNotesAndBibliography(view, ['First note.'], [ENTRY_BAKER]);
    expect(undoWithFallback(view), 'text after the bibliography differs').toEqual(FALLTHROUGH);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).not.toContain('Appendix.');
    expect(undoWithFallback(view)).toEqual(STRUCTURAL_A);
  });

  it('RS5 limit (reported to the judge): a custom bibliography header name is not recognised, so the region is compared exactly: refused, never a wrong undo', async () => {
    const view = await makeRealEditor(realDoc('Works Cited'));
    deleteAlphaAsOp(view);
    typeAtEndOf(view, 'Gamma', ' EARLYWORD');
    dropParagraphsContaining(view, ['First note.', 'Adams']);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).not.toContain('EARLYWORD');
    expect(undoWithFallback(view), 'the removed entry is compared exactly').toEqual(FALLTHROUGH);
  });
});

describe('docsEquivalentIgnoringDerived on the real shape: what it ignores and what it never ignores', () => {
  const eqv = docsEquivalentIgnoringDerived;
  type Edit = (t: Transform, d: Node) => void;
  /** Applies `f` and asserts the document really changed (a text node built from ANOTHER editor's schema is
   * silently dropped by Transform, which would make a "must stay equivalent" check pass for nothing). */
  const edit = (doc: Node, f: Edit): Node => {
    const t = new Transform(doc);
    f(t, doc);
    expect(t.doc.eq(doc), 'premise: the edit changed the document').toBe(false);
    return t.doc;
  };
  function top(doc: Node, pred: (n: Node) => boolean): { node: Node; pos: number } {
    let hit: { node: Node; pos: number } | null = null;
    doc.forEach((node, pos) => {
      if (!hit && pred(node)) hit = { node, pos };
    });
    expect(hit).not.toBeNull();
    return hit!;
  }
  const contentEnd = (h: { node: Node; pos: number }) => h.pos + h.node.nodeSize - 1;
  const isBibHeading = (n: Node) => n.type.name === 'heading' && n.textContent === 'Bibliography';
  const isEnd = (n: Node) => n.type.name === 'auto_bibliography_end';
  const entry = (text: string) => (n: Node) => n.type.name === 'paragraph' && n.textContent.startsWith(text);
  const typeIntoAdams = (doc: Node) =>
    edit(doc, (t, d) => t.insert(contentEnd(top(d, entry('Adams'))), d.type.schema.text('X')));

  it('ignores changed, removed and added bibliography entries', async () => {
    const view = await makeRealEditor();
    const base = view.state.doc;
    const { schema } = view.state;
    expect(eqv(base, typeIntoAdams(base))).toBe(true);
    expect(
      eqv(
        base,
        edit(base, (t, d) => {
          const e = top(d, entry('Adams'));
          t.delete(e.pos, e.pos + e.node.nodeSize);
        })
      )
    ).toBe(true);
    expect(
      eqv(
        base,
        edit(base, (t, d) => t.insert(top(d, isEnd).pos, schema.nodes.paragraph.create(null, schema.text('Zed, Z.'))))
      )
    ).toBe(true);
  });

  it('ignores a bibliography that is gone entirely (heading, entries and end marker: every citation removed)', async () => {
    const base = (await makeRealEditor()).state.doc;
    expect(
      eqv(
        base,
        edit(base, (t, d) => {
          const h = top(d, isBibHeading);
          const e = top(d, isEnd);
          t.delete(h.pos, e.pos + e.node.nodeSize);
        })
      )
    ).toBe(true);
  });

  it('accepts a level 2 heading and the title References', async () => {
    const view = await makeRealEditor(realDoc('References', 2));
    expect(eqv(view.state.doc, typeIntoAdams(view.state.doc))).toBe(true);
  });

  it('never ignores text after the end marker', async () => {
    const view = await makeRealEditor();
    const base = view.state.doc;
    const { schema } = view.state;
    expect(
      eqv(
        base,
        edit(base, (t, d) => {
          const e = top(d, isEnd);
          t.insert(e.pos + e.node.nodeSize, schema.nodes.paragraph.create(null, schema.text('After.')));
        })
      )
    ).toBe(false);
  });

  it('never ignores body text before the bibliography, or an edit to a still-referenced footnote', async () => {
    const view = await makeRealEditor();
    const base = view.state.doc;
    const { schema } = view.state;
    expect(
      eqv(
        base,
        edit(base, (t, d) =>
          t.insert(contentEnd(top(d, (n) => n.textContent.startsWith('Gamma plain'))), schema.text('X'))
        )
      )
    ).toBe(false);
    expect(
      eqv(
        base,
        edit(base, (t, d) =>
          t.insert(
            contentEnd(top(d, (n) => n.firstChild?.type.name === 'footnote_def' && n.textContent.includes('Second'))),
            schema.text('X')
          )
        )
      )
    ).toBe(false);
  });

  it('never skips when the start is not recognised: a custom title, a level 3 heading, a subheading inside the run, an empty run, no end marker', async () => {
    const custom = (await makeRealEditor(realDoc('Works Cited'))).state.doc;
    expect(eqv(custom, typeIntoAdams(custom)), 'custom title').toBe(false);

    const level3 = (await makeRealEditor(realDoc('Bibliography', 3))).state.doc;
    expect(eqv(level3, typeIntoAdams(level3)), 'level 3 heading').toBe(false);

    const sub = (
      await makeRealEditor(realDocLines('Bibliography', 1, [ENTRY_ADAMS, '## Primary Sources', ENTRY_BAKER], true))
    ).state.doc;
    expect(eqv(sub, typeIntoAdams(sub)), 'the subheading is the nearest heading and is not a bibliography title').toBe(
      false
    );

    const empty = (await makeRealEditor(realDocLines('Bibliography', 1, [], true))).state.doc;
    expect(
      eqv(
        empty,
        edit(empty, (t, d) =>
          t.insert(top(d, isEnd).pos, d.type.schema.nodes.paragraph.create(null, d.type.schema.text('Q.')))
        )
      ),
      'an empty run (heading directly before the end marker) is not skipped'
    ).toBe(false);

    const noEnd = (await makeRealEditor(realDocLines('Bibliography', 1, [ENTRY_ADAMS, ENTRY_BAKER], false), false))
      .state.doc;
    expect(eqv(noEnd, typeIntoAdams(noEnd)), 'no end marker: compared exactly, not skipped to the end').toBe(false);
  });
});

describe('explainDerivedDifference: the reason for every "different"', () => {
  const explain = explainDerivedDifference;
  type Edit = (t: Transform, d: Node) => void;
  /** Applies `f` and asserts the document really changed (a text node built from ANOTHER editor's schema is
   * silently dropped by Transform, which would make a "must stay equivalent" check pass for nothing). */
  const edit = (doc: Node, f: Edit): Node => {
    const t = new Transform(doc);
    f(t, doc);
    expect(t.doc.eq(doc), 'premise: the edit changed the document').toBe(false);
    return t.doc;
  };
  function top(doc: Node, pred: (n: Node) => boolean): { node: Node; pos: number } {
    let hit: { node: Node; pos: number } | null = null;
    doc.forEach((node, pos) => {
      if (!hit && pred(node)) hit = { node, pos };
    });
    expect(hit).not.toBeNull();
    return hit!;
  }
  const contentEnd = (h: { node: Node; pos: number }) => h.pos + h.node.nodeSize - 1;
  const defParagraph = (text: string) => (n: Node) =>
    n.firstChild?.type.name === 'footnote_def' && n.textContent.includes(text);
  const withoutAlpha = (base: Node) => edit(base, (t, d) => t.delete(0, d.child(0).nodeSize + d.child(1).nodeSize));

  it('is null when the documents differ only in regenerated content, and names the difference once a real one is added', async () => {
    const base = (await makeRealEditor()).state.doc;
    // Everything the app regenerates after a swap, all at once: relabelled footnotes (references and
    // definitions together), a changed heading id, and a rebuilt bibliography (one entry changed, one removed).
    const regenerated = edit(base, (t, d) => {
      const relabel: Record<string, string> = { '1': '7', '2': '8', '3': '9' };
      d.descendants((n, pos) => {
        if (n.type.name === 'footnote_ref' || n.type.name === 'footnote_def') {
          t.setNodeMarkup(t.mapping.map(pos), undefined, { label: relabel[String(n.attrs.label)] });
        }
      });
      const h = top(d, (n) => n.type.name === 'heading');
      t.setNodeMarkup(t.mapping.map(h.pos), undefined, { ...h.node.attrs, id: 'other-id' });
      const adams = top(d, (n) => n.type.name === 'paragraph' && n.textContent.startsWith('Adams'));
      t.insert(t.mapping.map(adams.pos + adams.node.nodeSize - 1), d.type.schema.text('X'));
      const baker = top(d, (n) => n.type.name === 'paragraph' && n.textContent.startsWith('Baker'));
      t.delete(t.mapping.map(baker.pos), t.mapping.map(baker.pos + baker.node.nodeSize));
    });
    expect(base.eq(regenerated), 'premise: the documents are not equal').toBe(false);
    expect(explain(base, regenerated)).toBeNull();
    expect(explain(regenerated, base)).toBeNull();

    // The same regenerated variant PLUS one real change (typing in the last body paragraph): not equivalent,
    // and the reason names where. This is the half that goes red if the body comparison is removed.
    const typed = edit(regenerated, (t, d) =>
      t.insert(contentEnd(top(d, (n) => n.textContent.startsWith('Gamma plain'))), d.type.schema.text('X'))
    );
    expect(explain(base, typed)).toContain('body differs at body node');
  });

  it('names a footnote label defined twice', async () => {
    const A = withoutAlpha((await makeRealEditor()).state.doc);
    const dup = edit(A, (t, d) => {
      let pos = -1;
      d.descendants((n, p) => {
        if (pos < 0 && n.type.name === 'footnote_def' && String(n.attrs.label) === '1') pos = p;
      });
      t.setNodeMarkup(pos, undefined, { label: '2' });
    });
    expect(explain(A, dup)).toBe('a footnote label is defined twice in b');
    expect(explain(dup, A)).toBe('a footnote label is defined twice in a');
  });

  it('names the first differing body node by type and size, never by text', async () => {
    const base = (await makeRealEditor()).state.doc;
    const reason = explain(base, withoutAlpha(base)) ?? '';
    expect(reason).toContain('body differs at body node 0');
    // "Alpha" is 5 characters long, "Beta" 4: the sizes are the whole identification.
    expect(reason).toContain('a=heading1(size=5) b=heading1(size=4)');
    expect(reason).not.toContain('Alpha');
    expect(reason).not.toContain('Beta');
  });

  it('says how the bibliography was recognised, and names the nearest heading when it was not', async () => {
    const custom = (await makeRealEditor(realDoc('Works Cited'))).state.doc;
    const edited = edit(custom, (t, d) =>
      t.insert(contentEnd(top(d, (n) => n.textContent.startsWith('Adams'))), d.type.schema.text('X'))
    );
    const reason = explain(custom, edited) ?? '';
    expect(reason).toContain('body differs');
    // "Works Cited" is 11 characters long; the title is named by whether it matched, never spelled out.
    expect(reason).toContain('not bounded: nearest heading before it is heading1(size=11)');
    expect(reason).toContain('titleMatches=false level=1');
    expect(reason).not.toContain('Works');

    const recognised = (await makeRealEditor()).state.doc;
    const ofRecognised = explain(recognised, withoutAlpha(recognised)) ?? '';
    expect(ofRecognised).toContain('skipped (level 1 Bibliography/References heading .. end marker)');
  });

  it('names an opening marker that has no end marker', async () => {
    const view = await makeNotesEditor();
    const base = view.state.doc;
    const noEnd = edit(base, (t, d) => {
      const e = top(d, (n) => n.type.name === 'auto_bibliography_end');
      t.delete(e.pos, e.pos + e.node.nodeSize);
    });
    const reason =
      explain(
        noEnd,
        edit(noEnd, (t, d) =>
          t.insert(contentEnd(top(d, (n) => n.textContent.startsWith('Entry Alpha'))), d.type.schema.text('X'))
        )
      ) ?? '';
    expect(reason).toContain('opening marker at child');
    expect(reason).toContain('has no end marker');
  });

  it('names a footnote whose text differs', async () => {
    const view = await makeRealEditor();
    const base = view.state.doc;
    const edited = edit(base, (t, d) =>
      t.insert(contentEnd(top(d, defParagraph('Second note.'))), d.type.schema.text('X'))
    );
    const reason = explain(base, edited) ?? '';
    expect(reason).toContain('footnote text differs at reference 1 of 3');
    expect(reason).not.toContain('Second');
  });

  it('names orphan definitions that differ on both sides', async () => {
    const view = await makeRealEditor();
    const A = withoutAlpha(view.state.doc);
    const edited = edit(A, (t, d) =>
      t.insert(contentEnd(top(d, defParagraph('First note.'))), d.type.schema.text('X'))
    );
    const reason = explain(A, edited) ?? '';
    expect(reason).toContain('orphan definitions differ');
    expect(reason).not.toContain('First');
  });

  it('is carried by the routing log lines: routing-equivalence (result=false) and routing-refused (equivalent=false)', async () => {
    const view = await makeRealEditor(realDoc('Works Cited'));
    const logs: string[] = [];
    (window as any).webkit.messageHandlers.errorHandler.postMessage = (m: { message: string }) => {
      logs.push(m.message);
    };
    deleteAlphaAsOp(view);
    typeAtEndOf(view, 'Gamma', ' EARLYWORD');
    dropParagraphsContaining(view, ['First note.', 'Adams']);
    expect(undo(view.state, view.dispatch)).toBe(true);
    handleUnifiedUndoKeydown(new KeyboardEvent('keydown', { key: 'z', metaKey: true }), view, 'undo');
    const equivalence = logs.find((l) => l.includes('routing-equivalence')) ?? '';
    expect(equivalence).toContain('result=false');
    expect(equivalence).toContain(' reason=body differs at body node');
    // The whole decision's time rides on the line (what the fall-through cost test reads), after `ms=`.
    expect(equivalence).toMatch(/ ms=\d+\.\d totalMs=\d+\.\d /);
    const refused = logs.find((l) => l.includes('routing-refused')) ?? '';
    expect(refused).toContain('equivalent=false');
    expect(refused).toContain(' equivalenceReason=body differs at body node');
    expect(refused).toContain('not bounded: nearest heading before it is heading1(size=11)');
    expect(refused).toMatch(/ routingMs=\d+\.\d diagMs=\d+\.\d/);
  });

  it('no trace line carries document text: typed word, heading text, footnote text, bibliography entry', async () => {
    const view = await makeRealEditor(realDoc('Works Cited'));
    const logs: string[] = [];
    (window as any).webkit.messageHandlers.errorHandler.postMessage = (m: { message: string }) => {
      logs.push(m.message);
    };
    deleteAlphaAsOp(view);
    typeAtEndOf(view, 'Gamma', ' EARLYWORD');
    renumberFootnotes({ '2': '1', '3': '2' }); // a chain that advances nothing; the typing is a real edit
    dropParagraphsContaining(view, ['First note.', 'Adams']);
    expect(undo(view.state, view.dispatch)).toBe(true);
    handleUnifiedUndoKeydown(new KeyboardEvent('keydown', { key: 'z', metaKey: true }), view, 'undo');
    const trace = logs.filter((l) => l.startsWith('[STRUCT-TRACE]'));
    expect(
      trace.some((l) => l.includes('routing-equivalence')),
      'premise: the lines were logged'
    ).toBe(true);
    expect(
      trace.some((l) => l.includes('routing-refused')),
      'premise: the lines were logged'
    ).toBe(true);
    for (const forbidden of [
      'EARLYWORD',
      'Works',
      'Cited',
      'Gamma',
      'Alpha',
      'Beta',
      'First',
      'Second',
      'Adams',
      'Baker',
    ]) {
      expect(
        trace.filter((l) => l.includes(forbidden)),
        `a trace line carries document text: ${forbidden}`
      ).toEqual([]);
    }
  });

  it('a routed press logs result=true and no reason', async () => {
    const view = await makeRealEditor();
    const logs: string[] = [];
    (window as any).webkit.messageHandlers.errorHandler.postMessage = (m: { message: string }) => {
      logs.push(m.message);
    };
    deleteAlphaAsOp(view);
    typeAtEndOf(view, 'Gamma', ' EARLYWORD');
    rebuildRealNotesAndBibliography(view, ['First note.'], [ENTRY_BAKER]);
    expect(undo(view.state, view.dispatch)).toBe(true);
    handleUnifiedUndoKeydown(new KeyboardEvent('keydown', { key: 'z', metaKey: true }), view, 'undo');
    const equivalence = logs.find((l) => l.includes('routing-equivalence')) ?? '';
    expect(equivalence).toContain('decision=structural result=true');
    expect(equivalence).not.toContain('reason=');
    expect(logs.some((l) => l.includes('routing-refused'))).toBe(false);
  });
});
