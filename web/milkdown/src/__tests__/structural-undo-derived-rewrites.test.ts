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
import { blockSyncPlugin, hasUnsettledLocalEdit, resetBlockSyncState, setSyncPaused } from '../block-sync-plugin';
import { docsEquivalentIgnoringDerived, explainDerivedDifference } from '../derived-equivalence';
import { setEditorInstance } from '../editor-state';
import { footnotePlugin, renumberFootnotes } from '../footnote-plugin';
import { highlightPlugin } from '../highlight-plugin';
import { USER_DIFF_CELL_BUDGET } from '../saved-copy-rebase';
import {
  beginStructuralOp,
  decideRedoRouting,
  decideUndoRouting,
  finalizeStructuralOpPostOpDoc,
  getRegistry,
  getUndoDescriptor,
  handleUndoReplyFromSwift,
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

  it('exact equality alone (no fallback): typing BEFORE a rewrite lands, then undoing the typing, now routes exactly: the saved copy followed the rewrite (t-dfc4fb02)', async () => {
    const view = await makeSectionsEditor();
    await deleteSection(OP_A, AFTER_DELETE_ALPHA);
    setUndoDescriptor({ undoTopOpId: OP_A });
    typeAtEndOf(view, 'Paragraph seven', ' EARLYWORD');
    automaticRebuildAddsSection(view, 'Notes', 'Rebuilt note.');
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).not.toContain('EARLYWORD');
    expect(undoDecision(view)).toEqual(STRUCTURAL_A);
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
    expect(view.state.doc.eq(savedPostOp()), 'the saved copy followed the rebuild (t-dfc4fb02)').toBe(true);
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
    expect(view.state.doc.eq(savedPostOp()), 'the saved copy followed the rebuild (t-dfc4fb02)').toBe(true);
    expect(undoWithFallback(view)).toEqual(STRUCTURAL_A);
  });

  it('R1: after a fallback-routed undo and a redo, the saved copy is re-anchored: a later rewrite is absorbed and the next Cmd-Z routes EXACTLY (no fallback)', async () => {
    const view = await makeNotesEditor();
    deleteAlphaAsOp(view);
    editFootnoteText(view, 'Second note.', ' EDITEDNOTE'); // the user edits a still-referenced footnote
    relabelAsSync(view, { '2': '7' }); // an automatic rewrite of that same block: never folded into the saved copy
    expect(undo(view.state, view.dispatch)).toBe(true); // the user undoes the edit
    expect(view.state.doc.textContent).not.toContain('EDITEDNOTE');
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
    expect(view.state.doc.eq(savedPostOp()), 'the saved copy followed the rebuild (t-dfc4fb02)').toBe(true);
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

  it('RS5: with a custom bibliography heading, the saved copy follows the rebuild, so the press routes exactly (t-dfc4fb02)', async () => {
    const view = await makeRealEditor(realDoc('Works Cited'));
    deleteAlphaAsOp(view);
    typeAtEndOf(view, 'Gamma', ' EARLYWORD');
    dropParagraphsContaining(view, ['First note.', 'Adams']);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).not.toContain('EARLYWORD');
    expect(undoWithFallback(view)).toEqual(STRUCTURAL_A);
  });

  // RS5b pins the limit that RS5's flip leaves: it is NOT a must-fail test (it passes with the fix in and out). When the
  // saved copy cannot follow the rewrite (here the rewrite overlaps the user's own edit), the press is decided by the
  // fallback comparison, which does not recognise a custom bibliography heading and compares that region exactly.
  it('RS5b limit (t-a4b4c914): a custom bibliography heading with a rewrite that overlaps the user edit: the fallback does not recognise the region and refuses, never a wrong undo', async () => {
    const view = await makeRealEditor(realDoc('Works Cited'));
    deleteAlphaAsOp(view);
    editFootnoteText(view, 'Second note.', ' EDITEDNOTE'); // the user edits a still-referenced footnote
    relabelAsSync(view, { '2': '7' }, ['Adams']); // an automatic rewrite of that definition that also drops a bibliography entry
    expect(undo(view.state, view.dispatch)).toBe(true); // the user undoes the edit
    expect(view.state.doc.textContent).not.toContain('EDITEDNOTE');
    expect(undoWithFallback(view), 'the removed entry sits in an unrecognised region: compared exactly').toEqual(
      FALLTHROUGH
    );
    const reason = explainDerivedDifference(view.state.doc, savedPostOp()) ?? '';
    expect(reason, 'the fallback says "different" and names the unrecognised bibliography region').toContain(
      'body differs at body node'
    );
    expect(reason).toContain('not bounded: nearest heading before it is heading1(size=11)');
    expect(reason).toContain('titleMatches=false');
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
    // The automatic rewrite overlaps the user's own edit, so the saved copy does not follow it (t-dfc4fb02)
    // and the fallback comparison still has to run.
    editFootnoteText(view, 'Second note.', ' EDITEDNOTE');
    relabelAsSync(view, { '2': '7' }, ['Adams']);
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
    // The rewrite overlaps the user's own edit, so the saved copy does not follow it (t-dfc4fb02): only the
    // fallback comparison can route this press, which is the line this test reads.
    editFootnoteText(view, 'Second note.', ' EDITEDNOTE');
    relabelAsSync(view, { '2': '7' });
    expect(undo(view.state, view.dispatch)).toBe(true);
    handleUnifiedUndoKeydown(new KeyboardEvent('keydown', { key: 'z', metaKey: true }), view, 'undo');
    const equivalence = logs.find((l) => l.includes('routing-equivalence')) ?? '';
    expect(equivalence).toContain('decision=structural result=true');
    expect(equivalence).not.toContain('reason=');
    expect(logs.some((l) => l.includes('routing-refused'))).toBe(false);
  });
});

// === t-dfc4fb02: the saved copy follows a rebuild that lands after the user started typing ===
// The editor-first delete leaves the deleted section's footnote definitions in Notes. The renumber (posted before
// the delete's job runs) moves the survivors onto those numbers and is absorbed into the saved post-delete copy,
// which then defines a label twice. Typing before the Notes rebuild lands kept the rebuild out of the saved copy,
// so after the typing was undone every Cmd-Z was refused.
//
// TR3, TR4 and TR6c are MECHANISM tests. TR1, TR2, TR5, TR6, TR6b, TR7, S1 and S2 are the user-outcome
// reproductions. FS1, FS1b, FS2 and TB1 are guards.

/** A sync-origin relabel of footnotes (references and definitions together), optionally removing top-level
 * paragraphs in the SAME transaction: an automatic rewrite, not in the text history. */
function relabelAsSync(view: EditorView, map: Record<string, string>, dropTexts: string[] = []): void {
  const tr = view.state.tr;
  view.state.doc.descendants((n, pos) => {
    const to = map[String(n.attrs.label)];
    if ((n.type.name === 'footnote_ref' || n.type.name === 'footnote_def') && to) {
      tr.setNodeMarkup(pos, undefined, { ...n.attrs, label: to });
    }
  });
  const drops: Array<{ from: number; to: number }> = [];
  view.state.doc.forEach((node, pos) => {
    if (node.type.name === 'paragraph' && dropTexts.some((t) => node.textContent.includes(t))) {
      drops.push({ from: pos, to: pos + node.nodeSize });
    }
  });
  for (const d of drops.reverse()) tr.delete(tr.mapping.map(d.from), tr.mapping.map(d.to));
  expect(tr.docChanged, 'premise: the rewrite changed the document').toBe(true);
  view.dispatch(tr.setMeta('addToHistory', false));
}

/** The real document shape at BOOK size, with no footnote-count premises (makeRealEditor's are specific to the small fixture). */
async function makeBookEditor(markdown: string): Promise<EditorView> {
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
  return view;
}

