// @vitest-environment jsdom
// The slash menu must survive ProseMirror rebuilding the editor's plugin views.
//
// ProseMirror destroys every plugin view and re-runs every plugin's `spec.view(...)` whenever
// `view.updateState(state)` is handed a state whose `plugins` array differs from the previous
// one (`EditorView.updatePluginViews`). This app does exactly that on EVERY project switch /
// Open Recent (`resetForProjectSwitch` -> `clearEditorHistory`, which ends in
// `view.updateState(...)` with a freshly built history plugin) and on ordinary undo-stack
// eviction (`clearStructuralUndoState` -> `clearEditorHistory`).
//
// Before the fix, `slash-commands.ts` created its menu element, `SlashProvider` and document
// keydown listener ONCE (in `configureSlash`) but tore all three down in the plugin view's
// `destroy()`. The re-run `view()` factory rebuilt none of them, so after the first rebuild the
// "/" menu never opened again (and arrow/Enter/Cmd-Z handling was gone) until a fresh WebView.
//
// These tests use a REAL Milkdown editor with the real slash plugin and drive the same rebuild
// the app does (`clearEditorHistory`, `resetForProjectSwitch`) -- no mocks of the plugin.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { history as historyPlugin } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { undoDepth } from '@milkdown/kit/prose/history';
import { Selection } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { registerWebPopupOpenCheck } from '../../../shared/escape-ladder';
import { clearEditorHistory, resetForProjectSwitch } from '../api-content';
import { blockIdPlugin, resetBlockIdState } from '../block-id-plugin';
import { resetBlockSyncState, setSyncPaused } from '../block-sync-plugin';
import { setEditorInstance, setPendingSlashRedo, setPendingSlashUndo } from '../editor-state';
import { configureSlash, dismissSlashMenu, isSlashMenuOpen, slash } from '../slash-commands';

/** Longer than SlashProvider's 200 ms internal debounce, so the provider's update has fired. */
const PAST_SLASH_DEBOUNCE_MS = 300;
const settle = () => new Promise<void>((resolve) => setTimeout(resolve, PAST_SLASH_DEBOUNCE_MS));
/** `executeSlashCommand` re-enables the menu on the next animation frame. */
const nextFrame = () => new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));

