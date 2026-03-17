import { describe, expect, it } from 'vitest';
import { type CitationAttrs, citationBracketRegex, parseCitationBracket, serializeCitation } from '../citation-types';

describe('citationBracketRegex', () => {
  it('matches single citekey [@smith2023]', () => {
    const text = 'See [@smith2023] for details.';
    const matches = [...text.matchAll(citationBracketRegex)];
    expect(matches).toHaveLength(1);
    expect(matches[0][1]).toBe('@smith2023');
  });

  it('matches multiple citekeys [@a; @b]', () => {
    const text = 'See [@jones2020; @smith2023] for details.';
    const matches = [...text.matchAll(citationBracketRegex)];
    expect(matches).toHaveLength(1);
    expect(matches[0][1]).toBe('@jones2020; @smith2023');
  });

  it('matches citekey with locator [@smith2023, p. 42]', () => {
    const text = 'As noted [@smith2023, p. 42].';
    const matches = [...text.matchAll(citationBracketRegex)];
    expect(matches).toHaveLength(1);
    expect(matches[0][1]).toContain('@smith2023');
  });

  it('does not match brackets without @', () => {
    const text = 'See [this link] for details.';
    const matches = [...text.matchAll(citationBracketRegex)];
    expect(matches).toHaveLength(0);
  });

  it('matches citekey with colon and dot [@doe:2024.ch1]', () => {
    const text = '[@doe:2024.ch1]';
    const matches = [...text.matchAll(citationBracketRegex)];
    expect(matches).toHaveLength(1);
  });

  it('matches suppress-author [-@smith2023]', () => {
    const text = '[-@smith2023]';
    const matches = [...text.matchAll(citationBracketRegex)];
    expect(matches).toHaveLength(1);
  });
});

describe('parseCitationBracket', () => {
  it('parses single citekey', () => {
    const result = parseCitationBracket('@smith2023');
    expect(result.citekeys).toEqual(['smith2023']);
    expect(result.locators).toEqual(['']);
    expect(result.prefix).toBe('');
    expect(result.suppressAuthor).toBe(false);
  });

  it('parses multiple citekeys separated by semicolons', () => {
    const result = parseCitationBracket('@jones2020; @smith2023');
    expect(result.citekeys).toEqual(['jones2020', 'smith2023']);
  });

  it('parses citekey with locator', () => {
    const result = parseCitationBracket('@smith2023, p. 42');
    expect(result.citekeys).toEqual(['smith2023']);
    expect(result.locators).toEqual(['p. 42']);
  });

  it('parses prefix text before @', () => {
    const result = parseCitationBracket('see @smith2023');
    expect(result.prefix).toBe('see');
    expect(result.citekeys).toEqual(['smith2023']);
  });

  it('parses suppress-author flag', () => {
    const result = parseCitationBracket('-@smith2023');
    expect(result.suppressAuthor).toBe(true);
    expect(result.citekeys).toEqual(['smith2023']);
  });

  it('stores rawSyntax with brackets', () => {
    const result = parseCitationBracket('@smith2023');
    expect(result.rawSyntax).toBe('[@smith2023]');
  });

  it('handles complex multi-key with locators', () => {
    const result = parseCitationBracket('@jones2020, ch. 3; @smith2023, p. 42');
    expect(result.citekeys).toEqual(['jones2020', 'smith2023']);
    expect(result.locators).toEqual(['ch. 3', 'p. 42']);
  });
});

describe('serializeCitation', () => {
  it('serializes single citekey', () => {
    const attrs: CitationAttrs = {
      citekeys: 'smith2023',
      locators: '[""]',
      prefix: '',
      suffix: '',
      suppressAuthor: false,
      rawSyntax: '[@smith2023]',
    };
    expect(serializeCitation(attrs)).toBe('[@smith2023]');
  });

  it('serializes with locator', () => {
    const attrs: CitationAttrs = {
      citekeys: 'smith2023',
      locators: '["p. 42"]',
      prefix: '',
      suffix: '',
      suppressAuthor: false,
      rawSyntax: '[@smith2023, p. 42]',
    };
    expect(serializeCitation(attrs)).toBe('[@smith2023, p. 42]');
  });

  it('serializes with prefix', () => {
    const attrs: CitationAttrs = {
      citekeys: 'smith2023',
      locators: '[""]',
      prefix: 'see',
      suffix: '',
      suppressAuthor: false,
      rawSyntax: '[see @smith2023]',
    };
    expect(serializeCitation(attrs)).toBe('[see @smith2023]');
  });

  it('serializes suppress-author', () => {
    const attrs: CitationAttrs = {
      citekeys: 'smith2023',
      locators: '[""]',
      prefix: '',
      suffix: '',
      suppressAuthor: true,
      rawSyntax: '[-@smith2023]',
    };
    expect(serializeCitation(attrs)).toBe('[-@smith2023]');
  });

  it('serializes multiple citekeys', () => {
    const attrs: CitationAttrs = {
      citekeys: 'jones2020,smith2023',
      locators: '["", "p. 42"]',
      prefix: '',
      suffix: '',
      suppressAuthor: false,
      rawSyntax: '[@jones2020; @smith2023, p. 42]',
    };
    expect(serializeCitation(attrs)).toBe('[@jones2020; @smith2023, p. 42]');
  });

  it('roundtrips parse → serialize for simple citation', () => {
    const parsed = parseCitationBracket('@smith2023');
    const attrs: CitationAttrs = {
      citekeys: parsed.citekeys.join(','),
      locators: JSON.stringify(parsed.locators),
      prefix: parsed.prefix,
      suffix: parsed.suffix,
      suppressAuthor: parsed.suppressAuthor,
      rawSyntax: parsed.rawSyntax,
    };
    expect(serializeCitation(attrs)).toBe('[@smith2023]');
  });
});
