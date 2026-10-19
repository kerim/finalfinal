// @vitest-environment jsdom
//
// Phase 4b slice 2, round 2c (t-18b7fa48): `replaceRangeEditorFirst` and `redoReplaceRangeEditorFirst` (api-structural-replace.ts) --
// the editor half of the three Version History restores. The editor replaces the whole document ('whole'), the target heading's FLAT
// section ('section') or inserts a fragment after an anchor ('insertAfter') first, in one synchronous JavaScript turn, gives the new
// top-level blocks the ids the payload carries, and hands Swift the batch of pending edits it consumed. The quick undo of every mode
// is the generic `undoSectionDeleteEditorFirst` (api-section-undo.ts), which is NOT changed here; these tests only prove it undoes
// each mode back to the exact pre-op document.
//
// V2-1 section mode replaces only the flat range (an H1's H2 children keep their ids and text), a figure takes its image metadata,
// insertAfter lands after the anchor or above Notes/Bibliography. V2-2 a payload the editor's parse cannot take is refused with
// `idAlignment` and the document, the ids, the managed set and block-sync are exactly as they were. F6: batch N, the replace and the
// re-baseline are one turn: typing just before the click is in the batch and not reported again, typing after the reply is an UPDATE
// of the payload's id. Undo of each mode, the redo with the same ids, the redo gate, two restores in a row, the trace line.
// (V2-3, the payload against the real Swift output, is restore-payload-alignment.test.ts.)
//
// The harness (editor-first-harness.ts) is the real thing: a real Milkdown editor with the block-id, block-sync and history plugins,
// `view.dispatch` wired through the production `runUndoTrackedDispatch`. Swift's side of the conversation is played by the test.

import { Selection } from '@milkdown/kit/prose/state';
import { afterEach, describe, expect, it } from 'vitest';
import { getBlockChangesApi, setContentWithBlockIds } from '../api-content';
import { undoSectionDeleteEditorFirst } from '../api-section-undo';
import {
  type ReplaceRangePayload,
  redoReplaceRangeEditorFirst,
  replaceRangeEditorFirst,
  setTestAfterReplaceHook,
} from '../api-structural-replace';
import { bibliographyEndMarkerPlugin } from '../bibliography-end-marker-plugin';
import { bibliographyPlugin } from '../bibliography-plugin';
import {
  getAllBlockIds,
  getManagedBlockIds,
  isTempBlockId,
  setManagedBlockIds,
  setTopLevelIdsAt,
} from '../block-id-plugin';
import { flushPendingBlockChanges } from '../block-sync-plugin';
import { imagePlugin } from '../image-plugin';
import { getRegistry, receiveRedoOutcome } from '../undo-coordinator';
import {
  EMPTY_BATCH,
  heading,
  idsInOrder,
  load,
  makeEditor,
  markdownOf,
  type Posted,
  para,
  pressRedo,
  pressUndo,
  type Spec,
  sectionBreak,
  sleep,
  swiftFinishesRedo,
  swiftFinishesUndo,
  typeInto,
  typeIntoNth,
  waitForRAF,
} from './editor-first-harness';

const OP = 'dddddddd-2222-3333-4444-555555555555';
const OP_2 = 'eeeeeeee-2222-3333-4444-555555555555';

const DOC = [
  heading('h1', 1, 'Chapter'),
  para('p1', 'Chapter body.'),
  heading('a', 2, 'Section A'),
  para('pa', 'A body.'),
  heading('b', 2, 'Section B'),
  para('pb', 'B body.'),
];

afterEach(() => {
  setTestAfterReplaceHook(null);
});

// === Payload helpers: what Swift's `editorPayload(for:)` would give for these rows ===

function blockTypeOf(md: string): string {
  if (md.startsWith('#')) return 'heading';
  if (md.startsWith('![')) return 'image';
  if (md.startsWith('<!-- ::break')) return 'section_break';
  if (md.startsWith('- ')) return 'bullet_list';
  return 'paragraph';
}

function payloadOf(
  mode: ReplaceRangePayload['mode'],
  specs: Spec[],
  extra: Partial<ReplaceRangePayload> = {}
): ReplaceRangePayload {
  return {
    mode,
    markdown: markdownOf(specs),
    blockIds: specs.map((s) => s.name),
    expectedBlocks: specs.map((s) => {
      const blockType = blockTypeOf(s.md);
      return { blockType, nonEmpty: blockType !== 'image' && blockType !== 'section_break' };
    }),
    managedIds: [],
    ...extra,
  };
}

const sectionA = () =>
  payloadOf('section', [heading('a', 2, 'Section A restored'), para('pa2', 'A restored body.')], { rootBlockId: 'a' });
const WHOLE = [
  heading('w1', 1, 'Whole'),
  para('w2', 'Whole body.'),
  heading('w3', 2, 'Whole sub'),
  para('w4', 'Sub body.'),
];
const whole = () => payloadOf('whole', WHOLE, { managedBlockIds: [] });
const insertAfterPa = () =>
  payloadOf('insertAfter', [heading('ins', 2, 'Inserted'), para('insp', 'Inserted body.')], { anchorBlockId: 'pa' });

