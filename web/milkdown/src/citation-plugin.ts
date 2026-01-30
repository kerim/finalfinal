// Citation Plugin for Milkdown
// Parses Pandoc-style citations: [@citekey], [@a; @b], [@key, p. 42]
// Renders as inline atomic nodes with formatted display

import { MilkdownPlugin, Ctx } from '@milkdown/kit/ctx';
import { Node } from '@milkdown/kit/prose/model';
import { $node, $remark, $view } from '@milkdown/kit/utils';
import { visit } from 'unist-util-visit';
import type { Root } from 'mdast';
import { getCiteprocEngine, CSLItem } from './citeproc-engine';

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
      // Use 'html' node type to output raw content without escaping
      // (text nodes escape [ to \[ which breaks citation syntax)
      state.addNode('html', undefined, syntax);
    },
  },
}));

// Re-export CSLItem type for external use
export type { CSLItem };

// Parse edited citation text back to structured data
function parseEditedCitation(text: string): {
  citekeys: string[];
  locators: string[];
  prefix: string;
  suffix: string;
  suppressAuthor: boolean;
} | null {
  const trimmed = text.trim();

  // Must be bracketed
  if (!trimmed.startsWith('[') || !trimmed.endsWith(']')) {
    return null;
  }

  const inner = trimmed.slice(1, -1);
  if (!inner.includes('@')) {
    return null;
  }

  const citekeys: string[] = [];
  const locators: string[] = [];
  let prefix = '';
  let suffix = '';
  let suppressAuthor = false;

  // Split by semicolon for multiple citations
  const parts = inner.split(';').map(p => p.trim());

  for (const part of parts) {
    // Check for prefix before @
    const atIndex = part.indexOf('@');
    if (atIndex > 0) {
      const beforeAt = part.slice(0, atIndex).trim();
      if (beforeAt !== '-') {
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

  if (citekeys.length === 0) {
    return null;
  }

  return { citekeys, locators, prefix, suffix, suppressAuthor };
}

// Citation edit popup state (module-level singleton)
let editPopup: HTMLElement | null = null;
let editPopupInput: HTMLInputElement | null = null;
let editPopupPreview: HTMLElement | null = null;
let editingNodePos: number | null = null;
let editingView: EditorView | null = null;
let editPopupBlurTimeout: ReturnType<typeof setTimeout> | null = null;

// Import EditorView type for popup functions
import type { EditorView } from '@milkdown/kit/prose/view';

// Create the edit popup structure (singleton, reused)
function createEditPopup(): HTMLElement {
  if (editPopup) return editPopup;

  // Create popup container
  const popup = document.createElement('div');
  popup.className = 'ff-citation-edit-popup';
  popup.style.cssText = `
    position: fixed;
    z-index: 10000;
    background: var(--bg-primary, #fff);
    border: 1px solid var(--border-color, #ccc);
    border-radius: 6px;
    padding: 8px;
    box-shadow: 0 4px 12px rgba(0,0,0,0.15);
    min-width: 280px;
    display: none;
  `;

  // Create input element
  const input = document.createElement('input');
  input.type = 'text';
  input.className = 'ff-citation-edit-input';
  input.spellcheck = false;
  input.style.cssText = `
    width: 100%;
    padding: 6px 8px;
    border: 1px solid var(--border-color, #ccc);
    border-radius: 4px;
    font-family: monospace;
    font-size: 13px;
    background: var(--bg-secondary, #f5f5f5);
    color: var(--text-primary, #333);
    box-sizing: border-box;
  `;

  // Create preview element
  const preview = document.createElement('div');
  preview.className = 'ff-citation-edit-preview';
  preview.style.cssText = `
    margin-top: 6px;
    padding: 6px 8px;
    background: var(--bg-tertiary, #eee);
    border-radius: 4px;
    font-size: 13px;
    color: var(--text-secondary, #666);
  `;

  // Create hint element
  const hint = document.createElement('div');
  hint.className = 'ff-citation-edit-hint';
  hint.textContent = 'Enter to save • Escape to cancel';
  hint.style.cssText = `
    margin-top: 6px;
    font-size: 11px;
    color: var(--text-tertiary, #999);
    text-align: center;
  `;

  // Assemble popup
  popup.appendChild(input);
  popup.appendChild(preview);
  popup.appendChild(hint);

  // Event handlers
  input.addEventListener('input', () => {
    updateEditPreview();
  });

  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      commitEdit(input.value);
    } else if (e.key === 'Escape') {
      e.preventDefault();
      cancelEdit();
    }
  });

  input.addEventListener('blur', () => {
    // Delay to allow click-through to other citations
    editPopupBlurTimeout = setTimeout(() => {
      if (editPopup?.style.display !== 'none') {
        commitEdit(input.value);
      }
    }, 150);
  });

  input.addEventListener('focus', () => {
    // Cancel any pending blur commit if we refocused
    if (editPopupBlurTimeout) {
      clearTimeout(editPopupBlurTimeout);
      editPopupBlurTimeout = null;
    }
  });

  editPopup = popup;
  editPopupInput = input;
  editPopupPreview = preview;

  document.body.appendChild(popup);
  return popup;
}