describe('t-dfc4fb02: typing before the Notes rebuild lands, then Cmd-Z', () => {
  it('TR1: renumber absorbed, typing, Notes rebuild: once the typing is undone, Cmd-Z restores the section', async () => {
    const view = await makeNotesEditor();
    deleteAlphaAsOp(view); // footnote 1's definition stays as an orphan
    renumberFootnotes({ '2': '1', '3': '2' }); // before the first keystroke: absorbed into the saved copy
    expect(labelsIn(savedPostOp(), 'footnote_def'), 'premise: the saved copy defines label 1 twice').toEqual([
      '1',
      '1',
      '2',
    ]);
    typeAtEndOf(view, 'Gamma', ' EARLYWORD');
    rebuildNotesAndBibliography(view, ['First note.'], ['Entry Beta.']); // lands AFTER the typing
    expect(savedPostOp().textContent, 'the typed word never enters the saved copy').not.toContain('EARLYWORD');
    expect(undoWithFallback(view), 'the typed word is still there').toEqual(FALLTHROUGH);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).not.toContain('EARLYWORD');
    expect(undoWithFallback(view)).toEqual(STRUCTURAL_A);
  });

  it('TR2 (real document shape, no bibliography opening marker): the same', async () => {
    const view = await makeRealEditor();
    deleteAlphaAsOp(view);
    renumberFootnotes({ '2': '1', '3': '2' });
    expect(labelsIn(savedPostOp(), 'footnote_def'), 'premise: the saved copy defines label 1 twice').toEqual([
      '1',
      '1',
      '2',
    ]);
    typeAtEndOf(view, 'Gamma', ' EARLYWORD');
    rebuildRealNotesAndBibliography(view, ['First note.'], [ENTRY_BAKER]);
    expect(undoWithFallback(view)).toEqual(FALLTHROUGH);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).not.toContain('EARLYWORD');
    expect(undoWithFallback(view)).toEqual(STRUCTURAL_A);
  });

  it('TR3 (mechanism): once the typing is undone the document EQUALS the saved copy (exact; the saved copy followed the rebuild)', async () => {
    const view = await makeNotesEditor();
    deleteAlphaAsOp(view);
    renumberFootnotes({ '2': '1', '3': '2' });
    typeAtEndOf(view, 'Gamma', ' EARLYWORD');
    rebuildNotesAndBibliography(view, ['First note.'], ['Entry Beta.']);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.eq(savedPostOp())).toBe(true);
    expect(undoDecision(view)).toEqual(STRUCTURAL_A);
  });

  it('TR4 (mechanism): a renumber after the typing stays OUT of the saved copy (the user undoes it); the rebuild after it is folded in', async () => {
    const view = await makeNotesEditor();
    deleteAlphaAsOp(view);
    typeAtEndOf(view, 'Gamma', ' EARLYWORD');
    const beforeRenumber = savedPostOp();
    renumberFootnotes({ '2': '1', '3': '2' });
    expect(savedPostOp(), 'a chain in the text history is never folded into the saved copy').toBe(beforeRenumber);
    rebuildNotesAndBibliography(view, ['First note.'], ['Entry Beta.']);
    expect(undo(view.state, view.dispatch)).toBe(true); // the renumber
    expect(undo(view.state, view.dispatch)).toBe(true); // the typing
    expect(view.state.doc.textContent).not.toContain('EARLYWORD');
    expect(undoDecision(view), 'exact equality: the saved copy followed the rebuild').toEqual(STRUCTURAL_A);
  });

  it('TR5: two deletes, the renumber absorbed into the second one, typing, rebuild: the second section returns, then the first; only the newest entry is rebased', async () => {
    const view = await makeNotesEditor();
    deleteAlphaAsOp(view);
    const savedA = savedPostOp();
    // A second delete (Gamma, no footnote) as an op of its own: the newest registry entry.
    expect(beginStructuralOp(OP_B)).toBe(true);
    let from = -1;
    let to = -1;
    view.state.doc.forEach((node, pos) => {
      if (from < 0 && node.type.name === 'heading' && node.textContent === 'Gamma') from = pos;
      if (from >= 0 && to < 0 && node.type.name === 'paragraph' && node.textContent.startsWith('Gamma')) {
        to = pos + node.nodeSize;
      }
    });
    expect(from >= 0 && to > from, 'premise: the Gamma section exists').toBe(true);
    view.dispatch(view.state.tr.delete(from, to).setMeta('addToHistory', false));
    expect(finalizeStructuralOpPostOpDoc(OP_B)).toBe(true);
    setUndoDescriptor({ undoTopOpId: OP_B });
    renumberFootnotes({ '2': '1', '3': '2' }); // absorbed into OP_B's saved copy only
    expect(
      labelsIn(getRegistry().get(OP_B)!.postOpDoc, 'footnote_def'),
      "premise: OP_B's saved copy defines label 1 twice"
    ).toEqual(['1', '1', '2']);
    typeAtEndOf(view, 'Beta', ' EARLYWORD');
    rebuildNotesAndBibliography(view, ['First note.'], ['Entry Beta.']); // drops the only orphan, as the real rebuild does
    expect(getRegistry().get(OP_A)!.postOpDoc, 'the older entry is not rebased').toBe(savedA);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).not.toContain('EARLYWORD');
    expect(undoWithFallback(view)).toEqual({ action: 'structural', opId: OP_B });
    expect(performStructuralSwap(OP_B, 'undo')).toBe(true);
    setUndoDescriptor({ undoTopOpId: OP_A, redoTopOpId: OP_B });
    expect(undoDecision(view), 'the older entry still routes exactly once the newer one is undone').toEqual(
      STRUCTURAL_A
    );
  });

  it('TR6: the user adds a paragraph (one block more) before the rebuild lands: Cmd-Z still restores the section', async () => {
    const view = await makeNotesEditor();
    deleteAlphaAsOp(view);
    renumberFootnotes({ '2': '1', '3': '2' });
    const { schema } = view.state;
    const g = paragraphRange(view, 'Gamma');
    view.dispatch(view.state.tr.insert(g.to + 1, schema.nodes.paragraph.create(null, schema.text('NEWPARA'))));
    rebuildNotesAndBibliography(view, ['First note.'], ['Entry Beta.']);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).not.toContain('NEWPARA');
    expect(undoWithFallback(view)).toEqual(STRUCTURAL_A);
  });

  it('TR6b: the user deletes a paragraph (one block fewer) before the rebuild lands: Cmd-Z brings it back, then the section', async () => {
    const view = await makeNotesEditor();
    deleteAlphaAsOp(view);
    renumberFootnotes({ '2': '1', '3': '2' });
    const g = paragraphRange(view, 'Gamma');
    view.dispatch(view.state.tr.delete(g.from - 1, g.to + 1));
    expect(view.state.doc.textContent, 'premise: the paragraph is gone').not.toContain('Gamma plain text.');
    rebuildNotesAndBibliography(view, ['First note.'], ['Entry Beta.']);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).toContain('Gamma plain text.');
    expect(undoWithFallback(view)).toEqual(STRUCTURAL_A);
  });

  it('TR6c (mechanism): an automatic change that only INSERTS a block, after the user added a paragraph, lands at the same place in the saved copy', async () => {
    const view = await makeNotesEditor();
    deleteAlphaAsOp(view);
    const { schema } = view.state;
    const g = paragraphRange(view, 'Gamma');
    view.dispatch(view.state.tr.insert(g.to + 1, schema.nodes.paragraph.create(null, schema.text('NEWPARA'))));
    let endPos = -1;
    view.state.doc.forEach((n, pos) => {
      if (n.type.name === 'auto_bibliography_end') endPos = pos;
    });
    expect(endPos).toBeGreaterThan(0);
    view.dispatch(
      view.state.tr
        .insert(endPos, schema.nodes.paragraph.create(null, schema.text('Entry Zed.')))
        .setMeta('addToHistory', false)
    );
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).not.toContain('NEWPARA');
    expect(view.state.doc.eq(savedPostOp()), 'the saved copy holds the inserted entry at the same place').toBe(true);
    expect(undoDecision(view)).toEqual(STRUCTURAL_A);
  });

  it('S1 (sibling cause 1): a Cmd-Z pressed right after the press that undid the typing, while the detect timer is still pending, restores the section (keydown path)', async () => {
    const view = await makeSectionsEditor();
    await deleteSection(OP_A, AFTER_DELETE_ALPHA);
    setUndoDescriptor({ undoTopOpId: OP_A });
    const posted: unknown[] = [];
    (window as any).webkit.messageHandlers.structuralUndoRequested = { postMessage: (m: unknown) => posted.push(m) };
    typeAtEndOf(view, 'Paragraph seven', ' TYPEDWORD');
    await vi.advanceTimersByTimeAsync(200); // the typing has settled
    expect(undo(view.state, view.dispatch)).toBe(true); // the press that undid the typing (Milkdown's own keymap)
    expect(view.state.doc.textContent).not.toContain('TYPEDWORD');
    expect(hasUnsettledLocalEdit(), "premise: that undo's 100 ms detect timer is still pending").toBe(true);
    const logs: string[] = [];
    (window as any).webkit.messageHandlers.errorHandler.postMessage = (m: { message: string }) => {
      logs.push(m.message);
    };
    const key = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });
    expect(handleUnifiedUndoKeydown(key, view, 'undo'), 'the press is routed, not left to the text undo').toBe(true);
    expect(posted).toEqual([{ opId: OP_A }]);
    // The flush is logged once, counts only, because a timer was pending before it.
    const flushLines = logs.filter((l) => l.includes('routing-flush'));
    expect(flushLines).toHaveLength(1);
    expect(flushLines[0]).toMatch(/^\[STRUCT-TRACE\] routing-flush direction=undo ms=\d+\.\d$/);
  });

  it('S2 (S-F6): a keystroke right after the first renumbered footnote marker, within half a second, is its own undo step; Cmd-Z then restores the section', async () => {
    const view = await makeNotesEditor();
    deleteAlphaAsOp(view);
    renumberFootnotes({ '2': '1', '3': '2' }); // absorbed into the saved copy
    let refEnd = -1;
    view.state.doc.descendants((n, pos) => {
      if (refEnd < 0 && n.type.name === 'footnote_ref') refEnd = pos + n.nodeSize;
    });
    expect(refEnd).toBeGreaterThan(0);
    view.dispatch(view.state.tr.insertText('X', refEnd)); // typed straight after the first relabelled marker
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(labelsIn(view.state.doc, 'footnote_ref'), 'the undo took back only the typing, not the renumber').toEqual([
      '1',
      '2',
    ]);
    expect(undoWithFallback(view)).toEqual(STRUCTURAL_A);
  });

  // FS1 goes red only if BOTH the overlap rule and the block check are removed; FS1b guards the overlap rule alone.
  it('FS1 fail-safe: an automatic rewrite of a block the user changed is never folded in, and the user text never enters the saved copy', async () => {
    const view = await makeNotesEditor();
    deleteAlphaAsOp(view);
    const saved = savedPostOp();
    editFootnoteText(view, 'Second note.', ' EDITEDNOTE'); // the user edits a still-referenced footnote
    relabelAsSync(view, { '2': '7' }); // an automatic rewrite of that same definition (and its reference)
    expect(savedPostOp(), 'not rebased: the rewrite touched the block the user changed').toBe(saved);
    expect(savedPostOp().textContent).not.toContain('EDITEDNOTE');
    expect(undoWithFallback(view), 'the edit is still there').toEqual(FALLTHROUGH);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).not.toContain('EDITEDNOTE');
    expect(undoWithFallback(view), 'the fallback still routes it: only labels differ').toEqual(STRUCTURAL_A);
  });

  it('FS1b fail-safe (overlap rule alone): an automatic insertion between two paragraphs the user just added is never folded in', async () => {
    const view = await makeNotesEditor();
    deleteAlphaAsOp(view);
    const saved = savedPostOp();
    const { schema } = view.state;
    const g = paragraphRange(view, 'Gamma');
    view.dispatch(
      view.state.tr.insert(g.to + 1, [
        schema.nodes.paragraph.create(null, schema.text('USERONE')),
        schema.nodes.paragraph.create(null, schema.text('USERTWO')),
      ])
    );
    const one = paragraphRange(view, 'USERONE');
    view.dispatch(
      view.state.tr
        .insert(one.to + 1, schema.nodes.paragraph.create(null, schema.text('AUTOPARA')))
        .setMeta('addToHistory', false)
    );
    expect(savedPostOp(), 'not rebased: the insertion lands inside the blocks the user added').toBe(saved);
  });

  it('FS2 (flow test, not a guard of the limits; FS1/FS1b/TB1 guard them): delete; Cmd-Z; type; rebuild; Cmd-Shift-Z; Cmd-Z; Cmd-Z; Cmd-Shift-Z; Cmd-Z: nothing typed is lost, every structural press lands on the right document', async () => {
    const view = await makeNotesEditor();
    deleteAlphaAsOp(view);
    expect(undoWithFallback(view)).toEqual(STRUCTURAL_A); // Cmd-Z: the section comes back
    expect(performStructuralSwap(OP_A, 'undo')).toBe(true);
    setUndoDescriptor({ redoTopOpId: OP_A });
    expect(view.state.doc.textContent).toContain('Alpha text with a note.');
    typeAtEndOf(view, 'Gamma', ' LATEWORD');
    rebuildNotesAndBibliography(view, [], ['Entry Alpha.', 'Entry Beta.', 'Entry Gamma.']); // the restore's rebuild, after the typing
    expect(savedPostOp().textContent, 'the typed word never enters a saved copy').not.toContain('LATEWORD');
    expect(getRegistry().get(OP_A)!.preOpDoc.textContent).not.toContain('LATEWORD');
    expect(redoWithFallback(view), 'Cmd-Shift-Z with the typed word on screen is never the structural redo').toEqual(
      FALLTHROUGH
    );
    expect(view.state.doc.textContent).toContain('LATEWORD');
    expect(undoWithFallback(view)).toEqual(FALLTHROUGH); // Cmd-Z: a text undo of the typing
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).not.toContain('LATEWORD');
    expect(undoWithFallback(view)).toEqual(FALLTHROUGH); // Cmd-Z again: nothing left, nothing structural
    expect(undo(view.state, view.dispatch)).toBe(false);
    expect(redoWithFallback(view)).toEqual(STRUCTURAL_A); // Cmd-Shift-Z: the delete is redone
    expect(performStructuralSwap(OP_A, 'redo')).toBe(true);
    setUndoDescriptor({ undoTopOpId: OP_A });
    expect(view.state.doc.textContent).not.toContain('Alpha text with a note.');
    expect(view.state.doc.textContent).toContain('Gamma plain text.');
    expect(undoDecision(view)).toEqual(STRUCTURAL_A); // Cmd-Z: the section comes back again
    expect(performStructuralSwap(OP_A, 'undo')).toBe(true);
    expect(view.state.doc.textContent).toContain('Alpha text with a note.');
    expect(view.state.doc.textContent).not.toContain('LATEWORD');
  });

  // Round F3 of t-18b7fa48 changed TB1 deliberately: it used to pin result=too-far for edits in chapter 2 and chapter 10,
  // which is the exact refusal the judge's ruling removed (the single trimmed-middle cost check treated the two edits as
  // one region of several hundred blocks). The cost bound itself is kept, per region, in TB1b.
  it('TB1 (regions): on a book-sized document, edits in chapter 2 and chapter 10 are two small regions: the rebuild is rebased and the typed words never enter the saved copy', async () => {
    const lines: string[] = [];
    let n = 0;
    for (let c = 1; c <= 12; c++) {
      lines.push(`# Chapter ${c}`);
      for (let p = 1; p <= 40; p++) {
        n++;
        lines.push(`Chapter ${c} paragraph ${p} text.[^${n}]`);
      }
    }
    const defs = Array.from({ length: n }, (_, i) => `[^${i + 1}]: Note ${i + 1}.`);
    const view = await makeBookEditor(
      [...lines, '# Notes', ...defs, '# Bibliography', 'Entry 1.', 'Entry 2.', END_MARKER].join('\n\n')
    );
    const logs: string[] = [];
    (window as any).webkit.messageHandlers.errorHandler.postMessage = (m: { message: string }) => {
      logs.push(m.message);
    };
    deleteAlphaAsOp(view); // Chapter 1's heading and first paragraph, as an operation
    const saved = savedPostOp();
    typeAtEndOf(view, 'Chapter 2 paragraph 5 ', ' EDITTWO');
    typeAtEndOf(view, 'Chapter 10 paragraph 5 ', ' EDITTEN');
    dropParagraphsContaining(view, ['Entry 1.']); // an automatic change
    const rebased = savedPostOp();
    expect(rebased, 'rebased: the saved copy followed the automatic change').not.toBe(saved);
    expect(rebased.textContent, 'the typed words never enter the saved copy').not.toContain('EDITTWO');
    expect(rebased.textContent).not.toContain('EDITTEN');
    expect(rebased.textContent, 'the automatic change did enter it').not.toContain('Entry 1.');
    const line = logs.find((l) => l.includes('registry-rebase')) ?? '';
    expect(line).toContain('result=rebased');
    expect(line).toContain('userRanges=2 chainRanges=1');
    expect(line).toMatch(/ ms=\d+\.\d/);
    expect(line, 'counts only: no document text in the line').not.toContain('EDITTWO');
  }, 30_000);

  it('TB1b (cost bound, per region): ONE stretch of the book rewritten by the user that is over the budget is still refused as too-far', async () => {
    const lines: string[] = [];
    let n = 0;
    for (let c = 1; c <= 12; c++) {
      lines.push(`# Chapter ${c}`);
      for (let p = 1; p <= 40; p++) {
        n++;
        lines.push(`Chapter ${c} paragraph ${p} text.[^${n}]`);
      }
    }
    const defs = Array.from({ length: n }, (_, i) => `[^${i + 1}]: Note ${i + 1}.`);
    const view = await makeBookEditor(
      [...lines, '# Notes', ...defs, '# Bibliography', 'Entry 1.', 'Entry 2.', END_MARKER].join('\n\n')
    );
    const logs: string[] = [];
    (window as any).webkit.messageHandlers.errorHandler.postMessage = (m: { message: string }) => {
      logs.push(m.message);
    };
    deleteAlphaAsOp(view);
    const saved = savedPostOp();
    // The user rewrites chapters 3 to 9 in one stretch: 7 chapters of a heading and 40 paragraphs, replaced by as many other paragraphs.
    let from = -1;
    let to = -1;
    let count = 0;
    view.state.doc.forEach((node, pos) => {
      const text = node.textContent;
      if (!(/^Chapter [3-9] /.test(text) || /^Chapter [3-9]$/.test(text))) return;
      if (from < 0) from = pos;
      to = pos + node.nodeSize;
      count++;
    });
    expect(count, 'premise: the stretch is 7 chapters of a heading and 40 paragraphs').toBe(7 * 41);
    expect(count * count, 'premise: the stretch is over the budget on its own').toBeGreaterThan(USER_DIFF_CELL_BUDGET);
    const { schema } = view.state;
    const replacement = Array.from({ length: count }, (_, i) =>
      schema.nodes.paragraph.create(null, schema.text(`Rewritten block ${i}.`))
    );
    view.dispatch(view.state.tr.replaceWith(from, to, replacement));
    dropParagraphsContaining(view, ['Entry 1.']); // an automatic change
    expect(savedPostOp(), 'not rebased').toBe(saved);
    const line = logs.find((l) => l.includes('registry-rebase')) ?? '';
    expect(line).toContain('result=too-far');
    expect(line).toContain(`cells=${count * count}`);
  }, 30_000);
});

