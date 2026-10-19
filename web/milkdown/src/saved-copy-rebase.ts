// Saved-copy rebase (t-dfc4fb02): lets a structural operation's saved post-operation document follow an automatic
// change that lands AFTER the user started typing.
//
// The problem. After a section delete the editor keeps a saved copy of the document as it stood right after the
// operation (`UndoRegistryEntry.postOpDoc`). Cmd-Z routes to the structural undo when the live document equals that
// copy (or is equivalent to it modulo what the app regenerates; derived-equivalence.ts). Automatic rewrites that land
// while the document still equals the saved copy move it forward with the document (`advanceRegistryEntries`). Once the
// user has typed, the document no longer equals the saved copy, so the next automatic rewrite (the Notes and
// bibliography rebuild) was not absorbed; after the typing was undone the saved copy and the document differed by that
// rebuild for good, and the fallback comparison could refuse it (a footnote label defined twice in the saved copy).
//
// The rule. `saved` is the saved copy, `before` the live document before an automatic chain, `after` the live document
// after it. Two lists of top-level block ranges are worked out:
//   U = what the USER changed since the saved copy   = the changes from `saved` to `before`
//   R = what the AUTOMATIC chain changed             = the changes from `before` to `after`
// Each list is worked out REGION BY REGION (round F3 of t-18b7fa48), not as one diff over everything between the first
// and the last change: the blocks that are unchanged are lined up first (by identity, which ProseMirror keeps for every
// block a transaction did not touch, and by equality where identity is broken, for example after a full content
// replace), the changed blocks between two lined-up blocks form one REGION, and each region is diffed on its own. On a
// book the user's typing in chapter 1 and a Notes rebuild near the end are two small regions, however many hundred
// blocks lie between them; the old single trimmed-middle diff treated them as one region of several hundred blocks on
// each side and refused it as `too-far`, so the "type before the Notes rebuild lands, then Cmd-Z" support never
// worked on a book.
// When no block is on both lists, the chain is applied to the saved copy too, so that once the user has undone their own
// typing the document equals the saved copy again. Otherwise (or when anything does not line up) nothing is applied and
// the outcome is what it was before: the press is refused or routed by the fallback, never a wrong undo.
//
// Why the user's text can never enter the saved copy. The splice replaces blocks the chain replaced (and inserts blocks
// the chain inserted), and a block is only replaced when (a) it is not on U's list (the overlap rule), and (b) it is the
// same NOW in `saved` as in `before` (the block check), so it is a block whose content the user has not changed since the
// saved copy (a block the user typed and then fully undid is the same again, and is replaced like any other); an insertion
// replaces nothing and is kept off the user's blocks by the overlap rule. The caller adds the third limit that makes this
// safe: it only calls this for a chain with no text-history step (undo-coordinator.ts), so nothing the user's own Cmd-Z
// would take back is ever folded in.
//
// All offsets here are TOP-LEVEL BLOCK COUNTS (indices into `doc.child(i)`), never document positions.

import { Fragment, type Node } from '@milkdown/kit/prose/model';
import { type BlockChangeRange, diffTopLevelBlocks } from './api-content';

/** Most cells (old length times new length of ONE region) the user-side diff may cost for any single region. The budget is
 * per region: a region above it makes the rebase refuse with `too-far` WITHOUT running any diff (the user rewrote more
 * than a couple of hundred blocks in one stretch since the saved copy, and the app must not pay a quadratic diff on every
 * automatic chain for it); regions under it are each diffed, however many there are, because the lined-up unchanged
 * blocks keep the total linear in the document. An edit region of a few blocks costs a few cells; 50,000 cells is a
 * stretch of about 220 blocks replaced by 220 others. The chain's own regions are not budgeted here (they have always
 * been bounded by `diffTopLevelBlocks`'s own cap, which falls back to one coarse range for that region, and the block
 * check below makes a coarse range safe). This is a scope limit, not a safety one: the result is today's behaviour (the
 * saved copy stays as it is). */
