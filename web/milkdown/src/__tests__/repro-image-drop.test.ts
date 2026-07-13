// @vitest-environment jsdom
//
// Regression suite for the "image drag-and-drop lands at the bottom of the
// document" bug (image-drag-drop-position plan, §1/§3), against the REAL
// Milkdown editor pipeline — real commonmark/gfm schema, real
// blockIdPlugin/blockSyncPlugin, real imagePlugin, and the real
// api-content.ts insertImage() — as opposed to insert-pos.test.ts's
// hand-rolled schema, which validates computeCursorAwareInsertPos in
// isolation but cannot catch a regression that only manifests through the
// real plugin pipeline.
//
// Modeled directly on repro-list-paste.test.ts's approach for the sibling
// paste-position fix: drives the ACTUAL imagePasteDropPlugin.handleDrop code
// path (via view.someProp) so pendingDropPos is captured exactly the way
// production captures it — no module mocking, no reimplementation of
// insertImage()'s internals. view.posAtCoords is monkey-patched to a fixed
// {pos, inside} since jsdom has no real layout/getBoundingClientRect to
// resolve actual mouse coordinates against.
import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { Slice } from '@milkdown/kit/prose/model';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { insertImage } from '../api-content';
import { blockIdPlugin, resetBlockIdState } from '../block-id-plugin';
import { blockSyncPlugin, flushPendingBlockChanges, getBlockChanges, resetBlockSyncState } from '../block-sync-plugin';
import { setEditorInstance } from '../editor-state';
import { highlightPlugin } from '../highlight-plugin';
import { consumePendingDropPos, imagePlugin } from '../image-plugin';

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
    if (node.type.name === 'figure') {
      out.push(`FIGURE(src=${node.attrs.src})`);
    } else {
      out.push(`${node.type.name}(${JSON.stringify(node.textContent)})`);
    }
  });
  return out;
}

/** Position immediately after a given top-level paragraph's closing tag —
 * the depth-0 gap between it and its next sibling (the same class of
 * position the pre-fix `handleDrop` discarded in favor of doc-end). */
function findGapAfterParagraph(doc: any, text: string): number {
  let pos = -1;
  doc.forEach((node: any, offset: number) => {
    if (pos < 0 && node.type.name === 'paragraph' && node.textContent === text) {
      pos = offset + node.nodeSize;
    }
  });
  if (pos < 0) throw new Error(`paragraph with text ${JSON.stringify(text)} not found`);
  return pos;
}

function fakeDropEvent(): DragEvent {
  const fakeFile = new File(['fake-image-bytes'], 'test.png', { type: 'image/png' });
  return {
    dataTransfer: { files: [fakeFile] },
    clientX: 0,
    clientY: 0,
    preventDefault: () => {},
    stopPropagation: () => {},
  } as unknown as DragEvent;
}

/** Directly invoke the imagePasteDropPlugin's own handleDrop prop, bypassing
 * EditorView.someProp: someProp only returns a value when the callback
 * returns something truthy (see prosemirror-view's implementation), so it
 * collapses a literal `false` return (Fix X's early exit) into `undefined` —
 * which would defeat an exact `toBe(false)` assertion below. */
function callHandleDropDirectly(view: EditorView, event: DragEvent): boolean {
  const plugin = view.state.plugins.find((p) => typeof p.props.handleDrop === 'function');
  if (!plugin) throw new Error('no plugin with a handleDrop prop found');
  return (plugin.props.handleDrop as (v: EditorView, e: DragEvent) => boolean)(view, event);
}

// handleDrop's duplicate-drop dedup guard (`lastDropTime` in image-plugin.ts)
// is module-scoped state that persists across tests in this file. Mock
// Date.now with a fresh, far-apart (>200ms) timestamp per test so one test's
// drop is never mistaken for a duplicate of a previous test's drop.
let mockNow = Date.now();
beforeEach(() => {
  mockNow += 10_000;
  vi.spyOn(Date, 'now').mockImplementation(() => mockNow);
});

afterEach(() => {
  vi.restoreAllMocks();
});

const THREE_PARA_MD = ['First paragraph.', '', 'Second paragraph.', '', 'Third paragraph.'].join('\n');

const THREE_ITEM_LIST_MD = ['Before paragraph.', '', '- Item 1', '- Item 2', '- Item 3', '', 'After paragraph.'].join(
  '\n'
);

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

describe('REAL pipeline repro: external file drop at a depth-0 gap', () => {
  afterEach(() => {
    setEditorInstance(null);
    resetBlockSyncState();
    resetBlockIdState();
  });

  it('drop resolving to the gap between the first and second paragraphs lands there, not at doc-end', async () => {
    const editor = await makeEditor(THREE_PARA_MD);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const gapPos = findGapAfterParagraph(view.state.doc, 'First paragraph.');
    view.posAtCoords = () => ({ pos: gapPos, inside: -1 });

    const handled = view.someProp('handleDrop', (f) => f(view, fakeDropEvent(), undefined as any));
    expect(handled).toBe(true);

    // Call the REAL insertImage(), exactly as Swift does after the
    // FileReader/native-image-import round trip completes.
    insertImage({ src: 'projectmedia://test.png', alt: '', caption: '', width: null, blockId: 'temp-test-block' });

    const top = describeDoc(view.state.doc);
    expect(top).toEqual([
      'paragraph("First paragraph.")',
      'FIGURE(src=projectmedia://test.png)',
      'paragraph("Second paragraph.")',
      'paragraph("Third paragraph.")',
    ]);

    flushPendingBlockChanges();
    expect(getBlockChanges().deletes).toEqual([]);
  });

  it('drop resolving mid-list-item cleanly splits the list around the image (§5 regression insurance)', async () => {
    const editor = await makeEditor(THREE_ITEM_LIST_MD);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const item2Pos = findTextPos(view.state.doc, 'Item 2');
    view.posAtCoords = () => ({ pos: item2Pos, inside: -1 });

    const handled = view.someProp('handleDrop', (f) => f(view, fakeDropEvent(), undefined as any));
    expect(handled).toBe(true);

    insertImage({ src: 'projectmedia://test.png', alt: '', caption: '', width: null, blockId: 'temp-test-block' });

    const top = describeDoc(view.state.doc);
    expect(top).toEqual([
      'paragraph("Before paragraph.")',
      'bullet_list("Item 1")',
      'FIGURE(src=projectmedia://test.png)',
      'bullet_list("Item 2Item 3")',
      'paragraph("After paragraph.")',
    ]);

    flushPendingBlockChanges();
    expect(getBlockChanges().deletes).toEqual([]);
  });
});

describe('Fix X: view.dragging guard', () => {
  afterEach(() => {
    setEditorInstance(null);
    resetBlockSyncState();
    resetBlockIdState();
  });

  it('handleDrop returns false immediately when view.dragging is truthy, without capturing a pending drop position', async () => {
    const editor = await makeEditor(THREE_PARA_MD);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    // Simulate a drag gesture that began inside this editor (a figure move),
    // which ProseMirror's own dragstart handler marks by setting this field.
    view.dragging = { slice: Slice.empty, move: true };

    const handled = callHandleDropDirectly(view, fakeDropEvent());
    expect(handled).toBe(false);

    // The guard must return before touching pendingDropPos — nothing for a
    // later insertImage() call to (wrongly) pick up.
    expect(consumePendingDropPos()).toBeNull();
  });
});
