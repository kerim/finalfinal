// @vitest-environment jsdom
//
// Regression suite for "click at start of a non-first bullet, paste an
// image" against the REAL Milkdown editor pipeline — real commonmark/gfm
// schema (with list_item's actual `defining: true`, etc.), real
// blockIdPlugin/blockSyncPlugin, real imagePlugin, and the real
// api-content.ts insertImage() — as opposed to insert-pos.test.ts's
// hand-rolled schema, which validates computeCursorAwareInsertPos in
// isolation but cannot catch a regression that only manifests through the
// real plugin pipeline (block-id/block-sync interaction, ghost-image
// removal, paste-position expiry).
//
// Drives the ACTUAL imagePasteDropPlugin.handlePaste code path (via
// view.someProp) so pendingPastePos is captured exactly the way production
// captures it — no module mocking, no reimplementation of insertImage()'s
// internals.
import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { TextSelection } from '@milkdown/kit/prose/state';
import { getMarkdown } from '@milkdown/kit/utils';
import { afterEach, describe, expect, it } from 'vitest';
import { insertImage } from '../api-content';
import { blockIdPlugin, getAllBlockIds, resetBlockIdState, setBlockIdsForTopLevel } from '../block-id-plugin';
import {
  blockSyncPlugin,
  flushPendingBlockChanges,
  getBlockChanges,
  nodeToMarkdownFragment,
  resetAndSnapshot,
  resetBlockSyncState,
} from '../block-sync-plugin';
import { setEditorInstance } from '../editor-state';
import { highlightPlugin } from '../highlight-plugin';
import { imagePlugin } from '../image-plugin';
import { orderedListOrderPlugin } from '../ordered-list-order-plugin';

async function makeEditor(markdown: string): Promise<Editor> {
  const div = document.createElement('div');
  document.body.appendChild(div);
  const editor = await Editor.make()
    .config((ctx) => {
      ctx.set(rootCtx, div);
      ctx.set(defaultValueCtx, markdown);
    })
    .use(blockIdPlugin)
    .use(blockSyncPlugin)
    .use(imagePlugin)
    .use(commonmark)
    .use(gfm)
    .use(orderedListOrderPlugin)
    .use(highlightPlugin)
    .create();
  return editor;
}

function describeDoc(doc: any): string[] {
  const out: string[] = [];
  doc.forEach((node: any) => {
    if (node.type.name === 'bullet_list') {
      const items: string[] = [];
      node.forEach((li: any) => {
        items.push(JSON.stringify(li.textContent));
      });
      out.push(`bullet_list[${items.join(',')}]`);
    } else if (node.type.name === 'ordered_list') {
      const items: string[] = [];
      node.forEach((li: any) => {
        items.push(JSON.stringify(li.textContent));
      });
      out.push(`ordered_list(order=${node.attrs.order})[${items.join(',')}]`);
    } else if (node.type.name === 'figure') {
      out.push(`FIGURE(src=${node.attrs.src})`);
    } else {
      out.push(`${node.type.name}(${JSON.stringify(node.textContent)})`);
    }
  });
  return out;
}

function findTextPos(doc: any, text: string): number {
  let pos = -1;
  doc.descendants((node: any, p: number) => {
    if (pos >= 0) return false;
    if (node.isText && node.text === text) pos = p;
    return true;
  });
  if (pos < 0) throw new Error(`text node ${JSON.stringify(text)} not found`);
  return pos;
}

function fakePasteEvent(): ClipboardEvent {
  const fakeFile = new File(['fake-image-bytes'], 'test.png', { type: 'image/png' });
  return {
    clipboardData: { items: [{ type: 'image/png', getAsFile: () => fakeFile }] },
    preventDefault: () => {},
  } as unknown as ClipboardEvent;
}

/** Simulates closing and reopening a document: builds a completely fresh
 * editor (same construction path as makeEditor) from already-serialized
 * markdown and returns its doc. Used to prove numbering (and figure
 * fidelity) survive a real serialize → re-parse round trip, not just the
 * in-memory transaction that produced it. */
async function reparse(markdown: string): Promise<any> {
  const editor = await makeEditor(markdown);
  const view = editor.ctx.get(editorViewCtx);
  return view.state.doc;
}

/** Walks up from the (unique) text node matching `text` to the nearest
 * ancestor of node type `typeName` — e.g. the `ordered_list`/`bullet_list`/
 * `list_item` directly containing a given item's text, regardless of
 * nesting depth. Returns null if no such ancestor exists. */
function nearestAncestorOfType(doc: any, text: string, typeName: string): any {
  const pos = findTextPos(doc, text);
  const $pos = doc.resolve(pos);
  for (let d = $pos.depth; d >= 0; d--) {
    if ($pos.node(d).type.name === typeName) return $pos.node(d);
  }
  return null;
}

function countNodesOfType(doc: any, typeName: string): number {
  let count = 0;
  doc.descendants((node: any) => {
    if (node.type.name === typeName) count++;
    return true;
  });
  return count;
}

const THREE_ITEM_LIST_MD = ['Before paragraph.', '', '- Item 1', '- Item 2', '- Item 3', '', 'After paragraph.'].join(
  '\n'
);