// === t-dfc4fb02 through the real rebuild push ===

const REAL_PUSH_BLOCKS: TestBlock[] = [
  { id: 'h-alpha', md: '# Alpha' },
  { id: 'p-alpha', md: 'Alpha text with a note.[^1]' },
  { id: 'h-beta', md: '# Beta' },
  { id: 'p-beta', md: 'Beta text with a note.[^2] And another.[^3]' },
  { id: 'h-gamma', md: '# Gamma' },
  { id: 'p-gamma', md: 'Gamma plain text.' },
  { id: 'h-notes', md: '# Notes' },
  { id: 'd-1', md: '[^1]: First note.' },
  { id: 'd-2', md: '[^2]: Second note.' },
  { id: 'd-3', md: '[^3]: Third note.' },
  { id: 'h-bib', md: '# Bibliography' },
  { id: 'e-adams', md: ENTRY_ADAMS },
  { id: 'e-baker', md: ENTRY_BAKER },
];
const REAL_PUSH_MANAGED = ['h-notes', 'd-1', 'd-2', 'd-3', 'h-bib', 'e-adams', 'e-baker'];
const realPushMarkdown = (blocks: TestBlock[]) => `${markdownOf(blocks)}\n\n${END_MARKER}`;

/** makeSectionsEditor's style with the footnote and bibliography plugins: real block ids, block-sync, a real load push. */
async function makeRealPushEditor(
  blocks: TestBlock[] = REAL_PUSH_BLOCKS,
  managed: string[] = REAL_PUSH_MANAGED
): Promise<EditorView> {
  (window as any).webkit = { messageHandlers: { errorHandler: { postMessage: () => {} } } };
  const div = document.createElement('div');
  document.body.appendChild(div);
  const editor = await Editor.make()
    .config((ctx) => {
      ctx.set(rootCtx, div);
      ctx.set(defaultValueCtx, realPushMarkdown(blocks));
    })
    .use(blockIdPlugin)
    .use(footnotePlugin)
    .use(bibliographyPlugin)
    .use(bibliographyEndMarkerPlugin)
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
  setContentWithBlockIds(realPushMarkdown(blocks), idsOf(blocks), { managedBlockIds: managed });
  await vi.advanceTimersByTimeAsync(100);
  return view;
}