// Update preview based on current input
function updateEditPreview(): void {
  if (!editPopupInput || !editPopupPreview) return;

  const text = editPopupInput.value;
  const parsed = parseEditedCitation(text);

  if (parsed && parsed.citekeys.length > 0) {
    const engine = getCiteprocEngine();
    const allResolved = parsed.citekeys.every(k => engine.hasItem(k));

    if (allResolved) {
      try {
        const formatted = engine.formatCitation(parsed.citekeys, {
          suppressAuthor: parsed.suppressAuthor,
          locator: parsed.locators[0] || undefined,
          prefix: parsed.prefix,
          suffix: parsed.suffix,
        });
        editPopupPreview.textContent = formatted;
        editPopupPreview.style.color = 'var(--text-secondary, #666)';
      } catch (e) {
        editPopupPreview.textContent = `(${parsed.citekeys.join('; ')})`;
        editPopupPreview.style.color = 'var(--text-secondary, #666)';
      }
    } else {
      // Show unresolved keys with ?
      const display = parsed.citekeys.map(k =>
        engine.hasItem(k) ? engine.getShortCitation(k) : `${k}?`
      ).join('; ');
      editPopupPreview.textContent = `(${display})`;
      editPopupPreview.style.color = 'var(--warning-color, #c9a227)';
    }
  } else {
    editPopupPreview.textContent = 'Invalid citation syntax';
    editPopupPreview.style.color = 'var(--error-color, #c00)';
  }
}

// Show the citation edit popup
function showCitationEditPopup(pos: number, view: EditorView, attrs: CitationAttrs): void {
  console.log('[CitationEditPopup] showCitationEditPopup called, pos:', pos);

  // If popup already open, commit current edit first
  if (editingNodePos !== null && editingView && editPopupInput) {
    commitEdit(editPopupInput.value);
  }

  // Store editing context
  editingNodePos = pos;
  editingView = view;

  // Create popup if needed
  const popup = createEditPopup();
  const input = editPopupInput!;

  // Get raw syntax
  const rawSyntax = attrs.rawSyntax || serializeCitation(attrs);

  // Position popup below the citation
  const coords = view.coordsAtPos(pos);
  popup.style.left = `${coords.left}px`;
  popup.style.top = `${coords.bottom + 4}px`;

  // Populate and show
  input.value = rawSyntax;
  popup.style.display = 'block';

  // Update preview
  updateEditPreview();

  // Focus and select all
  input.focus();
  input.select();
}

// Commit the edit
function commitEdit(newSyntax: string): void {
  console.log('[CitationEditPopup] commitEdit called with:', newSyntax);

  const pos = editingNodePos;
  const view = editingView;

  if (pos === null || !view) {
    hideEditPopup();
    return;
  }

  // Parse the edited syntax
  const parsed = parseEditedCitation(newSyntax);

  if (parsed && parsed.citekeys.length > 0) {
    // Verify node still exists at position
    const currentNode = view.state.doc.nodeAt(pos);
    if (currentNode && currentNode.type.name === 'citation') {
      console.log('[CitationEditPopup] Updating citation attrs:', parsed.citekeys);
      const tr = view.state.tr.setNodeMarkup(pos, undefined, {
        citekeys: parsed.citekeys.join(','),
        locators: JSON.stringify(parsed.locators),
        prefix: parsed.prefix,
        suffix: parsed.suffix,
        suppressAuthor: parsed.suppressAuthor,
        rawSyntax: newSyntax.trim(),
      });
      view.dispatch(tr);
    }
  }

  hideEditPopup();
  // Refocus editor
  view.focus();
}

// Cancel the edit
function cancelEdit(): void {
  console.log('[CitationEditPopup] cancelEdit called');
  const view = editingView;
  hideEditPopup();
  // Refocus editor
  view?.focus();
}

// Hide the popup and clear state
function hideEditPopup(): void {
  if (editPopup) {
    editPopup.style.display = 'none';
  }
  if (editPopupBlurTimeout) {
    clearTimeout(editPopupBlurTimeout);
    editPopupBlurTimeout = null;
  }
  editingNodePos = null;
  editingView = null;
}