function topLevelTexts(view: {
  state: { doc: { forEach: (f: (n: { textContent: string }) => void) => void } };
}): string[] {
  const texts: string[] = [];
  view.state.doc.forEach((node) => {
    texts.push(node.textContent);
  });
  return texts;
}

/** The replace-related trace lines the editor posted, in order. */
function replaceTraces(posted: Posted): string[] {
  return posted
    .filter((p) => p.handler === 'errorHandler' && typeof p.body?.message === 'string')
    .map((p) => p.body.message as string)
    .filter((m) => m.startsWith('[STRUCT-TRACE] replace'));
}

/** A document with Notes and Bibliography at the end, markers included: the block ids are in `ids`, the marker atoms hold none. */
const MANAGED_IDS = ['notes', 'np', 'bib', 'bp'];
const MANAGED_DOC_IDS = ['t', 'b1', 'b2', ...['notes', 'np', 'bib', 'bp']];
const MANAGED_DOC_MD = [
  '# Title',
  'Body one.',
  'Body two.',
  '## Notes',
  'Note text.',
  '<!-- ::auto-bibliography:: -->',
  '## Bibliography',
  'Reference one.',
  '<!-- ::auto-bibliography-end:: -->',
].join('\n\n');

async function loadManagedDoc(): Promise<void> {
  setContentWithBlockIds(MANAGED_DOC_MD, MANAGED_DOC_IDS, { managedBlockIds: MANAGED_IDS });
  await waitForRAF();
  getBlockChangesApi();
  expect(idsInOrder()).toEqual(MANAGED_DOC_IDS);
}