describe('t-dfc4fb02 through the real rebuild push', () => {
  it('TR7: renumber absorbed, typing, setContentWithBlockIds(..., {preserveUserBlocks: true}) without the orphan: Cmd-Z restores the section', async () => {
    const view = await makeRealPushEditor();
    deleteAlphaAsOp(view);
    renumberFootnotes({ '2': '1', '3': '2' });
    expect(labelsIn(savedPostOp(), 'footnote_def'), 'premise: the saved copy defines label 1 twice').toEqual([
      '1',
      '1',
      '2',
    ]);
    typeAtEndOf(view, 'Gamma', ' EARLYWORD');
    await vi.advanceTimersByTimeAsync(200);
    // The database after its Notes write: renumbered, the orphan gone, the deleted section's entry gone.
    // Gamma's stored row is stale (no EARLYWORD): the merge keeps the editor's own paragraph.
    const dbBlocks: TestBlock[] = [
      { id: 'h-beta', md: '# Beta' },
      { id: 'p-beta', md: 'Beta text with a note.[^1] And another.[^2]' },
      { id: 'h-gamma', md: '# Gamma' },
      { id: 'p-gamma', md: 'Gamma plain text.' },
      { id: 'h-notes', md: '# Notes' },
      { id: 'd-2', md: '[^1]: Second note.' },
      { id: 'd-3', md: '[^2]: Third note.' },
      { id: 'h-bib', md: '# Bibliography' },
      { id: 'e-baker', md: ENTRY_BAKER },
    ];
    const merged = setContentWithBlockIds(realPushMarkdown(dbBlocks), idsOf(dbBlocks), {
      managedBlockIds: ['h-notes', 'd-2', 'd-3', 'h-bib', 'e-baker'],
      preserveUserBlocks: true,
    });
    expect(merged, 'premise: the merge kept the typing').toContain('EARLYWORD');
    await vi.advanceTimersByTimeAsync(200);
    expect(labelsIn(view.state.doc, 'footnote_def'), 'premise: the orphan is gone from the editor').toEqual(['1', '2']);
    expect(undo(view.state, view.dispatch)).toBe(true);
    expect(view.state.doc.textContent).not.toContain('EARLYWORD');
    expect(undoWithFallback(view)).toEqual(STRUCTURAL_A);
  });
});

// === t-dfc4fb02 at BOOK scale, the late order: the user types BEFORE the footnote renumber lands ===
//
// The renumber is posted from the footnote write's `prepare` (FootnoteSyncService), which starts at the footnote burst
// deadline (about 3 s) or after the delete's job and the bibliography resync, so a user who clicks back and types
// straight after Delete Section usually types first: typing, then the renumber (a history step), then the real Notes push.