// NodeView for custom rendering with formatted citation display
// This must be in the same file as citationNode to maintain atom identity with $view
// NOTE: $view expects (ctx) => NodeViewConstructor, NOT () => (ctx) => NodeViewConstructor
const citationNodeView = $view(citationNode, (ctx: Ctx) => {
  console.log('[CitationNodeView] FACTORY CALLED - ctx:', !!ctx);
  return (node, view, getPos) => {
    console.log('[CitationNodeView] VIEW CREATED for node:', node.attrs.citekeys);
    const attrs = node.attrs as CitationAttrs;
    // NOTE: citekeys is computed fresh inside updateDisplay() to avoid stale closure

    // Create DOM structure
    const dom = document.createElement('span');
    dom.className = 'ff-citation';

    // Update display content
    const updateDisplay = () => {
      // Compute citekeys fresh from current attrs (not stale closure)
      const citekeys = attrs.citekeys.split(',').filter(k => k.trim());

      const engine = getCiteprocEngine();
      let displayText = '';
      let isResolved = true;
      let tooltipText = '';

      console.log('[CitationNodeView] updateDisplay called for citekeys:', citekeys, 'from attrs.citekeys:', attrs.citekeys);

      if (citekeys.length === 0) {
        displayText = '[?]';
        isResolved = false;
        tooltipText = 'No citation key';
      } else {
        // Check resolution status
        const unresolvedKeys = citekeys.filter(k => !engine.hasItem(k));
        isResolved = unresolvedKeys.length === 0;

        if (isResolved) {
          // Get formatted citation from citeproc
          try {
            displayText = engine.formatCitation(citekeys, {
              suppressAuthor: attrs.suppressAuthor,
              locator: attrs.locators ? JSON.parse(attrs.locators)[0] : undefined,
              prefix: attrs.prefix,
              suffix: attrs.suffix,
            });

            // Build tooltip with full citation info
            const items = citekeys.map(k => engine.getItem(k)).filter(Boolean) as CSLItem[];
            tooltipText = items.map(item => {
              const author = item.author?.[0];
              const authorName = author?.family || author?.literal || '';
              const year = item.issued?.['date-parts']?.[0]?.[0] || 'n.d.';
              const title = item.title || '';
              return `${authorName} (${year}). ${title}`;
            }).join('\n');
          } catch (e) {
            // Fallback to short citation
            displayText = `(${citekeys.map(k => engine.getShortCitation(k)).join('; ')})`;
            tooltipText = displayText;
          }
        } else {
          // Show unresolved with ? suffix
          displayText = `(${citekeys.map(k => {
            if (engine.hasItem(k)) {
              return engine.getShortCitation(k);
            }
            return `${k}?`;
          }).join('; ')})`;
          tooltipText = `Unresolved: ${unresolvedKeys.join(', ')}`;
        }
      }

      // Update DOM
      console.log('[CitationNodeView] Display result:', { displayText, isResolved, citekeys });
      dom.textContent = displayText;
      dom.title = tooltipText;
      dom.className = `ff-citation ${isResolved ? 'ff-citation-resolved' : 'ff-citation-unresolved'}`;
      dom.dataset.citekeys = attrs.citekeys;
      dom.dataset.rawsyntax = attrs.rawSyntax;
    };

    // Click handler - open popup
    dom.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      const pos = typeof getPos === 'function' ? getPos() : null;
      if (pos !== null && pos !== undefined) {
        showCitationEditPopup(pos, view, node.attrs as CitationAttrs);
      }
    });

    // Initial render
    updateDisplay();

    return {
      dom,
      update: (updatedNode) => {
        if (updatedNode.type.name !== 'citation') return false;

        // Update attrs from node
        const newAttrs = updatedNode.attrs as CitationAttrs;
        Object.assign(attrs, newAttrs);

        // Refresh display
        updateDisplay();
        return true;
      },
      destroy: () => {
        // Nothing to clean up - popup is singleton
      },
      // Let ProseMirror handle events normally (no edit mode)
      stopEvent: () => false,
      // Ignore mutations to this node
      ignoreMutation: () => true,
    };
  };
});

// Export the plugin array - node view MUST be in same array to maintain atom identity
export const citationPlugin: MilkdownPlugin[] = [
  remarkCitationPlugin,
  citationNode,
  citationNodeView,  // Node view included here, same file as node definition
].flat();

// Export node for use in citation-search.ts (citationNode is already exported via the const definition)