describe('slash menu survives plugin-view rebuilds (real editor, real clearEditorHistory)', () => {
  let editor: Editor | null = null;
  let view: EditorView;
  /** Document-level keydown listeners registered in the CAPTURE phase and not yet removed. */
  let liveKeydownCapture: Set<EventListenerOrEventListenerObject>;
  let webPopupPosts: Array<{ open: boolean }>;

  beforeAll(() => {
    // jsdom has no layout. SlashProvider positions the menu via ProseMirror's `coordsAtPos`,
    // which asks a DOM Range for its client rects; jsdom does not implement those. The provider
    // swallows the resulting rejection with `console.error` (position is irrelevant here), so
    // give Range inert rects to keep the output clean.
    const emptyRect = { x: 0, y: 0, top: 0, left: 0, right: 0, bottom: 0, width: 0, height: 0, toJSON: () => ({}) };
    const proto = Range.prototype as unknown as Record<string, unknown>;
    proto.getBoundingClientRect ??= () => emptyRect;
    proto.getClientRects ??= () => [];
  });

  beforeEach(() => {
    liveKeydownCapture = new Set();
    const addListener = document.addEventListener.bind(document);
    const removeListener = document.removeEventListener.bind(document);
    const isCapture = (options: boolean | AddEventListenerOptions | EventListenerOptions | undefined) =>
      options === true || (typeof options === 'object' && !!options?.capture);
    vi.spyOn(document, 'addEventListener').mockImplementation((type, listener, options) => {
      if (type === 'keydown' && listener && isCapture(options)) liveKeydownCapture.add(listener);
      addListener(type, listener, options);
    });
    vi.spyOn(document, 'removeEventListener').mockImplementation((type, listener, options) => {
      if (type === 'keydown' && listener && isCapture(options)) liveKeydownCapture.delete(listener);
      removeListener(type, listener, options);
    });

    // What Swift is told about web popups: main.ts registers its aggregate check (which includes
    // isSlashMenuOpen) and the recompute pushes it over this message handler.
    webPopupPosts = [];
    (window as unknown as Record<string, unknown>).webkit = {
      messageHandlers: { escapeWebPopupOpen: { postMessage: (msg: { open: boolean }) => webPopupPosts.push(msg) } },
    };
    registerWebPopupOpenCheck(() => isSlashMenuOpen());
  });

  afterEach(async () => {
    await nextFrame(); // let any `suppressSlashMenu` reset land before the next test
    vi.restoreAllMocks();
    if (editor) {
      await editor.destroy();
      editor = null;
    }
    setEditorInstance(null);
    resetBlockIdState();
    resetBlockSyncState();
    setSyncPaused(false);
    setPendingSlashUndo(false);
    setPendingSlashRedo(false);
    delete (window as unknown as Record<string, unknown>).webkit;
    document.body.replaceChildren();
  });

  // Same plugin order as clear-history.test.ts / main.ts: blockIdPlugin first, history last,
  // slash configured through `.config(configureSlash)` and registered with `.use(slash)`.
  async function makeEditor(markdown: string): Promise<EditorView> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      .config(configureSlash)
      .use(blockIdPlugin)
      .use(commonmark)
      .use(gfm)
      .use(historyPlugin)
      .use(slash)
      .create();
    editor = e;
    setEditorInstance(e);
    view = e.ctx.get(editorViewCtx);
    return view;
  }

  const liveMenus = () => [...document.querySelectorAll<HTMLElement>('.slash-menu')];

  /** The user clicks into the paragraph and types "/", then the 200 ms debounce passes. */
  async function typeSlashInEmptyParagraph(): Promise<void> {
    // A project switch re-parents the editor DOM and drops focus; the user's click restores it.
    view.focus();
    expect(view.state.doc.childCount).toBe(1);
    expect(view.state.doc.child(0).type.name).toBe('paragraph');
    expect(view.state.doc.child(0).textContent).toBe('');
    view.dispatch(view.state.tr.insertText('/'));
    await settle();
  }

  function expectMenuOpenWithItems(): HTMLElement {
    const menus = liveMenus();
    expect(menus).toHaveLength(1);
    const menu = menus[0]!;
    expect(menu.isConnected).toBe(true);
    expect(menu.getAttribute('data-show')).toBe('true');
    expect(menu.querySelectorAll('.slash-menu-item').length).toBeGreaterThan(0);
    expect(isSlashMenuOpen()).toBe(true);
    return menu;
  }

  function pressKey(key: string): KeyboardEvent {
    const event = new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true });
    view.dom.dispatchEvent(event);
    return event;
  }

  const selectedIndex = (menu: HTMLElement) =>
    menu.querySelector<HTMLElement>('.slash-menu-item.selected')?.dataset.index ?? null;

  /** Menu opens, ArrowDown moves the selection, Enter runs the selected command. */
  async function expectMenuFullyWorks(): Promise<void> {
    await typeSlashInEmptyParagraph();
    const menu = expectMenuOpenWithItems();
    expect(selectedIndex(menu)).toBe('0');

    const down = pressKey('ArrowDown');
    expect(down.defaultPrevented).toBe(true);
    expect(selectedIndex(menu)).toBe('1');

    // Index 1 is "/h1": Enter must turn the paragraph into a level-1 heading and close the menu.
    const enter = pressKey('Enter');
    expect(enter.defaultPrevented).toBe(true);
    expect(view.state.doc.child(0).type.name).toBe('heading');
    expect(view.state.doc.child(0).attrs.level).toBe(1);
    expect(menu.getAttribute('data-show')).toBe('false');
    expect(isSlashMenuOpen()).toBe(false);
    await nextFrame();
  }

  /** Put the document back to one empty paragraph with the menu closed, as a new project has. */
  async function backToEmptyParagraph(): Promise<void> {
    const emptyParagraph = view.state.schema.nodes.paragraph!.create();
    view.dispatch(view.state.tr.replaceWith(0, view.state.doc.content.size, emptyParagraph));
    await settle();
  }

  it('(a) control: "/" in a fresh paragraph opens the menu, and ArrowDown/Enter drive it', async () => {
    await makeEditor('');
    await expectMenuFullyWorks();
  });

  it('(b) after clearEditorHistory (the rebuild every project switch performs) "/" opens the menu again and ArrowDown/Enter still work', async () => {
    await makeEditor('');
    await typeSlashInEmptyParagraph();
    expectMenuOpenWithItems();
    dismissSlashMenu(); // user cancels the first menu (this also deletes the typed "/")
    expect(isSlashMenuOpen()).toBe(false);

    // The same rebuild the app runs on a project switch: every plugin view is destroyed and
    // every plugin's view() factory re-run.
    clearEditorHistory(view);

    await expectMenuFullyWorks();
  });

  it('(b, user path) open project A, switch to project B via resetForProjectSwitch, type "/" -> the menu opens', async () => {
    await makeEditor('Project A content.');
    // Project A: the menu works before any switch.
    view.focus();
    view.dispatch(view.state.tr.setSelection(Selection.atEnd(view.state.doc)));
    view.dispatch(view.state.tr.insertText('/'));
    await settle();
    expectMenuOpenWithItems();

    // Open Recent -> project B. resetForProjectSwitch clears the document (to one empty
    // paragraph) and, through clearEditorHistory, rebuilds every plugin view.
    resetForProjectSwitch();
    await settle();
    expect(isSlashMenuOpen()).toBe(false);

    await expectMenuFullyWorks();
  });

  it('(c) several project switches in one session: the menu works after every one of them', async () => {
    await makeEditor('');
    await expectMenuFullyWorks();
    for (let switchNumber = 1; switchNumber <= 3; switchNumber++) {
      resetForProjectSwitch();
      await settle();
      await expectMenuFullyWorks();
    }
    // And back-to-back rebuilds with no typing in between (e.g. eviction right after a switch).
    clearEditorHistory(view);
    clearEditorHistory(view);
    await backToEmptyParagraph();
    await expectMenuFullyWorks();
  });

  it('(d) exactly one live menu element and one document keydown listener, before and after rebuilds, none after destroy', async () => {
    await makeEditor('');
    expect(liveMenus()).toHaveLength(1);
    expect(liveKeydownCapture.size).toBe(1);

    for (let rebuild = 1; rebuild <= 3; rebuild++) {
      clearEditorHistory(view);
      // Soft assertions so one run reports the menu element AND the listener separately.
      expect.soft(liveMenus(), `live .slash-menu elements after rebuild ${rebuild}`).toHaveLength(1);
      expect.soft(liveMenus()[0]?.isConnected, `menu connected after rebuild ${rebuild}`).toBe(true);
      expect.soft(liveKeydownCapture.size, `document keydown capture listeners after rebuild ${rebuild}`).toBe(1);
    }

    await editor!.destroy();
    editor = null;
    expect(liveMenus()).toHaveLength(0);
    expect(liveKeydownCapture.size).toBe(0);
  });

  it('a rebuild while the menu is open closes it: no stale open state, and Swift is told the popup closed', async () => {
    await makeEditor('');
    await typeSlashInEmptyParagraph();
    expectMenuOpenWithItems();
    webPopupPosts.length = 0;

    clearEditorHistory(view);

    expect(isSlashMenuOpen()).toBe(false);
    expect(liveMenus()).toHaveLength(1);
    expect(liveMenus()[0]!.getAttribute('data-show')).toBe('false');
    // A stale open menu must not swallow arrow keys meant for the editor.
    expect(pressKey('ArrowDown').defaultPrevented).toBe(false);
    // Swift's "is a web popup open" flag must not stay stuck on `true`.
    expect(webPopupPosts.length).toBeGreaterThan(0);
    expect(webPopupPosts[webPopupPosts.length - 1]).toEqual({ open: false });
  });

  it('the same document-level handler (smart undo, unified-undo routing) is still live after a rebuild', async () => {
    await makeEditor('Hello');
    clearEditorHistory(view);
    expect(undoDepth(view.state)).toBe(0);

    // Armed exactly as executeSlashCommand arms it after a slash command ran.
    setPendingSlashUndo(true);
    const cmdZ = new KeyboardEvent('keydown', { key: 'z', metaKey: true, bubbles: true, cancelable: true });
    view.dom.dispatchEvent(cmdZ);

    // handleSlashKeydown's smart-undo branch consumes the keystroke; with no listener it falls
    // through to the browser/editor untouched.
    expect(cmdZ.defaultPrevented).toBe(true);
  });
});