export const USER_DIFF_CELL_BUDGET = 50_000;

export type SavedCopyRebaseResult = 'rebased' | 'no-change' | 'too-far' | 'overlap' | 'mismatch';

export interface SavedCopyRebase {
  /** The rebased copy, or null when nothing was applied (every result but `rebased`). */
  doc: Node | null;
  result: SavedCopyRebaseResult;
  /** Number of ranges in U, or -1 when it was not computed (`no-change`, `too-far`). */
  userRanges: number;
  /** Number of ranges in R. */
  chainRanges: number;
  /** Cells the most expensive single user-side region costs (0 when R was empty). */
  cells: number;
  /** Counts-only text of U (`describeBlockDifferences`'s format; for `too-far`, how many regions and the largest one's
   * size); '' when it was not computed. Carried for the `registry-rebase` trace line. */
  userSummary: string;
  /** Counts-only text of R; '' when R was empty. */
  chainSummary: string;
}

interface Pair {
  a: number;
  b: number;
}

/** A stretch of changed blocks between two lined-up unchanged blocks: `a[aFrom,aTo)` became `b[bFrom,bTo)`; one side may be empty. */
interface Region {
  aFrom: number;
  aTo: number;
  bFrom: number;
  bTo: number;
}

function childList(doc: Node): Node[] {
  const out: Node[] = [];
  doc.forEach((node) => {
    out.push(node);
  });
  return out;
}

/** The longest chain of `pairs` (ascending in `.a`, distinct `.b`) whose `.b` also ascends: a monotone set of true
 * equalities, which is all a diff needs from its anchors. Patience sorting, O(n log n). */
function increasingChain(pairs: Pair[]): Pair[] {
  const tails: number[] = [];
  const prev: number[] = new Array(pairs.length).fill(-1);
  for (let k = 0; k < pairs.length; k++) {
    let lo = 0;
    let hi = tails.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (pairs[tails[mid]].b < pairs[k].b) lo = mid + 1;
      else hi = mid;
    }
    if (lo > 0) prev[k] = tails[lo - 1];
    tails[lo] = k;
  }
  const out: Pair[] = [];
  for (let k = tails.length > 0 ? tails[tails.length - 1] : -1; k >= 0; k = prev[k]) out.push(pairs[k]);
  return out.reverse();
}

/** Stage 1: blocks that are the very same object in `a` and `b`. A transaction keeps every block it did not touch, so on
 * the live documents this lines up everything unchanged in one linear pass. A block object that occurs several times is
 * paired occurrence by occurrence. */
function identityPairs(a: Node[], b: Node[]): Pair[] {
  const slots = new Map<Node, number[]>();
  for (let j = 0; j < b.length; j++) {
    const list = slots.get(b[j]);
    if (list) list.push(j);
    else slots.set(b[j], [j]);
  }
  const taken = new Map<Node, number>();
  const pairs: Pair[] = [];
  for (let i = 0; i < a.length; i++) {
    const list = slots.get(a[i]);
    if (!list) continue;
    const k = taken.get(a[i]) ?? 0;
    if (k < list.length) {
      pairs.push({ a: i, b: list[k] });
      taken.set(a[i], k + 1);
    }
  }
  return increasingChain(pairs);
}

/** A cheap key two equal blocks always share (type, size, the first characters of text): it only narrows the search; every
 * pairing is confirmed with `Node.eq`. */
function fingerprint(node: Node): string {
  return `${node.type.name}|${node.nodeSize}|${node.textBetween(0, Math.min(node.content.size, 40), ' ', ' ')}`;
}

/** Stage 2, for a gap `a[aFrom,aTo)` / `b[bFrom,bTo)` that identity left open: equal blocks (`Node.eq`) from the front, from
 * the back, then by fingerprint for the rest. This is what lines a document up when identity is broken (every block a new
 * object, as after a full content replace). Every pair is a confirmed equality, so any subset of them is a valid anchor set. */
