// Citation Plugin for Milkdown
// Parses Pandoc-style citations: [@citekey], [@a; @b], [@key, p. 42]
// Renders as inline atomic nodes with formatted display

import type { Ctx, MilkdownPlugin } from '@milkdown/kit/ctx';
import { keymap } from '@milkdown/kit/prose/keymap';
import type { Node } from '@milkdown/kit/prose/model';
import { $node, $prose, $remark, $view } from '@milkdown/kit/utils';
import type { Root } from 'mdast';
import { visit } from 'unist-util-visit';
import { buildCitationDeleteTransaction, CITATION_NODE_NAME } from './citation-delete';
import { showCitationEditPopup } from './citation-edit-popup';
import {
  type CitationAttrs,
  type CSLItem,
  citationBracketRegex,
  parseCitationBracket,
  serializeCitation,
} from './citation-types';
import { type CitationOptions, getCiteprocEngine } from './citeproc-engine';
import { isSourceModeEnabled } from './source-mode-plugin';

export {
  clearAppendMode,
  getEditPopupInput,
  getPendingAppendBase,
  isPendingAppendMode,
  updateEditPreview,
} from './citation-edit-popup';
// Re-export types and utilities for external consumers
export { type CitationAttrs, type CSLItem, serializeCitation } from './citation-types';

// === Lazy Resolution State ===
// Track citekeys that are pending resolution to avoid duplicate requests
const pendingResolutionKeys = new Set<string>();

/**
 * Request lazy resolution of unresolved citekeys from Swift/Zotero
 * Called from CitationNodeView when citekeys can't be formatted
 */
export function requestCitationResolution(keys: string[]): void {
  // Filter out keys already pending or already resolved
  const engine = getCiteprocEngine();
  const keysToRequest = keys.filter((k) => !engine.hasItem(k) && !pendingResolutionKeys.has(k));

  if (keysToRequest.length === 0) return;

  // Mark as pending
  for (const k of keysToRequest) {
    pendingResolutionKeys.add(k);
  }

  // Call the main.ts debounced resolution function
  if (typeof (window as any).FinalFinal?.requestCitationResolution === 'function') {
    (window as any).FinalFinal.requestCitationResolution(keysToRequest);
  }
}

/**
 * Clear pending resolution state for keys (called after resolution completes)
 */
export function clearPendingResolution(keys: string[]): void {
  for (const k of keys) {
    pendingResolutionKeys.delete(k);
  }
}