describe('replaceRangeEditorFirst: section mode (the FLAT range)', () => {
  it('V2-1a: an H1 with H2 children: only the heading and its own body are replaced; the H2 sections keep their ids and text', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    const before = view.state.doc;
    const payload = payloadOf(
      'section',
      [heading('h1', 1, 'Chapter restored'), para('p1n', 'Restored chapter body.')],
      { rootBlockId: 'h1' }
    );

    const r = replaceRangeEditorFirst(OP, payload);

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(idsInOrder(), 'the range took the payload ids; the H2 sections kept theirs').toEqual([
      'h1',
      'p1n',
      'a',
      'pa',
      'b',
      'pb',
    ]);
    expect(topLevelTexts(view)).toEqual([
      'Chapter restored',
      'Restored chapter body.',
      'Section A',
      'A body.',
      'Section B',
      'B body.',
    ]);
    for (let i = 2; i < 6; i++) {
      expect(view.state.doc.child(i).eq(before.child(i)), `child ${i} is untouched`).toBe(true);
    }
    expect(r.insertedIds).toEqual(['h1', 'p1n']);
    expect(r.insertedLeaderIds).toEqual(['h1']);
    expect(r.insertedSectionsSnapshot).toEqual([{ id: 'h1', kind: 'heading', level: 1, title: 'Chapter restored' }]);
    expect(r.removedIds, 'the flat range was the heading and its own paragraph').toEqual(['h1', 'p1']);
    expect(r.removedLeaderIds).toEqual(['h1']);
    expect(r.predecessorId, 'the range began the document').toBeNull();
    // The change is applied and re-baselined: it queues nothing, not even after block-sync's own debounce has run.
    await sleep(160);
    expect(getBlockChangesApi(), 'the new blocks are never reported as inserts').toEqual(EMPTY_BATCH);
  });

  it('V2-1b: a deeper heading ends the flat range too (an H3 under an H2), and a longer body is replaced whole', async () => {
    const { view } = await makeEditor();
    await load([
      heading('a', 2, 'Section A'),
      para('pa', 'A body.'),
      para('pa-2', 'A second paragraph.'),
      heading('a1', 3, 'Sub A'),
      para('pa1', 'Sub A body.'),
      heading('b', 2, 'Section B'),
    ]);

    const r = replaceRangeEditorFirst(
      OP,
      payloadOf('section', [heading('a', 2, 'Section A'), para('pa-new', 'Only one paragraph now.')], {
        rootBlockId: 'a',
      })
    );

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(r.removedIds).toEqual(['a', 'pa', 'pa-2']);
    expect(idsInOrder()).toEqual(['a', 'pa-new', 'a1', 'pa1', 'b']);
    expect(topLevelTexts(view)).toEqual(['Section A', 'Only one paragraph now.', 'Sub A', 'Sub A body.', 'Section B']);
  });

  it('V2-1c: a section break and the first Notes block end the range; a section break can be the target', async () => {
    const { view } = await makeEditor();
    await load([
      heading('h', 1, 'Lead'),
      para('hp', 'Lead body.'),
      sectionBreak('sb'),
      para('sp', 'After the break.'),
      heading('notes', 2, 'Notes'),
      para('np', 'A note.'),
    ]);
    const managedIds = ['notes', 'np'];

    const first = replaceRangeEditorFirst(
      OP,
      payloadOf('section', [heading('h', 1, 'Lead'), para('hp2', 'New lead body.')], {
        rootBlockId: 'h',
        managedIds,
      })
    );
    expect(first.ok, `reason: ${first.reason}`).toBe(true);
    expect(first.removedIds, 'the section break ends the heading section').toEqual(['h', 'hp']);

    const second = replaceRangeEditorFirst(
      OP_2,
      payloadOf('section', [sectionBreak('sb'), para('sp2', 'New text after the break.')], {
        rootBlockId: 'sb',
        managedIds,
      })
    );
    expect(second.ok, `reason: ${second.reason}`).toBe(true);
    expect(second.removedIds, 'Notes ends a section break section').toEqual(['sb', 'sp']);
    expect(second.insertedSectionsSnapshot).toEqual([{ id: 'sb', kind: 'section_break', level: 1, title: '' }]);
    expect(idsInOrder()).toEqual(['h', 'hp2', 'sb', 'sp2', 'notes', 'np']);
    expect(topLevelTexts(view)).toEqual([
      'Lead',
      'New lead body.',
      '',
      'New text after the break.',
      'Notes',
      'A note.',
    ]);
  });

  it('V2-1d: a figure in the replaced section takes its payload id and its image metadata (caption, width)', async () => {
    const { view } = await makeEditor([imagePlugin]);
    await load([
      heading('f', 1, 'Pictures'),
      para('fp', 'Look.'),
      { name: 'fig', md: '![old](media/old.png)' },
      heading('g', 1, 'After'),
    ]);

    const payload = payloadOf(
      'section',
      [
        heading('f', 1, 'Pictures'),
        para('fp2', 'Look again.'),
        { name: 'fig2', md: '![new](media/new.png)' },
        para('fp3', 'Closing line.'),
      ],
      { rootBlockId: 'f', imageMeta: [{ id: 'fig2', caption: 'The new caption', width: 320 }] }
    );
    const r = replaceRangeEditorFirst(OP, payload);

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(idsInOrder()).toEqual(['f', 'fp2', 'fig2', 'fp3', 'g']);
    const figures: Array<Record<string, unknown>> = [];
    view.state.doc.forEach((node) => {
      if (node.type.name === 'figure') figures.push(node.attrs);
    });
    expect(figures).toHaveLength(1);
    expect(figures[0].blockId).toBe('fig2');
    expect(figures[0].caption).toBe('The new caption');
    expect(figures[0].width).toBe(320);
    const painted = Array.from(view.dom.querySelectorAll('[data-block-id]')).map((el) =>
      el.getAttribute('data-block-id')
    );
    expect(painted, 'the DOM paints the payload ids, never a temp id').toEqual(idsInOrder());
  });

  it('V2-1e: a root that is not found, not a leader, or managed is refused; nothing is dispatched and no registry entry is left', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    const before = view.state.doc;
    const frag = [heading('a', 2, 'Section A'), para('pa2', 'x')];

    expect(replaceRangeEditorFirst(OP, payloadOf('section', frag, { rootBlockId: 'nope' })).reason).toBe(
      'rootNotFound'
    );
    expect(
      replaceRangeEditorFirst(OP, payloadOf('section', [heading('pa', 2, 'x'), para('q', 'y')], { rootBlockId: 'pa' }))
        .reason
    ).toBe('rootNotLeader');
    expect(
      replaceRangeEditorFirst(OP, payloadOf('section', frag, { rootBlockId: 'a', managedIds: ['a', 'pa'] })).reason
    ).toBe('managedRoot');

    expect(view.state.doc.eq(before)).toBe(true);
    expect(idsInOrder()).toEqual(DOC.map((s) => s.name));
    expect(getRegistry().has(OP)).toBe(false);
  });
});

