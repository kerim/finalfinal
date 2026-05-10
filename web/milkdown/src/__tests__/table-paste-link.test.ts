import { describe, expect, it } from 'vitest';

// Test the regex used by buildInlineContent in table-paste-plugin.ts in isolation.
// ProseMirror schema wiring is tested manually in the app.
const PATTERN = /\[([^\]]+)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)/g;

function findLinks(text: string) {
  return [...text.matchAll(PATTERN)].map((m) => ({
    full: m[0],
    text: m[1],
    href: m[2],
    title: m[3],
    index: m.index,
  }));
}

describe('table-paste buildInlineContent regex', () => {
  it('finds no links in plain text', () => {
    expect(findLinks('hello world')).toHaveLength(0);
  });

  it('finds a single link', () => {
    const links = findLinks('[hello](https://example.com)');
    expect(links).toHaveLength(1);
    expect(links[0].text).toBe('hello');
    expect(links[0].href).toBe('https://example.com');
    expect(links[0].title).toBeUndefined();
  });

  it('finds a link with title', () => {
    const links = findLinks('[hello](https://example.com "My Title")');
    expect(links[0].title).toBe('My Title');
  });

  it('finds a link in surrounding text (not end-anchored)', () => {
    const links = findLinks('Visit [hello](https://example.com) today');
    expect(links).toHaveLength(1);
    expect(links[0].index).toBe(6);
    expect(links[0].text).toBe('hello');
  });

  it('finds multiple links', () => {
    const links = findLinks('[a](http://a.com) and [b](http://b.com)');
    expect(links).toHaveLength(2);
    expect(links[0].text).toBe('a');
    expect(links[1].text).toBe('b');
  });

  it('finds consecutive links with no gap', () => {
    const links = findLinks('[a](http://a.com)[b](http://b.com)');
    expect(links).toHaveLength(2);
    expect(links[0].full).toBe('[a](http://a.com)');
    expect(links[1].full).toBe('[b](http://b.com)');
  });

  it('does not match when href contains whitespace', () => {
    expect(findLinks('[text](url with spaces)')).toHaveLength(0);
  });

  it('does not match when text is empty', () => {
    expect(findLinks('[](https://example.com)')).toHaveLength(0);
  });

  it('treats empty-string title as absent (falsy m[3])', () => {
    // [text](url "") triggers the title capture group with ""
    const links = findLinks('[text](https://example.com "")');
    expect(links).toHaveLength(1);
    expect(links[0].title).toBe('');
  });
});
