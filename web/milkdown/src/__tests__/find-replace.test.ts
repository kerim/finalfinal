import { describe, expect, it } from 'vitest';
import { buildSearchRegex } from '../find-replace';

describe('buildSearchRegex', () => {
  it('builds case-insensitive regex by default', () => {
    const regex = buildSearchRegex('hello', {});
    expect(regex).not.toBeNull();
    expect(regex!.flags).toContain('i');
    expect(regex!.flags).toContain('g');
    regex!.lastIndex = 0;
    expect(regex!.test('Hello')).toBe(true);
    regex!.lastIndex = 0;
    expect(regex!.test('HELLO')).toBe(true);
  });

  it('builds case-sensitive regex when option set', () => {
    const regex = buildSearchRegex('hello', { caseSensitive: true });
    expect(regex).not.toBeNull();
    expect(regex!.flags).not.toContain('i');
    regex!.lastIndex = 0;
    expect(regex!.test('hello')).toBe(true);
    regex!.lastIndex = 0;
    expect(regex!.test('Hello')).toBe(false);
  });

  it('escapes regex special characters for literal search', () => {
    const regex = buildSearchRegex('file.txt', {});
    expect(regex).not.toBeNull();
    regex!.lastIndex = 0;
    expect(regex!.test('file.txt')).toBe(true);
    regex!.lastIndex = 0;
    // Should NOT match "filextxt" (dot should be literal, not wildcard)
    expect(regex!.test('filextxt')).toBe(false);
  });

  it('escapes parentheses and brackets', () => {
    const regex = buildSearchRegex('fn(x)', {});
    expect(regex).not.toBeNull();
    regex!.lastIndex = 0;
    expect(regex!.test('fn(x)')).toBe(true);
  });

  it('wraps with word boundaries for wholeWord', () => {
    const regex = buildSearchRegex('the', { wholeWord: true });
    expect(regex).not.toBeNull();
    regex!.lastIndex = 0;
    expect(regex!.test('the')).toBe(true);
    regex!.lastIndex = 0;
    expect(regex!.test('the cat')).toBe(true);
    regex!.lastIndex = 0;
    expect(regex!.test('other')).toBe(false);
    regex!.lastIndex = 0;
    expect(regex!.test('theme')).toBe(false);
  });

  it('passes through raw regex when regexp option set', () => {
    const regex = buildSearchRegex('\\d+', { regexp: true });
    expect(regex).not.toBeNull();
    regex!.lastIndex = 0;
    expect(regex!.test('abc123')).toBe(true);
    regex!.lastIndex = 0;
    expect(regex!.test('abc')).toBe(false);
  });

  it('returns null for invalid regex pattern', () => {
    const regex = buildSearchRegex('[invalid', { regexp: true });
    expect(regex).toBeNull();
  });

  it('combines wholeWord and caseSensitive', () => {
    const regex = buildSearchRegex('Word', { wholeWord: true, caseSensitive: true });
    expect(regex).not.toBeNull();
    regex!.lastIndex = 0;
    expect(regex!.test('Word')).toBe(true);
    regex!.lastIndex = 0;
    expect(regex!.test('word')).toBe(false);
    regex!.lastIndex = 0;
    expect(regex!.test('Wordy')).toBe(false);
  });
});

describe('buildSearchRegex — annotation safety', () => {
  // In Milkdown (ProseMirror), annotations are atom nodes — findAllMatches
  // only walks node.isText nodes, so annotations are structurally invisible.
  // In CodeMirror, @codemirror/search operates on raw markdown — annotations
  // are plain <!-- ::type:: text --> strings and fully searchable/replaceable.
  // These tests document the regex-level behavior (no structural protection).

  it('matches text inside annotation comment syntax', () => {
    const regex = buildSearchRegex('fix', {});
    expect(regex).not.toBeNull();
    const annotationText = '<!-- ::task:: fix the bug -->';
    regex!.lastIndex = 0;
    expect(regex!.test(annotationText)).toBe(true);
  });

  it('matches both inside and outside annotation comments', () => {
    const regex = buildSearchRegex('review', {});
    expect(regex).not.toBeNull();
    const content = 'Please review this. <!-- ::task:: review the draft -->';
    const matches: string[] = [];
    let m: RegExpExecArray | null;
    regex!.lastIndex = 0;
    while ((m = regex!.exec(content)) !== null) {
      matches.push(m[0]);
    }
    // Regex finds "review" in both the prose and the annotation comment
    // This documents the vulnerability: replace-all would corrupt annotation syntax
    expect(matches.length).toBe(2);
  });

  it('matches annotation delimiter characters when searched literally', () => {
    // Searching for "::" would match inside annotation syntax
    const regex = buildSearchRegex('::', {});
    expect(regex).not.toBeNull();
    const annotationText = '<!-- ::task:: do something -->';
    regex!.lastIndex = 0;
    const matches: string[] = [];
    let m: RegExpExecArray | null;
    while ((m = regex!.exec(annotationText)) !== null) {
      matches.push(m[0]);
    }
    // Two occurrences of "::" in "::task::"
    expect(matches.length).toBe(2);
  });

  it('wholeWord does not protect annotation content', () => {
    // Even with wholeWord, a word like "fix" inside an annotation is matched
    const regex = buildSearchRegex('fix', { wholeWord: true });
    expect(regex).not.toBeNull();
    const annotationText = '<!-- ::task:: fix the bug -->';
    regex!.lastIndex = 0;
    expect(regex!.test(annotationText)).toBe(true);
  });
});
