// Pure-function tests for computeMinimalChanges -- no DOM, no CodeMirror EditorView.
// See set-content-selection.test.ts for the integration-level tests that exercise this
// through a real EditorView's setContent() call.
//
// judge-review should-fix #9: this file used to also test a single-span
// `computeMinimalChange` predecessor, deleted from text-diff.ts once
// `computeMinimalChanges` (below) became setContent's only caller and this was the last
// remaining user of the singular function.

import { describe, expect, it } from 'vitest';
import { computeMinimalChanges, computeRefinedChanges } from '../text-diff';

// P1 (undo-mode-switch-focus, second timing gap): multi-span diff -- see text-diff.ts's
// own doc comment for the full rationale.
describe('computeMinimalChanges', () => {
  it('returns an empty array for identical strings', () => {
    expect(computeMinimalChanges('same text', 'same text')).toEqual([]);
    expect(computeMinimalChanges('', '')).toEqual([]);
  });

  it('two separated differences produce two disjoint spans, not one covering span', () => {
    const oldText = '# Heading One\n\nSome untouched body text that must not be swallowed.\n\n# Heading Two\n';
    const newText = '# Fixed One\n\nSome untouched body text that must not be swallowed.\n\n# Fixed Two\n';
    const changes = computeMinimalChanges(oldText, newText);

    expect(changes.length).toBe(2);
    // Disjoint: the first change's `to` must not reach into the second's `from`.
    expect(changes[0].to).toBeLessThanOrEqual(changes[1].from);
    // Sorted in original-document order.
    expect(changes[0].from).toBeLessThan(changes[1].from);
    // The untouched body text between the two headings is NOT inside either span.
    const untouchedStart = oldText.indexOf('Some untouched');
    const untouchedEnd = untouchedStart + 'Some untouched body text that must not be swallowed.'.length;
    for (const c of changes) {
      const overlapsUntouched = c.from < untouchedEnd && c.to > untouchedStart;
      expect(overlapsUntouched).toBe(false);
    }

    // Applying all changes (highest offset first, so earlier offsets stay valid) reproduces newText.
    let result = oldText;
    for (const c of [...changes].sort((a, b) => b.from - a.from)) {
      result = result.slice(0, c.from) + c.insert + result.slice(c.to);
    }
    expect(result).toBe(newText);
  });

  it('spans are sorted, non-overlapping, and in original-document coordinates for a 3-way change', () => {
    const oldText = 'line A\nline B\nline C\nline D\nline E\nline F\nline G\n';
    const newText = 'line A2\nline B\nline C2\nline D\nline E\nline F2\nline G\n';
    const changes = computeMinimalChanges(oldText, newText);

    expect(changes.length).toBeGreaterThanOrEqual(3);
    for (let i = 1; i < changes.length; i++) {
      expect(changes[i].from).toBeGreaterThanOrEqual(changes[i - 1].to);
      expect(changes[i].from).toBeGreaterThan(changes[i - 1].from);
    }
    let result = oldText;
    for (const c of [...changes].sort((a, b) => b.from - a.from)) {
      result = result.slice(0, c.from) + c.insert + result.slice(c.to);
    }
    expect(result).toBe(newText);
  });

  it('never splits a surrogate pair at any emitted boundary', () => {
    const emoji = '😀'; // 😀, a surrogate pair
    const oldText = `line one ${emoji} end\nunchanged middle line\nline three ${emoji} end\n`;
    const newText = `line ONE ${emoji} end\nunchanged middle line\nline THREE ${emoji} end\n`;
    const changes = computeMinimalChanges(oldText, newText);
    const isHighSurrogate = (c: number) => c >= 0xd800 && c <= 0xdbff;
    const isLowSurrogate = (c: number) => c >= 0xdc00 && c <= 0xdfff;
    for (const c of changes) {
      for (const pos of [c.from, c.to]) {
        if (pos > 0 && pos < oldText.length) {
          const splitsPair = isHighSurrogate(oldText.charCodeAt(pos - 1)) && isLowSurrogate(oldText.charCodeAt(pos));
          expect(splitsPair).toBe(false);
        }
      }
    }
  });

  it('falls back to a single span when the differing middle exceeds the line-count bound', () => {
    const commonHead = 'HEAD\n';
    const commonTail = 'TAIL\n';
    const oldMiddle = Array.from({ length: 600 }, (_, i) => `old line ${i}`).join('\n');
    const newMiddle = Array.from({ length: 600 }, (_, i) => `new line ${i}`).join('\n');
    const oldText = `${commonHead}${oldMiddle}\n${commonTail}`;
    const newText = `${commonHead}${newMiddle}\n${commonTail}`;
    const changes = computeMinimalChanges(oldText, newText);
    expect(changes.length).toBe(1);
    expect(oldText.slice(0, changes[0].from) + changes[0].insert + oldText.slice(changes[0].to)).toBe(newText);
  });
});

