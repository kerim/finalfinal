// Citation Plugin for Milkdown
// Parses Pandoc-style citations: [@citekey], [@a; @b], [@key, p. 42]
// Renders as inline atomic nodes with formatted display

import { MilkdownPlugin } from '@milkdown/kit/ctx';
import { Node } from '@milkdown/kit/prose/model';
import { $node, $remark } from '@milkdown/kit/utils';
import { visit } from 'unist-util-visit';
import type { Root } from 'mdast';

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

// Regex to match full bracketed citation: [...]
// Must contain at least one @citekey
const citationBracketRegex = /\[([^\]]*@[\w:.-][^\]]*)\]/g;

// Regex to parse individual citations within bracket
// Matches: optional prefix, optional -, @citekey, optional locator/suffix
// Examples: @smith2023, -@smith2023, @smith2023, p. 42, see @smith2023
const singleCiteRegex = /(-?)@([\w:.-]+)(?:,\s*([^;@\]]+))?/g;

// Parse a citation bracket into structured data
interface ParsedCitation {
  citekeys: string[];
  locators: string[];
  prefix: string;
  suffix: string;
  suppressAuthor: boolean;
  rawSyntax: string;
}

function parseCitationBracket(bracketContent: string): ParsedCitation {
  const citekeys: string[] = [];
  const locators: string[] = [];
  let suppressAuthor = false;
  let prefix = '';
  let suffix = '';

  // Split by semicolon for multiple citations
  const parts = bracketContent.split(';').map(p => p.trim());

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
  const citekeys = attrs.citekeys.split(',').filter(k => k.trim());
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
    result = result.slice(0, -1) + ` ${attrs.suffix}]`;
  }

  return result;
}

// Remark plugin to convert citation text to citation nodes
const remarkCitationPlugin = $remark('citation', () => () => (tree: Root) => {
  visit(tree, 'text', (node: any, index: number | null, parent: any) => {
    const value = node.value as string;
    if (!value || !value.includes('@')) return;

    const matches: Array<{ start: number; end: number; parsed: ParsedCitation }> = [];

    // Find all citation brackets
    let match;
    citationBracketRegex.lastIndex = 0;
    while ((match = citationBracketRegex.exec(value)) !== null) {
      const parsed = parseCitationBracket(match[1]);
      if (parsed.citekeys.length > 0) {
        matches.push({
          start: match.index,
          end: match.index + match[0].length,
          parsed,
        });
      }
    }

    if (matches.length === 0) return;

    // Build new children array with text and citation nodes
    const newChildren: any[] = [];
    let lastEnd = 0;

    for (const m of matches) {
      // Add text before citation
      if (m.start > lastEnd) {
        newChildren.push({
          type: 'text',
          value: value.slice(lastEnd, m.start),
        });
      }

      // Add citation node
      newChildren.push({
        type: 'citation',
        data: {
          citekeys: m.parsed.citekeys.join(','),
          locators: JSON.stringify(m.parsed.locators),
          prefix: m.parsed.prefix,
          suffix: m.parsed.suffix,
          suppressAuthor: m.parsed.suppressAuthor,
          rawSyntax: m.parsed.rawSyntax,
        },
      });

      lastEnd = m.end;
    }

    // Add remaining text
    if (lastEnd < value.length) {
      newChildren.push({
        type: 'text',
        value: value.slice(lastEnd),
      });
    }

    // Replace this node with the new children
    if (parent && typeof index === 'number') {
      parent.children.splice(index, 1, ...newChildren);
    }
  });
});

// Define the citation node (atomic, not editable inline)
export const citationNode = $node('citation', () => ({
  group: 'inline',
  inline: true,
  atom: true,  // Atomic - not editable, treated as single unit
  selectable: true,
  draggable: false,

  attrs: {
    citekeys: { default: '' },
    locators: { default: '[]' },
    prefix: { default: '' },
    suffix: { default: '' },
    suppressAuthor: { default: false },
    rawSyntax: { default: '' },
  },

  parseDOM: [
    {
      tag: 'span.ff-citation',
      getAttrs: (dom: HTMLElement) => ({
        citekeys: dom.dataset.citekeys || '',
        locators: dom.dataset.locators || '[]',
        prefix: dom.dataset.prefix || '',
        suffix: dom.dataset.suffix || '',
        suppressAuthor: dom.dataset.suppressauthor === 'true',
        rawSyntax: dom.dataset.rawsyntax || '',
      }),
    },
  ],

  toDOM: (node: Node) => {
    const attrs = node.attrs as CitationAttrs;
    const citekeys = attrs.citekeys.split(',').filter(k => k.trim());

    // Basic display (will be enhanced by node view)
    const displayText = citekeys.length > 0
      ? `[@${citekeys.join('; @')}]`
      : '[?]';

    return [
      'span',
      {
        class: 'ff-citation',
        'data-citekeys': attrs.citekeys,
        'data-locators': attrs.locators,
        'data-prefix': attrs.prefix,
        'data-suffix': attrs.suffix,
        'data-suppressauthor': String(attrs.suppressAuthor),
        'data-rawsyntax': attrs.rawSyntax,
        title: displayText,
      },
      displayText,
    ];
  },

  parseMarkdown: {
    match: (node: any) => node.type === 'citation',
    runner: (state: any, node: any, type: any) => {
      state.addNode(type, {
        citekeys: node.data.citekeys,
        locators: node.data.locators,
        prefix: node.data.prefix,
        suffix: node.data.suffix,
        suppressAuthor: node.data.suppressAuthor,
        rawSyntax: node.data.rawSyntax,
      });
    },
  },

  toMarkdown: {
    match: (node: Node) => node.type.name === 'citation',
    runner: (state: any, node: Node) => {
      const attrs = node.attrs as CitationAttrs;
      // Use rawSyntax if available, otherwise serialize
      const syntax = attrs.rawSyntax || serializeCitation(attrs);
      state.addNode('text', undefined, syntax);
    },
  },
}));

// Export the plugin array
export const citationPlugin: MilkdownPlugin[] = [
  remarkCitationPlugin,
  citationNode,
].flat();

// Re-export for use in node view
export { citationNode as citationNodeDef };
