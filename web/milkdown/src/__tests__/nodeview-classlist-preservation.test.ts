// @vitest-environment jsdom
//
// Regression tests locking in the citation-plugin.ts / footnote-plugin.ts NodeView fix:
// their `update()` callbacks used to overwrite `dom.className` wholesale on every redraw,
// which would silently wipe out any class applied to the DOM element from OUTSIDE the
// NodeView. Both were changed to targeted `classList.add`/`classList.remove` calls that
// only touch the classes the plugin itself owns (the same fix already applied to
// annotation-plugin.ts), so an externally-applied class now survives a redraw.
//
// The "outside class" used here is not a stand-in for a hypothetical decoration:
// `ProseMirror-selectednode` is the real class ProseMirror's own default node-selection
// behavior applies to a selected atom's DOM element from outside the NodeView. Applying it
// by hand (`dom.classList.add(...)`) and then triggering a real `update()` call (via a
// ProseMirror transaction that changes the node) is the same shape of bug a real decoration
// would trigger, without needing to construct one.
//
// Reverting either plugin's NodeView back to `dom.className = [...]` makes every test below
// fail: the outside class would be gone after `update()` runs.
//
// Each NodeView's update() callback has TWO branches that used to do `dom.className = [...]`
// wholesale: the WYSIWYG branch and the `isSourceModeEnabled()` source-mode branch (source
// mode shows raw markdown syntax instead of the formatted/pill display). The WYSIWYG-branch
// tests above create the editor in the default (non-source) mode, so they only exercise
// that branch; the source-mode-branch tests below call `setSourceModeEnabled(true)` BEFORE
// creating the editor, so the NodeView is both created and updated while source mode is on
// (each NodeView's `update()` force-recreates the DOM element via `return false` when
// `isSourceModeEnabled()` differs from the mode the NodeView was created in — staying in
// source mode across the update is what keeps this a same-element `update()` call rather
// than a recreation). Reverting only the source-mode branch's line(s) back to wholesale
// `dom.className = [...]` leaves the WYSIWYG-branch tests above green and only fails the
// source-mode-branch tests below.
//
// Uses real Milkdown Editors (commonmark + gfm + citationPlugin / footnotePlugin) so the
// real NodeView + ProseMirror `update()` pipeline is exercised — mirrors
// annotation-collapse-on-create.test.ts's approach for annotation-plugin.ts's matching fix.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import type { MilkdownPlugin } from '@milkdown/kit/ctx';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { Node } from '@milkdown/kit/prose/model';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it } from 'vitest';
import { citationPlugin } from '../citation-plugin';
import { getCiteprocEngine, resetCiteprocEngine } from '../citeproc-engine';
import { footnotePlugin } from '../footnote-plugin';
import { setSourceModeEnabled } from '../source-mode-plugin';

// ProseMirror's own built-in class for a selected atom's DOM element, applied from
// outside the NodeView (prosemirror-view's NodeViewDesc.selectNode()). A genuine
// "outside class", not a made-up one.
const OUTSIDE_CLASS = 'ProseMirror-selectednode';