describe('REAL pipeline repro: paste image at start of non-first bullet', () => {
  afterEach(() => {
    setEditorInstance(null);
    resetBlockSyncState();
    resetBlockIdState();
  });

  it('splits the list cleanly around the image — no data loss', async () => {
    const editor = await makeEditor(THREE_ITEM_LIST_MD);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const item2Pos = findTextPos(view.state.doc, 'Item 2');
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, item2Pos)));

    const handled = view.someProp('handlePaste', (f) => f(view, fakePasteEvent(), undefined as any));
    expect(handled).toBe(true);

    // Call the REAL insertImage(), exactly as Swift does after the
    // FileReader/native-image-import round trip completes.
    insertImage({ src: 'projectmedia://test.png', alt: '', caption: '', width: null, blockId: 'temp-test-block' });

    const top = describeDoc(view.state.doc);
    expect(top).toEqual([
      'paragraph("Before paragraph.")',
      'bullet_list["Item 1"]',
      'FIGURE(src=projectmedia://test.png)',
      'bullet_list["Item 2","Item 3"]',
      'paragraph("After paragraph.")',
    ]);

    flushPendingBlockChanges();
    expect(getBlockChanges().deletes).toEqual([]);
  });

  it('with a WebKit ghost inline image already sitting at the caret before the paste completes', async () => {
    const editor = await makeEditor(THREE_ITEM_LIST_MD);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const item2Pos = findTextPos(view.state.doc, 'Item 2');

    // Simulate WebKit having already inserted a ghost inline <img> (blob:) right
    // at the caret before our JS paste handler's capture runs — the ghost
    // insertion is modeled as already having happened, with the selection
    // having moved to just after it (standard insert-then-advance-caret
    // behavior).
    const imageType = view.state.schema.nodes.image!;
    const ghost = imageType.create({ src: 'blob:fake-ghost-uuid' });
    view.dispatch(view.state.tr.insert(item2Pos, ghost));
    const afterGhostPos = item2Pos + ghost.nodeSize;
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, afterGhostPos)));

    const handled = view.someProp('handlePaste', (f) => f(view, fakePasteEvent(), undefined as any));
    expect(handled).toBe(true);

    insertImage({ src: 'projectmedia://test.png', alt: '', caption: '', width: null, blockId: 'temp-test-block' });

    const top = describeDoc(view.state.doc);
    expect(top).toEqual([
      'paragraph("Before paragraph.")',
      'bullet_list["Item 1"]',
      'FIGURE(src=projectmedia://test.png)',
      'bullet_list["Item 2","Item 3"]',
      'paragraph("After paragraph.")',
    ]);

    flushPendingBlockChanges();
    expect(getBlockChanges().deletes).toEqual([]);
  });

  it('with a pre-existing nearby figure block does not steal its id or delete it (proximity check)', async () => {
    // Mirrors the real user's document shape: an existing image shortly before
    // the list, all real (permanent, non-temp) block IDs already assigned, as
    // if freshly loaded from the DB via setContentWithBlockIds. Regression
    // guard for block-id-plugin's Phase 2 proximity matching, which skips the
    // content-relatedness check entirely for atomic types (figure) — a
    // brand-new pasted figure could otherwise claim a nearby EXISTING figure's
    // permanent id purely by distance.
    const markdown = [
      'Before paragraph.',
      '',
      '![existing](media/existing-photo.png)',
      '',
      '- Item 1',
      '- Item 2',
      '- Item 3',
      '',
      'After paragraph.',
    ].join('\n');
    const editor = await makeEditor(markdown);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const orderedIds = ['id-before-para', 'id-existing-figure', 'id-list', 'id-after-para'];
    resetBlockIdState();
    setBlockIdsForTopLevel(orderedIds, view.state.doc);
    // Mirror what setContentWithBlockIds's deferredSnapshotAndUnpause does
    // after real ids are assigned: re-baseline blockSyncPlugin's lastSnapshot
    // against the NEW real ids, instead of leaving it pointed at the
    // initial-load temp ids block-sync captured at editor-construction time.
    // Skipping this would be a test-setup artifact, not a production path.
    resetAndSnapshot(view.state.doc);

    const item2Pos = findTextPos(view.state.doc, 'Item 2');
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, item2Pos)));

    const handled = view.someProp('handlePaste', (f) => f(view, fakePasteEvent(), undefined as any));
    expect(handled).toBe(true);

    insertImage({ src: 'projectmedia://test.png', alt: '', caption: '', width: null, blockId: 'temp-test-block' });

    const top = describeDoc(view.state.doc);
    expect(top).toEqual([
      'paragraph("Before paragraph.")',
      'FIGURE(src=media/existing-photo.png)',
      'bullet_list["Item 1"]',
      'FIGURE(src=projectmedia://test.png)',
      'bullet_list["Item 2","Item 3"]',
      'paragraph("After paragraph.")',
    ]);

    flushPendingBlockChanges();
    const changes = getBlockChanges();
    expect(changes.deletes).not.toContain('id-existing-figure');
    expect(Array.from(getAllBlockIds().values())).toContain('id-existing-figure');
  });

  it('falls back to after-current-block placement (not a split) when pendingPastePos already expired', async () => {
    // Regression test for the root cause found in this investigation: Swift's
    // ImageImportService shows a blocking NSAlert for images over 10MB, which
    // can easily outlast a short pendingPastePos timeout while the paste is
    // still legitimately in flight (see PENDING_POS_TIMEOUT_MS in
    // image-plugin.ts). When the position has expired, insertImage() must
    // still behave sanely — landing after the current top-level block,
    // exactly like the pre-fix behavior — rather than doing anything
    // destructive. This also pins down the exact "list intact, image trails
    // it, not split/nested" shape observed in the real bug report, so a
    // future regression in the OTHER direction (this fallback firing when it
    // shouldn't, e.g. the timeout being too short again) is caught here.
    const editor = await makeEditor(THREE_ITEM_LIST_MD);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const item2Pos = findTextPos(view.state.doc, 'Item 2');
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, item2Pos)));

    const handled = view.someProp('handlePaste', (f) => f(view, fakePasteEvent(), undefined as any));
    expect(handled).toBe(true);

    // Simulate the pendingPastePos timeout having already fired by the time
    // Swift calls back — i.e. consume-and-discard it, mirroring what
    // consumePendingPastePos() would return after PENDING_POS_TIMEOUT_MS.
    const { consumePendingPastePos } = await import('../image-plugin');
    consumePendingPastePos();

    insertImage({ src: 'projectmedia://test.png', alt: '', caption: '', width: null, blockId: 'temp-test-block' });

    const top = describeDoc(view.state.doc);
    // No split: the list is untouched, and the figure trails the whole list —
    // the same shape as the pre-fix "after current block" fallback.
    expect(top).toEqual([
      'paragraph("Before paragraph.")',
      'bullet_list["Item 1","Item 2","Item 3"]',
      'FIGURE(src=projectmedia://test.png)',
      'paragraph("After paragraph.")',
    ]);

    flushPendingBlockChanges();
    expect(getBlockChanges().deletes).toEqual([]);
  });
});