describe('replaceRangeEditorFirst: insertAfter mode', () => {
  it('V2-1f: the fragment goes directly after the anchor; nothing is removed', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    const before = view.state.doc;

    const r = replaceRangeEditorFirst(
      OP,
      payloadOf('insertAfter', [heading('ins', 2, 'Inserted'), para('insp', 'Inserted body.')], { anchorBlockId: 'p1' })
    );

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(idsInOrder()).toEqual(['h1', 'p1', 'ins', 'insp', 'a', 'pa', 'b', 'pb']);
    expect(r.removedIds).toEqual([]);
    expect(r.removedLeaderIds).toEqual([]);
    expect(r.insertedIds).toEqual(['ins', 'insp']);
    expect(r.insertedSectionsSnapshot).toEqual([{ id: 'ins', kind: 'heading', level: 2, title: 'Inserted' }]);
    expect(r.predecessorId).toBe('p1');
    // The blocks around the insertion are untouched.
    expect(view.state.doc.child(0).eq(before.child(0))).toBe(true);
    expect(view.state.doc.child(4).eq(before.child(2))).toBe(true);
    await sleep(160);
    expect(getBlockChangesApi()).toEqual(EMPTY_BATCH);
  });

  it('V2-1g: with no anchor the fragment goes after the last non-managed block, above Notes and Bibliography and their markers', async () => {
    const { view } = await makeEditor([bibliographyPlugin, bibliographyEndMarkerPlugin]);
    await loadManagedDoc();

    const r = replaceRangeEditorFirst(
      OP,
      payloadOf('insertAfter', [heading('ins', 2, 'Restored'), para('insp', 'Restored text.')], {
        anchorBlockId: null,
        managedIds: MANAGED_IDS,
      })
    );

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(idsInOrder()).toEqual(['t', 'b1', 'b2', 'ins', 'insp', 'notes', 'np', 'bib', 'bp']);
    const names: string[] = [];
    view.state.doc.forEach((node) => {
      names.push(node.type.name);
    });
    expect(names, 'the bibliography markers still bracket the Bibliography section').toEqual([
      'heading',
      'paragraph',
      'paragraph',
      'heading',
      'paragraph',
      'heading',
      'paragraph',
      'auto_bibliography',
      'heading',
      'paragraph',
      'auto_bibliography_end',
    ]);
    expect(r.predecessorId).toBe('b2');
  });

  it('V2-1h: an anchor that does not exist or is managed is refused; the document is untouched', async () => {
    const { view } = await makeEditor([bibliographyPlugin, bibliographyEndMarkerPlugin]);
    await loadManagedDoc();
    const before = view.state.doc;
    const frag = [para('insp', 'Text.')];

    expect(
      replaceRangeEditorFirst(OP, payloadOf('insertAfter', frag, { anchorBlockId: 'nope', managedIds: MANAGED_IDS }))
        .reason
    ).toBe('anchorNotFound');
    expect(
      replaceRangeEditorFirst(OP, payloadOf('insertAfter', frag, { anchorBlockId: 'np', managedIds: MANAGED_IDS }))
        .reason
    ).toBe('managedAnchor');

    expect(view.state.doc.eq(before)).toBe(true);
    expect(getRegistry().has(OP)).toBe(false);
  });

  it('V2-1i: an unknown mode is refused', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    const before = view.state.doc;

    const r = replaceRangeEditorFirst(OP, { ...whole(), mode: 'sideways' as never });

    expect(r.reason).toBe('unknownMode');
    expect(view.state.doc.eq(before)).toBe(true);
    expect(getRegistry().has(OP)).toBe(false);
  });
});

describe('replaceRangeEditorFirst: whole mode', () => {
  it('V2-1j: the whole document is replaced; the editor holds the payload ids, managed ids and reply lists the leaders', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    setManagedBlockIds(['stale']);

    const r = replaceRangeEditorFirst(OP, { ...whole(), managedBlockIds: ['w4'] });

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(idsInOrder()).toEqual(['w1', 'w2', 'w3', 'w4']);
    expect(topLevelTexts(view)).toEqual(['Whole', 'Whole body.', 'Whole sub', 'Sub body.']);
    expect(Array.from(getManagedBlockIds()), "the payload's managed ids replace the editor's set").toEqual(['w4']);
    expect(r.insertedIds).toEqual(['w1', 'w2', 'w3', 'w4']);
    expect(r.insertedLeaderIds).toEqual(['w1', 'w3']);
    expect(r.insertedSectionsSnapshot).toEqual([
      { id: 'w1', kind: 'heading', level: 1, title: 'Whole' },
      { id: 'w3', kind: 'heading', level: 2, title: 'Whole sub' },
    ]);
    expect(r.removedIds).toEqual(['h1', 'p1', 'a', 'pa', 'b', 'pb']);
    expect(r.removedLeaderIds).toEqual(['h1', 'a', 'b']);
    expect(r.predecessorId).toBeNull();
    for (const id of idsInOrder()) expect(isTempBlockId(id)).toBe(false);
    await sleep(160);
    expect(getBlockChangesApi(), 'the replaced document queues nothing').toEqual(EMPTY_BATCH);
  });

  it('V2-1k: the caret is kept out of the bibliography span, as the whole-document push does', async () => {
    const { view } = await makeEditor([bibliographyPlugin, bibliographyEndMarkerPlugin]);
    await loadManagedDoc();
    // The caret sits at the end of the old document: inside what the new document will hold as the Bibliography section.
    view.dispatch(view.state.tr.setSelection(Selection.atEnd(view.state.doc)));
    const payload = payloadOf(
      'whole',
      [
        heading('n1', 1, 'New'),
        para('n2', 'One.'),
        para('n3', 'Two.'),
        heading('n4', 2, 'Bibliography'),
        para('n5', 'Ref.'),
      ],
      { bibBoundaryIndex: 3, bibBoundaryEndIndex: 5, managedBlockIds: ['n4', 'n5'] }
    );

    const r = replaceRangeEditorFirst(OP, payload);

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    let bibliographyStart = -1;
    view.state.doc.forEach((node, pos) => {
      if (node.type.name === 'heading' && node.textContent === 'Bibliography') bibliographyStart = pos;
    });
    expect(view.state.selection.from, 'the caret is before the Bibliography heading').toBeLessThan(bibliographyStart);
  });
});

