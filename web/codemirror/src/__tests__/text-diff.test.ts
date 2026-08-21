// Pure-function tests for computeMinimalChanges -- no DOM, no CodeMirror EditorView.
// See set-content-selection.test.ts for the integration-level tests that exercise this
// through a real EditorView's setContent() call.
//
// judge-review should-fix #9: this file used to also test a single-span
// `computeMinimalChange` predecessor, deleted from text-diff.ts once
// `computeMinimalChanges` (below) became setContent's only caller and this was the last
// remaining user of the singular function.

import { describe, expect, it } from 'vitest';
import { computeMinimalChanges } from '../text-diff';

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
