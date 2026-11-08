// @vitest-environment jsdom
//
// Phase 4b part 2, slice 2a (t-94369a83): `deleteSectionEditorFirst` (api-section-delete.ts) -- the editor removes a section
// first, in one synchronous JavaScript turn, and hands Swift the batch of pending edits it consumed.
//
// Plan tests covered here: W1 (the range rule, after each of the three kinds of content push), W2 (no deletes queued after the
// removal), W3 (the MUST-FAIL test: an edit typed outside the section reaches the returned batch), W5 (`postOpDoc` and `midOp`),
// W10 (failure after the removal puts the section back), plus the `efRemovalPainted` measurement message (plan R4) and the same
// operation on article-sized and six-chapter-book-sized generated documents.
//
// The harness is the real thing: a real Milkdown editor with the block-id, block-sync and history plugins, `view.dispatch`
// wired through the production `runUndoTrackedDispatch` exactly as main.ts's override does, real timers and real animation
// frames. Typing is a real history-adding ProseMirror transaction.

import { defaultValueCtx, Editor, editorViewCtx, rootCtx } from '@milkdown/kit/core';
import { history as historyPlugin } from '@milkdown/kit/plugin/history';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import type { EditorView } from '@milkdown/kit/prose/view';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { applyBlocks, setContent, setContentWithBlockIds } from '../api-content';
import { deleteSectionEditorFirst, setTestAfterRemovalHook } from '../api-section-delete';
import { bibliographyEndMarkerPlugin } from '../bibliography-end-marker-plugin';
import { bibliographyPlugin } from '../bibliography-plugin';
import { blockIdPlugin, getAllBlockIds, resetBlockIdState, setBlockIdZoomMode } from '../block-id-plugin';
import { blockSyncPlugin, resetBlockSyncState, setSyncPaused } from '../block-sync-plugin';
import { setEditorInstance } from '../editor-state';
import { highlightPlugin } from '../highlight-plugin';
import { sectionBreakPlugin } from '../section-break-plugin';
import type { Block } from '../types';
import { setTraceTyping } from '../typing-trace';
import {
  getRegistry,
  handleUnifiedUndoKeydown,
  resetUndoCoordinatorState,
  runUndoTrackedDispatch,
  setUndoDescriptor,
} from '../undo-coordinator';
import { takePendingAsReport } from './pending-for-test';

// === Documents ===

interface Spec {
  name: string;
  md: string;
  /** Swift `BlockType.rawValue`, for `applyBlocks`. */
  blockType: string;
  headingLevel?: number;
  text: string;
}

const heading = (name: string, level: number, title: string): Spec => ({
  name,
  md: `${'#'.repeat(level)} ${title}`,
  blockType: 'heading',
  headingLevel: level,
  text: title,
});
const para = (name: string, text: string): Spec => ({ name, md: text, blockType: 'paragraph', text });
const rule = (name: string): Spec => ({ name, md: '---', blockType: 'horizontal_rule', text: '' });
const sectionBreak = (name: string): Spec => ({ name, md: '<!-- ::break:: -->', blockType: 'section_break', text: '' });

const markdownOf = (specs: Spec[]) => specs.map((s) => s.md).join('\n\n');

type PushKind = 'setContentWithBlockIds' | 'setContent' | 'applyBlocks';
const PUSH_KINDS: PushKind[] = ['setContentWithBlockIds', 'setContent', 'applyBlocks'];

const OP_ID = '11111111-2222-3333-4444-555555555555';

// === Harness ===

let current: Editor | null = null;