describe('replaceRangeEditorFirst: a payload the editor cannot take is refused (V2-2)', () => {
  it('V2-2a: whole mode with a wrong id count: ok:false idAlignment, the document is eq to the original, block-sync runs, no registry entry', async () => {
    const { view, posted } = await makeEditor();
    await load(DOC);
    typeInto(view, 'B body', ' (pending)');
    const before = view.state.doc;
    setManagedBlockIds(['keep']);
    const bad = { ...whole(), blockIds: ['w1', 'w2', 'w3'] }; // four top-level nodes, three ids

    const r = replaceRangeEditorFirst(OP, bad);

    expect(r.ok).toBe(false);
    expect(r.reason).toBe('idAlignment');
    expect(r.insertedIds).toEqual([]);
    expect(
      r.batch.updates.map((u) => u.id),
      'a refusal still returns the batch it consumed'
    ).toEqual(['pb']);
    expect(view.state.doc.textContent).toBe(`${before.textContent}`);
    expect(view.state.doc.eq(before), 'the document is as it was').toBe(true);
    expect(idsInOrder()).toEqual(DOC.map((s) => s.name));
    expect(Array.from(getManagedBlockIds())).toEqual(['keep']);
    expect(getRegistry().has(OP), 'no registry entry is left behind').toBe(false);
    expect(replaceTraces(posted).pop()).toMatch(
      /^\[STRUCT-TRACE\] replace-editor-first mode=whole opId=dddddddd ok=false reason=idAlignment detail=count: nodes=4 ids=3$/
    );
    // Block-sync is running: the next edit is exactly one update of the ORIGINAL block.
    typeInto(view, 'A body', ' more');
    flushPendingBlockChanges();
    const diff = getBlockChangesApi();
    expect(diff.updates.map((u) => u.id)).toEqual(['pa']);
    expect(diff.inserts).toEqual([]);
    expect(diff.deletes).toEqual([]);
  });

  it('V2-2b: section mode: a count mismatch, a type mismatch, a first id that is not the root, and an id the document already holds', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    const before = view.state.doc;
    const good = [heading('a', 2, 'Section A restored'), para('pa2', 'A restored body.')];

    // Two nodes, one id.
    const short = replaceRangeEditorFirst(OP, { ...payloadOf('section', good, { rootBlockId: 'a' }), blockIds: ['a'] });
    // The payload says the second block is a heading; the parse makes it a paragraph.
    const wrongType = payloadOf('section', good, { rootBlockId: 'a' });
    wrongType.expectedBlocks[1] = { blockType: 'heading', nonEmpty: true };
    const typeMismatch = replaceRangeEditorFirst(OP, wrongType);
    // The first id is not the target's.
    const notRoot = replaceRangeEditorFirst(OP, {
      ...payloadOf('section', good, { rootBlockId: 'a' }),
      blockIds: ['other', 'pa2'],
    });
    // The second id is held by a block outside the range.
    const collision = replaceRangeEditorFirst(OP, {
      ...payloadOf('section', good, { rootBlockId: 'a' }),
      blockIds: ['a', 'pb'],
    });

    for (const r of [short, typeMismatch, notRoot, collision]) {
      expect(r.ok).toBe(false);
      expect(r.reason).toBe('idAlignment');
    }
    expect(view.state.doc.eq(before)).toBe(true);
    expect(idsInOrder()).toEqual(DOC.map((s) => s.name));
    expect(getRegistry().has(OP)).toBe(false);
  });

  it('V2-2c: a refusal AFTER the dispatch (an id the check does not find) puts the document, the ids, the managed set and block-sync back', async () => {
    const { view, posted } = await makeEditor();
    await load(DOC);
    typeInto(view, 'B body', ' (pending)');
    const docBefore = view.state.doc;
    setManagedBlockIds(['keep']);
    // Tamper with an id the way a broken alignment would leave one: the document is dispatched, the ids are set, then one is wrong.
    setTestAfterReplaceHook(() => {
      const firstPos = Array.from(getAllBlockIds().keys())[0];
      setTopLevelIdsAt([firstPos], ['tampered']);
    });

    const r = replaceRangeEditorFirst(OP, { ...whole(), managedBlockIds: ['w2'] });

    expect(r.ok).toBe(false);
    expect(r.reason).toBe('idAlignment');
    expect(r.batch.updates.map((u) => u.id)).toEqual(['pb']);
    expect(view.state.doc.eq(docBefore), 'the document is as it was').toBe(true);
    expect(idsInOrder(), 'and so are the block ids').toEqual(DOC.map((s) => s.name));
    expect(Array.from(getManagedBlockIds()), 'and the managed set').toEqual(['keep']);
    expect(getRegistry().has(OP)).toBe(false);
    expect(replaceTraces(posted).pop()).toMatch(
      /^\[STRUCT-TRACE\] replace-editor-first mode=whole opId=dddddddd ok=false reason=idAlignment detail=id at block 0 is not the expected one$/
    );
    setTestAfterReplaceHook(null);
    typeInto(view, 'A body', ' after');
    flushPendingBlockChanges();
    const diff = getBlockChangesApi();
    expect(diff.updates.map((u) => u.id)).toEqual(['pa']);
    expect(diff.inserts).toEqual([]);
    expect(diff.deletes).toEqual([]);
  });

  it('V2-2d: a refused SECTION replace after the dispatch is rolled back the same way', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    const docBefore = view.state.doc;
    setTestAfterReplaceHook(() => {
      const lastPos = Array.from(getAllBlockIds().keys()).pop() as number;
      setTopLevelIdsAt([lastPos], ['tampered']); // an id OUTSIDE the range changed
    });

    const r = replaceRangeEditorFirst(OP, sectionA());

    expect(r.ok).toBe(false);
    expect(r.reason).toBe('idAlignment');
    expect(view.state.doc.eq(docBefore)).toBe(true);
    expect(idsInOrder()).toEqual(DOC.map((s) => s.name));
    expect(getRegistry().has(OP)).toBe(false);
  });

  it('V2-2e: a throw after the dispatch puts everything back, and the reply still carries the batch', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    typeInto(view, 'B body', ' (pending)');
    const docBefore = view.state.doc;
    setManagedBlockIds(['keep']);
    setTestAfterReplaceHook(() => {
      throw new Error('injected failure after the replace');
    });

    const r = replaceRangeEditorFirst(OP, { ...whole(), managedBlockIds: ['w2'] });

    expect(r.ok).toBe(false);
    expect(r.reason).toContain('injected failure after the replace');
    expect(r.batch.updates.map((u) => u.id)).toEqual(['pb']);
    expect(view.state.doc.eq(docBefore)).toBe(true);
    expect(idsInOrder()).toEqual(DOC.map((s) => s.name));
    expect(Array.from(getManagedBlockIds())).toEqual(['keep']);
    expect(getRegistry().has(OP)).toBe(false);
  });
});

