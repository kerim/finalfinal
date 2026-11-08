// @vitest-environment jsdom
//
// Phase 4b slice 2, round 2c (t-18b7fa48), V2-3: the cross-language proof for the editor-first Version History restores.
//
// A restore hands the editor a payload built by Swift (`StructuralUndoController.editorPayload(for:)`: the Markdown, one id per
// top-level node, what each node is expected to be, the image metadata, the bibliography span and the managed ids) for rows that are
// not in the database yet. The ids only help if they line up with the editor's OWN parse of that Markdown, node for node. Swift's
// `BlockParser.alignmentPairs` decides the ids and types; the editor's parse decides the nodes. These tests load the payloads the
// REAL Swift code produced (fixtures/alignment-*.json, written by `RestorePrimitivesTests.testWriteAlignmentFixtures` from the real
// article, the real six-chapter book and a section fragment with a tight list, a loose list, an ordered list and a figure) into an
// editor built with the production plugins that decide the top-level structure, and assert:
//   - the parse has exactly one top-level node per id, of the type Swift expected, with zero alignment mismatches;
//   - the editor-first replace ('whole' mode) accepts the payload, holds exactly those ids, and builds the SAME document as the
//     whole-document push (`setContentWithBlockIds`) does for it;
//   - the fragment fixture also works in 'section' and 'insertAfter' mode, with its figure taking its image metadata;
//   - a payload with an id missing is refused with `idAlignment`.
// It also prints how long the whole-document replace of each fixture takes in jsdom. That number is NOT asserted (jsdom timing says
// little); the real one comes from the VM end-to-end run.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { ANNOTATION_NODE_NAME } from '../annotation-delete';
import { annotationPlugin } from '../annotation-plugin';
import { setContentWithBlockIds } from '../api-content';
import { type ReplaceRangePayload, replaceRangeEditorFirst } from '../api-structural-replace';
import { bibliographyEndMarkerPlugin } from '../bibliography-end-marker-plugin';
import { bibliographyPlugin } from '../bibliography-plugin';
import { alignTopLevelIds, isBlockType, pmTypeForBlockType } from '../block-id-plugin';
import { citationPlugin } from '../citation-plugin';
import { footnotePlugin } from '../footnote-plugin';
import { imagePlugin } from '../image-plugin';
import { mathPlugin } from '../math-plugin';
import type { ExpectedBlockMeta, ImageBlockMeta } from '../types';
import {
  EMPTY_BATCH,
  heading,
  idsInOrder,
  load,
  makeEditor,
  markdownOf,
  type Posted,
  para,
  sleep,
  waitForRAF,
} from './editor-first-harness';
import { takePendingAsReport } from './pending-for-test';

const OP = 'dddddddd-2222-3333-4444-555555555555';

/** The shape of fixtures/alignment-*.json (Swift's `BlockFetchResult`, ids normalised to blk-0001...). */
interface Fixture {
  name: string;
  markdown: string;
  blockIds: string[];
  expectedBlocks: ExpectedBlockMeta[];
  imageMeta: ImageBlockMeta[];
  bibBoundaryIndex?: number;
  bibBoundaryEndIndex?: number;
  managedBlockIds: string[];
}

function fixture(name: string): Fixture {
  const path = join(dirname(fileURLToPath(import.meta.url)), 'fixtures', `alignment-${name}.json`);
  return JSON.parse(readFileSync(path, 'utf8')) as Fixture;
}

/** The production plugins that decide the top-level structure of a parse (main.ts order; the harness adds the section break, the
 * commonmark and gfm presets, the highlight, block-id, history and block-sync plugins). */
const PRODUCTION_PARSE_PLUGINS = [
  bibliographyPlugin,
  bibliographyEndMarkerPlugin,
  annotationPlugin,
  citationPlugin,
  mathPlugin,
  footnotePlugin,
  imagePlugin,
];

/** Node types each fixture must produce, so the test cannot pass with the parse plugins missing. */
const LIVE_NODES: Record<string, string[]> = {
  article: ['citation', 'footnote_ref', 'footnote_def', 'auto_bibliography_end', ANNOTATION_NODE_NAME],
  book6: ['citation', 'footnote_ref', 'footnote_def', 'auto_bibliography_end', ANNOTATION_NODE_NAME],
  looseListSection: ['figure', 'bullet_list', 'ordered_list'],
};