// t-14f908b4: the refined diff, used only by the redo put-back (redo-branch.ts `putBackRedo`). No 500-line bound; character-level inside a
// changed run of lines.
describe('computeRefinedChanges', () => {
  const apply = (text: string, changes: Array<{ from: number; to: number; insert: string }>): string => {
    let result = text;
    for (const c of [...changes].sort((a, b) => b.from - a.from)) {
      result = result.slice(0, c.from) + c.insert + result.slice(c.to);
    }
    return result;
  };
  /** A document of `count` lines, one paragraph per two lines, in the shape the Markdown editor shows. */
  const book = (count: number, edit: (line: number, text: string) => string = (_i, text) => text): string =>
    Array.from({ length: count }, (_, i) => edit(i, i % 2 === 0 ? `Paragraph ${i / 2} of the book.` : '')).join('\n');

  it('returns an empty array for identical strings', () => {
    expect(computeRefinedChanges('same', 'same')).toEqual([]);
  });

  it('a book of 4000 lines with a label changed near the top and a line inserted near the end: two small changes, no collapse', () => {
    const oldText = book(4000, (i, text) => (i === 100 ? 'Paragraph 50 of the book.[^3]' : text));
    const relabelled = book(4000, (i, text) => (i === 100 ? 'Paragraph 50 of the book.[^4]' : text)).split('\n');
    relabelled.splice(3500, 0, 'A new line.'); // a whole new line, near the end
    const newText = relabelled.join('\n');
    const changes = computeRefinedChanges(oldText, newText);
    expect(apply(oldText, changes)).toBe(newText);
    // Not one span from line 100 to line 3500 (what computeMinimalChanges does past its 500-line bound):
    expect(computeMinimalChanges(oldText, newText).length).toBe(1);
    expect(changes.length).toBe(2);
    expect(changes[0]).toEqual({ from: oldText.indexOf('[^3]') + 2, to: oldText.indexOf('[^3]') + 3, insert: '4' });
    expect(changes[1].to - changes[1].from).toBe(0); // a pure insertion
    expect(changes[1].insert.trim()).toBe('A new line.'); // the line break may sit on either side of it
  });

  it('two labels in ONE long line: two one-character changes, the text between them untouched', () => {
    const oldText = 'before\n\nFirst.[^1] some words in between that stay. Second.[^2]\n\nafter\n';
    const newText = 'before\n\nFirst.[^7] some words in between that stay. Second.[^8]\n\nafter\n';
    const changes = computeRefinedChanges(oldText, newText);
    expect(changes).toEqual([
      { from: oldText.indexOf('[^1]') + 2, to: oldText.indexOf('[^1]') + 3, insert: '7' },
      { from: oldText.indexOf('[^2]') + 2, to: oldText.indexOf('[^2]') + 3, insert: '8' },
    ]);
  });

  it('an anchor glued in front of a heading is a pure insertion', () => {
    const oldText = 'Intro.\n\n# Chapter 2\n\nBody.\n';
    const newText = 'Intro.\n\n<!-- @sid:0123 --># Chapter 2\n\nBody.\n';
    expect(computeRefinedChanges(oldText, newText)).toEqual([
      { from: oldText.indexOf('# Chapter 2'), to: oldText.indexOf('# Chapter 2'), insert: '<!-- @sid:0123 -->' },
    ]);
  });

  it('reproduces the new text for a thousand random edits of a small text (a seeded generator)', () => {
    let seed = 12345;
    const next = (n: number): number => {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed % n;
    };
    const pieces = ['alpha', 'beta', '\n', '\n\n', ' ', '[^1]', '# H', 'x', 'gamma delta'];
    for (let round = 0; round < 1000; round++) {
      const make = (): string => Array.from({ length: 1 + next(40) }, () => pieces[next(pieces.length)]).join('');
      const oldText = make();
      let newText = oldText;
      for (let k = next(4); k > 0; k--) {
        const at = next(newText.length + 1);
        newText =
          newText.slice(0, at) + (next(2) === 0 ? pieces[next(pieces.length)] : '') + newText.slice(at + next(6));
      }
      const changes = computeRefinedChanges(oldText, newText);
      expect(apply(oldText, changes), `round ${round}: ${JSON.stringify([oldText, newText])}`).toBe(newText);
      for (let i = 1; i < changes.length; i++) expect(changes[i].from).toBeGreaterThanOrEqual(changes[i - 1].to);
    }
  });

  it('never splits a surrogate pair', () => {
    const oldText = 'one 😀 two\n\nthree 😀 four\n';
    const newText = 'one 😁 two\n\nthree 😁 four\n';
    const changes = computeRefinedChanges(oldText, newText);
    expect(apply(oldText, changes)).toBe(newText);
    for (const c of changes) {
      for (const pos of [c.from, c.to]) {
        const splits =
          pos > 0 &&
          pos < oldText.length &&
          /[\ud800-\udbff]/.test(oldText[pos - 1]) &&
          /[\udc00-\udfff]/.test(oldText[pos]);
        expect(splits).toBe(false);
      }
    }
  });

  // T-SUR (Round B2, judge ruling): a surrogate pair in the changed run used to collapse the whole run to ONE span (the character-level
  // pass was skipped for any run holding a surrogate), so typing in a duplicated chapter that held one emoji or one CJK Extension B
  // name could not be redone. The pass now runs on UTF-16 code units and every boundary is moved off the middle of a pair.
  // Break patch (T-SUR.patch): in text-diff.ts `refineRun`, add `|| /[\ud800-\udfff]/.test(oldMiddle + newMiddle)` to the condition that
  // pushes `whole` (the old skip). Predicted failure: the exact small changes, `expected [ { from: 3, to: 19, ...`.
  it('T-SUR a changed run holding an emoji and a CJK Extension B character keeps its character-level changes and splits no pair', () => {
    const emoji = '\u{1F600}'; // U+1F600, a surrogate pair (D83D DE00)
    const otherEmoji = '\u{1F601}'; // D83D DE01: same first half, other second half
    const extB = '\u{20BB7}'; // U+20BB7 (D842 DFB7), a CJK Extension B ideograph
    const otherExtB = '\u{20B9F}'; // D842 DF9F
    const oldText = `one ${emoji} two ${extB} three`;

    // Typing at both ends of the run, the pairs untouched between them: two one-character insertions, not one span over the middle.
    const typed = `oneX ${emoji} two ${extB} threeY`;
    expect(computeRefinedChanges(oldText, typed)).toEqual([
      { from: 3, to: 3, insert: 'X' },
      { from: 19, to: 19, insert: 'Y' },
    ]);

    // Typing plus both pairs changed in their second half only: each change is widened to the WHOLE pair, never half of one.
    const changed = `oneX ${otherEmoji} two ${otherExtB} threeY`;
    expect(computeRefinedChanges(oldText, changed)).toEqual([
      { from: 3, to: 3, insert: 'X' },
      { from: 4, to: 6, insert: otherEmoji },
      { from: 11, to: 13, insert: otherExtB },
      { from: 19, to: 19, insert: 'Y' },
    ]);

    // A seeded round trip over texts made of whole characters including both kinds of pair: the new text is reproduced, no boundary is
    // inside a pair of the old text, and no inserted piece starts with a second half or ends with a first half.
    let seed = 987654;
    const next = (n: number): number => {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed % n;
    };
    const isHigh = (c: number): boolean => c >= 0xd800 && c <= 0xdbff;
    const isLow = (c: number): boolean => c >= 0xdc00 && c <= 0xdfff;
    const offPair = (text: string, at: number): number => {
      let position = Math.min(at, text.length);
      while (
        position > 0 &&
        position < text.length &&
        isHigh(text.charCodeAt(position - 1)) &&
        isLow(text.charCodeAt(position))
      )
        position++;
      return position;
    };
    const pieces = ['alpha', ' ', '\n', '\n\n', 'x', '[^1]', emoji, otherEmoji, extB, otherExtB, 'beta gamma'];
    for (let round = 0; round < 600; round++) {
      const make = (): string => Array.from({ length: 1 + next(30) }, () => pieces[next(pieces.length)]).join('');
      const before = make();
      let after = before;
      for (let k = 1 + next(4); k > 0; k--) {
        const at = offPair(after, next(after.length + 1));
        const to = offPair(after, at + next(6));
        after = after.slice(0, at) + (next(3) === 0 ? '' : pieces[next(pieces.length)]) + after.slice(to);
      }
      const changes = computeRefinedChanges(before, after);
      const context = `round ${round}: ${JSON.stringify([before, after])}`;
      expect(apply(before, changes), context).toBe(after);
      for (const c of changes) {
        for (const pos of [c.from, c.to]) {
          const inside =
            pos > 0 && pos < before.length && isHigh(before.charCodeAt(pos - 1)) && isLow(before.charCodeAt(pos));
          expect(inside, `${context}: a boundary inside a pair at ${pos}`).toBe(false);
        }
        if (c.insert !== '') {
          expect(isLow(c.insert.charCodeAt(0)), `${context}: an insert starts with a second half`).toBe(false);
          expect(isHigh(c.insert.charCodeAt(c.insert.length - 1)), `${context}: an insert ends with a first half`).toBe(
            false
          );
        }
      }
      for (let i = 1; i < changes.length; i++)
        expect(changes[i].from, context).toBeGreaterThanOrEqual(changes[i - 1].to);
    }
  });

  it('past the edit limit the middle becomes one span (as computeMinimalChanges does), and still reproduces the new text', () => {
    const oldText = Array.from({ length: 3000 }, (_, i) => `old ${i}`).join('\n');
    const newText = Array.from({ length: 3000 }, (_, i) => `new ${i}`).join('\n');
    const changes = computeRefinedChanges(oldText, newText);
    expect(changes.length).toBe(1);
    expect(apply(oldText, changes)).toBe(newText);
  });
});
