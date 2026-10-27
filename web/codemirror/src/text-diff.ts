/**
 * Multi-span diff (undo-mode-switch-focus, second timing gap, P1): returns a disjoint,
 * sorted array of `{from, to, insert}` changes -- one per changed line-run -- turning
 * `oldText` into `newText`, or `[]` when they are identical.
 *
 * Why multi-span, not one contiguous span: CodeMirror maps every selection position inside
 * a replaced range to the START of the replacement, so a single span covering the whole
 * differing region would swallow any UNCHANGED text sitting between two separated
 * corrections (e.g. two headings fixed at once, with untouched user text between them) into
 * one giant replaced range -- dropping that unrelated text's own undo history the same way a
 * whole-document replace would (silently teleporting the cursor/scroll anchor to its start).
 * `setContent` (api.ts) passes this array straight to `view.dispatch({changes: [...]})`;
 * CodeMirror 6 accepts `ChangeSpec[]` natively. (judge-review should-fix #9: this file used
 * to also export a single-span `computeMinimalChange` predecessor; deleted once this became
 * `setContent`'s only caller and its own dedicated test file was the last remaining user.)
 *
 * Offsets are UTF-16 code units (CodeMirror's position space). The outer prefix/suffix trim
 * below is nudged so it never lands between a high and low surrogate -- splitting a pair
 * would corrupt an astral-plane character such as an emoji. Bound: if either side of the
 * differing middle exceeds ~500 lines, falls back to a single span covering the whole middle
 * rather than paying for an unbounded O(n*m) DP table.
 */
export function computeMinimalChanges(
  oldText: string,
  newText: string
): { from: number; to: number; insert: string }[] {
  if (oldText === newText) return [];

  const isHighSurrogate = (c: number) => c >= 0xd800 && c <= 0xdbff;
  const isLowSurrogate = (c: number) => c >= 0xdc00 && c <= 0xdfff;

  const oldLen = oldText.length;
  const newLen = newText.length;
  const maxCommon = Math.min(oldLen, newLen);

  let prefix = 0;
  while (prefix < maxCommon && oldText.charCodeAt(prefix) === newText.charCodeAt(prefix)) prefix++;
  if (prefix > 0 && isHighSurrogate(oldText.charCodeAt(prefix - 1))) prefix--;

  let suffix = 0;
  const maxSuffix = maxCommon - prefix;
  while (suffix < maxSuffix && oldText.charCodeAt(oldLen - 1 - suffix) === newText.charCodeAt(newLen - 1 - suffix))
    suffix++;
  if (suffix > 0 && isLowSurrogate(oldText.charCodeAt(oldLen - suffix))) suffix--;

  const oldMiddle = oldText.slice(prefix, oldLen - suffix);
  const newMiddle = newText.slice(prefix, newLen - suffix);
  if (oldMiddle === newMiddle) return [];

  const oldLines = splitKeepingLineEnds(oldMiddle);
  const newLines = splitKeepingLineEnds(newMiddle);

  // Bound: an unbounded DP table is O(oldLines * newLines) cells -- fall back to one span
  // covering the whole middle (same result computeMinimalChange would give) for pathologically
  // large diffs (e.g. pasting a whole new document) rather than doing that work.
  const LINE_COUNT_BOUND = 500;
  if (oldLines.length > LINE_COUNT_BOUND || newLines.length > LINE_COUNT_BOUND) {
    return [{ from: prefix, to: oldLen - suffix, insert: newMiddle }];
  }

  const blocks = diffLineBlocks(oldLines, newLines);
  const oldOffsets = lineStartOffsets(oldLines);

  return blocks.map((block) => {
    // No per-block surrogate-pair nudging here (judge-review should-fix #10: an earlier
    // version had one, widening `from`/`to` on the OLD-text side without also widening the
    // emitted `insert` on the new-text side -- if ever actually reached, that would have
    // corrupted text, not protected it). It's genuinely unnecessary, not just "probably
    // fine": a block's `from`/`to` can only ever land exactly on a line boundary (right
    // after a real '\n' code unit in oldText, or at the already-nudged prefix/suffix trim
    // points below), and a literal newline can never sit between the two code units of a
    // surrogate pair -- so this boundary can never actually split one. A wrong defensive
    // guard for an unreachable case is worse than no guard at all.
    const from = prefix + oldOffsets[block.oldStart];
    const to = prefix + oldOffsets[block.oldEnd];
    const insert = newLines.slice(block.newStart, block.newEnd).join('');
    return { from, to, insert };
  });
}