afterEach(async () => {
  setTestAfterRemovalHook(null);
  setTraceTyping(false);
  if (current) {
    await current.destroy();
    current = null;
  }
  setEditorInstance(null);
  resetBlockIdState();
  resetBlockSyncState();
  setBlockIdZoomMode(false);
  setSyncPaused(false);
  resetUndoCoordinatorState();
  delete (window as any).webkit;
});

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Waits `frames` animation frames and then one task: a content push unpauses block-sync from a frame callback. */
function waitForRAF(frames = 3): Promise<void> {
  return new Promise((resolve) => {
    let remaining = frames;
    const step = () => {
      remaining--;
      if (remaining <= 0) setTimeout(resolve, 0);
      else requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  });
}

async function makeEditor(
  extraPlugins: Array<Parameters<Editor['use']>[0]> = []
): Promise<{ editor: Editor; view: EditorView }> {
  const div = document.createElement('div');
  document.body.appendChild(div);
  // sectionBreakPlugin (and the bibliography markers) must be registered BEFORE commonmark/gfm: they turn HTML comments into
  // nodes before commonmark's own HTML handling sees them -- the order main.ts uses.
  let maker = Editor.make()
    .config((ctx) => {
      ctx.set(rootCtx, div);
      ctx.set(defaultValueCtx, '');
    })
    .use(sectionBreakPlugin);
  for (const plugin of extraPlugins) maker = maker.use(plugin);
  const editor = await maker
    .use(commonmark)
    .use(gfm)
    .use(highlightPlugin)
    .use(blockIdPlugin)
    .use(historyPlugin)
    .use(blockSyncPlugin)
    .create();
  current = editor;
  setEditorInstance(editor);
  const view = editor.ctx.get(editorViewCtx);
  // main.ts's `view.dispatch` override, through the same production function.
  const originalDispatch = view.dispatch.bind(view);
  view.dispatch = (tr) => runUndoTrackedDispatch(view, tr, originalDispatch);
  return { editor, view };
}

/** The block ids in document order, as the block-id plugin holds them (offset order). */
function idsInOrder(): string[] {
  return Array.from(getAllBlockIds().entries())
    .sort((a, b) => a[0] - b[0])
    .map(([, id]) => id);
}

/**
 * Loads `specs` with the given kind of content push and lets the push's deferred unpause run. Returns the block id of each spec by
 * name. `setContent()` carries no ids, so its blocks keep the temporary ids the block-id plugin gave them: ids are then taken from
 * the plugin in document order, which presumes one top-level block per spec.
 *
 * The push is never given the managed ids: the delete call is, and only the call's argument may decide what is managed.
 */
async function load(kind: PushKind, specs: Spec[]): Promise<Map<string, string>> {
  const markdown = markdownOf(specs);
  if (kind === 'setContentWithBlockIds') {
    setContentWithBlockIds(
      markdown,
      specs.map((s) => s.name)
    );
  } else if (kind === 'setContent') {
    setContent(markdown);
  } else {
    const blocks: Block[] = specs.map((s, i) => ({
      id: s.name,
      blockType: s.blockType,
      textContent: s.text,
      markdownFragment: s.md,
      headingLevel: s.headingLevel,
      sortOrder: i + 1,
    }));
    applyBlocks(blocks);
  }
  await waitForRAF();
  takePendingAsReport(); // whatever the push itself left pending is not what these tests are about
  const ids = idsInOrder();
  expect(ids.length, `${kind}: one block id per spec`).toBe(specs.length);
  return new Map(specs.map((s, i) => [s.name, ids[i]]));
}

/** Types `word` at the end of the paragraph whose text starts with `startsWith` -- a real, history-adding transaction. */
function typeIntoParagraph(view: EditorView, startsWith: string, word: string): void {
  let endPos = -1;
  view.state.doc.forEach((node, offset) => {
    if (endPos === -1 && node.type.name === 'paragraph' && node.textContent.startsWith(startsWith)) {
      endPos = offset + node.nodeSize - 1;
    }
  });
  expect(endPos, `paragraph starting with "${startsWith}" must exist`).toBeGreaterThan(-1);
  view.dispatch(view.state.tr.insertText(word, endPos));
}

// === W1: the range rule ===

interface RangeCase {
  label: string;
  specs: Spec[];
  managed: string[];
  root: string;
  /** Spec names the removal must take out, in order. */
  removed: string[];
  /** The leaders among them. */
  leaders: string[];
  predecessor: string | null;
}

const RANGE_CASES: RangeCase[] = [
  {
    label: 'a chapter followed by a section break (the break is a level-1 leader: the chapter stops before it)',
    specs: [
      heading('a', 1, 'Chapter A'),
      para('a-p1', 'Alpha one.'),
      heading('a-1', 2, 'A one'),
      para('a-1-p1', 'Alpha sub one.'),
      sectionBreak('brk'),
      heading('b', 1, 'Chapter B'),
      para('b-p1', 'Beta one.'),
    ],
    managed: [],
    root: 'a',
    removed: ['a', 'a-p1', 'a-1', 'a-1-p1'],
    leaders: ['a', 'a-1'],
    predecessor: null,
  },
  {
    label: 'a section-break root (it owns the deeper headings under it, up to the next level-1 leader)',
    specs: [
      heading('a', 1, 'Chapter A'),
      para('a-p1', 'Alpha one.'),
      sectionBreak('brk'),
      para('brk-p1', 'After the break.'),
      heading('brk-1', 2, 'Under the break'),
      para('brk-1-p1', 'Deeper text.'),
      heading('b', 1, 'Chapter B'),
      para('b-p1', 'Beta one.'),
    ],
    managed: [],
    root: 'brk',
    removed: ['brk', 'brk-p1', 'brk-1', 'brk-1-p1'],
    leaders: ['brk', 'brk-1'],
    predecessor: 'a-p1',
  },
  {
    label:
      'skipped levels (a level-1 root owns a level-3 and a level-4 heading; a level-3 root stops at a level-2 heading)',
    specs: [
      heading('a', 1, 'Chapter A'),
      para('a-p1', 'Alpha one.'),
      heading('a-3', 3, 'Skips level two'),
      para('a-3-p1', 'Deep one.'),
      heading('a-4', 4, 'Deeper still'),
      para('a-4-p1', 'Deeper one.'),
      heading('a-2', 2, 'Back to level two'),
      para('a-2-p1', 'Two one.'),
      heading('b', 1, 'Chapter B'),
      para('b-p1', 'Beta one.'),
    ],
    managed: [],
    root: 'a',
    removed: ['a', 'a-p1', 'a-3', 'a-3-p1', 'a-4', 'a-4-p1', 'a-2', 'a-2-p1'],
    leaders: ['a', 'a-3', 'a-4', 'a-2'],
    predecessor: null,
  },
  {
    label: 'skipped levels, level-3 root (stops at the next level-2 heading)',
    specs: [
      heading('a', 1, 'Chapter A'),
      para('a-p1', 'Alpha one.'),
      heading('a-3', 3, 'Skips level two'),
      para('a-3-p1', 'Deep one.'),
      heading('a-4', 4, 'Deeper still'),
      para('a-4-p1', 'Deeper one.'),
      heading('a-2', 2, 'Back to level two'),
      para('a-2-p1', 'Two one.'),
    ],
    managed: [],
    root: 'a-3',
    removed: ['a-3', 'a-3-p1', 'a-4', 'a-4-p1'],
    leaders: ['a-3', 'a-4'],
    predecessor: 'a-p1',
  },
  {
    label: 'a final chapter followed by a Notes heading one level below it (Notes is kept, whatever the level)',
    specs: [
      heading('a', 1, 'Chapter A'),
      para('a-p1', 'Alpha one.'),
      heading('z', 1, 'Final chapter'),
      para('z-p1', 'Last one.'),
      heading('z-1', 2, 'Last sub'),
      para('z-1-p1', 'Last sub one.'),
      heading('notes-h', 2, 'Notes'),
      para('notes-p1', 'First note.'),
      para('notes-p2', 'Second note.'),
    ],
    managed: ['notes-h', 'notes-p1', 'notes-p2'],
    root: 'z',
    removed: ['z', 'z-p1', 'z-1', 'z-1-p1'],
    leaders: ['z', 'z-1'],
    predecessor: 'a-p1',
  },
  {
    label: 'an hr inside a section (not a leader: it goes with the section)',
    specs: [
      heading('a', 1, 'Chapter A'),
      para('a-p1', 'Alpha one.'),
      rule('a-hr'),
      para('a-p2', 'Alpha two.'),
      heading('b', 1, 'Chapter B'),
      para('b-p1', 'Beta one.'),
    ],
    managed: [],
    root: 'a',
    removed: ['a', 'a-p1', 'a-hr', 'a-p2'],
    leaders: ['a'],
    predecessor: null,
  },
  {
    label: 'a middle section (the first heading at its own level ends it)',
    specs: [
      heading('a', 1, 'Chapter A'),
      para('a-p1', 'Alpha one.'),
      heading('b', 1, 'Chapter B'),
      para('b-p1', 'Beta one.'),
      heading('b-1', 2, 'B one'),
      para('b-1-p1', 'Beta sub one.'),
      heading('c', 1, 'Chapter C'),
      para('c-p1', 'Gamma one.'),
    ],
    managed: [],
    root: 'b',
    removed: ['b', 'b-p1', 'b-1', 'b-1-p1'],
    leaders: ['b', 'b-1'],
    predecessor: 'a-p1',
  },
];

describe('W1: deleteSectionEditorFirst takes out exactly the section the shared rule names', () => {
  for (const kind of PUSH_KINDS) {
    describe(`after ${kind}`, () => {
      for (const c of RANGE_CASES) {
        it(c.label, async () => {
          const { view } = await makeEditor();
          const idOf = await load(kind, c.specs);
          const survivors = c.specs.filter((s) => !c.removed.includes(s.name));
          const survivorIdsBefore = survivors.map((s) => idOf.get(s.name));

          const result = deleteSectionEditorFirst(
            OP_ID,
            idOf.get(c.root) as string,
            c.managed.map((n) => idOf.get(n) as string)
          );

          expect(result.ok, `reason: ${result.reason}`).toBe(true);
          expect(result.removedIds).toEqual(c.removed.map((n) => idOf.get(n)));
          expect(result.removedLeaderIds).toEqual(c.leaders.map((n) => idOf.get(n)));
          expect(result.removedSectionsSnapshot.map((s) => s.id)).toEqual(c.leaders.map((n) => idOf.get(n)));
          expect(result.predecessorId).toBe(c.predecessor === null ? null : idOf.get(c.predecessor));
          // The document keeps exactly the surviving blocks, in order, each with the id it had before.
          expect(idsInOrder()).toEqual(survivorIdsBefore);
          expect(view.state.doc.childCount).toBe(survivors.length);
          const survivingText = survivors.map((s) => s.text);
          const texts: string[] = [];
          view.state.doc.forEach((node) => {
            texts.push(node.textContent);
          });
          // hr and section_break have no text; every other survivor shows its own text.
          expect(texts).toEqual(survivingText);
        });
      }
    });
  }

  it('the first heading level and the section-break kind of each removed leader are reported', async () => {
    const { view } = await makeEditor();
    const specs = [
      heading('a', 1, 'Chapter A'),
      para('a-p1', 'Alpha one.'),
      heading('a-1', 3, 'Sub'),
      para('a-1-p1', 'Sub one.'),
      heading('b', 1, 'Chapter B'),
    ];
    const idOf = await load('setContentWithBlockIds', specs);
    const result = deleteSectionEditorFirst(OP_ID, idOf.get('a') as string, []);
    expect(result.ok).toBe(true);
    expect(result.removedSectionsSnapshot).toEqual([
      { id: idOf.get('a'), kind: 'heading', level: 1, title: 'Chapter A' },
      { id: idOf.get('a-1'), kind: 'heading', level: 3, title: 'Sub' },
    ]);
    expect(view.state.doc.childCount).toBe(1);

    const withBreak = [sectionBreak('brk'), para('brk-p1', 'Under the break.'), heading('b', 1, 'Chapter B')];
    const second = await load('setContentWithBlockIds', withBreak);
    const result2 = deleteSectionEditorFirst('22222222-2222-2222-2222-222222222222', second.get('brk') as string, []);
    expect(result2.removedSectionsSnapshot).toEqual([
      { id: second.get('brk'), kind: 'section_break', level: 1, title: '' },
    ]);
  });

  it('a Bibliography marker after the last chapter is kept with the Bibliography heading it opens (the marker has no block id)', async () => {
    const { view } = await makeEditor([bibliographyPlugin, bibliographyEndMarkerPlugin].flat());
    const specs = [
      heading('a', 1, 'Chapter A'),
      para('a-p1', 'Alpha one.'),
      heading('z', 1, 'Final chapter'),
      para('z-p1', 'Last one.'),
    ];
    const markdown = `${markdownOf(specs)}\n\n<!-- ::auto-bibliography:: -->\n\n# Bibliography\n\nSmith 2020.\n\n<!-- ::auto-bibliography-end:: -->`;
    const ids = ['a', 'a-p1', 'z', 'z-p1', 'bib-h', 'bib-p'];
    setContentWithBlockIds(markdown, ids);
    await waitForRAF();
    takePendingAsReport();
    const typesBefore: string[] = [];
    view.state.doc.forEach((node) => {
      typesBefore.push(node.type.name);
    });
    expect(typesBefore).toEqual([
      'heading',
      'paragraph',
      'heading',
      'paragraph',
      'auto_bibliography',
      'heading',
      'paragraph',
      'auto_bibliography_end',
    ]);

    const result = deleteSectionEditorFirst(OP_ID, 'z', ['bib-h', 'bib-p']);

    expect(result.ok, `reason: ${result.reason}`).toBe(true);
    expect(result.removedIds).toEqual(['z', 'z-p1']);
    const typesAfter: string[] = [];
    view.state.doc.forEach((node) => {
      typesAfter.push(node.type.name);
    });
    expect(typesAfter).toEqual([
      'heading',
      'paragraph',
      'auto_bibliography',
      'heading',
      'paragraph',
      'auto_bibliography_end',
    ]);
  });

  it('refuses, and still returns the consumed batch, when the root is not a block of the document, a leader, or is managed', async () => {
    const { view } = await makeEditor();
    const specs = [
      heading('a', 1, 'Chapter A'),
      para('a-p1', 'Alpha one.'),
      heading('notes-h', 2, 'Notes'),
      para('notes-p1', 'A note.'),
    ];
    const idOf = await load('setContentWithBlockIds', specs);
    typeIntoParagraph(view, 'Alpha', ' TYPED-REFUSAL');

    const unknown = deleteSectionEditorFirst(OP_ID, 'no-such-id', ['notes-h', 'notes-p1']);
    expect(unknown.ok).toBe(false);
    expect(unknown.reason).toBe('rootNotFound');
    // The typed edit was consumed by the call and must come back in the batch, even though nothing was removed.
    expect(unknown.batch.updates.map((u) => u.textContent).join('|')).toContain('TYPED-REFUSAL');

    expect(deleteSectionEditorFirst(OP_ID, idOf.get('a-p1') as string, []).reason).toBe('rootNotLeader');
    expect(deleteSectionEditorFirst(OP_ID, idOf.get('notes-h') as string, [idOf.get('notes-h') as string]).reason).toBe(
      'managedRoot'
    );

    // None of the refusals touched the document, left the registry holding an entry, or left block-sync paused.
    expect(view.state.doc.childCount).toBe(4);
    expect(getRegistry().size).toBe(0);
    typeIntoParagraph(view, 'Alpha', ' AFTER');
    await sleep(160);
    expect(
      takePendingAsReport()
        .updates.map((u) => u.textContent)
        .join('|')
    ).toContain('AFTER');
  });
});

// === W2, W3, W5 ===

describe('deleteSectionEditorFirst: what block-sync and the undo registry see', () => {
  const SPECS = [
    heading('a', 1, 'Chapter A'),
    para('a-p1', 'Alpha one.'),
    heading('b', 1, 'Chapter B'),
    para('b-p1', 'Beta one.'),
    para('b-p2', 'Beta two.'),
    heading('c', 1, 'Chapter C'),
    para('c-p1', 'Gamma one.'),
  ];

  it('W2: 150 ms after the call nothing the removal took out is queued for deletion (or anything else)', async () => {
    await makeEditor();
    const idOf = await load('setContentWithBlockIds', SPECS);

    const result = deleteSectionEditorFirst(OP_ID, idOf.get('b') as string, []);
    expect(result.ok).toBe(true);
    await sleep(150);

    const queued = takePendingAsReport();
    for (const id of result.removedIds) expect(queued.deletes).not.toContain(id);
    expect(queued).toEqual({ updates: [], inserts: [], deletes: [] });
  });

  it('block-sync is running again after the call, against the document without the section: a later edit is exactly one update', async () => {
    const { view } = await makeEditor();
    const idOf = await load('setContentWithBlockIds', SPECS);
    deleteSectionEditorFirst(OP_ID, idOf.get('b') as string, []);
    await sleep(150);
    takePendingAsReport();

    typeIntoParagraph(view, 'Gamma', ' AFTER-REMOVAL');
    await sleep(150);

    const queued = takePendingAsReport();
    expect(queued.updates.map((u) => u.id)).toEqual([idOf.get('c-p1')]);
    expect(queued.updates[0].textContent).toContain('AFTER-REMOVAL');
    expect(queued.inserts).toEqual([]);
    expect(queued.deletes).toEqual([]);
  });

  it('W3 (must-fail): an edit typed outside the section arrives in the RETURNED batch', async () => {
    const { view } = await makeEditor();
    const idOf = await load('setContentWithBlockIds', SPECS);
    typeIntoParagraph(view, 'Gamma', ' TYPED-W3');

    const result = deleteSectionEditorFirst(OP_ID, idOf.get('b') as string, []);

    expect(result.ok).toBe(true);
    const typedUpdate = result.batch.updates.find((u) => u.id === idOf.get('c-p1'));
    expect(
      typedUpdate?.textContent?.includes('TYPED-W3') === true,
      `expected batch.updates to contain "TYPED-W3", got ${JSON.stringify(result.batch.updates.map((u) => u.textContent))}`
    ).toBe(true);
    // Consumed: after the call it is not queued a second time.
    await sleep(150);
    expect(takePendingAsReport().updates).toEqual([]);
  });

  it('W3 variant: an edit whose 100 ms detection has already run (it is already a pending change) is consumed too', async () => {
    const { view } = await makeEditor();
    const idOf = await load('setContentWithBlockIds', SPECS);
    typeIntoParagraph(view, 'Gamma', ' TYPED-EARLY');
    await sleep(150); // block-sync's own debounce diffs it into the pending queue

    const result = deleteSectionEditorFirst(OP_ID, idOf.get('b') as string, []);

    expect(result.ok).toBe(true);
    expect(result.batch.updates.map((u) => u.textContent).join('|')).toContain('TYPED-EARLY');
    expect(takePendingAsReport().updates).toEqual([]);
  });

  it('W5: postOpDoc is the document after the removal, preOpDoc the one before it, and the entry is no longer mid-op', async () => {
    const { view } = await makeEditor();
    const idOf = await load('setContentWithBlockIds', SPECS);
    const docBefore = view.state.doc;

    const result = deleteSectionEditorFirst(OP_ID, idOf.get('b') as string, []);

    expect(result.ok).toBe(true);
    const entry = getRegistry().get(OP_ID);
    expect(entry).toBeDefined();
    expect(entry?.postOpDoc.eq(view.state.doc)).toBe(true);
    expect(entry?.postOpDoc.eq(docBefore)).toBe(false);
    expect(entry?.preOpDoc.eq(docBefore)).toBe(true);
    expect(entry?.checkpoint.doc.eq(docBefore)).toBe(true);
    // A left-over `midOp` would make the registry skip advancing EVERY entry (undo-coordinator.ts, advanceRegistryEntries).
    expect(entry?.midOp).toBe(false);
  });

  it('A12: a later automatic rewrite is absorbed into postOpDoc, and Cmd-Z then routes structurally to this op', async () => {
    const { view } = await makeEditor();
    const idOf = await load('setContentWithBlockIds', SPECS);
    deleteSectionEditorFirst(OP_ID, idOf.get('b') as string, []);

    // An automatic rewrite (sync origin: not added to the history), e.g. a footnote renumber or a Notes rebuild landing a moment
    // after the delete. With `midOp` still set the registry would skip it and the entry's target would fall one step behind.
    let endPos = -1;
    view.state.doc.forEach((node, offset) => {
      if (endPos === -1 && node.textContent.startsWith('Gamma')) endPos = offset + node.nodeSize - 1;
    });
    view.dispatch(view.state.tr.insertText(' (renumbered)', endPos).setMeta('addToHistory', false));
    expect(getRegistry().get(OP_ID)?.postOpDoc.eq(view.state.doc)).toBe(true);
    await sleep(150); // Cmd-Z only routes once block-sync's 100 ms detection of that rewrite has run

    const requested = vi.fn();
    (window as any).webkit = { messageHandlers: { structuralUndoRequested: { postMessage: requested } } };
    setUndoDescriptor({ undoTopOpId: OP_ID });
    const event = new KeyboardEvent('keydown', { key: 'z', metaKey: true, cancelable: true });
    expect(handleUnifiedUndoKeydown(event, view, 'undo')).toBe(true);
    expect(requested).toHaveBeenCalledWith({ opId: OP_ID });
  });

  it('the removal is one transaction that is not added to the text history', async () => {
    const { view } = await makeEditor();
    const idOf = await load('setContentWithBlockIds', SPECS);
    const seen: Array<{ structuralRemoval: unknown; addToHistory: unknown; steps: number }> = [];
    const dispatch = view.dispatch;
    view.dispatch = (tr) => {
      if (tr.docChanged) {
        seen.push({
          structuralRemoval: tr.getMeta('structuralRemoval'),
          addToHistory: tr.getMeta('addToHistory'),
          steps: tr.steps.length,
        });
      }
      dispatch(tr);
    };

    deleteSectionEditorFirst(OP_ID, idOf.get('b') as string, []);

    expect(seen).toEqual([{ structuralRemoval: true, addToHistory: false, steps: 1 }]);
  });

  it('efRemovalPainted (plan R4) is posted after the paint, only while the trace flag is on', async () => {
    await makeEditor();
    const painted = vi.fn();
    (window as any).webkit = { messageHandlers: { efRemovalPainted: { postMessage: painted } } };
    const idOf = await load('setContentWithBlockIds', SPECS);

    deleteSectionEditorFirst(OP_ID, idOf.get('c') as string, []);
    await waitForRAF();
    expect(painted).not.toHaveBeenCalled(); // flag off: nothing is posted

    setTraceTyping(true);
    const second = await load('setContentWithBlockIds', SPECS);
    deleteSectionEditorFirst('33333333-3333-3333-3333-333333333333', second.get('c') as string, []);
    expect(painted).not.toHaveBeenCalled(); // not before the frame
    await waitForRAF();
    expect(painted).toHaveBeenCalledTimes(1);
    expect(painted).toHaveBeenCalledWith({ opId: '33333333-3333-3333-3333-333333333333' });
  });
});

// === Round 13b: per-step timing in the success trace line ===

describe('round 13b: the success trace line carries the per-step timings', () => {
  it('posts "delete-editor-first ... ok=true" ending in a jsMs group with all ten named fields as whole, non-negative milliseconds', async () => {
    await makeEditor();
    const posted = vi.fn();
    (window as any).webkit = { messageHandlers: { errorHandler: { postMessage: posted } } };
    const specs = [
      heading('a', 1, 'Chapter A'),
      para('a-p1', 'Alpha one.'),
      heading('b', 1, 'Chapter B'),
      para('b-p1', 'Beta one.'),
      para('b-p2', 'Beta two.'),
      heading('c', 1, 'Chapter C'),
    ];
    const idOf = await load('setContentWithBlockIds', specs);

    const result = deleteSectionEditorFirst(OP_ID, idOf.get('b') as string, []);
    expect(result.ok, `reason: ${result.reason}`).toBe(true);

    const messages = posted.mock.calls
      .map(([payload]) => payload as { type: string; message: string })
      .filter((payload) => payload.message.includes('delete-editor-first') && payload.message.includes('ok=true'));
    expect(messages).toHaveLength(1);
    expect(messages[0].type).toBe('debug');
    // Chapter B owns itself and two paragraphs (3 removed, 1 leader); nothing was typed, so the batch is empty. The text before
    // ` jsMs` is the line as it was before the timings were added.
    const line =
      /^\[STRUCT-TRACE\] delete-editor-first opId=11111111 ok=true removed=3 leaders=1 batchUpdates=0 batchInserts=0 batchDeletes=0 jsMs total=(\d+) flush=(\d+) changes=(\d+) begin=(\d+) maps=(\d+) range=(\d+) collect=(\d+) dispatch=(\d+) snapshot=(\d+) finalize=(\d+)$/;
    const match = line.exec(messages[0].message);
    expect(match, `unexpected trace line: ${messages[0].message}`).not.toBeNull();
    const [total, ...steps] = (match as RegExpExecArray).slice(1).map(Number);
    expect(steps).toHaveLength(9);
    // Each step is a part of the whole, so no rounded step can exceed the rounded total.
    for (const step of steps) expect(step).toBeLessThanOrEqual(total);
  });
});

// === W12: the reply Swift decodes ===
// ONE exact reply of the real function, kept as a string constant. The Swift Tier-1 decode test copies this literal, so the two
// languages are pinned to the same JSON: if a field is renamed or reshaped here, this test fails, and the Swift copy must follow.
// The document: a chapter, a section break that owns a heading below it (removed), and a second chapter; one word typed into the
// chapter before the removed section, so the reply carries a non-empty batch.
const EDITOR_FIRST_DELETE_REPLY_FIXTURE =
  '{"batch":{"updates":[{"id":"a-p1","textContent":"Alpha one. TYPED-FIXTURE","markdownFragment":"Alpha one. TYPED-FIXTURE","blockType":"paragraph"}],"inserts":[],"deletes":[]},"ok":true,"removedIds":["brk","brk-p1","brk-1","brk-1-p1"],"removedLeaderIds":["brk","brk-1"],"predecessorId":"a-p1","removedSectionsSnapshot":[{"id":"brk","kind":"section_break","level":1,"title":""},{"id":"brk-1","kind":"heading","level":2,"title":"Under the break"}]}';

describe('W12: the reply of deleteSectionEditorFirst, as Swift decodes it', () => {
  it('is exactly EDITOR_FIRST_DELETE_REPLY_FIXTURE, and removedIds lists the blocks the removal actually deleted, in document order', async () => {
    const { view } = await makeEditor();
    const specs = [
      heading('a', 1, 'Chapter A'),
      para('a-p1', 'Alpha one.'),
      sectionBreak('brk'),
      para('brk-p1', 'After the break.'),
      heading('brk-1', 2, 'Under the break'),
      para('brk-1-p1', 'Deeper text.'),
      heading('b', 1, 'Chapter B'),
      para('b-p1', 'Beta one.'),
    ];
    await load('setContentWithBlockIds', specs);
    const idsBefore = idsInOrder();
    typeIntoParagraph(view, 'Alpha', ' TYPED-FIXTURE');

    const result = deleteSectionEditorFirst('11111111-2222-3333-4444-555555555555', 'brk', ['notes-h']);

    const idsAfter = idsInOrder();
    expect(result.removedIds).toEqual(idsBefore.filter((id) => !idsAfter.includes(id)));
    expect(result.removedIds).toEqual(['brk', 'brk-p1', 'brk-1', 'brk-1-p1']);
    expect(JSON.stringify(result)).toBe(EDITOR_FIRST_DELETE_REPLY_FIXTURE);
  });
});

// === W10 ===

describe('W10 failureAfterDispatchRestoresSection', () => {
  it('a throw after the removal was dispatched puts the section back, queues no deletes, and still returns the batch', async () => {
    const { view } = await makeEditor();
    const specs = [
      heading('a', 1, 'Chapter A'),
      para('a-p1', 'Alpha one.'),
      heading('b', 1, 'Chapter B'),
      para('b-p1', 'Beta one.'),
      heading('b-1', 2, 'B one'),
      para('b-1-p1', 'Beta sub one.'),
      heading('c', 1, 'Chapter C'),
      para('c-p1', 'Gamma one.'),
    ];
    const idOf = await load('setContentWithBlockIds', specs);
    const docBefore = view.state.doc;
    const idsBefore = idsInOrder();
    typeIntoParagraph(view, 'Gamma', ' TYPED-W10');
    const docWithTyping = view.state.doc;
    setTestAfterRemovalHook(() => {
      throw new Error('injected failure after the removal');
    });

    const result = deleteSectionEditorFirst(OP_ID, idOf.get('b') as string, []);

    expect(result.ok).toBe(false);
    expect(result.reason).toContain('injected failure after the removal');
    // The batch is returned although the call failed: the typed edit was consumed and Swift must still apply it.
    expect(result.batch.updates.map((u) => u.textContent).join('|')).toContain('TYPED-W10');
    // The section is on screen again, exactly as it was (with the typed word), ids included.
    expect(view.state.doc.eq(docWithTyping)).toBe(true);
    expect(view.state.doc.eq(docBefore)).toBe(false);
    expect(view.state.doc.textContent).toContain('Beta sub one.');
    expect(idsInOrder()).toEqual(idsBefore);
    // No half-finished op is left behind, and block-sync queued nothing.
    expect(getRegistry().has(OP_ID)).toBe(false);
    await sleep(150);
    expect(takePendingAsReport()).toEqual({ updates: [], inserts: [], deletes: [] });

    // Block-sync is running again, against the restored document: a new edit is detected as exactly one update.
    setTestAfterRemovalHook(null);
    typeIntoParagraph(view, 'Beta one', ' AFTER-W10');
    await sleep(150);
    const next = takePendingAsReport();
    expect(next.updates.map((u) => u.id)).toEqual([idOf.get('b-p1')]);
    expect(next.inserts).toEqual([]);
    expect(next.deletes).toEqual([]);
  });
});

// === Generated documents: article size and six-chapter-book size ===
// Built the way the app's own generated documents are sized (plan section 6): article = 17 sections, about 7.5 thousand words;
// book6 = 102 sections, about 45 thousand words. Plain paragraphs only (no citations or footnotes: those need plugins that
// change nothing about this API), each chapter with sub-sections, and a Notes region at the end.

const SENTENCE =
  'The fieldwork continued through the monsoon season while the archive stayed closed to outside readers. ';
const PARAGRAPH = SENTENCE.repeat(6).trim(); // 96 words

function generate(chapters: number, sectionsPerChapter: number, paragraphsPerSection: number): Spec[] {
  const specs: Spec[] = [];
  for (let c = 1; c <= chapters; c++) {
    specs.push(heading(`ch${c}`, 1, `Chapter ${c}`));
    specs.push(para(`ch${c}-intro`, `Chapter ${c}. ${PARAGRAPH}`));
    for (let s = 1; s <= sectionsPerChapter; s++) {
      specs.push(heading(`ch${c}-s${s}`, 2, `Section ${c}.${s}`));
      for (let k = 1; k <= paragraphsPerSection; k++) {
        specs.push(para(`ch${c}-s${s}-p${k}`, `Paragraph ${c}.${s}.${k}. ${PARAGRAPH}`));
      }
    }
  }
  specs.push(heading('notes-h', 2, 'Notes'));
  specs.push(para('notes-p1', 'Note one.'));
  specs.push(para('notes-p2', 'Note two.'));
  return specs;
}

const MANAGED_TAIL = ['notes-h', 'notes-p1', 'notes-p2'];

const SIZES = [
  { label: 'article (3 chapters, 18 sections)', chapters: 3, sections: 5, paragraphs: 5, victim: 'ch2' },
  { label: 'book6 (6 chapters, 102 sections)', chapters: 6, sections: 16, paragraphs: 5, victim: 'ch3' },
];

describe('deleteSectionEditorFirst on generated documents', () => {
  for (const size of SIZES) {
    it(`${size.label}: removes the middle chapter, keeps Notes, queues nothing`, async () => {
      const { view } = await makeEditor();
      const specs = generate(size.chapters, size.sections, size.paragraphs);
      const words = specs.reduce((n, s) => n + s.text.split(/\s+/).filter(Boolean).length, 0);
      const headings = specs.filter((s) => s.blockType === 'heading').length;
      console.log(`[generated] ${size.label}: blocks=${specs.length} headings=${headings} words=${words}`);
      const idOf = await load('setContentWithBlockIds', specs);

      const expectedRemoved = specs
        .filter((s) => s.name.startsWith(`${size.victim}-`) || s.name === size.victim)
        .map((s) => s.name);
      const survivors = specs.filter((s) => !expectedRemoved.includes(s.name));
      typeIntoParagraph(view, 'Chapter 1.', ' TYPED-BIG');

      const result = deleteSectionEditorFirst(
        OP_ID,
        idOf.get(size.victim) as string,
        MANAGED_TAIL.map((n) => idOf.get(n) as string)
      );

      expect(result.ok, `reason: ${result.reason}`).toBe(true);
      expect(result.removedIds).toEqual(expectedRemoved.map((n) => idOf.get(n)));
      expect(idsInOrder()).toEqual(survivors.map((s) => idOf.get(s.name)));
      expect(idsInOrder().slice(-3)).toEqual(MANAGED_TAIL.map((n) => idOf.get(n)));
      expect(result.batch.updates.map((u) => u.textContent).join('|')).toContain('TYPED-BIG');
      await sleep(150);
      expect(takePendingAsReport()).toEqual({ updates: [], inserts: [], deletes: [] });
      expect(getRegistry().get(OP_ID)?.postOpDoc.eq(view.state.doc)).toBe(true);
    });
  }
});
