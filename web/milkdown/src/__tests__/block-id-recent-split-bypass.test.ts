// @vitest-environment jsdom
import { type Node, Schema } from '@milkdown/kit/prose/model';
import { beforeEach, describe, expect, it } from 'vitest';
import {
  applyPendingConfirmations,
  assignBlockIds,
  canClaimViaRecentSplitBypass,
  confirmBlockId,
  getAllBlockIds,
  getRecentlySplitEmptyIds,
  phase1CanClaim,
  resetBlockIdState,
  setBlockIdsForTopLevel,
} from '../block-id-plugin';

// Regression suite for the split-then-fill ID-orphaning bug.
//
// The bug: a user splits a block (Enter creates a new empty paragraph) and
// then, in a SEPARATE sync cycle, fills that empty paragraph with content.
// `phase1CanClaim()` defers to `meaningfulTextOverlap(oldText, newText)` when
// `structureChanged` is true, and that function has a deliberate
// `if (oldText === '' || newText === '') return false` guard (anti-ID-theft
// protection) that can't distinguish a legitimate split-then-fill from actual
// theft — so the fill can't reclaim the empty paragraph's own id, orphaning
// it and misanchoring the filled content.
//
// The fix: `recentlySplitEmptyIds` marks ids that were just created empty by
// a structural split. `canClaimViaRecentSplitBypass` lets a later structural
// claim bypass `meaningfulTextOverlap` for a marked, still-empty id. The
// marker is pruned once its id either stops existing or stops being empty.

const NO_CLAIMED: ReadonlySet<string> = new Set();

describe('canClaimViaRecentSplitBypass — pure predicate', () => {
  it('unmarked id, empty oldText, non-empty newText → false (baseline)', () => {
    expect(canClaimViaRecentSplitBypass('', 'Filled text', 'id-a', new Set())).toBe(false);
  });

  it('marked id, empty oldText, non-empty newText → true (the fix)', () => {
    expect(canClaimViaRecentSplitBypass('', 'Filled text', 'id-a', new Set(['id-a']))).toBe(true);
  });

  it('marked id, NON-EMPTY oldText → false (gate stays load-bearing even when marked)', () => {
    expect(canClaimViaRecentSplitBypass('Some old text', 'Filled text', 'id-a', new Set(['id-a']))).toBe(false);
  });

  it('marked id, empty oldText, empty newText → true (sanity: marking does not change already-correct behavior)', () => {
    expect(canClaimViaRecentSplitBypass('', '', 'id-a', new Set(['id-a']))).toBe(true);
  });

  it('unmarked id, ordinary prefix/suffix overlap → true (passthrough sanity check)', () => {
    expect(canClaimViaRecentSplitBypass('Intro', 'Introduction', 'id-a', new Set())).toBe(true);
  });
});

describe('phase1CanClaim — recentlySplitEmptyIds bypass (8th argument)', () => {
  it('same-type branch: marked id, structural, empty oldText, filled newText → true', () => {
    const marked = new Set(['id-a']);
    expect(phase1CanClaim('paragraph', 'paragraph', 'id-a', NO_CLAIMED, true, '', 'Filled text', marked)).toBe(true);
  });

  it('cross-type branch: marked id, structural, empty oldText, filled newText → true (tested independently of the same-type branch)', () => {
    const marked = new Set(['id-a']);
    expect(phase1CanClaim('heading', 'paragraph', 'id-a', NO_CLAIMED, true, '', 'Filled text', marked)).toBe(true);
  });

  it('unmarked id: structural, empty oldText, filled newText → false (pre-existing contract unchanged)', () => {
    expect(phase1CanClaim('paragraph', 'paragraph', 'id-a', NO_CLAIMED, true, '', 'Filled text')).toBe(false);
  });
});

// ============================================================
// Deterministic multi-pass assignBlockIds tests
// ============================================================

const schema = new Schema({
  nodes: {
    doc: { content: 'block+' },
    paragraph: { group: 'block', content: 'inline*', toDOM: () => ['p', 0] },
    text: { group: 'inline' },
  },
});

