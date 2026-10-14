// @vitest-environment jsdom
//
// t-94369a83 Phase 3a-2, Step 1 (plan-v2 U-W1): a block UPDATE carries the editor's block type.
//
// Before this step an update held only id, textContent, markdownFragment and headingLevel. A paragraph the user
// turned into a list (or the reverse) kept its block id, so Swift patched the row's text but never its type: the row
// stayed a paragraph holding a list's text, and a reopen showed the list twice. detectChanges now puts
// `newBlock.blockType` on every update it queues, and a type difference alone is enough to queue one (review finding
// D16: if two types ever serialized alike, the change would otherwise be dropped silently).
import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { Node, Schema } from '@milkdown/kit/prose/model';
import { afterEach, describe, expect, it } from 'vitest';
import { blockIdPlugin, resetBlockIdState, setBlockIdsForTopLevel } from '../block-id-plugin';
import {
  type BlockSnapshot,
  blockSyncPlugin,
  detectChanges,
  flushPendingBlockChanges,
  getBlockChanges,
  resetAndSnapshot,
  resetBlockSyncState,
  snapshotBlocks,
} from '../block-sync-plugin';
import { setEditorInstance } from '../editor-state';
import { highlightPlugin } from '../highlight-plugin';

async function makeEditor(markdown: string): Promise<Editor> {
  const div = document.createElement('div');
  document.body.appendChild(div);
  return await Editor.make()
    .config((ctx) => {
      ctx.set(rootCtx, div);
      ctx.set(defaultValueCtx, markdown);
    })
    .use(blockIdPlugin)
    .use(blockSyncPlugin)
    .use(commonmark)
    .use(gfm)
    .use(highlightPlugin)
    .create();
}

describe('detectChanges — an update carries blockType', () => {
  afterEach(() => {
    setEditorInstance(null);
    resetBlockIdState();
    resetBlockSyncState();
  });

  it('a paragraph replaced by a bullet_list that keeps its id queues an update with blockType bullet_list', async () => {
    const editor = await makeEditor('convert me.');
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    resetBlockIdState();
    setBlockIdsForTopLevel(['id-para'], view.state.doc);
    resetAndSnapshot(view.state.doc);

    const { schema } = view.state;
    const list = schema.nodes.bullet_list!.create(
      null,
      schema.nodes.list_item!.create(null, schema.nodes.paragraph!.create(null, schema.text('convert me.')))
    );
    view.dispatch(view.state.tr.replaceWith(0, view.state.doc.content.size, list));
    flushPendingBlockChanges();
    const changes = getBlockChanges();

    expect(changes.inserts.length).toBe(0); // converted in place: no duplicate row
    const update = changes.updates.find((u) => u.id === 'id-para');
    expect(update).toBeDefined();
    expect(update?.blockType).toBe('bullet_list');
    expect(update?.markdownFragment).toMatch(/^[-*+]\s+convert me\.$/);
  });

  it('an ordinary text edit to a paragraph reports blockType paragraph, so every update states its type', async () => {
    const editor = await makeEditor('convert me.');
    setEditorInstance(editor);
    const view = editor.ctx.get(editorViewCtx);

    resetBlockIdState();
    setBlockIdsForTopLevel(['id-para'], view.state.doc);
    resetAndSnapshot(view.state.doc);

    view.dispatch(view.state.tr.insertText('more ', 1));
    flushPendingBlockChanges();
    const changes = getBlockChanges();

    const update = changes.updates.find((u) => u.id === 'id-para');
    expect(update).toBeDefined();
    expect(update?.textContent).toBe('more convert me.');
    expect(update?.blockType).toBe('paragraph');
  });

  // D16: text, node size, heading level and Markdown fragment are all identical; ONLY the type differs.
  it('a change of type alone, with identical text, size and fragment, still queues an update', async () => {
    const editor = await makeEditor('x');
    setEditorInstance(editor);
    const { schema } = editor.ctx.get(editorViewCtx).state;

    // Two distinct but identical nodes: the same-node fast path in detectChanges must not apply.
    const makeSnapshot = (blockType: string): BlockSnapshot => {
      const node = schema.nodes.paragraph!.create(null, schema.text('same text'));
      return {
        id: 'id-same',
        pos: 0,
        blockType,
        textContent: node.textContent,
        nodeSize: node.nodeSize,
        node,
        _cachedMarkdown: null,
      };
    };
    const state = {
      lastSnapshot: new Map<string, BlockSnapshot>(),
      pendingUpdates: new Map(),
      pendingInserts: new Map(),
      pendingDeletes: new Set<string>(),
    };

    detectChanges(
      new Map([['id-same', makeSnapshot('paragraph')]]),
      new Map([['id-same', makeSnapshot('bullet_list')]]),
      state
    );

    expect(state.pendingUpdates.size).toBe(1);
    expect(state.pendingUpdates.get('id-same')?.blockType).toBe('bullet_list');
  });
});