/** Splits `text` into lines, keeping each line's trailing '\n' attached so joining any
 * contiguous slice of the result reproduces the exact original substring (never lossy). */
function splitKeepingLineEnds(text: string): string[] {
  if (text === '') return [];
  const lines: string[] = [];
  let start = 0;
  for (let i = 0; i < text.length; i++) {
    if (text[i] === '\n') {
      lines.push(text.slice(start, i + 1));
      start = i + 1;
    }
  }
  if (start < text.length) lines.push(text.slice(start));
  return lines;
}

function lineStartOffsets(lines: string[]): number[] {
  const offsets: number[] = new Array(lines.length + 1);
  offsets[0] = 0;
  for (let i = 0; i < lines.length; i++) offsets[i + 1] = offsets[i] + lines[i].length;
  return offsets;
}

interface LineChangeBlock {
  oldStart: number;
  oldEnd: number;
  newStart: number;
  newEnd: number;
}

/** Bounded line-level LCS diff producing disjoint, sorted change blocks (line-index ranges
 * on each side) -- consecutive blocks are always separated by at least one matching
 * ("equal") line, by construction of the forward walk below, so blocks never overlap. */
function diffLineBlocks(oldLines: string[], newLines: string[]): LineChangeBlock[] {
  const m = oldLines.length;
  const n = newLines.length;

  const dp: Int32Array[] = new Array(m + 1);
  for (let i = 0; i <= m; i++) dp[i] = new Int32Array(n + 1);
  for (let i = m - 1; i >= 0; i--) {
    for (let j = n - 1; j >= 0; j--) {
      dp[i][j] = oldLines[i] === newLines[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }

  const blocks: LineChangeBlock[] = [];
  let curBlock: LineChangeBlock | null = null;
  const flush = () => {
    if (curBlock) {
      blocks.push(curBlock);
      curBlock = null;
    }
  };

  let i = 0;
  let j = 0;
  while (i < m && j < n) {
    if (oldLines[i] === newLines[j]) {
      flush();
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      if (!curBlock) curBlock = { oldStart: i, oldEnd: i, newStart: j, newEnd: j };
      curBlock.oldEnd = i + 1;
      i++;
    } else {
      if (!curBlock) curBlock = { oldStart: i, oldEnd: i, newStart: j, newEnd: j };
      curBlock.newEnd = j + 1;
      j++;
    }
  }
  // At most one of these can be non-empty: the loop above only stops when i===m or j===n.
  if (i < m || j < n) {
    if (!curBlock) curBlock = { oldStart: i, oldEnd: i, newStart: j, newEnd: j };
    curBlock.oldEnd = m;
    curBlock.newEnd = n;
  }
  flush();

  return blocks;
}

// =============================================================================================================================
// The refined diff (t-14f908b4): for the redo put-back (redo-branch.ts `putBackRedo`, through `redoListOnto`)
// =============================================================================================================================

/** One change, in the offsets of the old text: replace [from, to) by `insert`. */
export interface TextChange {
  from: number;
  to: number;
  insert: string;
}

/** The most line-level edits (lines deleted plus lines inserted) the refined diff will follow; beyond it one span covers the middle. */
const REFINED_LINE_EDIT_LIMIT = 2000;
/** The most character-level edits it follows inside ONE changed line-run, and the longest run (old plus new characters) it tries. */
const REFINED_CHAR_EDIT_LIMIT = 1000;
const REFINED_CHAR_RUN_LIMIT = 200_000;

interface Hunk {
  aFrom: number;
  aTo: number;
  bFrom: number;
  bTo: number;
}

/**
 * Myers' O(ND) difference of two sequences (element equality is `===`): the disjoint, sorted hunks that turn `a` into `b`, or null when
 * more than `maxEdits` elements would have to be deleted and inserted. Time and memory grow with the number of EDITS, not with the
 * product of the lengths, so a book-sized text that differs in a few places is cheap -- the reason `computeMinimalChanges` cannot be
 * used for this (its line-by-line table is bounded at 500 lines because it grows with lines x lines).
 */
function myersHunks(a: ArrayLike<string | number>, b: ArrayLike<string | number>, maxEdits: number): Hunk[] | null {
  const n = a.length;
  const m = b.length;
  const limit = Math.min(n + m, maxEdits);
  const offset = limit + 1;
  const v = new Int32Array(2 * offset + 3); // v[offset + k] = furthest x on diagonal k = x - y
  const trace: Int32Array[] = []; // trace[d] = v for k in [-d-1, d+1] as it stood before round d
  let found = -1;
  for (let d = 0; d <= limit && found < 0; d++) {
    trace.push(v.slice(offset - d - 1, offset + d + 2));
    for (let k = -d; k <= d; k += 2) {
      let x: number;
      if (k === -d || (k !== d && v[offset + k - 1] < v[offset + k + 1])) x = v[offset + k + 1];
      else x = v[offset + k - 1] + 1;
      let y = x - k;
      while (x < n && y < m && a[x] === b[y]) {
        x++;
        y++;
      }
      v[offset + k] = x;
      if (x >= n && y >= m) {
        found = d;
        break;
      }
    }
  }
  if (found < 0) return null;

  // Walk back from (n, m): each round contributes one deletion (a step in x) or insertion (a step in y); the diagonals between are matches.
  const hunks: Hunk[] = [];
  let x = n;
  let y = m;
  let current: Hunk | null = null;
  const take = (aFrom: number, aTo: number, bFrom: number, bTo: number): void => {
    // Edits come last to first: grow the hunk that starts where this edit ends, else open a new one.
    if (current && current.aFrom === aTo && current.bFrom === bTo) {
      current.aFrom = aFrom;
      current.bFrom = bFrom;
    } else {
      current = { aFrom, aTo, bFrom, bTo };
      hunks.push(current);
    }
  };
  for (let d = found; d > 0; d--) {
    const k = x - y;
    const before = trace[d];
    const at = (diagonal: number): number => before[diagonal + d + 1];
    const previousK = k === -d || (k !== d && at(k - 1) < at(k + 1)) ? k + 1 : k - 1;
    const previousX = at(previousK);
    const previousY = previousX - previousK;
    // Coming from diagonal k+1 is a step down (b[previousY] is inserted), from k-1 a step right (a[previousX] is deleted); whatever lies
    // between the edit and (x, y) is a run of matches.
    if (previousK === k + 1) take(previousX, previousX, previousY, previousY + 1);
    else take(previousX, previousX + 1, previousY, previousY);
    x = previousX;
    y = previousY;
  }
  return hunks.reverse();
}

const isHighSurrogateCode = (c: number): boolean => c >= 0xd800 && c <= 0xdbff;
const isLowSurrogateCode = (c: number): boolean => c >= 0xdc00 && c <= 0xdfff;

/**
 * `hunks` (the character-level hunks of `old` -> `next`, found on UTF-16 code units) with every boundary moved off the middle of a
 * surrogate pair: a hunk whose start or end would fall between the two halves of a pair, in either text, is widened by the one code
 * unit that completes the pair, on both sides (the unit next to a hunk is a match, so it is the same unit in both texts). A hunk that
 * then touches its neighbour is merged with it.
 */
function snapHunksToPairs(old: string, next: string, hunks: Hunk[]): Hunk[] {
  const splits = (text: string, at: number): boolean =>
    at > 0 &&
    at < text.length &&
    isHighSurrogateCode(text.charCodeAt(at - 1)) &&
    isLowSurrogateCode(text.charCodeAt(at));
  const snapped: Hunk[] = [];
  for (const hunk of hunks) {
    const startsInPair = splits(old, hunk.aFrom) || splits(next, hunk.bFrom);
    const endsInPair = splits(old, hunk.aTo) || splits(next, hunk.bTo);
    const aFrom = startsInPair ? hunk.aFrom - 1 : hunk.aFrom;
    const bFrom = startsInPair ? hunk.bFrom - 1 : hunk.bFrom;
    const aTo = endsInPair ? hunk.aTo + 1 : hunk.aTo;
    const bTo = endsInPair ? hunk.bTo + 1 : hunk.bTo;
    const previous = snapped[snapped.length - 1];
    if (previous && aFrom <= previous.aTo) {
      previous.aTo = Math.max(previous.aTo, aTo);
      previous.bTo = Math.max(previous.bTo, bTo);
    } else {
      snapped.push({ aFrom, aTo, bFrom, bTo });
    }
  }
  return snapped;
}

/** `old` -> `next` as the smallest changes inside one changed run, whose first character is at `base` in the old text. */
function refineRun(base: number, old: string, next: string, out: TextChange[]): void {
  const maxCommon = Math.min(old.length, next.length);
  let prefix = 0;
  while (prefix < maxCommon && old.charCodeAt(prefix) === next.charCodeAt(prefix)) prefix++;
  if (prefix > 0 && isHighSurrogateCode(old.charCodeAt(prefix - 1))) prefix--;
  let suffix = 0;
  const maxSuffix = maxCommon - prefix;
  while (suffix < maxSuffix && old.charCodeAt(old.length - 1 - suffix) === next.charCodeAt(next.length - 1 - suffix))
    suffix++;
  if (suffix > 0 && isLowSurrogateCode(old.charCodeAt(old.length - suffix))) suffix--;

  const oldMiddle = old.slice(prefix, old.length - suffix);
  const newMiddle = next.slice(prefix, next.length - suffix);
  if (oldMiddle === newMiddle) return;
  const from = base + prefix;
  const whole = { from, to: base + old.length - suffix, insert: newMiddle };

  // One more level: inside the run, only the characters that really differ. Skipped (the run trimmed at both ends is the change) when
  // the run is long or differs in more than a handful of places. The comparison is on UTF-16 code units, so a hunk can start or end
  // between the halves of a surrogate pair (an emoji, a CJK Extension B name); `snapHunksToPairs` widens it by that one unit.
  const tooLong = oldMiddle.length + newMiddle.length > REFINED_CHAR_RUN_LIMIT;
  if (oldMiddle === '' || newMiddle === '' || tooLong) {
    out.push(whole);
    return;
  }
  const rawHunks = myersHunks(oldMiddle, newMiddle, REFINED_CHAR_EDIT_LIMIT);
  if (rawHunks === null) {
    out.push(whole);
    return;
  }
  for (const hunk of snapHunksToPairs(oldMiddle, newMiddle, rawHunks)) {
    out.push({ from: from + hunk.aFrom, to: from + hunk.aTo, insert: newMiddle.slice(hunk.bFrom, hunk.bTo) });
  }
}

/**
 * The changes that turn `oldText` into `newText`, as fine as the texts allow and with NO line-count bound: a disjoint, sorted array in the
 * offsets of `oldText` (`[]` when they are equal), like `computeMinimalChanges`. The texts are cut into lines and compared by Myers'
 * difference (no 500-line collapse), each changed run of lines is trimmed to the characters that differ and, when it is not long, compared
 * again character by character -- so a footnote label that went from `[^3]` to `[^4]`, or an anchor comment glued in front of a heading,
 * is a one-character or a pure-insertion change however long the book is. When the texts differ in more than a few thousand places the
 * middle becomes one span, as in `computeMinimalChanges`. Offsets are UTF-16 code units and no change starts or ends inside a surrogate pair.
 *
 * Used by the redo put-back (redo-branch.ts `putBackRedo`); the redo list kept across a footnote renumber (`keptRedoOnto`) maps through
 * that transaction's own change set instead. `computeMinimalChanges` (setContent, the saved-copy swap, the carry) is unchanged.
 */
export function computeRefinedChanges(oldText: string, newText: string): TextChange[] {
  if (oldText === newText) return [];
  const oldLen = oldText.length;
  const newLen = newText.length;
  const maxCommon = Math.min(oldLen, newLen);
  let prefix = 0;
  while (prefix < maxCommon && oldText.charCodeAt(prefix) === newText.charCodeAt(prefix)) prefix++;
  if (prefix > 0 && isHighSurrogateCode(oldText.charCodeAt(prefix - 1))) prefix--;
  let suffix = 0;
  const maxSuffix = maxCommon - prefix;
  while (suffix < maxSuffix && oldText.charCodeAt(oldLen - 1 - suffix) === newText.charCodeAt(newLen - 1 - suffix))
    suffix++;
  if (suffix > 0 && isLowSurrogateCode(oldText.charCodeAt(oldLen - suffix))) suffix--;

  const oldMiddle = oldText.slice(prefix, oldLen - suffix);
  const newMiddle = newText.slice(prefix, newLen - suffix);
  if (oldMiddle === newMiddle) return [];

  const oldLines = splitKeepingLineEnds(oldMiddle);
  const newLines = splitKeepingLineEnds(newMiddle);
  const hunks = myersHunks(oldLines, newLines, REFINED_LINE_EDIT_LIMIT);
  if (hunks === null) return [{ from: prefix, to: oldLen - suffix, insert: newMiddle }];

  const oldOffsets = lineStartOffsets(oldLines);
  const changes: TextChange[] = [];
  for (const hunk of hunks) {
    refineRun(
      prefix + oldOffsets[hunk.aFrom],
      oldLines.slice(hunk.aFrom, hunk.aTo).join(''),
      newLines.slice(hunk.bFrom, hunk.bTo).join(''),
      changes
    );
  }
  return changes;
}
