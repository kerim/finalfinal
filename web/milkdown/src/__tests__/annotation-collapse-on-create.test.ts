// @vitest-environment jsdom
//
// Regression tests: a freshly-created annotation must render collapsed
// immediately when the current display mode for its type is 'collapsed' —
// it should not require a subsequent toggle to "kick" the redraw.
//
// annotation-display-plugin.ts computes decorations statelessly from the
// live doc + the live displayModes module state on every redraw
// (props.decorations(state), not plugin `state`/`apply`), so any dispatch —
// including the transaction that inserts the new node — should already
// pick up the current mode. These tests pin that down using the two real
// annotation-creation entry points in this codebase: the window.FinalFinal
// insertAnnotation() API (api-annotations.ts, used by the toolbar/keyboard
// shortcuts) and the slash-command's combined delete+insert+setSelection
// transaction (slash-commands.ts's /comment /task /reference handling).
//
// Uses a real Milkdown Editor (commonmark + gfm + annotationPlugin +
// annotationDisplayPlugin) — mirrors annotation-collapsed-click.test.ts's
// approach so the real NodeView + decoration pipeline is exercised, not a
// hand-built minimal Schema.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { Selection } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it } from 'vitest';
import { annotationDisplayPlugin } from '../annotation-display-plugin';
import { annotationNode, annotationPlugin } from '../annotation-plugin';
import { insertAnnotation, setAnnotationDisplayModes } from '../api-annotations';
import { setEditorInstance } from '../editor-state';

describe('freshly-created annotation respects the current collapse mode', () => {
  let editor: Editor | null = null;

  afterEach(async () => {
    // Reset module-level display-mode state so it doesn't leak into other
    // tests in this file (or, in watch mode, other files sharing the worker).
    setAnnotationDisplayModes({ task: 'inline', comment: 'inline', reference: 'inline' });
    setEditorInstance(null);
    if (editor) {
      await editor.destroy();
      editor = null;
    }
  });

  async function makeEditor(markdown: string): Promise<EditorView> {
    const div = document.createElement('div');
    document.body.appendChild(div);
    const e = await Editor.make()
      .config((ctx) => {
        ctx.set(rootCtx, div);
        ctx.set(defaultValueCtx, markdown);
      })
      // annotationPlugin before commonmark/gfm mirrors main.ts's real ordering.
      // annotationDisplayPlugin supplies the collapse-mode decorations under test.
      .use(annotationPlugin)
      .use(commonmark)
      .use(gfm)
      .use(annotationDisplayPlugin)
      .create();
    editor = e;
    return e.ctx.get(editorViewCtx);
  }

  it('gets the ff-annotation-collapsed class immediately via the real insertAnnotation() API, with no prior toggle', async () => {
    const view = await makeEditor('Hello world');
    setEditorInstance(editor);

    // The preference is ALREADY 'collapsed' before the annotation is created —
    // this is not a toggle event, just the current standing mode.
    setAnnotationDisplayModes({ comment: 'collapsed' });

    // Place the cursor inside the paragraph, mirroring real cursor placement.
    view.dispatch(view.state.tr.setSelection(Selection.near(view.state.doc.resolve(3))));

    insertAnnotation('comment');

    const el = view.dom.querySelector('.ff-annotation') as HTMLElement | null;
    expect(el).not.toBeNull();
    expect(el!.className).toContain('ff-annotation-collapsed');
  });

  it('gets the ff-annotation-collapsed class immediately via the slash-command insertion pattern, with no prior toggle', async () => {
    const view = await makeEditor('Hello /comment world');
    setAnnotationDisplayModes({ comment: 'collapsed' });

    const cmdStart = 7; // start of "/comment" in "Hello /comment world"
    const cmdEnd = 15; // end of "/comment"
    const nodeType = annotationNode.type(editor!.ctx);
    const node = nodeType.create({ type: 'comment', isCompleted: false, text: '' });

    // Mirrors slash-commands.ts's executeSlashCommand: delete the slash text,
    // insert the annotation node, move the selection past it — all in one transaction.
    let tr = view.state.tr.delete(cmdStart, cmdEnd);
    tr = tr.insert(cmdStart, node);
    tr = tr.setSelection(Selection.near(tr.doc.resolve(cmdStart + node.nodeSize)));
    view.dispatch(tr);

    const el = view.dom.querySelector('.ff-annotation') as HTMLElement | null;
    expect(el).not.toBeNull();
    expect(el!.className).toContain('ff-annotation-collapsed');
  });

  it('does NOT collapse a freshly-created annotation of a type still in inline mode', async () => {
    const view = await makeEditor('Hello world');
    setEditorInstance(editor);

    // comment is collapsed, but task is untouched (defaults to inline) —
    // the fresh node should follow ITS OWN type's mode, not a global flag.
    setAnnotationDisplayModes({ comment: 'collapsed' });
    view.dispatch(view.state.tr.setSelection(Selection.near(view.state.doc.resolve(3))));

    insertAnnotation('task');

    const el = view.dom.querySelector('.ff-annotation') as HTMLElement | null;
    expect(el).not.toBeNull();
    expect(el!.className).not.toContain('ff-annotation-collapsed');
  });
});