const BOOK_CHAPTERS = 12;
const BOOK_PARAGRAPHS = 40;
const BOOK_NOTES_PER_CHAPTER = 3; // the first three paragraphs of every chapter carry a footnote: 36 footnotes

/** A 12-chapter book in the Swift-assembled shape, with real block ids: "# Chapter c", 40 paragraphs each, then Notes with
 * one definition per footnote, then Bibliography. With `afterChapterOneDeleted` it is the DATABASE after the delete's Notes
 * rebuild: chapter 1 and its three footnotes gone, the survivors' footnotes renumbered from 1 (the same ids and texts). */
function bookBlocks(afterChapterOneDeleted: boolean): { blocks: TestBlock[]; managed: string[] } {
  const blocks: TestBlock[] = [];
  const defs: TestBlock[] = [];
  let n = 0;
  for (let c = 1; c <= BOOK_CHAPTERS; c++) {
    const gone = afterChapterOneDeleted && c === 1;
    if (!gone) blocks.push({ id: `h-${c}`, md: `# Chapter ${c}` });
    for (let p = 1; p <= BOOK_PARAGRAPHS; p++) {
      let md = `Chapter ${c} paragraph ${p} text.`;
      if (p <= BOOK_NOTES_PER_CHAPTER) {
        n++;
        const label = afterChapterOneDeleted ? n - BOOK_NOTES_PER_CHAPTER : n;
        md += `[^${label}]`;
        if (!gone) defs.push({ id: `d-${n}`, md: `[^${label}]: Note ${n}.` });
      }
      if (!gone) blocks.push({ id: `p-${c}-${p}`, md });
    }
  }
  const tail: TestBlock[] = [
    { id: 'h-notes', md: '# Notes' },
    ...defs,
    { id: 'h-bib', md: '# Bibliography' },
    { id: 'e-1', md: ENTRY_ADAMS },
    { id: 'e-2', md: ENTRY_BAKER },
  ];
  return { blocks: [...blocks, ...tail], managed: tail.map((b) => b.id) };
}

/** Delete Section on chapter 1 (its heading and its 40 paragraphs, three footnotes), as an operation of its own. The
 * chapter's definitions stay in Notes, as the editor-first delete leaves them. */
function deleteChapterOneAsOp(view: EditorView): void {
  expect(beginStructuralOp(OP_A)).toBe(true);
  let end = 0;
  for (let i = 0; i <= BOOK_PARAGRAPHS; i++) end += view.state.doc.child(i).nodeSize;
  view.dispatch(view.state.tr.delete(0, end).setMeta('addToHistory', false));
  expect(finalizeStructuralOpPostOpDoc(OP_A)).toBe(true);
  setUndoDescriptor({ undoTopOpId: OP_A });
}

describe('t-dfc4fb02 at book scale: the renumber lands AFTER the typing (late order)', () => {
  it('BS1: delete a chapter with footnotes, type, renumber (a history step), real Notes push: repeated Cmd-Z brings the chapter back with its footnote numbers', async () => {
    const book = bookBlocks(false);
    const view = await makeRealPushEditor(book.blocks, book.managed);
    const logs: string[] = [];
    const posted: unknown[] = [];
    (window as any).webkit.messageHandlers.errorHandler.postMessage = (m: { message: string }) => {
      logs.push(m.message);
    };
    (window as any).webkit.messageHandlers.structuralUndoRequested = { postMessage: (m: unknown) => posted.push(m) };
    const refsBefore = labelsIn(view.state.doc, 'footnote_ref');
    const defsBefore = labelsIn(view.state.doc, 'footnote_def');
    const footnotes = BOOK_CHAPTERS * BOOK_NOTES_PER_CHAPTER;
    expect(refsBefore, 'premise: 36 footnote references, numbered 1 to 36').toEqual(
      Array.from({ length: footnotes }, (_, i) => String(i + 1))
    );
    expect(defsBefore, 'premise: 36 footnote definitions').toEqual(refsBefore);

    deleteChapterOneAsOp(view);
    typeAtEndOf(view, 'Chapter 5 paragraph 20 ', ' EARLYWORD'); // the user types straight away
    // Then the footnote write's renumber lands: the survivors move down by the deleted chapter's three numbers. The
    // deleted chapter's definitions are still in Notes, so labels 1 to 3 are defined twice until the Notes push lands.
    const mapping: Record<string, string> = {};
    for (let n = BOOK_NOTES_PER_CHAPTER + 1; n <= footnotes; n++)
      mapping[String(n)] = String(n - BOOK_NOTES_PER_CHAPTER);
    renumberFootnotes(mapping);
    expect(labelsIn(view.state.doc, 'footnote_ref')[0], 'premise: the renumber landed after the typing').toBe('1');
    expect(
      labelsIn(view.state.doc, 'footnote_def').filter((l) => l === '1'),
      'premise: label 1 is defined twice until the Notes push lands'
    ).toHaveLength(2);
    await vi.advanceTimersByTimeAsync(200);

    // The real Notes push: the database after its Notes write (chapter 1's definitions gone, survivors renumbered).
    const db = bookBlocks(true);
    const merged = setContentWithBlockIds(realPushMarkdown(db.blocks), idsOf(db.blocks), {
      managedBlockIds: db.managed,
      preserveUserBlocks: true,
    });
    expect(merged, 'premise: the merge kept the typing').toContain('EARLYWORD');
    await vi.advanceTimersByTimeAsync(200);
    expect(
      labelsIn(view.state.doc, 'footnote_def'),
      'premise: the deleted chapter definitions are gone from the editor'
    ).toEqual(Array.from({ length: footnotes - BOOK_NOTES_PER_CHAPTER }, (_, i) => String(i + 1)));

    // Cmd-Z through the live routing, one press at a time, as the keydown path does: a press that is not routed is
    // the editor's own text undo.
    const decisions: string[] = [];
    let restored = false;
    for (let press = 1; press <= 8 && !restored; press++) {
      const typedOnScreen = view.state.doc.textContent.includes('EARLYWORD');
      const renumberOnScreen = labelsIn(view.state.doc, 'footnote_ref')[0] === '1';
      logs.length = 0;
      const key = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });
      const routed = handleUnifiedUndoKeydown(key, view, 'undo');
      const refusals = logs.filter((l) => l.includes('routing-refused'));
      for (const line of refusals)
        expect(line, `press ${press}: refused for the old reason`).not.toContain('defined twice');
      if (!typedOnScreen && !renumberOnScreen) {
        expect(refusals, `press ${press}: nothing of the user's is left on screen, so no refusal`).toEqual([]);
      }
      if (routed) {
        decisions.push('structural');
        expect(posted).toEqual([{ opId: OP_A }]);
        expect(performStructuralSwap(OP_A, 'undo')).toBe(true);
        handleUndoReplyFromSwift({ opId: OP_A, outcome: 'performed' }, 'undo');
        restored = true;
      } else {
        decisions.push('fallthrough');
        expect(undo(view.state, view.dispatch), `press ${press}: the editor's own text undo`).toBe(true);
      }
      // The typed word never enters a saved copy (nor the checkpoint).
      const entry = getRegistry().get(OP_A)!;
      expect(entry.postOpDoc.textContent).not.toContain('EARLYWORD');
      expect(entry.preOpDoc.textContent).not.toContain('EARLYWORD');
      expect(entry.checkpoint.doc.textContent).not.toContain('EARLYWORD');
    }

    expect(
      decisions,
      'the renumber, then the typing, are taken back as text; the third press restores the chapter'
    ).toEqual(['fallthrough', 'fallthrough', 'structural']);
    expect(view.state.doc.textContent, 'the chapter is back').toContain('Chapter 1 paragraph 1 text.');
    expect(view.state.doc.textContent, 'the typed word is gone').not.toContain('EARLYWORD');
    expect(
      labelsIn(view.state.doc, 'footnote_ref'),
      'the footnote numbers are what they were before the delete'
    ).toEqual(refsBefore);
    expect(labelsIn(view.state.doc, 'footnote_def')).toEqual(defsBefore);
  }, 60_000);
});

