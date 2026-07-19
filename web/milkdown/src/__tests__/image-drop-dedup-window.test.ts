// @vitest-environment jsdom
//
// Regression suite for handleDrop's two dedup guards in image-plugin.ts:
//
// 1. The 200ms `lastDropTime` guard — macOS can fire two DOM `drop` events for
//    a single user drag (kDragIPCCompleted firing twice), so handleDrop
//    ignores a second drop that lands within 200ms of the last one.
// 2. The 3000ms identity guard — a slower duplicate delivery of the SAME file
//    (matching name/size/lastModified) can land outside the 200ms window but
//    still be a spurious re-delivery rather than a genuine user-initiated
//    second drop. handleDrop ignores a second drop of an identical file
//    within 3000ms of the last accepted drop.
//
// This file proves both guards' actual behavior at their boundaries — a drop
// just inside a window is swallowed, a drop just outside it is treated as
// genuinely new — rather than asserting an idealized threshold. It also
// proves the two guards compose correctly: a drop suppressed by the identity
// guard must NOT refresh/slide the identity window for later drops, and only
// a MATCHING file identity triggers the identity guard (mere timing is not
// enough).
//
// Modeled directly on repro-image-drop.test.ts's approach: drives the REAL
// imagePasteDropPlugin.handleDrop code path (via callHandleDropDirectly, not
// EditorView.someProp — someProp collapses a literal `false` return into
// `undefined`) against the real Milkdown pipeline, then simulates the async
// Swift round-trip by calling the real insertImage() directly, exactly as
// that file does.
import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { insertImage } from '../api-content';
import { blockIdPlugin, resetBlockIdState } from '../block-id-plugin';
import { blockSyncPlugin, resetBlockSyncState } from '../block-sync-plugin';
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
 * mirrors repro-image-drop.test.ts's findGapAfterParagraph. */
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

/** The same File instance is reused for both drops in a scenario (identical
 * name/size/lastModified) — matching the real repro this guard exists for:
 * macOS re-delivering ONE user drag as two DOM `drop` events. Pass a
 * different `name` to construct a file with a guaranteed-non-matching
 * identity, for the 3000ms identity guard's different-file scenario. */
function fakeFile(name = 'test.png'): File {
  return new File(['fake-image-bytes'], name, { type: 'image/png' });
}

/** Like repro-image-drop.test.ts's fakeDropEvent(), but with vi.fn() spies
 * for preventDefault/stopPropagation so the DEDUP-vs-pass-through asymmetry
 * (only the pass-through branch calls stopPropagation — see handleDrop in
 * image-plugin.ts) is directly observable. */
function fakeDropEventWithSpies(file: File): {
  event: DragEvent;
  preventDefault: ReturnType<typeof vi.fn>;
  stopPropagation: ReturnType<typeof vi.fn>;
} {
  const preventDefault = vi.fn();
  const stopPropagation = vi.fn();
  const event = {
    dataTransfer: { files: [file] },
    clientX: 0,
    clientY: 0,
    preventDefault,
    stopPropagation,
  } as unknown as DragEvent;
  return { event, preventDefault, stopPropagation };
}

/** Directly invoke the imagePasteDropPlugin's own handleDrop prop, bypassing
 * EditorView.someProp: someProp only returns a value when the callback
 * returns something truthy, which would collapse a literal `false` return
 * into `undefined` and defeat an exact `toBe(false)`/`toBe(true)` assertion. */
function callHandleDropDirectly(view: EditorView, event: DragEvent): boolean {
  const plugin = view.state.plugins.find((p) => typeof p.props.handleDrop === 'function');
  if (!plugin) throw new Error('no plugin with a handleDrop prop found');
  return (plugin.props.handleDrop as (v: EditorView, e: DragEvent) => boolean)(view, event);
}

// Captures every syncLog(...) call routed through the errorHandler bridge
// (see sync-debug.ts) so suppression assertions can verify a guard actually
// logged, not just that it returned the right boolean. Follows the same
// window.webkit.messageHandlers.errorHandler.postMessage capturing-mock
// pattern as block-id-alignment.test.ts.
let postMessages: { message: string }[] = [];