// Regression suite for "ordered-list numbering restarts at 1 after a split"
// (e.g. pasting an image mid-list) — against the REAL Milkdown editor
// pipeline, including orderedListOrderPlugin (the fixed ordered_list schema;
// see ordered-list-order-plugin.ts) so getMarkdown() actually reflects the
// `order` attribute changes insertImage()'s split-continuation logic makes.
//
// Every case whose scenario actually splits a list round-trips through
// getMarkdown() → reparse() (a fresh second editor) to prove the fix holds
// after a real close-and-reopen, not just in the transaction that produced
// it — this is the exact bug this suite guards against: parseMarkdown
// previously dropped mdast's `node.start`, silently resetting `order` to 1
// on every reload (see ordered-list-order-plugin.ts). Cases that never split
// anything (no figure inserted, nothing to lose) skip the round trip.
describe('REAL pipeline: ordered_list numbering across a split vs. a deliberate restart', () => {
  afterEach(() => {
    setEditorInstance(null);
    resetBlockSyncState();
    resetBlockIdState();
  });

  const THREE_ITEM_ORDERED_LIST_MD = [
    'Before paragraph.',
    '',
    '1. Item 1',
    '2. Item 2',
    '3. Item 3',
    '',
    'After paragraph.',
  ].join('\n');

  const NESTED_ORDERED_LIST_MD = ['1. Outer 1', '   1. Inner 1', '   2. Inner 2', '   3. Inner 3', '2. Outer 2'].join(
    '\n'
  );

  const MIXED_NESTING_MD = ['- Outer A', '  1. Inner 1', '  2. Inner 2', '  3. Inner 3', '- Outer B'].join('\n');

  const NESTED_BULLET_LIST_MD = ['- Outer A', '  - Inner 1', '  - Inner 2', '  - Inner 3', '- Outer B'].join('\n');

  it('(a) top-level split: continues the tail list numbering after pasting an image mid-list, and survives a reload round-trip', async () => {
    const editor = await makeEditor(THREE_ITEM_ORDERED_LIST_MD);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const item2Pos = findTextPos(view.state.doc, 'Item 2');
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, item2Pos)));

    const handled = view.someProp('handlePaste', (f) => f(view, fakePasteEvent(), undefined as any));
    expect(handled).toBe(true);

    // Realistic src (media/<name>.png, matching Swift's ImageImportService
    // output) since this test round-trips: remarkFigurePlugin only
    // reconstructs a `figure` node on re-parse for URLs starting with
    // `media/` (see image-plugin.ts) — a projectmedia:// URL would silently
    // degrade to a plain image on reparse, unrelated to list numbering.
    insertImage({ src: 'media/test.png', alt: '', caption: '', width: null, blockId: 'temp-test-block' });

    const top = describeDoc(view.state.doc);
    expect(top).toEqual([
      'paragraph("Before paragraph.")',
      'ordered_list(order=1)["Item 1"]',
      'FIGURE(src=media/test.png)',
      'ordered_list(order=2)["Item 2","Item 3"]',
      'paragraph("After paragraph.")',
    ]);

    // getMarkdown() must reflect the corrected `start:` too — not just the
    // in-memory attr — confirming orderedListOrderPlugin's toMarkdown fix
    // (no longer hardcoding start: 1) actually reaches serialization.
    const markdown = getMarkdown()(editor.ctx);
    expect(markdown).toMatch(/2\.\s+Item 2/);
    expect(markdown).toMatch(/3\.\s+Item 3/);

    // Reload: re-parse the serialized markdown in a FRESH editor and confirm
    // the tail list's order survives.
    const reloaded = await reparse(markdown);
    expect(describeDoc(reloaded)).toEqual([
      'paragraph("Before paragraph.")',
      'ordered_list(order=1)["Item 1"]',
      'FIGURE(src=media/test.png)',
      'ordered_list(order=2)["Item 2","Item 3"]',
      'paragraph("After paragraph.")',
    ]);

    flushPendingBlockChanges();
    expect(getBlockChanges().deletes).toEqual([]);
  });

  it("(b) nested split: continuing a nested list tail's numbering survives a reload round-trip, outer list unchanged", async () => {
    const editor = await makeEditor(NESTED_ORDERED_LIST_MD);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    // Sanity-check the premise: one outer list (2 items), one nested list
    // (3 items) inside the first outer item.
    expect(countNodesOfType(view.state.doc, 'ordered_list')).toBe(2);

    const inner2Pos = findTextPos(view.state.doc, 'Inner 2');
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, inner2Pos)));

    const handled = view.someProp('handlePaste', (f) => f(view, fakePasteEvent(), undefined as any));
    expect(handled).toBe(true);

    insertImage({ src: 'media/test.png', alt: '', caption: '', width: null, blockId: 'temp-test-block' });

    const doc = view.state.doc;
    expect(countNodesOfType(doc, 'ordered_list')).toBe(3); // outer + inner-head + inner-tail
    expect(countNodesOfType(doc, 'figure')).toBe(1);
    expect(nearestAncestorOfType(doc, 'Outer 1', 'ordered_list').attrs.order).toBe(1);
    expect(nearestAncestorOfType(doc, 'Outer 1', 'ordered_list').childCount).toBe(2);
    expect(nearestAncestorOfType(doc, 'Inner 1', 'ordered_list').attrs.order).toBe(1);
    expect(nearestAncestorOfType(doc, 'Inner 1', 'ordered_list').childCount).toBe(1);
    expect(nearestAncestorOfType(doc, 'Inner 2', 'ordered_list').attrs.order).toBe(2);
    expect(nearestAncestorOfType(doc, 'Inner 2', 'ordered_list').childCount).toBe(2);

    const markdown = getMarkdown()(editor.ctx);
    const reloaded = await reparse(markdown);
    expect(countNodesOfType(reloaded, 'ordered_list')).toBe(3);
    expect(countNodesOfType(reloaded, 'figure')).toBe(1);
    expect(nearestAncestorOfType(reloaded, 'Outer 1', 'ordered_list').attrs.order).toBe(1);
    expect(nearestAncestorOfType(reloaded, 'Inner 1', 'ordered_list').attrs.order).toBe(1);
    expect(nearestAncestorOfType(reloaded, 'Inner 2', 'ordered_list').attrs.order).toBe(2);
    expect(nearestAncestorOfType(reloaded, 'Inner 2', 'ordered_list').childCount).toBe(2);

    flushPendingBlockChanges();
    expect(getBlockChanges().deletes).toEqual([]);
  });

  it('counterexample: a gap between two SEPARATE adjacent ordered lists is not treated as a split', async () => {
    // `1.`/`2.` and `1)`/`2)` use different delimiters, which CommonMark/remark
    // treats as two distinct lists even with no blank line between them — the
    // exact "gap between two independent pre-existing lists" case the plan's
    // pre-transaction discriminator must reject (its .parent resolves to the
    // containing doc, never ordered_list, so `continuation` stays null).
    const markdown = ['1. a', '2. b', '1) c', '2) d'].join('\n');
    const editor = await makeEditor(markdown);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    // Sanity-check the premise: two separate ordered_list nodes, not one.
    const before = describeDoc(view.state.doc);
    expect(before).toEqual(['ordered_list(order=1)["a","b"]', 'ordered_list(order=1)["c","d"]']);

    const cPos = findTextPos(view.state.doc, 'c');
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, cPos)));

    const handled = view.someProp('handlePaste', (f) => f(view, fakePasteEvent(), undefined as any));
    expect(handled).toBe(true);

    insertImage({ src: 'projectmedia://test.png', alt: '', caption: '', width: null, blockId: 'temp-test-block' });

    const top = describeDoc(view.state.doc);
    // Figure lands between the two lists; NEITHER list's order is touched.
    expect(top).toEqual([
      'ordered_list(order=1)["a","b"]',
      'FIGURE(src=projectmedia://test.png)',
      'ordered_list(order=1)["c","d"]',
    ]);
  });

  it('(c) deliberate restart: an ordinary second numbered list stays at order=1, unaffected before and after a reload round-trip', async () => {
    // No insertImage() call at all here — this pins down that ordinary list
    // creation (parsing markdown / typing "1.") is completely unaffected by
    // the split-continuation logic added to insertImage(), and that this
    // stays true through a reload — a regression guard against an
    // over-broad fix (e.g. one that always adds an offset rather than
    // reading the real parsed start number).
    const markdown = [
      '1. First list item A',
      '2. First list item B',
      '',
      'A paragraph in between.',
      '',
      '1. Second list item A',
      '2. Second list item B',
    ].join('\n');
    const editor = await makeEditor(markdown);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const top = describeDoc(view.state.doc);
    expect(top).toEqual([
      'ordered_list(order=1)["First list item A","First list item B"]',
      'paragraph("A paragraph in between.")',
      'ordered_list(order=1)["Second list item A","Second list item B"]',
    ]);

    const serialized = getMarkdown()(editor.ctx);
    const reloaded = await reparse(serialized);
    expect(describeDoc(reloaded)).toEqual([
      'ordered_list(order=1)["First list item A","First list item B"]',
      'paragraph("A paragraph in between.")',
      'ordered_list(order=1)["Second list item A","Second list item B"]',
    ]);
  });

  it('(d) mixed nesting: bullet outer / ordered inner — nested split survives a reload round-trip, outer bullet list unaffected', async () => {
    const editor = await makeEditor(MIXED_NESTING_MD);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    expect(countNodesOfType(view.state.doc, 'bullet_list')).toBe(1);
    expect(countNodesOfType(view.state.doc, 'ordered_list')).toBe(1);

    const inner2Pos = findTextPos(view.state.doc, 'Inner 2');
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, inner2Pos)));

    const handled = view.someProp('handlePaste', (f) => f(view, fakePasteEvent(), undefined as any));
    expect(handled).toBe(true);

    insertImage({ src: 'media/test.png', alt: '', caption: '', width: null, blockId: 'temp-test-block' });

    const doc = view.state.doc;
    expect(nearestAncestorOfType(doc, 'Outer A', 'bullet_list').childCount).toBe(2); // unaffected
    expect(countNodesOfType(doc, 'ordered_list')).toBe(2); // inner-head + inner-tail
    expect(countNodesOfType(doc, 'figure')).toBe(1);
    expect(nearestAncestorOfType(doc, 'Inner 1', 'ordered_list').attrs.order).toBe(1);
    expect(nearestAncestorOfType(doc, 'Inner 1', 'ordered_list').childCount).toBe(1);
    expect(nearestAncestorOfType(doc, 'Inner 2', 'ordered_list').attrs.order).toBe(2);
    expect(nearestAncestorOfType(doc, 'Inner 2', 'ordered_list').childCount).toBe(2);

    const markdown = getMarkdown()(editor.ctx);
    const reloaded = await reparse(markdown);
    expect(nearestAncestorOfType(reloaded, 'Outer A', 'bullet_list').childCount).toBe(2);
    expect(countNodesOfType(reloaded, 'ordered_list')).toBe(2);
    expect(countNodesOfType(reloaded, 'figure')).toBe(1);
    expect(nearestAncestorOfType(reloaded, 'Inner 1', 'ordered_list').attrs.order).toBe(1);
    expect(nearestAncestorOfType(reloaded, 'Inner 2', 'ordered_list').attrs.order).toBe(2);
    expect(nearestAncestorOfType(reloaded, 'Inner 2', 'ordered_list').childCount).toBe(2);

    flushPendingBlockChanges();
    expect(getBlockChanges().deletes).toEqual([]);
  });

  it('(e) mid-paragraph paste: a mid-word paste inside an item never splits the list (immediate-state canary, nothing to lose on reload)', async () => {
    const editor = await makeEditor(THREE_ITEM_ORDERED_LIST_MD);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    // Mid-word, not at any text-node boundary: between "It" and "em 2".
    const midPos = findTextPos(view.state.doc, 'Item 2') + 2;
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, midPos)));

    const handled = view.someProp('handlePaste', (f) => f(view, fakePasteEvent(), undefined as any));
    expect(handled).toBe(true);

    insertImage({ src: 'projectmedia://test.png', alt: '', caption: '', width: null, blockId: 'temp-test-block' });

    const doc = view.state.doc;
    // The text node "Item 2" is gone now (split around the paste point into
    // "It" and "em 2"), so look the list up via a fragment that survived.
    expect(countNodesOfType(doc, 'ordered_list')).toBe(1);
    expect(countNodesOfType(doc, 'figure')).toBe(1);
    const list = nearestAncestorOfType(doc, 'em 2', 'ordered_list');
    expect(list.attrs.order).toBe(1);
    expect(list.childCount).toBe(3); // still exactly 3 items — no split

    // The figure lands as an extra block child of item 2's OWN list_item
    // (list_item's "paragraph block*" content model absorbs it directly,
    // per the comment in api-content.ts's insertImage()) — never as a new
    // sibling list item.
    const item2 = nearestAncestorOfType(doc, 'em 2', 'list_item');
    let figureChildren = 0;
    item2.forEach((child: any) => {
      if (child.type.name === 'figure') figureChildren++;
    });
    expect(figureChildren).toBe(1);

    flushPendingBlockChanges();
    expect(getBlockChanges().deletes).toEqual([]);
  });

  it('(f) bullet-list counterexample: a boundary paste in a nested bullet list never introduces ordered-list numbering', async () => {
    const editor = await makeEditor(NESTED_BULLET_LIST_MD);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const inner2Pos = findTextPos(view.state.doc, 'Inner 2');
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, inner2Pos)));

    const handled = view.someProp('handlePaste', (f) => f(view, fakePasteEvent(), undefined as any));
    expect(handled).toBe(true);

    insertImage({ src: 'media/test.png', alt: '', caption: '', width: null, blockId: 'temp-test-block' });

    expect(countNodesOfType(view.state.doc, 'ordered_list')).toBe(0);
    expect(countNodesOfType(view.state.doc, 'figure')).toBe(1);

    const markdown = getMarkdown()(editor.ctx);
    // No ordered-list marker (`1.`/`1)`) appears anywhere in the serialized
    // output — the split never got miscategorized as an ordered-list split.
    expect(markdown).not.toMatch(/^\s*\d+[.)]\s/m);

    const reloaded = await reparse(markdown);
    expect(countNodesOfType(reloaded, 'ordered_list')).toBe(0);
    expect(countNodesOfType(reloaded, 'bullet_list')).toBeGreaterThan(0);
    expect(countNodesOfType(reloaded, 'figure')).toBe(1);

    flushPendingBlockChanges();
    expect(getBlockChanges().deletes).toEqual([]);
  });

  it('(f) bullet-list counterexample: a mid-text paste in a nested bullet list never introduces ordered-list numbering', async () => {
    const editor = await makeEditor(NESTED_BULLET_LIST_MD);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const midPos = findTextPos(view.state.doc, 'Inner 2') + 2;
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, midPos)));

    const handled = view.someProp('handlePaste', (f) => f(view, fakePasteEvent(), undefined as any));
    expect(handled).toBe(true);

    insertImage({ src: 'media/test.png', alt: '', caption: '', width: null, blockId: 'temp-test-block' });

    expect(countNodesOfType(view.state.doc, 'ordered_list')).toBe(0);
    expect(countNodesOfType(view.state.doc, 'figure')).toBe(1);

    const markdown = getMarkdown()(editor.ctx);
    expect(markdown).not.toMatch(/^\s*\d+[.)]\s/m);

    const reloaded = await reparse(markdown);
    expect(countNodesOfType(reloaded, 'ordered_list')).toBe(0);
    expect(countNodesOfType(reloaded, 'figure')).toBe(1);

    flushPendingBlockChanges();
    expect(getBlockChanges().deletes).toEqual([]);
  });

  it('(g) figure fidelity: a round-tripped figure stays a figure node (not degraded to inline image + text) — top-level split', async () => {
    const editor = await makeEditor(THREE_ITEM_ORDERED_LIST_MD);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const item2Pos = findTextPos(view.state.doc, 'Item 2');
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, item2Pos)));
    expect(view.someProp('handlePaste', (f) => f(view, fakePasteEvent(), undefined as any))).toBe(true);

    insertImage({
      src: 'media/test.png',
      alt: 'alt text',
      caption: 'a caption',
      width: null,
      blockId: 'temp-test-block',
    });

    expect(countNodesOfType(view.state.doc, 'figure')).toBe(1);
    expect(countNodesOfType(view.state.doc, 'image')).toBe(0);

    const markdown = getMarkdown()(editor.ctx);
    const reloaded = await reparse(markdown);
    expect(countNodesOfType(reloaded, 'figure')).toBe(1);
    expect(countNodesOfType(reloaded, 'image')).toBe(0);

    let figureSrc = '';
    reloaded.descendants((node: any) => {
      if (node.type.name === 'figure') figureSrc = node.attrs.src;
      return true;
    });
    expect(figureSrc).toBe('media/test.png');
  });

  it('(g) figure fidelity: a round-tripped figure stays a figure node (not degraded to inline image + text) — nested split', async () => {
    const editor = await makeEditor(NESTED_ORDERED_LIST_MD);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const inner2Pos = findTextPos(view.state.doc, 'Inner 2');
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, inner2Pos)));
    expect(view.someProp('handlePaste', (f) => f(view, fakePasteEvent(), undefined as any))).toBe(true);

    insertImage({
      src: 'media/test.png',
      alt: 'alt text',
      caption: 'a caption',
      width: null,
      blockId: 'temp-test-block',
    });

    expect(countNodesOfType(view.state.doc, 'figure')).toBe(1);
    expect(countNodesOfType(view.state.doc, 'image')).toBe(0);

    const markdown = getMarkdown()(editor.ctx);
    const reloaded = await reparse(markdown);
    expect(countNodesOfType(reloaded, 'figure')).toBe(1);
    expect(countNodesOfType(reloaded, 'image')).toBe(0);

    let figureSrc = '';
    reloaded.descendants((node: any) => {
      if (node.type.name === 'figure') figureSrc = node.attrs.src;
      return true;
    });
    expect(figureSrc).toBe('media/test.png');
  });
});