describe('replaceRangeEditorFirst: batch N, the replace and the re-baseline are one turn (F6)', () => {
  const modes: Array<[string, () => ReplaceRangePayload, string]> = [
    ['section', sectionA, 'B body'],
    ['whole', whole, 'B body'],
    ['insertAfter', insertAfterPa, 'B body'],
  ];

  it.each(
    modes
  )('F6a (%s): typing just BEFORE the click lands in batch N and is not reported again after the replace', async (_name, payload, typedIn) => {
    const { view } = await makeEditor();
    await load(DOC);
    typeInto(view, typedIn, ' (pending)'); // the 100 ms detection has not run when the click arrives

    const r = replaceRangeEditorFirst(OP, payload());

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(r.batch.updates.map((u) => u.id)).toEqual(['pb']);
    expect(r.batch.updates[0].textContent).toBe('B body. (pending)');
    expect(r.batch.inserts).toEqual([]);
    expect(r.batch.deletes).toEqual([]);
    await sleep(160);
    expect(
      getBlockChangesApi(),
      'the consumed edit is not queued a second time, and the replace queues nothing'
    ).toEqual(EMPTY_BATCH);
  });

  it('F6b: typing just before the click into a block the replace removes is in batch N, and nothing is reported after', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    typeInto(view, 'A body', ' (pending)'); // 'pa' is inside the replaced range

    const r = replaceRangeEditorFirst(OP, sectionA());

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(
      r.batch.updates.map((u) => u.id),
      'applied BEFORE the job that removes the row'
    ).toEqual(['pa']);
    await sleep(160);
    expect(getBlockChangesApi()).toEqual(EMPTY_BATCH);
    expect(view.state.doc.textContent).not.toContain('(pending)');
  });

  it.each([
    ['section', sectionA, 'A restored body', 'pa2'],
    ['whole', whole, 'Whole body.', 'w2'],
    ['insertAfter', insertAfterPa, 'Inserted body.', 'insp'],
  ] as Array<
    [string, () => ReplaceRangePayload, string, string]
  >)('F6c (%s): typing AFTER the reply is an UPDATE of the payload id, never an insert, never lost', async (_name, payload, startsWith, expectedId) => {
    const { view } = await makeEditor();
    await load(DOC);
    expect(replaceRangeEditorFirst(OP, payload()).ok).toBe(true);

    typeIntoNth(view, startsWith, 0, ' typed');
    flushPendingBlockChanges();
    const diff = getBlockChangesApi();

    expect(diff.inserts, 'typing in replaced content is not an insert').toEqual([]);
    expect(diff.deletes).toEqual([]);
    expect(diff.updates.map((u) => u.id)).toEqual([expectedId]);
    expect(isTempBlockId(expectedId)).toBe(false);
  });

  it('F6d: the call is one synchronous turn: a microtask queued before it has not run when it returns', async () => {
    await makeEditor();
    await load(DOC);
    let microtaskRan = false;
    queueMicrotask(() => {
      microtaskRan = true;
    });

    const r = replaceRangeEditorFirst(OP, whole());

    expect(r.ok).toBe(true);
    expect(microtaskRan, 'nothing could run between the batch, the replace and the re-baseline').toBe(false);
  });
});

