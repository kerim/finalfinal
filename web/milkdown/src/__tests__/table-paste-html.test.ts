// @vitest-environment jsdom
import { describe, expect, it } from 'vitest';

// Test buildInlineContentFromHTML logic in isolation using real DOMParser (jsdom).
// The function walks text/html clipboard content and extracts text + <a href> nodes.

function buildInlineContentFromHTML(html: string): { text: string; href?: string }[] | null {
  if (!html.includes('<a ')) return null;
  try {
    const doc = new DOMParser().parseFromString(html, 'text/html');
    const nodes: { text: string; href?: string }[] = [];
    let hasLinks = false;

    const walkNode = (node: globalThis.Node): void => {
      if (node.nodeType === 3 /* TEXT_NODE */) {
        const t = (node.textContent ?? '').replace(/\s+/g, ' ');
        if (t.trim()) nodes.push({ text: t });
      } else if ((node as Element).tagName === 'A') {
        const href = (node as HTMLAnchorElement).getAttribute('href') ?? '';
        const t = (node.textContent ?? '').replace(/\s+/g, ' ').trim();
        if (t) {
          hasLinks = true;
          nodes.push(href ? { text: t, href } : { text: t });
        }
      } else {
        Array.from(node.childNodes).forEach(walkNode);
      }
    };

    Array.from(doc.body.childNodes).forEach(walkNode);
    return hasLinks ? nodes : null;
  } catch {
    return null;
  }
}

describe('buildInlineContentFromHTML', () => {
  it('returns null when HTML has no <a> tags', () => {
    expect(buildInlineContentFromHTML('<p>hello world</p>')).toBeNull();
  });

  it('returns null for empty string', () => {
    expect(buildInlineContentFromHTML('')).toBeNull();
  });

  it('extracts a single link with href', () => {
    const nodes = buildInlineContentFromHTML('<a href="https://example.com">hello</a>');
    expect(nodes).not.toBeNull();
    expect(nodes).toHaveLength(1);
    expect(nodes![0]).toEqual({ text: 'hello', href: 'https://example.com' });
  });

  it('extracts text before and after a link', () => {
    const nodes = buildInlineContentFromHTML('Visit <a href="https://example.com">hello</a> today');
    expect(nodes).not.toBeNull();
    expect(nodes).toHaveLength(3);
    expect(nodes![0].text).toBe('Visit ');
    expect(nodes![0].href).toBeUndefined();
    expect(nodes![1]).toEqual({ text: 'hello', href: 'https://example.com' });
    expect(nodes![2].text).toBe(' today');
    expect(nodes![2].href).toBeUndefined();
  });

  it('extracts multiple links', () => {
    const nodes = buildInlineContentFromHTML('<a href="http://a.com">A</a> and <a href="http://b.com">B</a>');
    expect(nodes).not.toBeNull();
    expect(nodes!.filter((n) => n.href)).toHaveLength(2);
    expect(nodes!.find((n) => n.href === 'http://a.com')?.text).toBe('A');
    expect(nodes!.find((n) => n.href === 'http://b.com')?.text).toBe('B');
  });

  it('<a> with empty href produces text node without href', () => {
    const nodes = buildInlineContentFromHTML('<a href="">no link</a>');
    expect(nodes).not.toBeNull();
    expect(nodes![0].href).toBeUndefined();
    expect(nodes![0].text).toBe('no link');
  });

  it('handles Milkdown-style HTML with wrapper spans and paragraphs', () => {
    const milkdownHtml =
      "<meta charset='utf-8'><p><span>checking you need to sign up for </span>" +
      '<a href="https://languagetool.org/premium">the premium version</a>' +
      '<span> and get an API key.</span></p>';
    const nodes = buildInlineContentFromHTML(milkdownHtml);
    expect(nodes).not.toBeNull();
    const linkNode = nodes!.find((n) => n.href);
    expect(linkNode).toEqual({ text: 'the premium version', href: 'https://languagetool.org/premium' });
  });

  it('returns null when <a> tags are present but all empty', () => {
    // No text in the anchor → hasLinks stays false → null
    expect(buildInlineContentFromHTML('<a href="https://example.com"></a>')).toBeNull();
  });
});
