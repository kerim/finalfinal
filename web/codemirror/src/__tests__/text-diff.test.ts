// Pure-function tests for computeMinimalChange -- no DOM, no CodeMirror EditorView.
// See set-content-selection.test.ts for the integration-level tests that exercise this
// through a real EditorView's setContent() call.

import { describe, expect, it } from 'vitest';
import { computeMinimalChange } from '../text-diff';

describe('computeMinimalChange', () => {
  it('returns null for identical strings', () => {
    expect(computeMinimalChange('same text', 'same text')).toBeNull();
    expect(computeMinimalChange('', '')).toBeNull();
  });

  it('returns a from=to=oldLen insert for a pure tail append', () => {
    const oldText = 'Hello world';
    const appended = ', how are you?';
    const newText = oldText + appended;
    const change = computeMinimalChange(oldText, newText);
    expect(change).toEqual({ from: oldText.length, to: oldText.length, insert: appended });
  });

  it('finds a prefix well past a body-text cursor position for a tail bibliography resync', () => {
    const body = `${'A'.repeat(500)}\n\n# Body Heading\n\nSome body text the cursor sits in.\n\n`;
    const oldText = `${body}# References\n\nOld entry (2020).`;
    const newText = `${body}# References\n\nNew entry (2021).\n\nAnother entry (2022).`;
    const change = computeMinimalChange(oldText, newText);
    expect(change).not.toBeNull();
    // The common prefix must extend at least through the unchanged `body`, well past
    // any cursor position sitting inside it -- proving the change is confined to the
    // bibliography tail, not a whole-document replace.
    expect(change!.from).toBeGreaterThanOrEqual(body.length);
    expect(oldText.slice(0, change!.from) + change!.insert + oldText.slice(change!.to)).toBe(newText);
  });

  it('degrades to a whole-document replace for completely different documents', () => {
    // First and last characters deliberately differ ('C'/'z' vs 'T'/'q') so neither a
    // shared prefix nor a shared suffix exists -- a genuine no-overlap case.
    const oldText = 'Completely different content xyz';
    const newText = 'Totally unrelated new document abq';
    const change = computeMinimalChange(oldText, newText);
    expect(change).toEqual({ from: 0, to: oldText.length, insert: newText });
  });

  it('handles oldText === "" and newText === "" edge cases', () => {
    expect(computeMinimalChange('', 'new content')).toEqual({ from: 0, to: 0, insert: 'new content' });
    expect(computeMinimalChange('old content', '')).toEqual({ from: 0, to: 'old content'.length, insert: '' });
  });

  it('finds a prefix-only change when a heading at the top is edited', () => {
    const oldText = '# Old Heading\n\nBody text that stays the same.';
    const newText = '# New Heading\n\nBody text that stays the same.';
    const change = computeMinimalChange(oldText, newText);
    expect(change).not.toBeNull();
    expect(oldText.slice(0, change!.from) + change!.insert + oldText.slice(change!.to)).toBe(newText);
    // The unchanged body text should be captured entirely by the suffix, i.e. `to`
    // should land before the body text starts.
    expect(change!.to).toBeLessThanOrEqual(oldText.indexOf('Body text'));
  });

  // ---- Surrogate pairs ----
  // 'a😀b' -> 'a😀c': shared prefix is 'a😀', shared suffix is '' (b != c). Neither
  // boundary should land inside the 😀 surrogate pair.
  it('does not split a surrogate pair when only the trailing character changes', () => {
    const oldText = 'a😀b';
    const newText = 'a😀c';
    const change = computeMinimalChange(oldText, newText);
    expect(change).not.toBeNull();
    assertNoSurrogateSplit(oldText, newText, change!);
  });

  // 'a😀b' -> 'a🎉b': the emoji itself changes; prefix/suffix must not straddle either
  // surrogate pair.
  it('does not split a surrogate pair when the emoji itself changes', () => {
    const oldText = 'a😀b';
    const newText = 'a🎉b';
    const change = computeMinimalChange(oldText, newText);
    expect(change).not.toBeNull();
    assertNoSurrogateSplit(oldText, newText, change!);
  });

  // Exercises the boundary assertNoSurrogateSplit previously never checked: the END of
  // the insert in newText (as opposed to `to` in oldText). Old and new share a suffix
  // that starts with the low-surrogate half of an emoji; the character immediately
  // before that shared suffix differs between old and new (a different high surrogate
  // in each), and the leading character differs too, so nothing is shared at the start.
  // Naively cutting the suffix boundary right at the shared low surrogate would leave
  // the insert ending in a lone, unpaired high surrogate in newText -- the suffix-nudge
  // logic in computeMinimalChange must pull that low surrogate into the insert instead.
  it('does not split a surrogate pair between the insert and the shared suffix in newText', () => {
    const highA = '\uD83D'; // high surrogate, distinct from highB
    const highB = '\uD83C';
    const lowShared = '\uDE00'; // low surrogate shared by both old and new's suffix
    const tail = 'tail-shared-text';
    const oldText = `X${highA}${lowShared}${tail}`;
    const newText = `Y${highB}${lowShared}${tail}`;

    const change = computeMinimalChange(oldText, newText);
    expect(change).not.toBeNull();
    assertNoSurrogateSplit(oldText, newText, change!);
    // The insert must end with the full low surrogate (pulled in from what would
    // otherwise be the shared suffix), not with a lone highB.
    expect(change!.insert.endsWith(lowShared)).toBe(true);
  });

  // ---- Round-trip invariant across every case above ----
  it('satisfies the round-trip invariant old.slice(0, from) + insert + old.slice(to) === new for every case', () => {
    const cases: Array<[string, string]> = [
      ['same text', 'same text'],
      ['Hello world', 'Hello world, how are you?'],
      ['# Old Heading\n\nBody text.', '# New Heading\n\nBody text.'],
      ['Completely different content here.', 'Totally unrelated new document text.'],
      ['', 'new content'],
      ['old content', ''],
      ['', ''],
      ['a😀b', 'a😀c'],
      ['a😀b', 'a🎉b'],
    ];

    for (const [oldText, newText] of cases) {
      const change = computeMinimalChange(oldText, newText);
      if (change === null) {
        expect(oldText).toBe(newText);
        continue;
      }
      const result = oldText.slice(0, change.from) + change.insert + oldText.slice(change.to);
      expect(result).toBe(newText);
    }
  });

  it('cursor-inside-changed-span case: change spans the full replaced region (accepted residual documented in api.ts)', () => {
    // This case is really exercised end-to-end in set-content-selection.test.ts (where a
    // real cursor position is mapped through a real dispatch); here we just confirm the
    // computed span is the one that would cause that mapping.
    const oldText = 'before [MIDDLE] after';
    const newText = 'before [CHANGED] after';
    const change = computeMinimalChange(oldText, newText);
    expect(change).not.toBeNull();
    expect(change!.from).toBe('before ['.length);
    expect(oldText.slice(0, change!.from) + change!.insert + oldText.slice(change!.to)).toBe(newText);
  });
});