describe('replaceRangeEditorFirst: undo, redo and a second restore', () => {
  const scenarios: Array<[string, () => ReplaceRangePayload]> = [
    ['whole', whole],
    ['section', sectionA],
    ['insertAfter', insertAfterPa],
  ];

  it.each(
    scenarios
  )('U (%s): the generic quick undo gives back the exact pre-op document, ids included', async (_name, payload) => {
    const { view } = await makeEditor();
    await load(DOC);
    const before = view.state.doc;
    const first = replaceRangeEditorFirst(OP, payload());
    expect(first.ok, `reason: ${first.reason}`).toBe(true);
    expect(view.state.doc.eq(before)).toBe(false);

    expect(pressUndo(view, OP), 'Cmd-Z routes to the replace').toBe(true);
    const u = undoSectionDeleteEditorFirst(OP);

    expect(u.ok, `reason: ${u.reason}`).toBe(true);
    expect(view.state.doc.eq(before), 'the exact pre-op document is back').toBe(true);
    expect(idsInOrder()).toEqual(DOC.map((s) => s.name));
    swiftFinishesUndo(OP, { redoTopOpId: OP });
    // And block-sync is running against the restored document: typing is an update of the original id.
    typeInto(view, 'B body', ' later');
    flushPendingBlockChanges();
    const diff = getBlockChangesApi();
    expect(diff.updates.map((x) => x.id)).toEqual(['pb']);
    expect(diff.inserts).toEqual([]);
  });

  it.each(
    scenarios
  )('R (%s): the quick redo gives the SAME ids as the first click, and typing in the redone content is an update of them', async (_name, payload) => {
    const { view } = await makeEditor();
    await load(DOC);
    const first = replaceRangeEditorFirst(OP, payload());
    expect(first.ok).toBe(true);
    const idsAfterFirst = idsInOrder();
    const docAfterFirst = view.state.doc;
    expect(pressUndo(view, OP)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP).ok).toBe(true);
    swiftFinishesUndo(OP, { redoTopOpId: OP });
    getBlockChangesApi();

    expect(pressRedo(view, OP), 'Cmd-Shift-Z routes to the undone replace').toBe(true);
    const redo = redoReplaceRangeEditorFirst(OP, payload());

    expect(redo.ok, `reason: ${redo.reason}`).toBe(true);
    expect(redo.insertedIds, 'the redo reuses the ids of the first click').toEqual(first.insertedIds);
    expect(idsInOrder()).toEqual(idsAfterFirst);
    expect(view.state.doc.eq(docAfterFirst), 'and gives the same document').toBe(true);
    swiftFinishesRedo(OP, { undoTopOpId: OP });
    const typedStart = { whole: 'Whole body.', section: 'A restored body', insertAfter: 'Inserted body.' }[
      _name
    ] as string;
    typeIntoNth(view, typedStart, 0, ' typed');
    flushPendingBlockChanges();
    const diff = getBlockChangesApi();
    expect(diff.inserts).toEqual([]);
    expect(diff.updates.map((x) => x.id)).toEqual([first.insertedIds[1] ?? first.insertedIds[0]]);
  });

  it('R-gate: a redo whose gate finds the document changed since the press touches nothing and consumes nothing', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    expect(replaceRangeEditorFirst(OP, sectionA()).ok).toBe(true);
    expect(pressUndo(view, OP)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP).ok).toBe(true);
    swiftFinishesUndo(OP, { redoTopOpId: OP });
    await sleep(160);
    getBlockChangesApi();
    expect(pressRedo(view, OP)).toBe(true);
    typeInto(view, 'B body', ' typed after the press');
    const docBefore = view.state.doc;
    const entryBefore = getRegistry().get(OP);

    const redo = redoReplaceRangeEditorFirst(OP, sectionA());

    expect(redo.ok).toBe(false);
    expect(redo.reason).toBe('docChanged');
    expect(redo.batch, 'a refusal consumes nothing').toEqual(EMPTY_BATCH);
    expect(redo.insertedIds).toEqual([]);
    expect(view.state.doc.eq(docBefore)).toBe(true);
    expect(getRegistry().get(OP), 'the undone entry is untouched').toBe(entryBefore);
    await sleep(160);
    expect(getBlockChangesApi().updates.map((u) => u.id)).toEqual(['pb']);
    receiveRedoOutcome(OP, 'failed');
  });

  it('R-fail: a redo whose replace is refused leaves the undone entry in place', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    expect(replaceRangeEditorFirst(OP, sectionA()).ok).toBe(true);
    expect(pressUndo(view, OP)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP).ok).toBe(true);
    swiftFinishesUndo(OP, { redoTopOpId: OP });
    expect(pressRedo(view, OP)).toBe(true);
    const entryBefore = getRegistry().get(OP);
    const docBefore = view.state.doc;

    const redo = redoReplaceRangeEditorFirst(OP, { ...sectionA(), blockIds: ['a'] }); // the ids no longer fit

    expect(redo.ok).toBe(false);
    expect(redo.reason).toBe('idAlignment');
    expect(view.state.doc.eq(docBefore)).toBe(true);
    expect(getRegistry().get(OP), 'the entry the redo replaced is put back untouched').toBe(entryBefore);
    receiveRedoOutcome(OP, 'failed');
  });

  it('S: a second restore after a first: ids stay consistent and both undo, newest first, back to the exact documents', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    const original = view.state.doc;
    expect(replaceRangeEditorFirst(OP, sectionA()).ok).toBe(true);
    const afterFirst = view.state.doc;
    const idsAfterFirst = idsInOrder();
    expect(idsAfterFirst).toEqual(['h1', 'p1', 'a', 'pa2', 'b', 'pb']);
    const second = replaceRangeEditorFirst(OP_2, whole());
    expect(second.ok, `reason: ${second.reason}`).toBe(true);
    expect(idsInOrder()).toEqual(['w1', 'w2', 'w3', 'w4']);

    expect(pressUndo(view, OP_2, {})).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP_2).ok).toBe(true);
    expect(view.state.doc.eq(afterFirst), 'the second restore is undone').toBe(true);
    expect(idsInOrder()).toEqual(idsAfterFirst);
    swiftFinishesUndo(OP_2, { undoTopOpId: OP, redoTopOpId: OP_2 });

    expect(pressUndo(view, OP, { redoTopOpId: OP_2 })).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP).ok).toBe(true);
    expect(view.state.doc.eq(original), 'the first restore is undone').toBe(true);
    expect(idsInOrder()).toEqual(DOC.map((s) => s.name));
    swiftFinishesUndo(OP, { redoTopOpId: OP });
  });
});