// Regression suite for the bug fixed in this commit: `nodeToMarkdownFragment`
// (this file's hand-rolled serializer — the one that actually persists to
// SQLite via `getBlockChanges()`, NOT Milkdown's own `getMarkdown()`) used to
// omit `bullet_list`/`ordered_list` from `NESTED_BLOCK_ATOM_TYPES`, so a
// nested sub-list took the generic recursive fallback (no marker-generation
// logic of its own) whenever its containing block was re-saved through THIS
// serializer — silently stripping every `-`/`1.` marker from the nested
// list on persistence, even with no image paste or split involved at all.
// Every prior "nested lists work" test (the describe block above,
// `insert-pos.test.ts`, etc.) exercised Milkdown's stock `getMarkdown()`
// path instead, so none of them could have caught this.
//
// These tests build the top-level list node via the REAL Milkdown pipeline
// (parsing markdown through `makeEditor`, exactly like the suites above),
// serialize ONLY that node with `nodeToMarkdownFragment` (bypassing
// `getMarkdown()` entirely), then reparse the resulting fragment ALONE in a
// fresh editor instance and assert on the resulting document's STRUCTURE
// (nesting depth / parent-child node types / child counts) — not just
// substring matching on the output text — to prove the fix survives a real
// serialize → reparse round trip, not just an in-memory read of the
// fragment string.
describe('nodeToMarkdownFragment — nested list structural round-trip (bug: NESTED_BLOCK_ATOM_TYPES omitted lists)', () => {
  afterEach(() => {
    setEditorInstance(null);
    resetBlockSyncState();
    resetBlockIdState();
  });

  /** Returns the first top-level `bullet_list`/`ordered_list` child of a doc
   * built by parsing `markdown` through the real Milkdown pipeline. */
  async function topLevelListNode(markdown: string): Promise<any> {
    const editor = await makeEditor(markdown);
    const view = editor.ctx.get(editorViewCtx);
    let node: any = null;
    view.state.doc.forEach((child: any) => {
      if (!node && (child.type.name === 'bullet_list' || child.type.name === 'ordered_list')) node = child;
    });
    if (!node) throw new Error('topLevelListNode: no top-level list found in parsed doc');
    return node;
  }

  /** Walks up from the (unique) text node matching `text` and returns the
   * chain of ancestor type names from the document's top-level block down to
   * (and including) the immediate textblock parent — e.g.
   * `['bullet_list', 'list_item', 'ordered_list', 'list_item', 'paragraph']`
   * for a bullet item's nested ordered sub-item. Used to assert exact
   * nesting depth and parent/child node types, not just text content. */
  function ancestorChainTypeNames(doc: any, text: string): string[] {
    const pos = findTextPos(doc, text);
    const $pos = doc.resolve(pos);
    const chain: string[] = [];
    for (let d = 1; d <= $pos.depth; d++) {
      chain.push($pos.node(d).type.name);
    }
    return chain;
  }

  const BULLET_OVER_ORDERED_MD = ['- Outer A', '  1. Inner 1', '  2. Inner 2', '- Outer B'].join('\n');
  const ORDERED_OVER_BULLET_MD = ['1. Outer A', '   - Inner 1', '   - Inner 2', '2. Outer B'].join('\n');

  // 3-level nesting, both directions — confirms the fix works at arbitrary
  // depth, not just one level.
  const BULLET_OVER_ORDERED_OVER_BULLET_MD = [
    '- Outer A',
    '  1. Middle 1',
    '     - Leaf 1',
    '     - Leaf 2',
    '  2. Middle 2',
    '- Outer B',
  ].join('\n');
  const ORDERED_OVER_BULLET_OVER_ORDERED_MD = [
    '1. Outer A',
    '   - Middle 1',
    '     1. Leaf 1',
    '     2. Leaf 2',
    '   - Middle 2',
    '2. Outer B',
  ].join('\n');

  it('2-level: bullet_list containing a nested ordered_list — structure survives serialize → reparse', async () => {
    const listNode = await topLevelListNode(BULLET_OVER_ORDERED_MD);
    const fragment = nodeToMarkdownFragment(listNode);
    const reloaded = await reparse(fragment);

    expect(countNodesOfType(reloaded, 'bullet_list')).toBe(1);
    expect(countNodesOfType(reloaded, 'ordered_list')).toBe(1);
    expect(ancestorChainTypeNames(reloaded, 'Inner 1')).toEqual([
      'bullet_list',
      'list_item',
      'ordered_list',
      'list_item',
      'paragraph',
    ]);
    expect(nearestAncestorOfType(reloaded, 'Outer A', 'bullet_list').childCount).toBe(2);
    const inner = nearestAncestorOfType(reloaded, 'Inner 1', 'ordered_list');
    expect(inner.childCount).toBe(2);
    expect(inner.attrs.order).toBe(1);
  });

  it('2-level: ordered_list containing a nested bullet_list — structure survives serialize → reparse', async () => {
    const listNode = await topLevelListNode(ORDERED_OVER_BULLET_MD);
    const fragment = nodeToMarkdownFragment(listNode);
    const reloaded = await reparse(fragment);

    expect(countNodesOfType(reloaded, 'ordered_list')).toBe(1);
    expect(countNodesOfType(reloaded, 'bullet_list')).toBe(1);
    expect(ancestorChainTypeNames(reloaded, 'Inner 1')).toEqual([
      'ordered_list',
      'list_item',
      'bullet_list',
      'list_item',
      'paragraph',
    ]);
    expect(nearestAncestorOfType(reloaded, 'Outer A', 'ordered_list').childCount).toBe(2);
    expect(nearestAncestorOfType(reloaded, 'Outer A', 'ordered_list').attrs.order).toBe(1);
    expect(nearestAncestorOfType(reloaded, 'Inner 1', 'bullet_list').childCount).toBe(2);
  });

  it('3-level: bullet > ordered > bullet — structure survives serialize → reparse at arbitrary depth', async () => {
    const listNode = await topLevelListNode(BULLET_OVER_ORDERED_OVER_BULLET_MD);
    const fragment = nodeToMarkdownFragment(listNode);
    const reloaded = await reparse(fragment);

    expect(ancestorChainTypeNames(reloaded, 'Leaf 1')).toEqual([
      'bullet_list',
      'list_item',
      'ordered_list',
      'list_item',
      'bullet_list',
      'list_item',
      'paragraph',
    ]);
    expect(nearestAncestorOfType(reloaded, 'Outer A', 'bullet_list').childCount).toBe(2);
    const middle = nearestAncestorOfType(reloaded, 'Middle 1', 'ordered_list');
    expect(middle.childCount).toBe(2);
    expect(middle.attrs.order).toBe(1);
    expect(nearestAncestorOfType(reloaded, 'Leaf 1', 'bullet_list').childCount).toBe(2);
  });

  it('3-level: ordered > bullet > ordered — structure survives serialize → reparse at arbitrary depth', async () => {
    const listNode = await topLevelListNode(ORDERED_OVER_BULLET_OVER_ORDERED_MD);
    const fragment = nodeToMarkdownFragment(listNode);
    const reloaded = await reparse(fragment);

    expect(ancestorChainTypeNames(reloaded, 'Leaf 1')).toEqual([
      'ordered_list',
      'list_item',
      'bullet_list',
      'list_item',
      'ordered_list',
      'list_item',
      'paragraph',
    ]);
    expect(nearestAncestorOfType(reloaded, 'Outer A', 'ordered_list').childCount).toBe(2);
    const middle = nearestAncestorOfType(reloaded, 'Middle 1', 'bullet_list');
    expect(middle.childCount).toBe(2);
    const leaf = nearestAncestorOfType(reloaded, 'Leaf 1', 'ordered_list');
    expect(leaf.childCount).toBe(2);
    expect(leaf.attrs.order).toBe(1);
  });

  // Mirrors the existing "(b) nested split" case above (a nested ordered
  // list interrupted mid-list by a dropped image), but exercised through
  // `nodeToMarkdownFragment` directly instead of `getMarkdown()` — proving
  // the numbering fix holds for the hand-rolled persistence serializer in
  // the same split scenario the stock-serializer suite above already covers.
  it('split-list case: nested ordered list interrupted by a dropped image — numbers stay sequential after reparse (no restart)', async () => {
    const NESTED_ORDERED_LIST_MD = ['1. Outer 1', '   1. Inner 1', '   2. Inner 2', '   3. Inner 3', '2. Outer 2'].join(
      '\n'
    );
    const editor = await makeEditor(NESTED_ORDERED_LIST_MD);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const inner2Pos = findTextPos(view.state.doc, 'Inner 2');
    view.dispatch(view.state.tr.setSelection(TextSelection.create(view.state.doc, inner2Pos)));

    const handled = view.someProp('handlePaste', (f) => f(view, fakePasteEvent(), undefined as any));
    expect(handled).toBe(true);

    insertImage({ src: 'media/test.png', alt: '', caption: '', width: null, blockId: 'temp-test-block' });

    // The whole document is a single top-level ordered_list (no surrounding
    // paragraphs in NESTED_ORDERED_LIST_MD), so it alone is what gets
    // persisted via nodeToMarkdownFragment for this block.
    let topNode: any = null;
    view.state.doc.forEach((child: any) => {
      if (!topNode) topNode = child;
    });
    const fragment = nodeToMarkdownFragment(topNode);

    // Sanity: nodeToMarkdownFragment itself must emit numbered markers for
    // BOTH split halves of the nested list. Pre-fix, bullet_list/ordered_list
    // were excluded from NESTED_BLOCK_ATOM_TYPES, so the nested lists took
    // the plain recursive fallback and serialized with NO markers at all
    // ("Inner 1"/"Inner 2"/"Inner 3" as bare lines) — destroying the nested
    // numbering entirely, not just miscounting it.
    expect(fragment).toMatch(/1\.\s+Inner 1/);
    expect(fragment).toMatch(/2\.\s+Inner 2/);
    expect(fragment).toMatch(/3\.\s+Inner 3/);

    const reloaded = await reparse(fragment);

    // Fixed: the container-recursion branch of serializeInlineContent now
    // inserts a blank-line separator ('\n\n') between adjacent children
    // whenever either neighbor is a NESTED_BLOCK_ATOM_TYPES member, so the
    // dropped image no longer demotes from `figure` to a plain inline image,
    // and the two split nested-list fragments no longer re-merge into one
    // list on reparse. Assert the actual structure, not just that the
    // numbers stay sequential.
    expect(countNodesOfType(reloaded, 'figure')).toBe(1);
    expect(countNodesOfType(reloaded, 'image')).toBe(0);
    expect(countNodesOfType(reloaded, 'ordered_list')).toBe(3); // outer list + 2 split nested-list fragments
    expect(nearestAncestorOfType(reloaded, 'Inner 1', 'ordered_list')).not.toBe(
      nearestAncestorOfType(reloaded, 'Inner 2', 'ordered_list')
    );

    let reloadedTopNode: any = null;
    reloaded.forEach((child: any) => {
      if (!reloadedTopNode) reloadedTopNode = child;
    });
    const reloadedFragment = nodeToMarkdownFragment(reloadedTopNode);
    expect(reloadedFragment).toMatch(/1\.\s+Inner 1/);
    expect(reloadedFragment).toMatch(/2\.\s+Inner 2/);
    expect(reloadedFragment).toMatch(/3\.\s+Inner 3/);

    flushPendingBlockChanges();
    expect(getBlockChanges().deletes).toEqual([]);
  });

  // Plain tight nested list (list_item: paragraph + nested list, NO split, NO
  // blank line) — proves the blank-line-insertion fix above does not visibly
  // change output for the common, unsplit case: getMarkdown() on the
  // reloaded doc must be byte-identical to getMarkdown() on the original.
  it('plain tight nested list (no split): serialize → reparse round-trips getMarkdown() identically', async () => {
    const editor = await makeEditor(BULLET_OVER_ORDERED_MD);
    setEditorInstance(editor);

    const originalMarkdown = getMarkdown()(editor.ctx);

    let topNode: any = null;
    editor.ctx.get(editorViewCtx).state.doc.forEach((child: any) => {
      if (!topNode) topNode = child;
    });
    const fragment = nodeToMarkdownFragment(topNode);
    const reloadedEditor = await makeEditor(fragment);
    const reloadedMarkdown = getMarkdown()(reloadedEditor.ctx);

    expect(reloadedMarkdown).toBe(originalMarkdown);
  });

  // Blockquote containing a paragraph + a nested ordered_list as its second
  // child, split with NO blank line — built via direct schema node
  // constructors (mirrors the "ghost inline image" pattern above: real
  // schema nodes, no markdown parsing involved in construction). Proves the
  // fix generalizes to blockquote, not just list_item.
  //
  // The nested list deliberately starts at `order: 2`, not 1: CommonMark's
  // list-interrupts-paragraph rule lets an ordered list starting at exactly
  // 1 interrupt an open paragraph even with no blank line, which would make
  // this test pass identically whether or not the fix is applied (no real
  // discriminating power). A list starting at 2 can NOT interrupt a
  // paragraph without a blank line, so this only reparses as one blockquote
  // containing an intact nested list because serializeInlineContent now
  // inserts that blank line — verified empirically by reverting the fix and
  // confirming this test fails.
  it('blockquote containing a paragraph + nested ordered_list, split with no blank line, is not split by the fix', async () => {
    const editor = await makeEditor('placeholder');
    const view = editor.ctx.get(editorViewCtx);
    const schema = view.state.schema;

    const innerList = schema.nodes.ordered_list!.create({ order: 2 }, [
      schema.nodes.list_item!.create({}, [schema.nodes.paragraph!.create({}, schema.text('Inner 1'))]),
      schema.nodes.list_item!.create({}, [schema.nodes.paragraph!.create({}, schema.text('Inner 2'))]),
    ]);
    const quote = schema.nodes.blockquote!.create({}, [
      schema.nodes.paragraph!.create({}, schema.text('Quoted intro')),
      innerList,
    ]);

    const fragment = nodeToMarkdownFragment(quote);
    const reloaded = await reparse(fragment);

    expect(countNodesOfType(reloaded, 'blockquote')).toBe(1);
    expect(nearestAncestorOfType(reloaded, 'Inner 1', 'blockquote')).not.toBeNull();
    expect(nearestAncestorOfType(reloaded, 'Inner 1', 'ordered_list')).not.toBeNull();
  });

  // Genericity spot-checks: the same "split mid-list, no blank line" shape,
  // but with a code_block / table standing in for the dropped image — proves
  // the fix applies to NESTED_BLOCK_ATOM_TYPES generically, not just
  // figure/list. (horizontal_rule is deliberately excluded: its real schema
  // node name is `hr`, not `horizontal_rule`, so NESTED_BLOCK_ATOM_TYPES can
  // never actually match it — a separate, pre-existing, out-of-scope issue.)
  it('genericity: nested ordered list split by a code_block (no blank line) stays split on reparse', async () => {
    const editor = await makeEditor('placeholder');
    const view = editor.ctx.get(editorViewCtx);
    const schema = view.state.schema;

    const innerList1 = schema.nodes.ordered_list!.create({ order: 1 }, [
      schema.nodes.list_item!.create({}, [schema.nodes.paragraph!.create({}, schema.text('Inner 1'))]),
    ]);
    const codeBlock = schema.nodes.code_block!.create({ language: '' }, schema.text('const x = 1;'));
    const innerList2 = schema.nodes.ordered_list!.create({ order: 2 }, [
      schema.nodes.list_item!.create({}, [schema.nodes.paragraph!.create({}, schema.text('Inner 2'))]),
    ]);
    const outerItem = schema.nodes.list_item!.create({}, [
      schema.nodes.paragraph!.create({}, schema.text('Outer 1')),
      innerList1,
      codeBlock,
      innerList2,
    ]);
    const outerList = schema.nodes.ordered_list!.create({ order: 1 }, [outerItem]);

    const fragment = nodeToMarkdownFragment(outerList);
    const reloaded = await reparse(fragment);

    expect(countNodesOfType(reloaded, 'code_block')).toBe(1);
    expect(countNodesOfType(reloaded, 'ordered_list')).toBe(3); // outer list + 2 split nested-list fragments
    expect(nearestAncestorOfType(reloaded, 'Inner 1', 'ordered_list')).not.toBe(
      nearestAncestorOfType(reloaded, 'Inner 2', 'ordered_list')
    );
  });

  it('genericity: nested ordered list split by a table (no blank line) stays split on reparse', async () => {
    const editor = await makeEditor('placeholder');
    const view = editor.ctx.get(editorViewCtx);
    const schema = view.state.schema;

    const innerList1 = schema.nodes.ordered_list!.create({ order: 1 }, [
      schema.nodes.list_item!.create({}, [schema.nodes.paragraph!.create({}, schema.text('Inner 1'))]),
    ]);
    const table = schema.nodes.table!.create({}, [
      schema.nodes.table_header_row!.create({}, [
        schema.nodes.table_header!.create({}, schema.nodes.paragraph!.create({}, schema.text('H'))),
      ]),
      schema.nodes.table_row!.create({}, [
        schema.nodes.table_cell!.create({}, schema.nodes.paragraph!.create({}, schema.text('C'))),
      ]),
    ]);
    const innerList2 = schema.nodes.ordered_list!.create({ order: 2 }, [
      schema.nodes.list_item!.create({}, [schema.nodes.paragraph!.create({}, schema.text('Inner 2'))]),
    ]);
    const outerItem = schema.nodes.list_item!.create({}, [
      schema.nodes.paragraph!.create({}, schema.text('Outer 1')),
      innerList1,
      table,
      innerList2,
    ]);
    const outerList = schema.nodes.ordered_list!.create({ order: 1 }, [outerItem]);

    const fragment = nodeToMarkdownFragment(outerList);
    const reloaded = await reparse(fragment);

    expect(countNodesOfType(reloaded, 'table')).toBe(1);
    expect(countNodesOfType(reloaded, 'ordered_list')).toBe(3); // outer list + 2 split nested-list fragments
    expect(nearestAncestorOfType(reloaded, 'Inner 1', 'ordered_list')).not.toBe(
      nearestAncestorOfType(reloaded, 'Inner 2', 'ordered_list')
    );
  });
});
