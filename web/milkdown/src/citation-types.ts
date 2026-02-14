// Shared citation types and utilities
// Used by both citation-plugin.ts and citation-edit-popup.ts to avoid circular imports

import type { CSLItem } from './citeproc-engine';

// Re-export for consumers
export type { CSLItem };

// Citation attributes interface
export interface CitationAttrs {
  // Semicolon-separated list of citekeys
  citekeys: string;
  // Individual locators per citekey (JSON array, same order as citekeys)
  locators: string;
  // Prefix text (e.g., "see")
  prefix: string;
  // Suffix text
  suffix: string;
  // Suppress author (for -@key syntax)
  suppressAuthor: boolean;
  // Raw syntax for serialization
  rawSyntax: string;
}

// Parse a citation bracket into structured data
interface ParsedCitation {
  citekeys: string[];
  locators: string[];
  prefix: string;
  suffix: string;
  suppressAuthor: boolean;
  rawSyntax: string;
}

// Regex to match full bracketed citation: [...]
// Must contain at least one @citekey
export const citationBracketRegex = /\[([^\]]*@[\w:.-][^\]]*)\]/g;

export function parseCitationBracket(bracketContent: string): ParsedCitation {
  const citekeys: string[] = [];
  const locators: string[] = [];
  let suppressAuthor = false;
  let prefix = '';
  const suffix = '';

  // Split by semicolon for multiple citations
  const parts = bracketContent.split(';').map((p) => p.trim());

  for (const part of parts) {
    // Check for prefix before @
    const atIndex = part.indexOf('@');
    if (atIndex > 0) {
      const beforeAt = part.slice(0, atIndex).trim();
      if (!beforeAt.match(/^-$/)) {
        // This is a prefix (only capture from first citation)
        if (citekeys.length === 0) {
          prefix = beforeAt;
        }
      }
    }

    // Extract citekey and locator
    const match = part.match(/(-?)@([\w:.-]+)(?:,\s*(.+))?/);
    if (match) {
      const [, suppress, citekey, locator] = match;
      if (suppress === '-') {
        suppressAuthor = true;
      }
      citekeys.push(citekey);
      locators.push(locator?.trim() || '');
    }
  }

  return {
    citekeys,
    locators,
    prefix,
    suffix,
    suppressAuthor,
    rawSyntax: `[${bracketContent}]`,
  };
}

// Serialize citation attrs back to Pandoc syntax
export function serializeCitation(attrs: CitationAttrs): string {
  const citekeys = attrs.citekeys.split(',').filter((k) => k.trim());
  const locators = attrs.locators ? JSON.parse(attrs.locators) : [];

  const parts: string[] = [];

  for (let i = 0; i < citekeys.length; i++) {
    const key = citekeys[i].trim();
    const locator = locators[i] || '';
    const suppressPrefix = attrs.suppressAuthor && i === 0 ? '-' : '';
    const prefixText = i === 0 && attrs.prefix ? `${attrs.prefix} ` : '';

    let citation = `${prefixText}${suppressPrefix}@${key}`;
    if (locator) {
      citation += `, ${locator}`;
    }
    parts.push(citation);
  }

  let result = `[${parts.join('; ')}]`;
  if (attrs.suffix) {
    // Suffix goes inside bracket after last citation
    result = `${result.slice(0, -1)} ${attrs.suffix}]`;
  }

  return result;
}
