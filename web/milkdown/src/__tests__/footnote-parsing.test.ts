import { describe, expect, it } from 'vitest';
import { footnoteRefRegex } from '../footnote-plugin';

describe('footnoteRefRegex', () => {
  function findMatches(text: string): Array<{ full: string; label: string; index: number }> {
    footnoteRefRegex.lastIndex = 0;
    const results: Array<{ full: string; label: string; index: number }> = [];
    let match: RegExpExecArray | null;
    while ((match = footnoteRefRegex.exec(text)) !== null) {
      results.push({ full: match[0], label: match[1], index: match.index });
    }
    return results;
  }

  it('matches single digit footnote [^1]', () => {
    const matches = findMatches('Some text[^1] here.');
    expect(matches).toHaveLength(1);
    expect(matches[0].label).toBe('1');
    expect(matches[0].full).toBe('[^1]');
  });

  it('matches multi-digit footnote [^12]', () => {
    const matches = findMatches('Text with[^12] reference.');
    expect(matches).toHaveLength(1);
    expect(matches[0].label).toBe('12');
  });

  it('matches multiple footnotes in same text', () => {
    const matches = findMatches('First[^1] and second[^2] notes.');
    expect(matches).toHaveLength(2);
    expect(matches[0].label).toBe('1');
    expect(matches[1].label).toBe('2');
  });

  it('does NOT match footnote definitions [^1]:', () => {
    const matches = findMatches('[^1]: This is a definition.');
    expect(matches).toHaveLength(0);
  });

  it('matches reference but not definition in same text', () => {
    const text = 'See[^1] for details.\n\n[^1]: The definition.';
    const matches = findMatches(text);
    expect(matches).toHaveLength(1);
    expect(matches[0].label).toBe('1');
    expect(matches[0].index).toBeLessThan(text.indexOf('[^1]:'));
  });

  it('does not match text without footnote syntax', () => {
    const matches = findMatches('No footnotes here.');
    expect(matches).toHaveLength(0);
  });

  it('does not match non-digit footnotes [^abc]', () => {
    const matches = findMatches('Text [^abc] here.');
    expect(matches).toHaveLength(0);
  });

  it('matches adjacent footnotes', () => {
    const matches = findMatches('Text[^1][^2] here.');
    expect(matches).toHaveLength(2);
  });
});