function equalityPairs(a: Node[], b: Node[], aFrom: number, aTo: number, bFrom: number, bTo: number): Pair[] {
  const out: Pair[] = [];
  let front = 0;
  while (aFrom + front < aTo && bFrom + front < bTo && a[aFrom + front].eq(b[bFrom + front])) {
    out.push({ a: aFrom + front, b: bFrom + front });
    front++;
  }
  const tail: Pair[] = [];
  let back = 0;
  while (
    aTo - 1 - back >= aFrom + front &&
    bTo - 1 - back >= bFrom + front &&
    a[aTo - 1 - back].eq(b[bTo - 1 - back])
  ) {
    tail.push({ a: aTo - 1 - back, b: bTo - 1 - back });
    back++;
  }
  const midAFrom = aFrom + front;
  const midATo = aTo - back;
  const midBFrom = bFrom + front;
  const midBTo = bTo - back;
  if (midAFrom < midATo && midBFrom < midBTo) {
    const buckets = new Map<string, number[]>();
    for (let j = midBFrom; j < midBTo; j++) {
      const key = fingerprint(b[j]);
      const list = buckets.get(key);
      if (list) list.push(j);
      else buckets.set(key, [j]);
    }
    const cursor = new Map<string, number>();
    const pairs: Pair[] = [];
    for (let i = midAFrom; i < midATo; i++) {
      const key = fingerprint(a[i]);
      const list = buckets.get(key);
      if (!list) continue;
      let k = cursor.get(key) ?? 0;
      while (k < list.length && !a[i].eq(b[list[k]])) k++;
      if (k < list.length) {
        pairs.push({ a: i, b: list[k] });
        cursor.set(key, k + 1);
      }
    }
    out.push(...increasingChain(pairs));
  }
  out.push(...tail.reverse());
  return out;
}

/** The monotone list of (index in a, index in b) pairs of unchanged blocks: identity first, then equality inside every gap
 * identity left open. */
function alignUnchanged(a: Node[], b: Node[]): Pair[] {
  const byIdentity = identityPairs(a, b);
  const all: Pair[] = [];
  let prevA = 0;
  let prevB = 0;
  for (let k = 0; k <= byIdentity.length; k++) {
    const endA = k < byIdentity.length ? byIdentity[k].a : a.length;
    const endB = k < byIdentity.length ? byIdentity[k].b : b.length;
    if (endA > prevA && endB > prevB) all.push(...equalityPairs(a, b, prevA, endA, prevB, endB));
    if (k < byIdentity.length) all.push(byIdentity[k]);
    prevA = endA + 1;
    prevB = endB + 1;
  }
  return all;
}

/** The changed stretches between the lined-up unchanged blocks, in document order. */
function regionsBetween(a: Node[], b: Node[], anchors: Pair[]): Region[] {
  const regions: Region[] = [];
  let prevA = 0;
  let prevB = 0;
  for (let k = 0; k <= anchors.length; k++) {
    const endA = k < anchors.length ? anchors[k].a : a.length;
    const endB = k < anchors.length ? anchors[k].b : b.length;
    if (endA > prevA || endB > prevB) regions.push({ aFrom: prevA, aTo: endA, bFrom: prevB, bTo: endB });
    prevA = endA + 1;
    prevB = endB + 1;
  }
  return regions;
}

interface RegionDiff {
  ranges: BlockChangeRange[];
  regions: number;
  /** The most expensive single region, in cells (old length times new length). */
  maxCells: number;
  /** True when `budget` was given and a region is above it; `ranges` is then empty and no region was diffed. */
  overBudget: boolean;
}

/** The block changes from `oldDoc` to `newDoc`, found region by region. A region with an empty side is one plain range; any
 * other region is diffed on its own with `diffTopLevelBlocks` (the one block diff the app has), on a document made of just
 * that region's blocks. `budget` (null: none) applies to every region on its own. */