function wholePayload(f: Fixture): ReplaceRangePayload {
  return {
    mode: 'whole',
    markdown: f.markdown,
    blockIds: f.blockIds,
    expectedBlocks: f.expectedBlocks,
    managedIds: [],
    imageMeta: f.imageMeta,
    bibBoundaryIndex: f.bibBoundaryIndex,
    bibBoundaryEndIndex: f.bibBoundaryEndIndex,
    managedBlockIds: f.managedBlockIds,
  };
}

const OLD_DOC = [heading('old-1', 1, 'Old title'), para('old-2', 'Old body.'), heading('old-3', 2, 'Old sub')];

function replaceTraces(posted: Posted): string[] {
  return posted
    .filter((p) => p.handler === 'errorHandler' && typeof p.body?.message === 'string')
    .map((p) => p.body.message as string)
    .filter((m) => m.startsWith('[STRUCT-TRACE] replace'));
}

describe.each(['article', 'book6', 'looseListSection'])('the Swift payload for %s against the editor', (name) => {
  const f = fixture(name);
  const slow = { timeout: 180_000 };

  it(
    `V2-3a (${name}): the editor's parse has one top-level node per id, of the expected type, with zero mismatches`,
    slow,
    async () => {
      const { view } = await makeEditor(PRODUCTION_PARSE_PLUGINS);
      setContentWithBlockIds(f.markdown, f.blockIds, {
        expected: f.expectedBlocks,
        imageMeta: f.imageMeta,
        managedBlockIds: f.managedBlockIds,
        cursorBoundary: f.bibBoundaryIndex,
        cursorBoundaryEnd: f.bibBoundaryEndIndex,
      });
      await waitForRAF();

      // The production plugins are live: what they parse is not left behind as text, and their node types are in the document.
      const nodeNames = new Set<string>();
      view.state.doc.descendants((node) => {
        nodeNames.add(node.type.name);
      });
      for (const required of LIVE_NODES[name] ?? []) expect(nodeNames, `${required} is parsed`).toContain(required);
      expect(view.state.doc.textContent, 'citations are atoms, not text').not.toContain('[@');

      const types: string[] = [];
      view.state.doc.forEach((node) => {
        if (isBlockType(node)) types.push(node.type.name);
      });
      expect(types.length, 'one top-level node per Swift id').toBe(f.blockIds.length);
      expect(types, 'the types Swift expected').toEqual(f.expectedBlocks.map((e) => pmTypeForBlockType(e.blockType)));
      const aligned = alignTopLevelIds(f.blockIds, view.state.doc, f.expectedBlocks);
      expect(aligned.mismatches, 'no withheld ids').toEqual([]);
      expect(aligned.walked).toBe(f.blockIds.length);
      expect(idsInOrder(), 'the editor holds exactly the ids Swift sent').toEqual(f.blockIds);
    }
  );

  it(
    `V2-3b (${name}): the editor-first whole replace takes the payload and builds the same document as the whole-document push`,
    slow,
    async () => {
      const { view, posted } = await makeEditor(PRODUCTION_PARSE_PLUGINS);
      await load(OLD_DOC);

      // Route 1: the whole-document push.
      setContentWithBlockIds(f.markdown, f.blockIds, {
        expected: f.expectedBlocks,
        imageMeta: f.imageMeta,
        managedBlockIds: f.managedBlockIds,
        cursorBoundary: f.bibBoundaryIndex,
        cursorBoundaryEnd: f.bibBoundaryEndIndex,
      });
      await waitForRAF();
      const pushed = JSON.stringify(view.state.doc.toJSON());
      expect(idsInOrder()).toEqual(f.blockIds);

      // Back to the old document, then route 2: the editor-first replace.
      setContentWithBlockIds(
        markdownOf(OLD_DOC),
        OLD_DOC.map((s) => s.name)
      );
      await waitForRAF();
      takePendingAsReport();
      expect(idsInOrder()).toEqual(OLD_DOC.map((s) => s.name));

      const start = performance.now();
      const r = replaceRangeEditorFirst(OP, wholePayload(f));
      const ms = performance.now() - start;

      expect(r.ok, `reason: ${r.reason}`).toBe(true);
      expect(idsInOrder(), 'the editor holds exactly the ids Swift sent').toEqual(f.blockIds);
      expect(r.insertedIds).toEqual(f.blockIds);
      expect(JSON.stringify(view.state.doc.toJSON()), 'the same document as the push builds').toBe(pushed);
      await sleep(160);
      expect(takePendingAsReport(), 'the replace queues nothing').toEqual(EMPTY_BATCH);
      // Measurement only (no assertion on time): jsdom says little, the VM end-to-end run gives the real number.
      const jsMs = replaceTraces(posted)
        .filter((line) => line.includes('ok=true'))
        .map((line) => line.slice(line.indexOf('jsMs')))
        .pop();
      console.info(
        `[round 2c timing] whole replace of ${name}: ${f.blockIds.length} blocks, ${f.markdown.length} chars, ` +
          `${ms.toFixed(0)} ms in jsdom (${jsMs ?? 'no jsMs'})`
      );
    }
  );

  it(
    `V2-3c (${name}): a payload with one id missing is refused with idAlignment, and the document is untouched`,
    slow,
    async () => {
      const { view } = await makeEditor(PRODUCTION_PARSE_PLUGINS);
      await load(OLD_DOC);
      const before = view.state.doc;

      const r = replaceRangeEditorFirst(OP, { ...wholePayload(f), blockIds: f.blockIds.slice(1) });

      expect(r.ok).toBe(false);
      expect(r.reason).toBe('idAlignment');
      expect(view.state.doc.eq(before)).toBe(true);
      expect(idsInOrder()).toEqual(OLD_DOC.map((s) => s.name));
    }
  );
});

