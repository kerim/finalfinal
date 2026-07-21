// @vitest-environment jsdom
//
// Regression suite for "a plain (non-figure) inline `image` node never
// renders" (async-image-corruption plan). remarkFigurePlugin only promotes a
// standalone-line `![alt](media/...)` image to the app's own `figure` node
// (image-plugin.ts's promotion gate requires the image to be the paragraph's
// FIRST child, with only a recognized `{alt=...}` attrs block as any
// subsequent sibling — see image-plugin.ts's remarkFigurePlugin). A `media/`
// image with a real text sibling elsewhere in the same paragraph — confirmed
// for both a plain top-level paragraph and a list item's own paragraph —
// fails that gate and stays a plain, upstream-schema `image` node. Before
// this fix, upstream's `image` schema wrote the raw `media/...` path
// straight into the rendered `<img src>`, which is not a resolvable URL
// scheme for WKWebView, so the image rendered as a permanent broken-image
// icon. image-node-rewrite-plugin.ts fixes this the same way FigureNodeView
// already fixes it for `figure`: rewrite `media/...` to `projectmedia://...`
// for display, while keeping the canonical `media/...` value recoverable via
// a `data-src` attribute.
//
// Verified directly against this real Milkdown pipeline (see the design
// investigation notes in the implementing plan) that production's
// `insertImage()` (api-content.ts) — the sole entry point for BOTH an
// image-FILE paste and an image-FILE drag-and-drop — unconditionally
// constructs a `figureType` node, never a plain `image` node, regardless of
// where in a paragraph the cursor/drop point lands (ProseMirror's replace
// algorithm splits the surrounding paragraph and inserts the figure as a
// block sibling instead). So the plain-`image` scenario this plugin fixes is
// reached via markdown TEXT containing an inline image reference mid-
// paragraph — e.g. a paste of a markdown snippet, a drag-and-drop of a `.md`
// file/text selection, or simply loading/reopening a document whose stored
// markdown already has this shape (imported content, or text typed directly
// in Source Mode) — all of which go through the exact same commonmark parse
// + remarkFigurePlugin promotion-gate path exercised below via
// `defaultValueCtx`. Cases 1-4 use that path (the only one that reliably,
// verifiably produces a plain `image` node with a `media/`-prefixed src in
// this codebase); case 5 uses the REAL `imagePasteDropPlugin.handleDrop` +
// `insertImage()` file-drop path (repro-image-drop.test.ts's established
// pattern) as a drag-and-drop regression guard for the (figure) path that
// mechanism actually produces — see that test's own comment for why it
// can't reach the plain-image path.
//
// makeEditor()/reparse() pattern follows repro-list-paste.test.ts /
// repro-image-drop.test.ts: real commonmark/gfm schema, real
// blockIdPlugin/blockSyncPlugin, real imagePlugin, plus the new
// imageNodeRewritePlugin under test — matching main.ts's real registration
// order (AFTER commonmark/gfm, alongside orderedListOrderPlugin).
import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { EditorView } from '@milkdown/kit/prose/view';
import { getMarkdown } from '@milkdown/kit/utils';
import { afterEach, describe, expect, it } from 'vitest';
import { insertImage } from '../api-content';
import { blockIdPlugin, resetBlockIdState } from '../block-id-plugin';
import { blockSyncPlugin, flushPendingBlockChanges, getBlockChanges, resetBlockSyncState } from '../block-sync-plugin';
import { setEditorInstance } from '../editor-state';
import { highlightPlugin } from '../highlight-plugin';
import { imageNodeRewritePlugin } from '../image-node-rewrite-plugin';
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
    .use(imageNodeRewritePlugin)
    .use(highlightPlugin)
    .create();
  return editor;
}

/** Mirrors repro-list-paste.test.ts's reparse() but returns the VIEW (not
 * just .state.doc) so the rendered `<img src>` can be inspected post-reload
 * too — the actual coverage gap this suite exists to close (existing test
 * (e) in repro-list-paste.test.ts never round-trips; (g) round-trips but
 * only checks node type/attrs, never the rendered DOM). */
async function reparseToView(markdown: string): Promise<EditorView> {
  const editor = await makeEditor(markdown);
  return editor.ctx.get(editorViewCtx);
}