/**
 * Fails the test if any boundary the change touches splits a UTF-16 surrogate pair, in
 * EITHER oldText or newText. Checks four boundaries total:
 *   - oldText at `from` and `to` (edges of the removed span)
 *   - newText at `from` and at `from + insert.length` (edges of the inserted span)
 * The two `from` boundaries are usually equivalent (oldText and newText agree on the
 * shared prefix up to `from` by construction), but both are checked explicitly rather
 * than assuming that redundancy holds. The newText insert-end boundary is the one that
 * matters most: it sits at a genuinely different offset than `to` whenever
 * `insert.length !== to - from`, and was never checked before this fix -- e.g. an insert
 * ending in a lone high surrogate immediately followed by the shared suffix's low
 * surrogate would have slipped past a check that only ever looked at oldText.
 */
function assertNoSurrogateSplit(
  oldText: string,
  newText: string,
  change: { from: number; to: number; insert: string }
): void {
  const isHighSurrogate = (c: number) => c >= 0xd800 && c <= 0xdbff;
  const isLowSurrogate = (c: number) => c >= 0xdc00 && c <= 0xdfff;

  const assertBoundarySafe = (text: string, pos: number) => {
    if (pos > 0 && pos < text.length) {
      const before = text.charCodeAt(pos - 1);
      const at = text.charCodeAt(pos);
      expect(isHighSurrogate(before) && isLowSurrogate(at)).toBe(false);
    }
  };

  assertBoundarySafe(oldText, change.from);
  assertBoundarySafe(oldText, change.to);
  assertBoundarySafe(newText, change.from);
  assertBoundarySafe(newText, change.from + change.insert.length);

  // Round-trip must still hold -- proves no data was corrupted by the surrogate nudge.
  expect(oldText.slice(0, change.from) + change.insert + oldText.slice(change.to)).toBe(newText);
}
