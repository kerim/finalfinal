import { describe, expect, it } from 'vitest';

// Test the regex used by buildInlineContent in table-paste-plugin.ts in isolation.
// ProseMirror schema wiring is tested manually in the app.
// Matches [text](url "title") OR bare https?:// URLs.
const PATTERN = /\[([^\]]+)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)|(https?:\/\/[^\s]+)/g;

function findLinks(text: string) {
  return [...text.matchAll(PATTERN)].map((m) => ({
    full: m[0],
    text: m[1] ?? m[4],
    href: m[2] ?? m[4],
    title: m[3],
    isBare: m[4] !== undefined,
    index: m.index,
  }));
}

describe('table-paste buildInlineContent regex', () => {
  // Markdown [text](url) syntax
  it('finds no links in plain text', () => {
    expect(findLinks('hello world')).toHaveLength(0);
  });

  it('finds a single markdown link', () => {
    const links = findLinks('[hello](https://example.com)');
    expect(links).toHaveLength(1);
    expect(links[0].text).toBe('hello');
    expect(links[0].href).toBe('https://example.com');
    expect(links[0].title).toBeUndefined();
    expect(links[0].isBare).toBe(false);
  });

  it('finds a markdown link with title', () => {
    const links = findLinks('[hello](https://example.com "My Title")');
    expect(links[0].title).toBe('My Title');
    expect(links[0].isBare).toBe(false);
  });

  it('finds a markdown link in surrounding text (not end-anchored)', () => {
    const links = findLinks('Visit [hello](https://example.com) today');
    expect(links).toHaveLength(1);
    expect(links[0].index).toBe(6);
    expect(links[0].text).toBe('hello');
    expect(links[0].isBare).toBe(false);
  });

  it('finds multiple markdown links', () => {
    const links = findLinks('[a](http://a.com) and [b](http://b.com)');
    expect(links).toHaveLength(2);
    expect(links[0].text).toBe('a');
    expect(links[1].text).toBe('b');
  });

  it('finds consecutive markdown links with no gap', () => {
    const links = findLinks('[a](http://a.com)[b](http://b.com)');
    expect(links).toHaveLength(2);
    expect(links[0].full).toBe('[a](http://a.com)');
    expect(links[1].full).toBe('[b](http://b.com)');
  });

  it('does not match markdown link when href contains whitespace', () => {
    // Only the URL part (before the space) would be matched as a bare URL if it starts with https?://
    expect(findLinks('[text](url with spaces)')).toHaveLength(0);
  });

  it('does not match markdown link when text is empty', () => {
    // [](url) — but the URL inside would match as a bare URL if it starts with https?://
    expect(findLinks('[](url with spaces)')).toHaveLength(0);
  });

  it('treats empty-string title as absent (falsy m[3])', () => {
    const links = findLinks('[text](https://example.com "")');
    expect(links).toHaveLength(1);
    expect(links[0].title).toBe('');
    expect(links[0].isBare).toBe(false);
  });

  // Bare URL detection
  it('finds a bare https URL', () => {
    const links = findLinks('https://example.com');
    expect(links).toHaveLength(1);
    expect(links[0].text).toBe('https://example.com');
    expect(links[0].href).toBe('https://example.com');
    expect(links[0].isBare).toBe(true);
  });

  it('finds a bare http URL', () => {
    const links = findLinks('http://example.com');
    expect(links).toHaveLength(1);
    expect(links[0].isBare).toBe(true);
    expect(links[0].href).toBe('http://example.com');
  });

  it('finds a bare URL in surrounding text', () => {
    const links = findLinks('Visit https://example.com today');
    expect(links).toHaveLength(1);
    expect(links[0].isBare).toBe(true);
    expect(links[0].href).toBe('https://example.com');
    expect(links[0].index).toBe(6);
  });

  it('does not match non-http bare URLs', () => {
    expect(findLinks('ftp://example.com')).toHaveLength(0);
  });

  it('finds a bare URL alongside a markdown link', () => {
    const links = findLinks('[hello](https://example.com) and https://other.com');
    expect(links).toHaveLength(2);
    expect(links[0].isBare).toBe(false);
    expect(links[0].text).toBe('hello');
    expect(links[1].isBare).toBe(true);
    expect(links[1].href).toBe('https://other.com');
  });

  it('bare URL inside [text](url) is consumed by markdown pattern, not double-matched', () => {
    // The URL in the markdown link should NOT be separately matched as a bare URL
    const links = findLinks('[hello](https://example.com)');
    expect(links).toHaveLength(1);
    expect(links[0].isBare).toBe(false);
  });
});