// === Round F3b of t-18b7fa48: a chapter in the MIDDLE of the book, definitions with repeating texts ===
//
// The real-app finding (testTypeDuringUndoingNoticeAtPersonPace_book6): the deleted chapter's footnote definitions (the
// orphans) sit in the MIDDLE of Notes, and the book's footnote texts repeat (the generator cycles through a few notes; a
// real scholar's "Ibid." does the same). After the renumber (a history step, landed after the typing) the survivors' definitions
// carry the orphans' numbers, and the real Notes push's block diff then deletes the RELABELLED copies (they are
// block-for-block equal to the orphans) and keeps the orphans. Taking the renumber back as text moves the references back to
// their old numbers but cannot bring the deleted copies back, so references of the old numbers have NO definition in the live
// document while the saved copy has them. The comparison called that a difference for ever (`footnote text differs at
// reference N: a=no definition b=(size=..)`), so Cmd-Z never reached the section. Nothing is lost by swapping in that state:
// the live document merely LACKS definitions the saved copy holds, and the swap puts them back.

const MID_CHAPTERS = 6;
const MID_PARAGRAPHS = 40;
const MID_NOTES_PER_CHAPTER = 3; // the first three paragraphs of every chapter carry a footnote: 18 footnotes
const MID_DELETED_CHAPTER = 3; // footnotes 7 to 9

/** The 6-chapter book in the Swift-assembled shape with real block ids, footnote texts that REPEAT every chapter ("Note 1." ..
 * "Note 3.", like the generator and like a scholar's "Ibid."). With `afterChapterDeleted` it is the DATABASE after the delete's
 * Notes rebuild: the chapter and its three footnotes gone, the survivors' footnotes renumbered from 7 down (same ids and texts). */
function midBookBlocks(afterChapterDeleted: boolean): { blocks: TestBlock[]; managed: string[] } {
  const blocks: TestBlock[] = [];
  const defs: TestBlock[] = [];
  let n = 0;
  for (let c = 1; c <= MID_CHAPTERS; c++) {
    const gone = afterChapterDeleted && c === MID_DELETED_CHAPTER;
    if (!gone) blocks.push({ id: `h-${c}`, md: `# Chapter ${c}` });
    for (let p = 1; p <= MID_PARAGRAPHS; p++) {
      let md = `Chapter ${c} paragraph ${p} text.`;
      if (p <= MID_NOTES_PER_CHAPTER) {
        n++;
        const label = afterChapterDeleted && c > MID_DELETED_CHAPTER ? n - MID_NOTES_PER_CHAPTER : n;
        md += `[^${label}]`;
        if (!gone) defs.push({ id: `d-${n}`, md: `[^${label}]: Note ${((n - 1) % MID_NOTES_PER_CHAPTER) + 1}.` });
      }
      if (!gone) blocks.push({ id: `p-${c}-${p}`, md });
    }
  }
  const tail: TestBlock[] = [
    { id: 'h-notes', md: '# Notes' },
    ...defs,
    { id: 'h-bib', md: '# Bibliography' },
    { id: 'e-1', md: ENTRY_ADAMS },
    { id: 'e-2', md: ENTRY_BAKER },
  ];
  return { blocks: [...blocks, ...tail], managed: tail.map((b) => b.id) };
}

/** Delete Section on chapter `MID_DELETED_CHAPTER` (its heading and its paragraphs), as an operation of its own. Its three definitions
 * stay in Notes, as the editor-first delete leaves them. */
function deleteMiddleChapterAsOp(view: EditorView): void {
  expect(beginStructuralOp(OP_A)).toBe(true);
  const first = (MID_DELETED_CHAPTER - 1) * (MID_PARAGRAPHS + 1);
  let from = 0;
  for (let i = 0; i < first; i++) from += view.state.doc.child(i).nodeSize;
  let to = from;
  for (let i = first; i <= first + MID_PARAGRAPHS; i++) to += view.state.doc.child(i).nodeSize;
  view.dispatch(view.state.tr.delete(from, to).setMeta('addToHistory', false));
  expect(finalizeStructuralOpPostOpDoc(OP_A)).toBe(true);
  setUndoDescriptor({ undoTopOpId: OP_A });
}

describe('t-18b7fa48 round F3b: the live Notes lack definitions the saved copy holds (a chapter in the middle of the book)', () => {
  it('BS2: delete a middle chapter with footnotes, type, renumber (a history step), real Notes push: repeated Cmd-Z brings the chapter back', async () => {
    const book = midBookBlocks(false);
    const view = await makeRealPushEditor(book.blocks, book.managed);
    const logs: string[] = [];
    const posted: unknown[] = [];
    (window as any).webkit.messageHandlers.errorHandler.postMessage = (m: { message: string }) => {
      logs.push(m.message);
    };
    (window as any).webkit.messageHandlers.structuralUndoRequested = { postMessage: (m: unknown) => posted.push(m) };
    const footnotes = MID_CHAPTERS * MID_NOTES_PER_CHAPTER;
    const refsBefore = labelsIn(view.state.doc, 'footnote_ref');
    const defsBefore = labelsIn(view.state.doc, 'footnote_def');
    expect(refsBefore, 'premise: 18 references numbered 1 to 18').toEqual(
      Array.from({ length: footnotes }, (_, i) => String(i + 1))
    );
    expect(defsBefore).toEqual(refsBefore);

    deleteMiddleChapterAsOp(view);
    typeAtEndOf(view, 'Chapter 5 paragraph 20 ', ' EARLYWORD'); // the user types straight away
    const mapping: Record<string, string> = {};
    const deletedFirst = (MID_DELETED_CHAPTER - 1) * MID_NOTES_PER_CHAPTER + 1; // 7
    for (let n = deletedFirst + MID_NOTES_PER_CHAPTER; n <= footnotes; n++) {
      mapping[String(n)] = String(n - MID_NOTES_PER_CHAPTER);
    }
    renumberFootnotes(mapping);
    expect(
      labelsIn(view.state.doc, 'footnote_ref')[deletedFirst - 1],
      'premise: the renumber landed after the typing'
    ).toBe(String(deletedFirst));
    await vi.advanceTimersByTimeAsync(200);

    const db = midBookBlocks(true);
    const merged = setContentWithBlockIds(realPushMarkdown(db.blocks), idsOf(db.blocks), {
      managedBlockIds: db.managed,
      preserveUserBlocks: true,
    });
    expect(merged, 'premise: the merge kept the typing').toContain('EARLYWORD');
    await vi.advanceTimersByTimeAsync(200);
    expect(
      labelsIn(view.state.doc, 'footnote_def'),
      'premise: the Notes hold definitions 1 to 15 after the push'
    ).toEqual(Array.from({ length: footnotes - MID_NOTES_PER_CHAPTER }, (_, i) => String(i + 1)));

    const decisions: string[] = [];
    const reasons: string[] = [];
    let restored = false;
    for (let press = 1; press <= 8 && !restored; press++) {
      logs.length = 0;
      const key = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });
      const routed = handleUnifiedUndoKeydown(key, view, 'undo');
      reasons.push(
        logs
          .filter((l) => l.includes('routing-equivalence'))
          .map((l) => l.replace(/^.*reason=/, ''))
          .join('|') || 'none'
      );
      if (routed) {
        decisions.push('structural');
        expect(posted).toEqual([{ opId: OP_A }]);
        expect(performStructuralSwap(OP_A, 'undo')).toBe(true);
        handleUndoReplyFromSwift({ opId: OP_A, outcome: 'performed' }, 'undo');
        restored = true;
      } else {
        decisions.push('fallthrough');
        if (!undo(view.state, view.dispatch)) break; // the text history is empty: the press is stuck
      }
      const entry = getRegistry().get(OP_A)!;
      expect(entry.postOpDoc.textContent, 'the typed word never enters a saved copy').not.toContain('EARLYWORD');
    }
    expect(
      decisions,
      `the renumber, then the typing, are taken back as text; the third press restores the chapter (the comparison said: ${reasons.join(' / ')})`
    ).toEqual(['fallthrough', 'fallthrough', 'structural']);
    expect(view.state.doc.textContent, 'the chapter is back').toContain('Chapter 3 paragraph 1 text.');
    expect(view.state.doc.textContent, 'the typed word is gone').not.toContain('EARLYWORD');
    expect(
      labelsIn(view.state.doc, 'footnote_ref'),
      'the footnote numbers are what they were before the delete'
    ).toEqual(refsBefore);
    expect(labelsIn(view.state.doc, 'footnote_def')).toEqual(defsBefore);
  }, 60_000);
});

