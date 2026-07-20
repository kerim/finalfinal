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
