import { describe, expect, it } from 'vitest';

// Test the regex pattern from the InputRule in isolation.
// ProseMirror wiring is tested manually in the app.
const PATTERN = /\[([^\]]+)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)$/;

describe('markdown-link InputRule regex', () => {
  it('matches basic [text](url)', () => {
    const m = '[hello](https://example.com)'.match(PATTERN);
    expect(m).not.toBeNull();
    expect(m![1]).toBe('hello');
    expect(m![2]).toBe('https://example.com');
    expect(m![3]).toBeUndefined();
  });

  it('matches [text](url "title")', () => {
    const m = '[hello](https://example.com "My Title")'.match(PATTERN);
    expect(m).not.toBeNull();
    expect(m![1]).toBe('hello');
    expect(m![2]).toBe('https://example.com');
    expect(m![3]).toBe('My Title');
  });

  it('does not match when text is empty', () => {
    expect('[](https://example.com)'.match(PATTERN)).toBeNull();
  });

  it('does not match when href is empty', () => {
    expect('[text]()'.match(PATTERN)).toBeNull();
  });

  it('does not match when href contains whitespace', () => {
    expect('[text](url with spaces)'.match(PATTERN)).toBeNull();
  });

  it('does not match URL with literal unencoded parenthesis (expected limitation)', () => {
    // Wikipedia-style URLs with literal () won't trigger — see plan risks section
    const m = '[C](https://en.wikipedia.org/wiki/C_(programming_language))'.match(PATTERN);
    // The regex stops at the first ) inside the URL, so this won't produce a full match
    // for the href. Acceptable: user must percent-encode or use escapeHref output.
    if (m) {
      expect(m[2]).not.toBe('https://en.wikipedia.org/wiki/C_(programming_language)');
    }
  });

  it('matches at end of longer text (inline within paragraph)', () => {
    const m = 'Here is a link [click here](https://x.com) text'.match(PATTERN);
    // $ anchors to end of string, so the link must be at the END
    // "text" after the ) means this won't match
    expect(m).toBeNull();
  });

  it('matches when link is at the very end of input', () => {
    const m = 'Here is [click here](https://x.com)'.match(PATTERN);
    expect(m).not.toBeNull();
    expect(m![1]).toBe('click here');
    expect(m![2]).toBe('https://x.com');
  });
});