function diffByRegions(oldDoc: Node, newDoc: Node, budget: number | null): RegionDiff {
  const a = childList(oldDoc);
  const b = childList(newDoc);
  const regions = regionsBetween(a, b, alignUnchanged(a, b));
  let maxCells = 0;
  for (const r of regions) maxCells = Math.max(maxCells, (r.aTo - r.aFrom) * (r.bTo - r.bFrom));
  if (budget !== null && maxCells > budget) return { ranges: [], regions: regions.length, maxCells, overBudget: true };
  const ranges: BlockChangeRange[] = [];
  for (const r of regions) {
    if (r.aFrom === r.aTo || r.bFrom === r.bTo) {
      ranges.push({ oldFrom: r.aFrom, oldTo: r.aTo, newFrom: r.bFrom, newTo: r.bTo });
      continue;
    }
    const inner = diffTopLevelBlocks(
      oldDoc.copy(Fragment.fromArray(a.slice(r.aFrom, r.aTo))),
      newDoc.copy(Fragment.fromArray(b.slice(r.bFrom, r.bTo)))
    );
    for (const x of inner) {
      ranges.push({
        oldFrom: x.oldFrom + r.aFrom,
        oldTo: x.oldTo + r.aFrom,
        newFrom: x.newFrom + r.bFrom,
        newTo: x.newTo + r.bFrom,
      });
    }
  }
  return { ranges, regions: regions.length, maxCells, overBudget: false };
}

/** Most ranges `describeBlockDifferences` lists; the rest are counted. */
const MAX_DESCRIBED_RANGES = 6;
/** Most distinct runs of node types listed per side of one range. */
const MAX_DESCRIBED_TYPES = 4;

/** The node types of `doc.child(from..to)` as runs: `paragraph,heading` or `paragraph*3`; `-` for an empty side. */
function typeList(doc: Node, from: number, to: number): string {
  if (from >= to) return '-';
  const runs: Array<{ name: string; count: number }> = [];
  for (let i = from; i < to; i++) {
    const name = doc.child(i).type.name;
    const last = runs.length > 0 ? runs[runs.length - 1] : null;
    if (last !== null && last.name === name) last.count++;
    else runs.push({ name, count: 1 });
  }
  const shown = runs.slice(0, MAX_DESCRIBED_TYPES).map((r) => (r.count > 1 ? `${r.name}*${r.count}` : r.name));
  return runs.length > MAX_DESCRIBED_TYPES ? `${shown.join(',')},...` : shown.join(',');
}

function describeRanges(ranges: BlockChangeRange[], oldDoc: Node, newDoc: Node): string {
  const parts = ranges
    .slice(0, MAX_DESCRIBED_RANGES)
    .map(
      (r) =>
        'a[' +
        r.oldFrom +
        ',' +
        r.oldTo +
        ')b[' +
        r.newFrom +
        ',' +
        r.newTo +
        ') ' +
        typeList(oldDoc, r.oldFrom, r.oldTo) +
        '>' +
        typeList(newDoc, r.newFrom, r.newTo)
    );
  const more = ranges.length > MAX_DESCRIBED_RANGES ? ` ; +${ranges.length - MAX_DESCRIBED_RANGES} more` : '';
  const head = `${ranges.length} range${ranges.length === 1 ? '' : 's'}`;
  return head + (parts.length > 0 ? `: ${parts.join(' ; ')}` : '') + more;
}

/**
 * Counts-only description of where the top-level blocks of `a` and `b` differ, for the trace lines (the `registry-rebase`
 * and `routing-equivalence` lines): the index ranges in each document and the node TYPES in them, never any text. The
 * differences are found the way the rebase finds the user's: region by region, each region under the user-side budget; a
 * region above it is reported as `too-far` with its size instead of being diffed. Example:
 * `2 ranges: a[5,6)b[5,6) paragraph>paragraph ; a[458,459)b[458,459) footnote_def>footnote_def`.
 */
export function describeBlockDifferences(a: Node, b: Node): string {
  const diff = diffByRegions(a, b, USER_DIFF_CELL_BUDGET);
  if (diff.overBudget) return `too-far: ${diff.regions} regions, the largest ${diff.maxCells} cells`;
  return describeRanges(diff.ranges, a, b);
}