describe('NodeView update() preserves outside-applied classes (citation, footnote_def, footnote_ref)', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    if (editor) {
      await editor.destroy();
      editor = null;
    }
    resetCiteprocEngine();
    // Source mode is module-level state in source-mode-plugin.ts (not tied to the editor
    // instance) -- reset it after every test so it never leaks into a later test in this
    // file (or another file sharing the module registry).
    setSourceModeEnabled(false);
  });

  async function makeEditor(markdown: string, plugin: MilkdownPlugin | MilkdownPlugin[]): Promise<EditorView> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      // Plugin registered before commonmark/gfm, mirroring main.ts's real ordering
      // (citation-delete.test.ts's comment: "MUST be registered before commonmark/gfm").
      .use(plugin)
      .use(commonmark)
      .use(gfm)
      .create();
    editor = e;
    return e.ctx.get(editorViewCtx);
  }

  it('citation NodeView: outside class survives update(), and ff-citation-resolved/unresolved swap cleanly', async () => {
    // Registered BEFORE the node is created, but under a DIFFERENT key than the node
    // cites -- the node itself starts out unresolved. The update() below is what makes
    // it resolved, not this bibliography registration.
    getCiteprocEngine().setBibliography([
      {
        id: 'resolvedkey',
        type: 'book',
        title: 'A Test Book',
        author: [{ family: 'Smith', given: 'Jane' }],
        issued: { 'date-parts': [[2020]] },
      },
    ]);

    const view = await makeEditor('[@unresolvedkey]', citationPlugin);

    const dom = view.dom.querySelector('.ff-citation') as HTMLElement | null;
    expect(dom).not.toBeNull();
    // Starting state: unresolved (citekey not in the bibliography).
    expect(dom!.classList.contains('ff-citation-unresolved')).toBe(true);
    expect(dom!.classList.contains('ff-citation-resolved')).toBe(false);

    // Simulate the outside class being applied to this exact DOM element, as
    // ProseMirror's own node-selection would.
    dom!.classList.add(OUTSIDE_CLASS);

    let citationPos = -1;
    view.state.doc.descendants((node: Node, pos: number) => {
      if (citationPos !== -1) return false;
      if (node.type.name === 'citation') {
        citationPos = pos;
        return false;
      }
    });
    expect(citationPos).not.toBe(-1);
    const citationNode = view.state.doc.nodeAt(citationPos);
    expect(citationNode).not.toBeNull();

    // A real node change (citekeys swapped to the resolved key), routed through the
    // NodeView's own `update()` callback.
    view.dispatch(
      view.state.tr.setNodeMarkup(citationPos, undefined, {
        ...citationNode!.attrs,
        citekeys: 'resolvedkey',
        rawSyntax: '[@resolvedkey]',
      })
    );

    // Same DOM element -- this went through update(), not a NodeView recreation.
    expect(view.dom.querySelector('.ff-citation')).toBe(dom);
    expect(dom!.classList.contains(OUTSIDE_CLASS)).toBe(true);
    // The plugin's own classes reflect the new, resolved state -- swapped cleanly.
    expect(dom!.classList.contains('ff-citation-resolved')).toBe(true);
    expect(dom!.classList.contains('ff-citation-unresolved')).toBe(false);
    expect(dom!.classList.contains('ff-citation')).toBe(true);
  });

  it('footnote_def NodeView: outside class survives update() across a label change', async () => {
    const view = await makeEditor('# Notes\n\n[^1]: first def', footnotePlugin);

    const dom = view.dom.querySelector('.ff-footnote-def') as HTMLElement | null;
    expect(dom).not.toBeNull();
    expect(dom!.textContent).toBe('1');

    dom!.classList.add(OUTSIDE_CLASS);

    let defPos = -1;
    view.state.doc.descendants((node: Node, pos: number) => {
      if (defPos !== -1) return false;
      if (node.type.name === 'footnote_def') {
        defPos = pos;
        return false;
      }
    });
    expect(defPos).not.toBe(-1);

    view.dispatch(view.state.tr.setNodeMarkup(defPos, undefined, { label: '2' }));

    // Same DOM element -- update(), not a recreation.
    expect(view.dom.querySelector('.ff-footnote-def')).toBe(dom);
    expect(dom!.classList.contains(OUTSIDE_CLASS)).toBe(true);
    // Plugin's own state for the new label: WYSIWYG text and dataset updated, base
    // class kept, and no source-mode class leaked in (editor is not in source mode).
    expect(dom!.textContent).toBe('2');
    expect(dom!.dataset.label).toBe('2');
    expect(dom!.classList.contains('ff-footnote-def')).toBe(true);
    expect(dom!.classList.contains('source-mode-footnote-def')).toBe(false);
  });

  it('footnote_ref NodeView: outside class survives update() across a label change', async () => {
    const view = await makeEditor('Body text[^1] tail.\n\n[^1]: the note', footnotePlugin);

    const dom = view.dom.querySelector('.ff-footnote-ref') as HTMLElement | null;
    expect(dom).not.toBeNull();
    expect(dom!.textContent).toBe('1');

    dom!.classList.add(OUTSIDE_CLASS);

    let refPos = -1;
    view.state.doc.descendants((node: Node, pos: number) => {
      if (refPos !== -1) return false;
      if (node.type.name === 'footnote_ref') {
        refPos = pos;
        return false;
      }
    });
    expect(refPos).not.toBe(-1);

    view.dispatch(view.state.tr.setNodeMarkup(refPos, undefined, { label: '2' }));

    // Same DOM element -- update(), not a recreation.
    expect(view.dom.querySelector('.ff-footnote-ref')).toBe(dom);
    expect(dom!.classList.contains(OUTSIDE_CLASS)).toBe(true);
    // Plugin's own state for the new label: superscript text updated, base class kept,
    // and no source-mode class leaked in (editor is not in source mode).
    expect(dom!.textContent).toBe('2');
    expect(dom!.classList.contains('ff-footnote-ref')).toBe(true);
    expect(dom!.classList.contains('source-mode-footnote')).toBe(false);
  });

  it('citation NodeView, source mode: outside class survives update(), source-mode-citation stays, and ff-citation-resolved/unresolved stay absent', async () => {
    // Enabled BEFORE the editor (and therefore the NodeView) is created, so the NodeView's
    // `createdInSourceMode` is true and the update() below does NOT force a DOM recreation
    // (it only recreates when isSourceModeEnabled() !== createdInSourceMode). That keeps the
    // update on the same DOM element and exercises the source-mode branch's classList calls.
    setSourceModeEnabled(true);

    const view = await makeEditor('[@somekey]', citationPlugin);

    const dom = view.dom.querySelector('.ff-citation') as HTMLElement | null;
    expect(dom).not.toBeNull();
    // Created while source mode is already on: the source-mode branch ran on the initial
    // render, so its classes are already in place and the WYSIWYG-only resolved/unresolved
    // classes were never added.
    expect(dom!.classList.contains('source-mode-citation')).toBe(true);
    expect(dom!.classList.contains('ff-citation-resolved')).toBe(false);
    expect(dom!.classList.contains('ff-citation-unresolved')).toBe(false);

    dom!.classList.add(OUTSIDE_CLASS);

    let citationPos = -1;
    view.state.doc.descendants((node: Node, pos: number) => {
      if (citationPos !== -1) return false;
      if (node.type.name === 'citation') {
        citationPos = pos;
        return false;
      }
    });
    expect(citationPos).not.toBe(-1);
    const citationNode = view.state.doc.nodeAt(citationPos);
    expect(citationNode).not.toBeNull();

    // A real node change, still in source mode -- routed through update(), not a recreation.
    view.dispatch(
      view.state.tr.setNodeMarkup(citationPos, undefined, {
        ...citationNode!.attrs,
        citekeys: 'anotherkey',
        rawSyntax: '[@anotherkey]',
      })
    );

    // Same DOM element -- this went through update(), not a NodeView recreation.
    expect(view.dom.querySelector('.ff-citation')).toBe(dom);
    expect(dom!.classList.contains(OUTSIDE_CLASS)).toBe(true);
    // The base class and the source-mode class both survive the redraw...
    expect(dom!.classList.contains('ff-citation')).toBe(true);
    expect(dom!.classList.contains('source-mode-citation')).toBe(true);
    // ...and the WYSIWYG-only resolved/unresolved classes are still absent, matching what
    // the source-mode branch actually does (it never adds them, only removes them).
    expect(dom!.classList.contains('ff-citation-resolved')).toBe(false);
    expect(dom!.classList.contains('ff-citation-unresolved')).toBe(false);
    expect(dom!.textContent).toBe('[@anotherkey]');
  });

  it('footnote_def NodeView, source mode: outside class survives update() across a label change', async () => {
    setSourceModeEnabled(true);

    const view = await makeEditor('# Notes\n\n[^1]: first def', footnotePlugin);

    const dom = view.dom.querySelector('.ff-footnote-def') as HTMLElement | null;
    expect(dom).not.toBeNull();
    expect(dom!.textContent).toBe('[^1]:');
    expect(dom!.classList.contains('source-mode-footnote-def')).toBe(true);

    dom!.classList.add(OUTSIDE_CLASS);

    let defPos = -1;
    view.state.doc.descendants((node: Node, pos: number) => {
      if (defPos !== -1) return false;
      if (node.type.name === 'footnote_def') {
        defPos = pos;
        return false;
      }
    });
    expect(defPos).not.toBe(-1);

    view.dispatch(view.state.tr.setNodeMarkup(defPos, undefined, { label: '2' }));

    // Same DOM element -- update(), not a recreation.
    expect(view.dom.querySelector('.ff-footnote-def')).toBe(dom);
    expect(dom!.classList.contains(OUTSIDE_CLASS)).toBe(true);
    // Plugin's own state for the new label, still in source mode: raw syntax text updated,
    // base class kept, and the source-mode class stays (it's this branch's own class).
    expect(dom!.textContent).toBe('[^2]:');
    expect(dom!.classList.contains('ff-footnote-def')).toBe(true);
    expect(dom!.classList.contains('source-mode-footnote-def')).toBe(true);
  });

  it('footnote_ref NodeView, source mode: outside class survives update() across a label change', async () => {
    setSourceModeEnabled(true);

    const view = await makeEditor('Body text[^1] tail.\n\n[^1]: the note', footnotePlugin);

    const dom = view.dom.querySelector('.ff-footnote-ref') as HTMLElement | null;
    expect(dom).not.toBeNull();
    expect(dom!.textContent).toBe('[^1]');
    expect(dom!.classList.contains('source-mode-footnote')).toBe(true);

    dom!.classList.add(OUTSIDE_CLASS);

    let refPos = -1;
    view.state.doc.descendants((node: Node, pos: number) => {
      if (refPos !== -1) return false;
      if (node.type.name === 'footnote_ref') {
        refPos = pos;
        return false;
      }
    });
    expect(refPos).not.toBe(-1);

    view.dispatch(view.state.tr.setNodeMarkup(refPos, undefined, { label: '2' }));

    // Same DOM element -- update(), not a recreation.
    expect(view.dom.querySelector('.ff-footnote-ref')).toBe(dom);
    expect(dom!.classList.contains(OUTSIDE_CLASS)).toBe(true);
    // Plugin's own state for the new label, still in source mode: raw syntax text updated,
    // base class kept, and the source-mode class stays (it's this branch's own class).
    expect(dom!.textContent).toBe('[^2]');
    expect(dom!.classList.contains('ff-footnote-ref')).toBe(true);
    expect(dom!.classList.contains('source-mode-footnote')).toBe(true);
  });
});