function countNodesOfType(doc: any, typeName: string): number {
  let count = 0;
  doc.descendants((node: any) => {
    if (node.type.name === typeName) count++;
    return true;
  });
  return count;
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

const LIST_ITEM_MID_IMAGE_MD = ['- Item with an ![alt text](media/test.png) embedded mid-line.'].join('\n');

const PLAIN_PARAGRAPH_MID_IMAGE_MD = 'Before text ![alt text](media/test.png) after text.';

describe('image-node-rewrite-plugin: plain inline image rendering', () => {
  afterEach(() => {
    setEditorInstance(null);
    resetBlockSyncState();
    resetBlockIdState();
  });

  it('1. mid-paragraph image inside a list item renders rewritten, fresh parse — and is a plain image, not a figure', async () => {
    const editor = await makeEditor(LIST_ITEM_MID_IMAGE_MD);
    const view = editor.ctx.get(editorViewCtx);

    expect(countNodesOfType(view.state.doc, 'image')).toBe(1);
    expect(countNodesOfType(view.state.doc, 'figure')).toBe(0);

    const img = view.dom.querySelector('img');
    expect(img?.getAttribute('src')).toBe('projectmedia://test.png');
    expect(img?.getAttribute('data-src')).toBe('media/test.png');
  });

  it('2. mid-paragraph image inside a list item renders rewritten, after a round trip', async () => {
    const editor = await makeEditor(LIST_ITEM_MID_IMAGE_MD);
    const markdown = getMarkdown()(editor.ctx);

    const reloadedView = await reparseToView(markdown);
    expect(countNodesOfType(reloadedView.state.doc, 'image')).toBe(1);
    expect(countNodesOfType(reloadedView.state.doc, 'figure')).toBe(0);

    const img = reloadedView.dom.querySelector('img');
    expect(img?.getAttribute('src')).toBe('projectmedia://test.png');
    expect(img?.getAttribute('data-src')).toBe('media/test.png');
  });

  it('3. mid-paragraph image inside an ordinary (non-list) paragraph renders rewritten, fresh parse', async () => {
    const editor = await makeEditor(PLAIN_PARAGRAPH_MID_IMAGE_MD);
    const view = editor.ctx.get(editorViewCtx);

    expect(countNodesOfType(view.state.doc, 'image')).toBe(1);
    expect(countNodesOfType(view.state.doc, 'figure')).toBe(0);

    const img = view.dom.querySelector('img');
    expect(img?.getAttribute('src')).toBe('projectmedia://test.png');
    expect(img?.getAttribute('data-src')).toBe('media/test.png');
  });

  it('4. mid-paragraph image inside an ordinary (non-list) paragraph renders rewritten, after a round trip', async () => {
    const editor = await makeEditor(PLAIN_PARAGRAPH_MID_IMAGE_MD);
    const markdown = getMarkdown()(editor.ctx);

    const reloadedView = await reparseToView(markdown);
    expect(countNodesOfType(reloadedView.state.doc, 'image')).toBe(1);
    expect(countNodesOfType(reloadedView.state.doc, 'figure')).toBe(0);

    const img = reloadedView.dom.querySelector('img');
    expect(img?.getAttribute('src')).toBe('projectmedia://test.png');
    expect(img?.getAttribute('data-src')).toBe('media/test.png');
  });

  it('5. drag-and-drop regression guard: a real file-drop mid-text inside a list item still renders rewritten', async () => {
    // Drives the ACTUAL imagePasteDropPlugin.handleDrop code path (established
    // pattern from repro-image-drop.test.ts), not a hand-rolled insert. As
    // documented at the top of this file, insertImage() (api-content.ts)
    // unconditionally constructs a `figure` node for a real image-file
    // drop — this can never reach the plain-`image` code path in production
    // (there is no code path that constructs a plain `image` node from a
    // dropped image FILE). This case instead guards that the drag-and-drop
    // mechanism, after the rewriteMediaUrl extraction in image-plugin.ts,
    // still renders correctly via FigureNodeView's own (separately
    // unit-tested, unmodified) rewrite — a regression guard on the shared
    // extraction, alongside case 6's paste-driven guard.
    const THREE_ITEM_LIST_MD = [
      'Before paragraph.',
      '',
      '- Item 1',
      '- Item 2',
      '- Item 3',
      '',
      'After paragraph.',
    ].join('\n');
    const editor = await makeEditor(THREE_ITEM_LIST_MD);
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    const item2Pos = findTextPos(view.state.doc, 'Item 2');
    view.posAtCoords = () => ({ pos: item2Pos, inside: -1 });

    const handled = view.someProp('handleDrop', (f) => f(view, fakeDropEvent(), undefined as any));
    expect(handled).toBe(true);

    insertImage({ src: 'media/dropped.png', alt: '', caption: '', width: null, blockId: 'temp-test-block' });

    expect(countNodesOfType(view.state.doc, 'figure')).toBe(1);
    const img = view.dom.querySelector('figure img');
    expect(img?.getAttribute('src')).toBe('projectmedia://dropped.png');

    flushPendingBlockChanges();
    expect(getBlockChanges().deletes).toEqual([]);
  });

  it('6. figure regression guard: a standalone-line image still promotes to figure and still renders via FigureNodeView', async () => {
    // Protects against a mistake in the rewriteMediaUrl extraction (file #1
    // of the plan) accidentally changing FigureNodeView's own behavior.
    const editor = await makeEditor('![a caption](media/standalone.png)');
    const view = editor.ctx.get(editorViewCtx);

    expect(countNodesOfType(view.state.doc, 'figure')).toBe(1);
    expect(countNodesOfType(view.state.doc, 'image')).toBe(0);

    // FigureNodeView (a custom NodeView) renders the live DOM directly and
    // takes precedence over figureNode's own toDOM spec — so `data-src` is
    // NOT present here (that attribute only exists in the unused toDOM
    // spec's output, e.g. for clipboard copy serialization). The canonical
    // value instead lives in the ProseMirror node's own attrs.src, checked
    // directly.
    const img = view.dom.querySelector('figure img');
    expect(img?.getAttribute('src')).toBe('projectmedia://standalone.png');
    let figureSrc = '';
    view.state.doc.descendants((node: any) => {
      if (node.type.name === 'figure') figureSrc = node.attrs.src;
      return true;
    });
    expect(figureSrc).toBe('media/standalone.png');
  });

  it('7. parseDOM readback safety: data-src wins over the rewritten src for our own rendered nodes', async () => {
    // Focused unit test of the new schema's parseDOM, not a full editor —
    // proves the DOM-readback mitigation (Design section of the plan): if
    // ProseMirror's readDOMChange ever reconciles a mutated region via this
    // parseDOM, the canonical media/... value must win, not the rewritten
    // display value.
    const editor = await makeEditor('plain paragraph, no image');
    const schema = editor.ctx.get(editorViewCtx).state.schema;
    const imageType = schema.nodes.image;
    expect(imageType).toBeTruthy();
    const parseDOMRules = imageType!.spec.parseDOM as Array<{ getAttrs: (dom: HTMLElement) => any }>;
    expect(parseDOMRules?.length).toBeGreaterThan(0);

    const el = document.createElement('img');
    el.setAttribute('src', 'projectmedia://x.png');
    el.setAttribute('data-src', 'media/x.png');
    el.setAttribute('alt', 'a');

    const attrs = parseDOMRules[0].getAttrs(el);
    expect(attrs.src).toBe('media/x.png');
    expect(attrs.alt).toBe('a');
  });

  it('7b. parseDOM readback safety: falls back to src for genuinely external HTML with no data-src', async () => {
    const editor = await makeEditor('plain paragraph, no image');
    const schema = editor.ctx.get(editorViewCtx).state.schema;
    const imageType = schema.nodes.image;
    const parseDOMRules = imageType!.spec.parseDOM as Array<{ getAttrs: (dom: HTMLElement) => any }>;

    const el = document.createElement('img');
    el.setAttribute('src', 'https://example.com/photo.jpg');
    el.setAttribute('alt', 'external');

    const attrs = parseDOMRules[0].getAttrs(el);
    expect(attrs.src).toBe('https://example.com/photo.jpg');
  });
});

// Sanity: rewriteMediaUrl itself is a no-op passthrough for anything not
// media/-prefixed, so the pre-existing WebKit "ghost image" blob:/data:
// handling (and its own tests) is provably unaffected by this plugin.
describe('image-node-rewrite-plugin: passthrough for non-media/ src', () => {
  afterEach(() => {
    setEditorInstance(null);
    resetBlockSyncState();
    resetBlockIdState();
  });

  it('an already-rewritten projectmedia:// src round-trips through toDOM unchanged', async () => {
    const editor = await makeEditor('Before ![a](media/test.png) after.');
    const view = editor.ctx.get(editorViewCtx);
    const img = view.dom.querySelector('img');
    expect(img?.getAttribute('src')).toBe('projectmedia://test.png');
  });
});