// === Round F3c of t-18b7fa48: the REAL order of the person-pace log, with the log's counts ===
//
// BS2 did not reproduce the saved copy the real run ended with. The real order (run 1792249156-19744, log lines 97-187):
//   delete a middle chapter (its 9 definitions, labels 19-27, stay in Notes) -> type at block 5 -> the renumber chain lands (a
//   history step: the rebase is skipped) -> the Notes push deletes 9 definition paragraphs from the LIVE document and the
//   rebase of the saved copy is refused (`overlap`: the renumber's ranges are the user ranges) -> the slow undo is refused
//   (the typing) -> press 1 takes the renumber back as text, press 2 the typing -> the footnote undo checkpoint matches and
//   Swift pushes the Notes again for the references that carry their old numbers: it replaces the 9 orphan definitions of the live
//   document (labels 19-27) by the 9 definitions the references 28-36 lack, and this chain DOES rebase onto the saved copy
//   (`registry-rebase result=rebased userRanges=1 chainRanges=1`): the saved copy, which still holds its own definitions 28-36 at the
//   place the push deleted them from the live document, now defines the labels 28-36 twice with the same text. From press 3 on,
//   every comparison said `a footnote label is defined twice in b`.

const LOG_CHAPTER_SIZES = [81, 81, 78, 81, 81, 80]; // blocks per chapter (heading + paragraphs); 482 in all, chapter 3 is deleted
const LOG_DELETED_CHAPTER = 3;
const LOG_NOTES_PER_CHAPTER = 9; // paragraphs 10 to 18 of every chapter carry a footnote: 54 in all, 19 to 27 are chapter 3's
const LOG_FIRST_DELETED_NOTE = 19;
const LOG_ENTRIES = 35;

type LogBookStage = 'before' | 'afterDeleteRenumbered' | 'afterDeleteOldNumbers';

/** The book of the log: 405 body nodes (with the Notes heading) and 54 definitions after the delete, a Bibliography of 37 blocks.
 * Footnote texts repeat every 9 notes (the generator's cycle), so the deleted chapter's definitions are block-for-block equal to the
 * relabelled survivors'. Stages: `before` (the whole book), `afterDeleteRenumbered` (the database after the delete's Notes write:
 * chapter 3 gone, the survivors renumbered from 19, definitions 1 to 45) and `afterDeleteOldNumbers` (the Notes push after the renumber was
 * taken back as text: chapter 3 gone, the references on their old numbers, one definition for each of them, in order). */
function logBookBlocks(stage: LogBookStage): { blocks: TestBlock[]; managed: string[] } {
  const blocks: TestBlock[] = [];
  const defs: TestBlock[] = [];
  let n = 0;
  const lastDeleted = LOG_FIRST_DELETED_NOTE + LOG_NOTES_PER_CHAPTER - 1;
  LOG_CHAPTER_SIZES.forEach((size, index) => {
    const c = index + 1;
    const gone = stage !== 'before' && c === LOG_DELETED_CHAPTER;
    if (!gone) blocks.push({ id: `h-${c}`, md: `# Chapter ${c}` });
    for (let p = 1; p < size; p++) {
      let md = `Chapter ${c} paragraph ${p} text.`;
      if (p >= 10 && p < 10 + LOG_NOTES_PER_CHAPTER) {
        n++;
        const label = stage === 'afterDeleteRenumbered' && n > lastDeleted ? n - LOG_NOTES_PER_CHAPTER : n;
        md += `[^${label}]`;
        if (!gone) defs.push({ id: `d-${n}`, md: `[^${label}]: Note ${((n - 1) % LOG_NOTES_PER_CHAPTER) + 1}.` });
      }
      if (!gone) blocks.push({ id: `p-${c}-${p}`, md });
    }
  });
  const entries: TestBlock[] = Array.from({ length: LOG_ENTRIES }, (_, i) => ({
    id: `e-${i + 1}`,
    md: `Author${i + 1}, A. (2019). *Title ${i + 1}*. Press.`,
  }));
  const tail: TestBlock[] = [
    { id: 'h-notes', md: '# Notes' },
    ...defs,
    { id: 'h-bib', md: '# Bibliography' },
    ...entries,
  ];
  return { blocks: [...blocks, ...tail], managed: tail.map((b) => b.id) };
}

/** Delete Section on chapter `LOG_DELETED_CHAPTER` (from its heading to the next chapter's heading), as an operation of its own. */
function deleteLogChapterAsOp(view: EditorView): void {
  expect(beginStructuralOp(OP_A)).toBe(true);
  let from = -1;
  let to = -1;
  view.state.doc.forEach((node, pos) => {
    if (node.type.name !== 'heading') return;
    if (node.textContent === `Chapter ${LOG_DELETED_CHAPTER}`) from = pos;
    if (node.textContent === `Chapter ${LOG_DELETED_CHAPTER + 1}`) to = pos;
  });
  expect(from >= 0 && to > from, 'premise: the chapter to delete is in the document').toBe(true);
  view.dispatch(view.state.tr.delete(from, to).setMeta('addToHistory', false));
  expect(finalizeStructuralOpPostOpDoc(OP_A)).toBe(true);
  setUndoDescriptor({ undoTopOpId: OP_A });
}