/** True when the chain range `r` (indices into `before`, its old side) and the user range `u` (indices into `before`,
 * its new side) must not both be applied: they overlap, or one EMPTY range lies strictly inside the other, or both are
 * empty at the same place (an insertion next to an insertion: which comes first is not decidable). */
function conflicts(r: BlockChangeRange, u: BlockChangeRange): boolean {
  const a = r.oldFrom;
  const b = r.oldTo;
  const c = u.newFrom;
  const d = u.newTo;
  // Covers: two ranges sharing a block, an empty chain range strictly inside the user's range (c < a < d), and an empty
  // user range strictly inside the chain's range (a < c < b).
  if (a < d && c < b) return true;
  return a === b && c === d && a === c;
}

/**
 * Applies the automatic chain `before` -> `after` to the saved copy `saved`, under the rule in the file header.
 * Order of work: R first (nothing to do when the chain changed no block), then U with the per-region cell budget, then the
 * conflicts, then the block check, then the splice (last range first, so earlier indices stay valid). The conflicts, the
 * block check and the splice work on the ranges only, so they are the same however the ranges were found.
 */
export function rebaseOntoSavedCopy(saved: Node, before: Node, after: Node): SavedCopyRebase {
  const chain = diffByRegions(before, after, null).ranges;
  if (chain.length === 0) {
    return {
      doc: null,
      result: 'no-change',
      userRanges: -1,
      chainRanges: 0,
      cells: 0,
      userSummary: '',
      chainSummary: '',
    };
  }
  const chainSummary = describeRanges(chain, before, after);

  const userDiff = diffByRegions(saved, before, USER_DIFF_CELL_BUDGET);
  if (userDiff.overBudget) {
    return {
      doc: null,
      result: 'too-far',
      userRanges: -1,
      chainRanges: chain.length,
      cells: userDiff.maxCells,
      userSummary: `too-far: ${userDiff.regions} regions, the largest ${userDiff.maxCells} cells`,
      chainSummary,
    };
  }
  const user = userDiff.ranges;
  const counts = {
    userRanges: user.length,
    chainRanges: chain.length,
    cells: userDiff.maxCells,
    userSummary: describeRanges(user, saved, before),
    chainSummary,
  };

  for (const r of chain) {
    for (const u of user) {
      if (conflicts(r, u)) return { doc: null, result: 'overlap', ...counts };
    }
  }

  // `before` index -> `saved` index: every user range that ends at or before the index moved the blocks after it by
  // (blocks it added) - (blocks it removed).
  const toSaved = (index: number): number => {
    let mapped = index;
    for (const u of user) {
      if (u.newTo <= index) mapped -= u.newTo - u.newFrom - (u.oldTo - u.oldFrom);
    }
    return mapped;
  };

  // Block check: every block the chain replaced must be the very same block in `saved` and in `before`. A pure
  // insertion replaces nothing, so it has nothing to check (the overlap rule above is what keeps it off the user's blocks).
  for (const r of chain) {
    const start = toSaved(r.oldFrom);
    const length = r.oldTo - r.oldFrom;
    if (start < 0 || start + length > saved.childCount) return { doc: null, result: 'mismatch', ...counts };
    for (let i = 0; i < length; i++) {
      if (!saved.child(start + i).eq(before.child(r.oldFrom + i))) return { doc: null, result: 'mismatch', ...counts };
    }
  }

  const children: Node[] = [];
  saved.forEach((node) => {
    children.push(node);
  });
  for (let k = chain.length - 1; k >= 0; k--) {
    const r = chain[k];
    const inserted: Node[] = [];
    for (let i = r.newFrom; i < r.newTo; i++) inserted.push(after.child(i));
    children.splice(toSaved(r.oldFrom), r.oldTo - r.oldFrom, ...inserted);
  }
  return { doc: saved.copy(Fragment.fromArray(children)), result: 'rebased', ...counts };
}