describe('the section fragment payload (a tight list, a loose list, an ordered list and a figure) in section and insertAfter mode', () => {
  const f = fixture('looseListSection');
  const fragmentPayload = (extra: Partial<ReplaceRangePayload>): ReplaceRangePayload => ({
    mode: 'section',
    markdown: f.markdown,
    blockIds: f.blockIds,
    expectedBlocks: f.expectedBlocks,
    managedIds: [],
    imageMeta: f.imageMeta,
    ...extra,
  });
  const figureAttrs = (view: { state: { doc: { forEach: (cb: (n: any) => void) => void } } }) => {
    const out: Array<Record<string, unknown>> = [];
    view.state.doc.forEach((node) => {
      if (node.type.name === 'figure') out.push(node.attrs);
    });
    return out;
  };

  it('V2-3d: section mode: the target heading takes the fragment, the next section is untouched, the figure holds its payload id', async () => {
    const { view } = await makeEditor(PRODUCTION_PARSE_PLUGINS);
    await load([
      heading(f.blockIds[0], 2, 'Old title'),
      para('old-body', 'Old body.'),
      heading('after', 2, 'After'),
      para('after-body', 'After body.'),
    ]);
    const before = view.state.doc;

    const r = replaceRangeEditorFirst(OP, fragmentPayload({ rootBlockId: f.blockIds[0] }));

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(idsInOrder()).toEqual([...f.blockIds, 'after', 'after-body']);
    expect(r.removedIds).toEqual([f.blockIds[0], 'old-body']);
    expect(view.state.doc.child(f.blockIds.length).eq(before.child(2)), 'the next section is untouched').toBe(true);
    const figures = figureAttrs(view);
    expect(figures).toHaveLength(1);
    expect(figures[0].blockId, 'the figure holds its payload id').toBe(f.imageMeta[0].id);
    // The EDITOR's own top-level nodes (fix round F1, review C9a): the fixture's `expectedBlocks` is what Swift expects, so counting it
    // proves nothing about the editor. The tight and the loose list of the fragment are ONE bullet-list node in the editor's document.
    let editorBulletLists = 0;
    view.state.doc.forEach((node) => {
      if (node.type.name === 'bullet_list') editorBulletLists += 1;
    });
    expect(editorBulletLists, 'the loose list is ONE node in the editor, with one id').toBe(1);
  });

  it('V2-3e: insertAfter mode: the fragment lands after the anchor with the same ids', async () => {
    const { view } = await makeEditor(PRODUCTION_PARSE_PLUGINS);
    await load([heading('top', 1, 'Top'), para('top-body', 'Top body.'), heading('next', 1, 'Next')]);

    const r = replaceRangeEditorFirst(OP, fragmentPayload({ mode: 'insertAfter', anchorBlockId: 'top-body' }));

    expect(r.ok, `reason: ${r.reason}`).toBe(true);
    expect(idsInOrder()).toEqual(['top', 'top-body', ...f.blockIds, 'next']);
    expect(figureAttrs(view)[0].blockId).toBe(f.imageMeta[0].id);
    expect(r.insertedLeaderIds).toEqual([f.blockIds[0]]);
  });
});