describe('t-18b7fa48 round F3c: the saved copy defines a label twice after the later Notes push is rebased (the log, in its real order)', () => {
  it('BS3: delete a middle chapter, type, renumber, Notes push, text undo of the renumber and the typing, the restoring Notes push is rebased: the next Cmd-Z restores the chapter', async () => {
    const book = logBookBlocks('before');
    const view = await makeRealPushEditor(book.blocks, book.managed);
    const logs: string[] = [];
    const posted: unknown[] = [];
    (window as any).webkit.messageHandlers.errorHandler.postMessage = (m: { message: string }) => {
      logs.push(m.message);
    };
    (window as any).webkit.messageHandlers.structuralUndoRequested = { postMessage: (m: unknown) => posted.push(m) };
    const total = LOG_CHAPTER_SIZES.length * LOG_NOTES_PER_CHAPTER;
    const refsBefore = labelsIn(view.state.doc, 'footnote_ref');
    const defsBefore = labelsIn(view.state.doc, 'footnote_def');
    expect(refsBefore, 'premise: 54 references numbered 1 to 54').toEqual(
      Array.from({ length: total }, (_, i) => String(i + 1))
    );
    expect(defsBefore).toEqual(refsBefore);

    // 1. Delete the middle chapter: the saved copy keeps all 54 definitions.
    deleteLogChapterAsOp(view);
    const saved = getRegistry().get(OP_A)!.postOpDoc;
    expect(saved.childCount, 'premise: 496 children after the delete, as in the log').toBe(496);
    expect(labelsIn(saved, 'footnote_def')).toHaveLength(total);

    // 2. The user types at block 5. 3. The renumber chain lands (a history step; the saved copy cannot follow it).
    typeAtEndOf(view, 'Chapter 1 paragraph 5 ', ' EARLYWORD');
    const mapping: Record<string, string> = {};
    const lastDeleted = LOG_FIRST_DELETED_NOTE + LOG_NOTES_PER_CHAPTER - 1;
    for (let n = lastDeleted + 1; n <= total; n++) mapping[String(n)] = String(n - LOG_NOTES_PER_CHAPTER);
    renumberFootnotes(mapping);
    await vi.advanceTimersByTimeAsync(200);
    expect(
      labelsIn(view.state.doc, 'footnote_def').filter((l) => l === String(LOG_FIRST_DELETED_NOTE)),
      'premise: label 19 is defined twice until the Notes push lands'
    ).toHaveLength(2);

    // 4. The Notes push after the delete: the database with the survivors renumbered. The live document loses 9 definitions.
    const afterDelete = logBookBlocks('afterDeleteRenumbered');
    const merged = setContentWithBlockIds(realPushMarkdown(afterDelete.blocks), idsOf(afterDelete.blocks), {
      managedBlockIds: afterDelete.managed,
      preserveUserBlocks: true,
    });
    expect(merged, 'premise: the merge kept the typing').toContain('EARLYWORD');
    await vi.advanceTimersByTimeAsync(200);
    expect(labelsIn(view.state.doc, 'footnote_def'), 'premise: the Notes hold definitions 1 to 45').toHaveLength(
      total - LOG_NOTES_PER_CHAPTER
    );
    expect(getRegistry().get(OP_A)!.postOpDoc, 'premise: the saved copy did not follow the push').toBe(saved);

    // 5. (The slow undo was refused because of the typing: nothing changes in the editor.) Press 1 takes the renumber back as text,
    // press 2 the typing.
    const decisions: string[] = [];
    const press = (expectTextStep = true): boolean => {
      logs.length = 0;
      const key = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });
      const routed = handleUnifiedUndoKeydown(key, view, 'undo');
      if (routed) {
        decisions.push('structural');
        return true;
      }
      decisions.push('fallthrough');
      if (expectTextStep) expect(undo(view.state, view.dispatch), "the editor's own text undo").toBe(true);
      return false;
    };
    expect(press()).toBe(false);
    expect(
      labelsIn(view.state.doc, 'footnote_ref')[LOG_FIRST_DELETED_NOTE - 1],
      'premise: press 1 took the renumber back'
    ).toBe('28');
    expect(press()).toBe(false);
    expect(view.state.doc.textContent, 'premise: press 2 took the typing back').not.toContain('EARLYWORD');
    await vi.advanceTimersByTimeAsync(200);

    // 6. The later Notes push: the references are on their old numbers again, so the Notes get one definition for each of them (in
    // place of the 9 orphans of the live document). This chain has no history step and the saved copy DOES follow it.
    // Applied as the block-level replace it amounts to (the live document's 9 orphan definitions, labels 19-27, are replaced by 9
    // definitions labelled 28-36 with the texts the saved copy holds for those labels), in ONE sync-origin transaction.
    logs.length = 0;
    const orphanSpan: { from: number; to: number } = { from: -1, to: -1 };
    view.state.doc.forEach((node, pos) => {
      const marker = node.firstChild;
      if (node.type.name !== 'paragraph' || marker?.type.name !== 'footnote_def') return;
      const label = Number(marker.attrs.label);
      if (label < LOG_FIRST_DELETED_NOTE || label >= LOG_FIRST_DELETED_NOTE + LOG_NOTES_PER_CHAPTER) return;
      if (orphanSpan.from < 0) orphanSpan.from = pos;
      orphanSpan.to = pos + node.nodeSize;
    });
    expect(orphanSpan.from, 'premise: the live document still holds the 9 orphan definitions 19-27').toBeGreaterThan(0);
    const restored: Node[] = [];
    getRegistry()
      .get(OP_A)!
      .postOpDoc.forEach((node) => {
        const marker = node.firstChild;
        if (node.type.name !== 'paragraph' || marker?.type.name !== 'footnote_def') return;
        const label = Number(marker.attrs.label);
        if (label >= lastDeleted + 1 && label < lastDeleted + 1 + LOG_NOTES_PER_CHAPTER) {
          restored.push(node.type.create(node.attrs, node.content, node.marks));
        }
      });
    expect(restored, 'premise: 9 definitions for the references 28-36').toHaveLength(LOG_NOTES_PER_CHAPTER);
    view.dispatch(view.state.tr.replaceWith(orphanSpan.from, orphanSpan.to, restored).setMeta('addToHistory', false));
    await vi.advanceTimersByTimeAsync(200);
    const rebaseLine = logs.find((l) => l.includes('registry-rebase')) ?? '';
    expect(rebaseLine, 'premise (log line 158): the later push is rebased onto the saved copy').toContain(
      'result=rebased'
    );
    const labelCounts = new Map<string, number>();
    for (const l of labelsIn(getRegistry().get(OP_A)!.postOpDoc, 'footnote_def')) {
      labelCounts.set(l, (labelCounts.get(l) ?? 0) + 1);
    }
    expect(
      [...labelCounts.values()].some((count) => count > 1),
      'premise (log line 160): the saved copy now defines a footnote label twice'
    ).toBe(true);

    // 7. The next Cmd-Z must be the structural undo.
    const routed = press(false);
    const reason = logs
      .filter((l) => l.includes('routing-equivalence'))
      .map((l) => l.replace(/^.*reason=/, ''))
      .join(' | ');
    expect(routed, `press 3 restores the chapter (the comparison said: ${reason})`).toBe(true);
    expect(posted).toEqual([{ opId: OP_A }]);
    expect(performStructuralSwap(OP_A, 'undo')).toBe(true);
    handleUndoReplyFromSwift({ opId: OP_A, outcome: 'performed' }, 'undo');
    expect(decisions).toEqual(['fallthrough', 'fallthrough', 'structural']);
    expect(view.state.doc.textContent, 'the chapter is back').toContain('Chapter 3 paragraph 1 text.');
    expect(view.state.doc.textContent, 'the typed word is gone').not.toContain('EARLYWORD');
    expect(
      labelsIn(view.state.doc, 'footnote_ref'),
      'the footnote numbers are what they were before the delete'
    ).toEqual(refsBefore);
    expect(labelsIn(view.state.doc, 'footnote_def')).toEqual(defsBefore);
  }, 120_000);
});

// === Round F3d of t-18b7fa48: the judge's scenario B, pinned as ACCEPTED behaviour ===
//
// After Delete Section the user deletes one footnote-definition paragraph BY HAND (its reference stays in the text), then presses Cmd-Z.
// The comparison treats a reference with no definition in the live document as no difference (round F3b: the Notes membership is what the
// app regenerates), so the first Cmd-Z routes to the structural undo and the swap brings the section back AND the definition the user
// deleted (the saved copy and the checkpoint hold it). The user's hand deletion is not taken back as its own text step first. This is
// the chosen, accepted behaviour (rare: nobody deletes a single footnote definition and keeps its reference); nothing the user wrote is
// lost, since the only text involved is the text they deleted. If it is ever changed, this test is the place that must change with it.
describe('t-18b7fa48 round F3d: a footnote definition deleted by hand after a section delete (accepted behaviour)', () => {
  it('SB1 (accepted, rare): the single Cmd-Z undoes the section delete and the hand-deleted definition comes back with it', async () => {
    const view = await makeNotesEditor();
    deleteAlphaAsOp(view);
    // The user selects the definition paragraph of footnote 2 and deletes it; the reference to footnote 2 stays in the body.
    let from = -1;
    let to = -1;
    view.state.doc.forEach((node, pos) => {
      if (from < 0 && node.firstChild?.type.name === 'footnote_def' && node.textContent.includes('Second note.')) {
        from = pos;
        to = pos + node.nodeSize;
      }
    });
    expect(from, 'premise: the definition of footnote 2 exists').toBeGreaterThan(0);
    view.dispatch(view.state.tr.delete(from, to)); // a real user step: it is in the text history
    expect(view.state.doc.textContent, 'premise: the definition is gone').not.toContain('Second note.');
    expect(labelsIn(view.state.doc, 'footnote_ref'), 'premise: the references are still there').toEqual(['2', '3']);

    expect(undoWithFallback(view), 'the first Cmd-Z is the structural undo (accepted behaviour)').toEqual(STRUCTURAL_A);
    expect(performStructuralSwap(OP_A, 'undo')).toBe(true);
    expect(view.state.doc.textContent, 'the section is back').toContain('Alpha text with a note.');
    expect(view.state.doc.textContent, 'and so is the definition the user had deleted').toContain('Second note.');
  });
});