// Remark plugin to convert citation text to citation nodes
const remarkCitationPlugin = $remark('citation', () => () => (tree: Root) => {
  visit(tree, 'text', (node: any, index: number | null, parent: any) => {
    const value = node.value as string;
    if (!value || !value.includes('@')) return;

    const matches: Array<{ start: number; end: number; parsed: ReturnType<typeof parseCitationBracket> }> = [];

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
  atom: true, // Atomic - not editable, treated as single unit
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
    const citekeys = attrs.citekeys.split(',').filter((k) => k.trim());

    // Basic display (will be enhanced by node view)
    const displayText = citekeys.length > 0 ? `[@${citekeys.join('; @')}]` : '[?]';

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

// Merge existing citation with new citation(s)
// existing: "[@key1; @key2, p. 42]"
// newCitation: "[@key3; @key4]"
// result: "[@key1; @key2, p. 42; @key3; @key4]"
export function mergeCitations(existing: string, newCitation: string): string {
  // Strip outer brackets from both
  const existingInner = existing.replace(/^\[|\]$/g, '');
  const newInner = newCitation.replace(/^\[|\]$/g, '');

  // Combine with semicolon separator
  return `[${existingInner}; ${newInner}]`;
}

/** The citekeys of a citation node, as the node view reads them (split on commas, blanks dropped; no trimming, no case change). */
export function citationKeysOf(attrs: CitationAttrs): string[] {
  return attrs.citekeys.split(',').filter((k) => k.trim());
}

/**
 * Exactly what the Rich Text node view asks `CiteprocEngine.formatCitation` for, for one citation node. The node view and the
 * ahead-of-time fill (citation-prefill.ts) both build their request here, so the fill can only warm the memo with the entries a real
 * load will look up. Throws if `attrs.locators` is not valid JSON (the node view catches that and shows its short form).
 */
export function citationFormatRequest(attrs: CitationAttrs): { citekeys: string[]; options: CitationOptions } {
  const citekeys = citationKeysOf(attrs);
  return {
    citekeys,
    options: {
      suppressAuthors: attrs.suppressAuthor ? citekeys.map(() => true) : undefined,
      locators: attrs.locators ? JSON.parse(attrs.locators) : undefined,
      prefix: attrs.prefix,
      suffix: attrs.suffix,
    },
  };
}

// NodeView for custom rendering with formatted citation display
// This must be in the same file as citationNode to maintain atom identity with $view
// NOTE: $view expects (ctx) => NodeViewConstructor, NOT () => (ctx) => NodeViewConstructor
const citationNodeView = $view(citationNode, (_ctx: Ctx) => {
  return (node, view, getPos) => {
    // The node this view currently shows. ProseMirror reuses a node view for a DIFFERENT citation when the document around it
    // changes (its `update` is called with whatever compatible node lands in the slot), so `update` below swaps this reference.
    // Never write into `node.attrs`: that object is the document's own, shared with every state that holds the node (an undo
    // checkpoint included) -- writing a reused view's new citekeys into it silently changed the saved checkpoint's citations
    // and the shift cascaded down the document.
    let currentNode = node;
    // NOTE: citekeys is computed fresh inside updateDisplay() to avoid stale closure

    // Track source mode at NodeView creation time
    // When mode changes, update() returns false to force NodeView recreation
    const createdInSourceMode = isSourceModeEnabled();

    // Create DOM structure
    const dom = document.createElement('span');
    dom.className = 'ff-citation';

    // Update display content
    const updateDisplay = () => {
      const attrs = currentNode.attrs as CitationAttrs;
      // Compute citekeys fresh from current attrs (not stale closure)
      const citekeys = citationKeysOf(attrs);

      // Source mode: show raw markdown syntax
      if (isSourceModeEnabled()) {
        // Display as [@citekey1; @citekey2]
        const rawSyntax = attrs.rawSyntax || `[@${citekeys.join('; @')}]`;
        dom.textContent = rawSyntax;
        dom.title = rawSyntax;
        // Targeted class ops (not wholesale `dom.className = ...`), matching
        // annotation-plugin.ts's NodeView update fix: this only adds/removes the
        // classes this plugin itself owns, so a future decoration-applied class
        // (e.g. `Decoration.node()`, same mechanism annotation-display-plugin.ts
        // uses) survives a redraw instead of being wiped every render. 'ff-citation'
        // itself is never removed -- it's set once at NodeView creation and stays
        // for the node's lifetime.
        dom.classList.add('source-mode-citation');
        dom.classList.remove('ff-citation-resolved', 'ff-citation-unresolved');
        dom.dataset.citekeys = attrs.citekeys;
        dom.dataset.rawsyntax = attrs.rawSyntax;
        return;
      }

      // WYSIWYG mode: formatted citation display
      const engine = getCiteprocEngine();
      let displayText = '';
      let isResolved = true;
      let tooltipText = '';

      if (citekeys.length === 0) {
        displayText = '[?]';
        isResolved = false;
        tooltipText = 'No citation key';
      } else {
        // Check resolution status
        const unresolvedKeys = citekeys.filter((k) => !engine.hasItem(k));
        isResolved = unresolvedKeys.length === 0;

        // Lazy resolution: request unresolved keys from Swift/Zotero
        if (unresolvedKeys.length > 0) {
          requestCitationResolution(unresolvedKeys);
        }

        if (isResolved) {
          // Get formatted citation from citeproc
          try {
            const request = citationFormatRequest(attrs);
            displayText = engine.formatCitation(request.citekeys, request.options);

            // Build tooltip with full citation info
            const items = citekeys.map((k) => engine.getItem(k)).filter(Boolean) as CSLItem[];
            tooltipText = items
              .map((item) => {
                const author = item.author?.[0];
                const authorName = author?.family || author?.literal || '';
                const year = item.issued?.['date-parts']?.[0]?.[0] || 'n.d.';
                const title = item.title || '';
                return `${authorName} (${year}). ${title}`;
              })
              .join('\n');
          } catch (_e) {
            // Fallback to short citation
            displayText = `(${citekeys.map((k) => engine.getShortCitation(k)).join('; ')})`;
            tooltipText = displayText;
          }
        } else {
          // Show unresolved with ? suffix
          displayText = `(${citekeys
            .map((k) => {
              if (engine.hasItem(k)) {
                return engine.getShortCitation(k);
              }
              return `${k}?`;
            })
            .join('; ')})`;
          tooltipText = `Unresolved: ${unresolvedKeys.join(', ')}`;
        }
      }

      // Update DOM
      dom.textContent = displayText;
      dom.title = tooltipText;
      // Targeted class ops -- see the source-mode branch above for why.
      dom.classList.remove('source-mode-citation', 'ff-citation-resolved', 'ff-citation-unresolved');
      dom.classList.add(isResolved ? 'ff-citation-resolved' : 'ff-citation-unresolved');
      dom.dataset.citekeys = attrs.citekeys;
      dom.dataset.rawsyntax = attrs.rawSyntax;
    };

    // Click handler - open in-app edit popup for citation editing (only in WYSIWYG mode)
    dom.addEventListener('click', (e) => {
      // Don't open edit popup in source mode
      if (isSourceModeEnabled()) return;

      e.preventDefault();
      e.stopPropagation();
      if (typeof getPos !== 'function') return;
      const nodeAttrs = currentNode.attrs as CitationAttrs;
      // Pass the live getPos closure itself (not a one-time-computed position
      // snapshot) so the popup can re-resolve the citation's CURRENT position at
      // the moment the user actually acts (commit/delete), even if a background
      // resync (e.g. setContentWithBlockIds) shifted it since the popup opened.
      showCitationEditPopup(getPos, view, nodeAttrs);
    });

    // Listen for citation library updates to re-render formatted display
    const onLibraryUpdate = () => updateDisplay();
    document.addEventListener('citation-library-updated', onLibraryUpdate);

    // Initial render
    updateDisplay();

    return {
      dom,
      update: (updatedNode) => {
        if (updatedNode.type.name !== 'citation') return false;

        // Force recreation if source mode changed
        // Display format differs significantly between modes
        if (isSourceModeEnabled() !== createdInSourceMode) {
          return false;
        }

        // Show the new node. The attrs are read from it, never copied INTO the previous node's attrs object (see `currentNode`).
        currentNode = updatedNode;

        // Refresh display
        updateDisplay();
        return true;
      },
      destroy: () => {
        // Clean up event listener
        document.removeEventListener('citation-library-updated', onLibraryUpdate);
      },
      // Let ProseMirror handle events normally (no edit mode)
      stopEvent: () => false,
      // Ignore mutations to this node
      ignoreMutation: () => true,
    };
  };
});

// Keymap for one-press citation deletion with whitespace cleanup.
// Mirrors heading-nodeview-plugin.ts's headingBackspaceKeymap pattern: a $prose-wrapped
// keymap() that only intercepts Backspace/Delete when the adjacent node is a citation atom,
// falling through (return false) for every other case so normal editing is unaffected.
const citationDeleteKeymap = $prose(() => {
  return keymap({
    Backspace: (state, dispatch) => {
      const { $from, empty } = state.selection;
      if (!empty) return false;

      const before = $from.nodeBefore;
      if (!before || before.type.name !== CITATION_NODE_NAME) return false;

      const tr = buildCitationDeleteTransaction(state, $from.pos - before.nodeSize);
      if (!tr) return false;

      if (dispatch) dispatch(tr);
      return true;
    },
    Delete: (state, dispatch) => {
      const { $from, empty } = state.selection;
      if (!empty) return false;

      const after = $from.nodeAfter;
      if (!after || after.type.name !== CITATION_NODE_NAME) return false;

      const tr = buildCitationDeleteTransaction(state, $from.pos);
      if (!tr) return false;

      if (dispatch) dispatch(tr);
      return true;
    },
  });
});

// Export the plugin array - node view MUST be in same array to maintain atom identity
export const citationPlugin: MilkdownPlugin[] = [
  remarkCitationPlugin,
  citationNode,
  citationNodeView, // Node view included here, same file as node definition
  citationDeleteKeymap,
].flat();