// Code review X9/X17e: the strings the plugin queues as `blockType` must be the Swift `BlockType` raw values
// (Models/Block.swift). Swift ignores an unknown string (it only logs it), so a mismatched name would silently
// leave every conversion of that kind a paragraph holding a list's text, as before Step 1. The expected strings
// below are written out here on purpose, not derived from the plugin, so renaming one in the plugin (or in a
// Milkdown upgrade of its node names) turns exactly one row of this table red.
describe('detectChanges — the queued blockType is the Swift BlockType raw value', () => {
  afterEach(() => {
    setEditorInstance(null);
    resetBlockIdState();
    resetBlockSyncState();
  });

  const textParagraph = (schema: Schema, text: string): Node => schema.nodes.paragraph!.create(null, schema.text(text));
  const listOf = (schema: Schema, listType: string): Node =>
    schema.nodes[listType]!.create(null, schema.nodes.list_item!.create(null, textParagraph(schema, 'item')));

  // [Swift BlockType.rawValue, the editor node that must produce it]
  const cases: Array<[string, (schema: Schema) => Node]> = [
    ['paragraph', (schema) => textParagraph(schema, 'changed text')],
    ['bullet_list', (schema) => listOf(schema, 'bullet_list')],
    ['ordered_list', (schema) => listOf(schema, 'ordered_list')],
    ['blockquote', (schema) => schema.nodes.blockquote!.create(null, textParagraph(schema, 'quoted'))],
    ['code_block', (schema) => schema.nodes.code_block!.create(null, schema.text('code'))],
    ['table', (schema) => schema.nodes.table!.createAndFill()!],
  ];

  // Snapshot a one-block document, snapshot the same block id holding a different node, and let detectChanges
  // queue the update, exactly as the editor's own diff does.
  function queuedUpdate(schema: Schema, before: Node, after: Node) {
    const snapshotOf = (node: Node) => {
      const doc = schema.nodes.doc!.create(null, node);
      resetBlockIdState();
      setBlockIdsForTopLevel(['id-table'], doc);
      return snapshotBlocks(doc);
    };
    const oldSnapshot = snapshotOf(before);
    const newSnapshot = snapshotOf(after);
    const state = {
      lastSnapshot: new Map<string, BlockSnapshot>(),
      pendingUpdates: new Map(),
      pendingInserts: new Map(),
      pendingDeletes: new Set<string>(),
    };
    detectChanges(oldSnapshot, newSnapshot, state);
    return state.pendingUpdates.get('id-table');
  }

  it.each(
    cases
  )('a paragraph that becomes %s queues an update whose blockType is exactly that string', async (rawValue, build) => {
    const editor = await makeEditor('x');
    setEditorInstance(editor);
    const { schema } = editor.ctx.get(editorViewCtx).state;

    const update = queuedUpdate(schema, textParagraph(schema, 'convert me.'), build(schema));

    expect(update).toBeDefined();
    expect(update?.blockType).toBe(rawValue);
  });

  it('a bullet list turned back into a paragraph queues blockType paragraph', async () => {
    const editor = await makeEditor('x');
    setEditorInstance(editor);
    const { schema } = editor.ctx.get(editorViewCtx).state;

    const update = queuedUpdate(schema, listOf(schema, 'bullet_list'), textParagraph(schema, 'item'));

    expect(update).toBeDefined();
    expect(update?.blockType).toBe('paragraph');
  });
});
