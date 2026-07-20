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