/** Asserts the shared "a drop was suppressed" shape: preventDefault called,
 * stopPropagation NOT called (unlike the pass-through branch, which calls
 * both), consumePendingDropPos() returns null (the guard returned before
 * re-capturing a position), and a syncLog message containing
 * `expectedLogSubstring` was posted. */
function expectSuppressed(
  handled: boolean,
  drop: { preventDefault: ReturnType<typeof vi.fn>; stopPropagation: ReturnType<typeof vi.fn> },
  expectedLogSubstring: string
): void {
  expect(handled).toBe(true);
  expect(drop.preventDefault).toHaveBeenCalled();
  expect(drop.stopPropagation).not.toHaveBeenCalled();
  expect(consumePendingDropPos()).toBeNull();
  expect(postMessages.some((m) => m.message.includes(expectedLogSubstring))).toBe(true);
}

/** Asserts the shared "a drop passed through as genuine" shape: both
 * preventDefault AND stopPropagation called, and consumePendingDropPos()
 * returns a real (non-null) position. */
function expectPassedThrough(
  handled: boolean,
  drop: { preventDefault: ReturnType<typeof vi.fn>; stopPropagation: ReturnType<typeof vi.fn> }
): void {
  expect(handled).toBe(true);
  expect(drop.preventDefault).toHaveBeenCalled();
  expect(drop.stopPropagation).toHaveBeenCalled();
  expect(consumePendingDropPos()).not.toBeNull();
}

// handleDrop's dedup guards (`lastDropTime`/`lastDropFile*` in
// image-plugin.ts) are module-scoped state that persists across tests in
// this file. Mock Date.now with a fresh, far-apart (>3000ms) timestamp per
// test so one test's drop is never mistaken for a duplicate of a previous
// test's drop by either guard.
let mockNow = Date.now();
beforeEach(() => {
  mockNow += 10_000;
  vi.spyOn(Date, 'now').mockImplementation(() => mockNow);
  postMessages = [];
  (window as any).webkit = {
    messageHandlers: {
      errorHandler: { postMessage: (msg: unknown) => postMessages.push(msg as { message: string }) },
    },
  };
});

afterEach(() => {
  vi.restoreAllMocks();
  delete (window as any).webkit;
});

const THREE_PARA_MD = ['First paragraph.', '', 'Second paragraph.', '', 'Third paragraph.'].join('\n');