function para(text: string): Node {
  return schema.nodes.paragraph.create(null, text ? [schema.text(text)] : []);
}

describe('assignBlockIds — recently-split-empty marker (multi-pass)', () => {
  beforeEach(() => {
    // recentlySplitEmptyIds/pendingConfirmations/currentBlockIds are module-level
    // state, not per-call — clear before each case so tests can't leak into,
    // or be polluted by, each other.
    resetBlockIdState();
  });

  it('core regression: pass 1 splits and marks a fresh empty id; pass 2 fills it under the SAME id and consumes the marker', () => {
    // Pass 1: split. A single paragraph becomes two — the original text
    // slides down, and a new empty paragraph appears at its old offset's
    // sibling slot. Force structureChanged via a 1-vs-2 block-count change.
    const oldDoc = schema.nodes.doc.create(null, [para('Hello world')]);
    const existingIds = new Map<number, string>([[0, 'id-1']]);
    const existingTypes = new Map<number, string>([[0, 'paragraph']]);
    const docSplit = schema.nodes.doc.create(null, [para('Hello world'), para('')]);

    const [idsAfterSplit, typesAfterSplit] = assignBlockIds(docSplit, existingIds, existingTypes, oldDoc);

    const helloSize = para('Hello world').nodeSize;
    const splitId = idsAfterSplit.get(helloSize);
    expect(splitId).toBeDefined();
    expect(splitId?.startsWith('temp-')).toBe(true);
    expect(idsAfterSplit.get(0)).toBe('id-1'); // original paragraph keeps its own id
    expect(getRecentlySplitEmptyIds().has(splitId!)).toBe(true);

    // Pass 2: fill the empty paragraph AND append an unrelated paragraph in
    // the same transaction — forcing structureChanged=true again, so it's
    // Phase-1's bypass being exercised here, not the `!structureChanged`
    // early-return (which would trivially pass regardless of this fix).
    const docFilled = schema.nodes.doc.create(null, [para('Hello world'), para('Filled text'), para('New appended')]);
    const [idsAfterFill] = assignBlockIds(docFilled, idsAfterSplit, typesAfterSplit, docSplit);

    expect(idsAfterFill.get(helloSize)).toBe(splitId); // SAME id, not a fresh one
    expect(getRecentlySplitEmptyIds().has(splitId!)).toBe(false); // marker consumed
  });

  it('expiry/consumption: the marker does not linger past its real validity window', () => {
    const oldDoc = schema.nodes.doc.create(null, [para('Hello world')]);
    const existingIds = new Map<number, string>([[0, 'id-1']]);
    const existingTypes = new Map<number, string>([[0, 'paragraph']]);
    const docSplit = schema.nodes.doc.create(null, [para('Hello world'), para('')]);
    const [idsAfterSplit, typesAfterSplit] = assignBlockIds(docSplit, existingIds, existingTypes, oldDoc);
    const helloSize = para('Hello world').nodeSize;
    const splitId = idsAfterSplit.get(helloSize)!;

    const docFilled = schema.nodes.doc.create(null, [para('Hello world'), para('Filled text'), para('New appended')]);
    assignBlockIds(docFilled, idsAfterSplit, typesAfterSplit, docSplit);

    // Immediately after consumption, the bypass must refuse to use the
    // (now-stale) marker for a brand new claim.
    expect(canClaimViaRecentSplitBypass('', 'anything else', splitId, getRecentlySplitEmptyIds())).toBe(false);
  });

  it('Phase-2 proximity: an offset-shifted fill is caught by the greedy loop, and a farther unrelated candidate does not steal it', () => {
    const oldDoc = schema.nodes.doc.create(null, [para('Hello world')]);
    const existingIds = new Map<number, string>([[0, 'id-1']]);
    const existingTypes = new Map<number, string>([[0, 'paragraph']]);
    const docSplit = schema.nodes.doc.create(null, [para('Hello world'), para('')]);
    const [idsAfterSplit, typesAfterSplit] = assignBlockIds(docSplit, existingIds, existingTypes, oldDoc);
    const helloSize = para('Hello world').nodeSize;
    const splitId = idsAfterSplit.get(helloSize)!;
    expect(getRecentlySplitEmptyIds().has(splitId)).toBe(true);

    // Fill pass: a short, unrelated paragraph is inserted BEFORE everything,
    // shifting the fill's offset so Phase 1's exact-position check misses it
    // — only Phase 2's proximity/greedy loop can reunite it with splitId. A
    // farther unrelated paragraph is appended after the fill as a competing,
    // farther candidate for the same marked id (the bypass is content-
    // agnostic, so it too generates a valid — but farther — candidate pair).
    const insertedLead = para('Zzz');
    const filled = para('Filled text');
    const farUnrelated = para('Something completely unrelated over here');
    const docFilled = schema.nodes.doc.create(null, [insertedLead, para('Hello world'), filled, farUnrelated]);
    const [idsAfterFill] = assignBlockIds(docFilled, idsAfterSplit, typesAfterSplit, docSplit);

    const helloOffset = insertedLead.nodeSize;
    const filledOffset = helloOffset + helloSize;
    const farOffset = filledOffset + filled.nodeSize;

    expect(idsAfterFill.get(filledOffset)).toBe(splitId); // the real fill wins (closest)
    expect(idsAfterFill.get(farOffset)).not.toBe(splitId); // the farther candidate does not steal it
    expect(idsAfterFill.get(helloOffset)).toBe('id-1'); // the shifted (but unrelated) sibling keeps its own id
  });

  describe('rename survives at each claim site', () => {
    it('(a) Phase-1 exact claim: a rename applied via applyPendingConfirmations() survives into a later structural fill', () => {
      const oldDoc = schema.nodes.doc.create(null, [para('Hello world')]);
      const existingIds = new Map<number, string>([[0, 'id-1']]);
      const existingTypes = new Map<number, string>([[0, 'paragraph']]);
      const docSplit = schema.nodes.doc.create(null, [para('Hello world'), para('')]);
      const [idsAfterSplit, typesAfterSplit] = assignBlockIds(docSplit, existingIds, existingTypes, oldDoc);
      const helloSize = para('Hello world').nodeSize;
      const tempId = idsAfterSplit.get(helloSize)!;
      expect(getRecentlySplitEmptyIds().has(tempId)).toBe(true);

      // Sync currentBlockIds to this pass's output, mirroring production
      // (the plugin sets currentBlockIds = blockIds after each assignBlockIds call).
      setBlockIdsForTopLevel(['id-1', tempId], docSplit);

      const permanentId = 'perm-uuid-a';
      confirmBlockId(tempId, permanentId);
      const applied = applyPendingConfirmations();
      expect(applied.get(tempId)).toBe(permanentId);
      expect(getRecentlySplitEmptyIds().has(permanentId)).toBe(true); // marker moved
      expect(getRecentlySplitEmptyIds().has(tempId)).toBe(false);

      const idsAfterConfirm = getAllBlockIds();
      const docFilled = schema.nodes.doc.create(null, [para('Hello world'), para('Filled text'), para('Appended')]);
      const [idsAfterFill] = assignBlockIds(docFilled, idsAfterConfirm, typesAfterSplit, docSplit);

      expect(idsAfterFill.get(helloSize)).toBe(permanentId); // fill succeeds under the NEW permanent id
    });

    it('(b) Phase-2 greedy: a pending confirmation resolves inside the proximity loop and moves the marker', () => {
      const oldDoc = schema.nodes.doc.create(null, [para('Hello world')]);
      const existingIds = new Map<number, string>([[0, 'id-1']]);
      const existingTypes = new Map<number, string>([[0, 'paragraph']]);
      const docSplit = schema.nodes.doc.create(null, [para('Hello world'), para('')]);
      const [idsAfterSplit, typesAfterSplit] = assignBlockIds(docSplit, existingIds, existingTypes, oldDoc);
      const helloSize = para('Hello world').nodeSize;
      const tempId = idsAfterSplit.get(helloSize)!;
      expect(getRecentlySplitEmptyIds().has(tempId)).toBe(true);

      // Confirmation arrives but is left pending (not applied immediately) —
      // the next structural pass must resolve it itself.
      const permanentId = 'perm-uuid-b';
      confirmBlockId(tempId, permanentId);

      // Collapse to a single remaining block. Its own old slot ('Hello
      // world', offset 0) cannot satisfy the content check for this new
      // text, so only the marked tempId slot — reached via Phase 2's
      // proximity/greedy loop, not Phase 1's exact-offset match — can claim
      // it, forcing resolution through the greedy loop specifically.
      const docFilled = schema.nodes.doc.create(null, [para('Filled text')]);
      const [idsAfterFill] = assignBlockIds(docFilled, idsAfterSplit, typesAfterSplit, docSplit);

      expect(idsAfterFill.get(0)).toBe(permanentId); // resolved via the greedy loop, not the stale temp id
      expect(getRecentlySplitEmptyIds().has(tempId)).toBe(false);
      expect(getRecentlySplitEmptyIds().has(permanentId)).toBe(false); // consumed (node is no longer empty)
    });

    it('(c) structure-unchanged branch: a rename resolved there survives into a later structural fill', () => {
      const oldDoc = schema.nodes.doc.create(null, [para('Hello world')]);
      const existingIds = new Map<number, string>([[0, 'id-1']]);
      const existingTypes = new Map<number, string>([[0, 'paragraph']]);
      const docSplit = schema.nodes.doc.create(null, [para('Hello world'), para('')]);
      const [idsAfterSplit, typesAfterSplit] = assignBlockIds(docSplit, existingIds, existingTypes, oldDoc);
      const helloSize = para('Hello world').nodeSize;
      const tempId = idsAfterSplit.get(helloSize)!;
      expect(getRecentlySplitEmptyIds().has(tempId)).toBe(true);

      // Confirmation arrives, left pending.
      const permanentId = 'perm-uuid-c';
      confirmBlockId(tempId, permanentId);

      // Non-structural pass: the preceding sibling's text grows in place
      // (same block count, so structureChanged=false) while the marked node
      // stays empty — just shifted to a new offset. This can only be
      // resolved by the structure-unchanged per-block proximity branch, not
      // Phase 1 (whose exact-offset lookup misses the shifted node) or
      // Phase 2's greedy loop (which only runs when structureChanged=true).
      const docShifted = schema.nodes.doc.create(null, [para('Hello world EXTENDED'), para('')]);
      const [idsAfterRename, typesAfterRename] = assignBlockIds(docShifted, idsAfterSplit, typesAfterSplit, docSplit);

      const shiftedOffset = para('Hello world EXTENDED').nodeSize;
      expect(idsAfterRename.get(shiftedOffset)).toBe(permanentId); // renamed via resolveConfirmedId there
      expect(getRecentlySplitEmptyIds().has(permanentId)).toBe(true); // still empty — marker survives
      expect(getRecentlySplitEmptyIds().has(tempId)).toBe(false);

      // Later structural pass: fill the still-marked node under its new
      // permanent id, forcing structureChanged via an appended paragraph.
      const docFilled = schema.nodes.doc.create(null, [
        para('Hello world EXTENDED'),
        para('Now filled'),
        para('Extra append'),
      ]);
      const [idsAfterFill] = assignBlockIds(docFilled, idsAfterRename, typesAfterRename, docShifted);

      expect(idsAfterFill.get(shiftedOffset)).toBe(permanentId); // fill succeeds under the permanent id
      expect(getRecentlySplitEmptyIds().has(permanentId)).toBe(false); // consumed
    });
  });

  // Regression test for the over-broad-marking bug: sites (1) and (2) used to
  // mark ANY existing id that resolved to empty text during ANY structural
  // pass — including ids that predate the transaction entirely and have
  // nothing to do with a recent split. That reopened the ID-theft exposure
  // meaningfulTextOverlap's empty-vs-empty gate exists to close, for every
  // long-lived blank block in the document, not just fresh splits.
  it('pre-existing blank block is NOT marked when an unrelated structural change fires elsewhere', () => {
    // Seed state: a blank paragraph's id is already part of the baseline —
    // NOT produced by a split within this test — modeling a long-lived blank
    // block that predates this transaction.
    const helloSize = para('Hello world').nodeSize;
    const oldDoc = schema.nodes.doc.create(null, [para('Hello world'), para('')]);
    const existingIds = new Map<number, string>([
      [0, 'id-1'],
      [helloSize, 'blank-id-preexisting'],
    ]);
    const existingTypes = new Map<number, string>([
      [0, 'paragraph'],
      [helloSize, 'paragraph'],
    ]);

    // Structural change happens ONLY at the end of the doc (an unrelated
    // append) — the blank block itself is untouched, still empty, same offset.
    const docChanged = schema.nodes.doc.create(null, [para('Hello world'), para(''), para('New unrelated')]);
    const [idsAfterChange] = assignBlockIds(docChanged, existingIds, existingTypes, oldDoc);

    // The blank block correctly keeps its own id (trivial empty===empty match)...
    expect(idsAfterChange.get(helloSize)).toBe('blank-id-preexisting');
    // ...but must NOT be (re-)marked as "recently split" — it wasn't split by
    // anything in this transaction, and structureChanged firing elsewhere in
    // the doc must not sweep it into the bypass's eligible population.
    expect(getRecentlySplitEmptyIds().has('blank-id-preexisting')).toBe(false);
  });

  it('marker survives an intervening unrelated structural pass across 3 passes, without needing re-marking', () => {
    // Pass 1: genuine split. A single paragraph becomes two; the new empty
    // paragraph is minted a temp id via the temp-ID loop (site 3) and
    // correctly marked.
    const oldDoc = schema.nodes.doc.create(null, [para('Hello world')]);
    const existingIds = new Map<number, string>([[0, 'id-1']]);
    const existingTypes = new Map<number, string>([[0, 'paragraph']]);
    const docSplit = schema.nodes.doc.create(null, [para('Hello world'), para('')]);
    const [idsAfterSplit, typesAfterSplit] = assignBlockIds(docSplit, existingIds, existingTypes, oldDoc);

    const helloSize = para('Hello world').nodeSize;
    const splitId = idsAfterSplit.get(helloSize)!;
    expect(splitId.startsWith('temp-')).toBe(true);
    expect(getRecentlySplitEmptyIds().has(splitId)).toBe(true);

    // Pass 2: a structural change SOMEWHERE ELSE (an unrelated append at the
    // end) — the still-empty split node is untouched, stays empty, and is
    // claimed via ordinary ''===''  overlap (not the bypass) through Phase 1's
    // exact-position match.
    const docPass2 = schema.nodes.doc.create(null, [para('Hello world'), para(''), para('Unrelated new')]);
    const [idsAfterPass2, typesAfterPass2] = assignBlockIds(docPass2, idsAfterSplit, typesAfterSplit, docSplit);

    expect(idsAfterPass2.get(helloSize)).toBe(splitId); // still the same id, still empty
    // The marker must survive this intervening pass — it was never touched by
    // this pass's own marking logic (sites 1/2 no longer mark at all; the
    // entry persists in the Set from pass 1 and isn't pruned because the node
    // is still empty).
    expect(getRecentlySplitEmptyIds().has(splitId)).toBe(true);

    // Pass 3: fill the still-empty split node (forced structural again via an
    // appended paragraph). The fill must claim the SAME id from pass 1 via the
    // bypass — oldText==='' (from docPass2) and the marker (surviving since
    // pass 1, untouched by pass 2) makes canClaimViaRecentSplitBypass true.
    const docPass3 = schema.nodes.doc.create(null, [
      para('Hello world'),
      para('Filled text'),
      para('Unrelated new'),
      para('Another append'),
    ]);
    const [idsAfterPass3] = assignBlockIds(docPass3, idsAfterPass2, typesAfterPass2, docPass2);

    expect(idsAfterPass3.get(helloSize)).toBe(splitId); // SAME id from pass 1, not a fresh one
    expect(getRecentlySplitEmptyIds().has(splitId)).toBe(false); // consumed — node is no longer empty
  });
});