describe('replaceRangeEditorFirst: what the dispatch looks like', () => {
  it('T1: the replace is ONE transaction, tagged, and not added to the text history', async () => {
    const { view } = await makeEditor();
    await load(DOC);
    const seen: Array<{ tag: unknown; addToHistory: unknown; steps: number }> = [];
    const dispatch = view.dispatch;
    view.dispatch = (tr) => {
      if (tr.docChanged) {
        seen.push({
          tag: tr.getMeta('structuralReplace'),
          addToHistory: tr.getMeta('addToHistory'),
          steps: tr.steps.length,
        });
      }
      dispatch(tr);
    };

    replaceRangeEditorFirst(OP, sectionA());

    expect(seen[0], 'the first document change is the one tagged replace, kept out of the text history').toEqual({
      tag: true,
      addToHistory: false,
      steps: 1,
    });
    expect(seen.slice(1).every((t) => t.addToHistory === false && t.tag === undefined)).toBe(true);
  });

  it('T2: the new blocks paint their payload ids in the DOM, never a temp id', async () => {
    const { view } = await makeEditor();
    await load(DOC);

    const r = replaceRangeEditorFirst(OP, insertAfterPa());

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    const painted = Array.from(view.dom.querySelectorAll('[data-block-id]')).map((el) =>
      el.getAttribute('data-block-id')
    );
    expect(painted).toEqual(idsInOrder());
    expect(painted.some((id) => id?.startsWith('temp-'))).toBe(false);
  });

  it('T3: the trace line names the mode, the op and the outcome (success carries the counts and the timings)', async () => {
    const { posted } = await makeEditor();
    await load(DOC);

    expect(replaceRangeEditorFirst(OP, sectionA()).ok).toBe(true);
    expect(replaceRangeEditorFirst(OP_2, { ...whole(), blockIds: [] }).ok).toBe(false);

    const lines = replaceTraces(posted);
    expect(lines[0]).toMatch(
      /^\[STRUCT-TRACE\] replace-editor-first mode=section opId=dddddddd ok=true inserted=2 removed=2 leaders=1 batchUpdates=0 batchInserts=0 batchDeletes=0 jsMs total=\d+ /
    );
    expect(lines[1]).toMatch(
      /^\[STRUCT-TRACE\] replace-editor-first mode=whole opId=eeeeeeee ok=false reason=idAlignment detail=count: nodes=4 ids=0$/
    );
  });

  it('T4: the redo traces under its own label', async () => {
    const { view, posted } = await makeEditor();
    await load(DOC);
    expect(replaceRangeEditorFirst(OP, insertAfterPa()).ok).toBe(true);
    expect(pressUndo(view, OP)).toBe(true);
    expect(undoSectionDeleteEditorFirst(OP).ok).toBe(true);
    swiftFinishesUndo(OP, { redoTopOpId: OP });
    expect(pressRedo(view, OP)).toBe(true);

    expect(redoReplaceRangeEditorFirst(OP, insertAfterPa()).ok).toBe(true);

    expect(replaceTraces(posted).pop()).toMatch(
      /^\[STRUCT-TRACE\] replace-redo-editor-first mode=insertAfter opId=dddddddd ok=true /
    );
    swiftFinishesRedo(OP, { undoTopOpId: OP });
  });
});
