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
//   U = what the USER changed since the saved copy   = diffTopLevelBlocks(saved, before)
//   R = what the AUTOMATIC chain changed             = diffTopLevelBlocks(before, after)
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

/** Most cells (trimmed-middle length of `saved` times that of `before`) the user-side diff may cost. Above it the
 * rebase refuses with `too-far` WITHOUT running the diff: the user has edited far apart from each other since the
 * saved copy, and the app must not pay a quadratic diff on every automatic chain for it. On a book of about a thousand
 * top-level blocks, one edit region of a few blocks costs a few cells; edits in two chapters far apart trim to a middle
 * of several hundred blocks on each side (around a hundred thousand cells), which is above this. This is a scope limit,
 * not a safety one: the result is today's behaviour (the saved copy stays as it is). */
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
  /** Cells the user-side diff would cost (0 when R was empty). */
  cells: number;
}

/** Cells of the trimmed middle of a diff between `a` and `b`: what `diffTopLevelBlocks` would fill, computed with the
 * same common prefix and suffix trimming (`Node.eq`, which short-circuits on identity), so the diff itself can be skipped. */
function trimmedMiddleCells(a: Node, b: Node): number {
  const na = a.childCount;
  const nb = b.childCount;
  const maxCommon = Math.min(na, nb);
  let prefix = 0;
  while (prefix < maxCommon && a.child(prefix).eq(b.child(prefix))) prefix++;
  let suffix = 0;
  const maxSuffix = maxCommon - prefix;
  while (suffix < maxSuffix && a.child(na - 1 - suffix).eq(b.child(nb - 1 - suffix))) suffix++;
  return (na - prefix - suffix) * (nb - prefix - suffix);
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
 * Order of work: R first (nothing to do when the chain changed no block), then the cell budget, then U, then the
 * conflicts, then the block check, then the splice (last range first, so earlier indices stay valid).
 */
export function rebaseOntoSavedCopy(saved: Node, before: Node, after: Node): SavedCopyRebase {
  const chain = diffTopLevelBlocks(before, after);
  if (chain.length === 0) return { doc: null, result: 'no-change', userRanges: -1, chainRanges: 0, cells: 0 };

  const cells = trimmedMiddleCells(saved, before);
  if (cells > USER_DIFF_CELL_BUDGET) {
    return { doc: null, result: 'too-far', userRanges: -1, chainRanges: chain.length, cells };
  }

  const user = diffTopLevelBlocks(saved, before);
  const counts = { userRanges: user.length, chainRanges: chain.length, cells };

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