describe('handleDrop dedup guards (200ms timing + 3000ms identity)', () => {
  afterEach(() => {
    setEditorInstance(null);
    resetBlockSyncState();
    resetBlockIdState();
  });

  it('ignores a second drop 50ms later (inside the 200ms window) — no second image is inserted', async () => {
    const editor = await makeEditor(THREE_PARA_MD);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const gapPos = findGapAfterParagraph(view.state.doc, 'First paragraph.');
    view.posAtCoords = () => ({ pos: gapPos, inside: -1 });

    const file = fakeFile();

    const drop1 = fakeDropEventWithSpies(file);
    const handled1 = callHandleDropDirectly(view, drop1.event);
    expect(handled1).toBe(true);

    // Simulate the real Swift round-trip completing for drop 1 only — a
    // deduped drop 2 never reaches the FileReader/postMessage code that
    // would eventually trigger a second one of these from Swift.
    insertImage({ src: 'projectmedia://test.png', alt: '', caption: '', width: null, blockId: 'temp-test-block-1' });

    mockNow += 50;
    const drop2 = fakeDropEventWithSpies(file);
    const handled2 = callHandleDropDirectly(view, drop2.event);

    // 200ms guard signature: logs "DEDUP:" (not "DEDUP-IDENTITY:").
    expectSuppressed(handled2, drop2, 'DEDUP:');

    // Only drop 1's image made it into the document.
    const top = describeDoc(view.state.doc);
    expect(top).toEqual([
      'paragraph("First paragraph.")',
      'FIGURE(src=projectmedia://test.png)',
      'paragraph("Second paragraph.")',
      'paragraph("Third paragraph.")',
    ]);
  });

  for (const delta of [250, 500, 1000]) {
    it(`ignores a second drop ${delta}ms later (inside the 3000ms identity window) — no second image is inserted`, async () => {
      const editor = await makeEditor(THREE_PARA_MD);
      setEditorInstance(editor);
      const view = editor.ctx.get(editorViewCtx);

      const gapPos = findGapAfterParagraph(view.state.doc, 'First paragraph.');
      view.posAtCoords = () => ({ pos: gapPos, inside: -1 });

      const file = fakeFile();

      const drop1 = fakeDropEventWithSpies(file);
      const handled1 = callHandleDropDirectly(view, drop1.event);
      expect(handled1).toBe(true);

      insertImage({
        src: 'projectmedia://test-1.png',
        alt: '',
        caption: '',
        width: null,
        blockId: 'temp-test-block-1',
      });

      mockNow += delta;
      const drop2 = fakeDropEventWithSpies(file);
      const handled2 = callHandleDropDirectly(view, drop2.event);

      // Outside the 200ms window but the SAME file identity within 3000ms —
      // the identity guard (not the 200ms guard) suppresses this one.
      expectSuppressed(handled2, drop2, 'DEDUP-IDENTITY');

      const top = describeDoc(view.state.doc);
      const figureCount = top.filter((n) => n.startsWith('FIGURE(')).length;
      expect(figureCount).toBe(1);
    });
  }

  it('accepts a second drop 3000ms later (exactly at the identity window boundary) as a genuine new drop', async () => {
    const editor = await makeEditor(THREE_PARA_MD);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const gapPos = findGapAfterParagraph(view.state.doc, 'First paragraph.');
    view.posAtCoords = () => ({ pos: gapPos, inside: -1 });

    const file = fakeFile();

    const drop1 = fakeDropEventWithSpies(file);
    const handled1 = callHandleDropDirectly(view, drop1.event);
    expect(handled1).toBe(true);

    insertImage({
      src: 'projectmedia://test-1.png',
      alt: '',
      caption: '',
      width: null,
      blockId: 'temp-test-block-1',
    });

    mockNow += 3000;
    const drop2 = fakeDropEventWithSpies(file);
    const handled2 = callHandleDropDirectly(view, drop2.event);

    // Exactly 3000ms since the last accepted drop of the SAME file: the
    // identity guard's condition is `< 3000`, so exactly 3000ms must NOT be
    // suppressed — this is the boundary edge.
    expectPassedThrough(handled2, drop2);

    insertImage({
      src: 'projectmedia://test-2.png',
      alt: '',
      caption: '',
      width: null,
      blockId: 'temp-test-block-2',
    });

    const top = describeDoc(view.state.doc);
    const figureCount = top.filter((n) => n.startsWith('FIGURE(')).length;
    expect(figureCount).toBe(2);
  });

  it('accepts a second drop 3050ms later (just past the identity window) as a genuine new drop', async () => {
    const editor = await makeEditor(THREE_PARA_MD);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const gapPos = findGapAfterParagraph(view.state.doc, 'First paragraph.');
    view.posAtCoords = () => ({ pos: gapPos, inside: -1 });

    const file = fakeFile();

    const drop1 = fakeDropEventWithSpies(file);
    const handled1 = callHandleDropDirectly(view, drop1.event);
    expect(handled1).toBe(true);

    insertImage({
      src: 'projectmedia://test-1.png',
      alt: '',
      caption: '',
      width: null,
      blockId: 'temp-test-block-1',
    });

    mockNow += 3050;
    const drop2 = fakeDropEventWithSpies(file);
    const handled2 = callHandleDropDirectly(view, drop2.event);

    // Proves the identity window has an actual edge — it does not suppress
    // matching-identity drops indefinitely.
    expectPassedThrough(handled2, drop2);

    insertImage({
      src: 'projectmedia://test-2.png',
      alt: '',
      caption: '',
      width: null,
      blockId: 'temp-test-block-2',
    });

    const top = describeDoc(view.state.doc);
    const figureCount = top.filter((n) => n.startsWith('FIGURE(')).length;
    expect(figureCount).toBe(2);
  });

  it('accepts a second drop 500ms later of a DIFFERENT file as a genuine new drop (identity, not just timing, gates the guard)', async () => {
    const editor = await makeEditor(THREE_PARA_MD);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const gapPos = findGapAfterParagraph(view.state.doc, 'First paragraph.');
    view.posAtCoords = () => ({ pos: gapPos, inside: -1 });

    const fileA = fakeFile('test-a.png');

    const drop1 = fakeDropEventWithSpies(fileA);
    const handled1 = callHandleDropDirectly(view, drop1.event);
    expect(handled1).toBe(true);

    insertImage({
      src: 'projectmedia://test-1.png',
      alt: '',
      caption: '',
      width: null,
      blockId: 'temp-test-block-1',
    });

    mockNow += 500;
    // A DIFFERENT file (different name — guaranteed non-matching identity),
    // dropped well inside the 3000ms identity window. Only a matching
    // identity should trigger suppression, not mere timing proximity.
    const fileB = fakeFile('test-b.png');
    const drop2 = fakeDropEventWithSpies(fileB);
    const handled2 = callHandleDropDirectly(view, drop2.event);

    expectPassedThrough(handled2, drop2);

    insertImage({
      src: 'projectmedia://test-2.png',
      alt: '',
      caption: '',
      width: null,
      blockId: 'temp-test-block-2',
    });

    const top = describeDoc(view.state.doc);
    const figureCount = top.filter((n) => n.startsWith('FIGURE(')).length;
    expect(figureCount).toBe(2);
  });

  it('does not refresh the identity window on a suppressed drop — a later genuine re-drop of the same file still passes through once ≥3000ms have elapsed since the ORIGINAL accepted drop', async () => {
    const editor = await makeEditor(THREE_PARA_MD);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const gapPos = findGapAfterParagraph(view.state.doc, 'First paragraph.');
    view.posAtCoords = () => ({ pos: gapPos, inside: -1 });

    const file = fakeFile();

    // Drop A at t=0 — accepted.
    const dropA = fakeDropEventWithSpies(file);
    const handledA = callHandleDropDirectly(view, dropA.event);
    expect(handledA).toBe(true);

    insertImage({
      src: 'projectmedia://test-1.png',
      alt: '',
      caption: '',
      width: null,
      blockId: 'temp-test-block-1',
    });

    // Ghost duplicate of the SAME file at t=500 — suppressed by the identity
    // guard. Per expectSuppressed, this must also log DEDUP-IDENTITY.
    mockNow += 500;
    const ghost = fakeDropEventWithSpies(file);
    const handledGhost = callHandleDropDirectly(view, ghost.event);
    expectSuppressed(handledGhost, ghost, 'DEDUP-IDENTITY');

    // A genuine re-drop of the SAME file at t=3100 (relative to drop A) —
    // i.e. 2600ms after the suppressed ghost. If the ghost's suppression had
    // refreshed/slid the identity window, this would measure only ~2600ms
    // since the "last matching drop" and get wrongly suppressed. It must NOT
    // be suppressed: the window is anchored to drop A's t=0, not the ghost's
    // t=500, proving a suppressed drop does not refresh the window.
    mockNow += 2600;
    const dropAgain = fakeDropEventWithSpies(file);
    const handledAgain = callHandleDropDirectly(view, dropAgain.event);
    expectPassedThrough(handledAgain, dropAgain);

    insertImage({
      src: 'projectmedia://test-2.png',
      alt: '',
      caption: '',
      width: null,
      blockId: 'temp-test-block-2',
    });

    const top = describeDoc(view.state.doc);
    const figureCount = top.filter((n) => n.startsWith('FIGURE(')).length;
    expect(figureCount).toBe(2);
  });
});
