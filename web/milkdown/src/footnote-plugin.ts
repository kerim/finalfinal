// Footnote Plugin for Milkdown
// Parses markdown footnote references: [^1], [^2], etc.
// Renders as inline atomic superscript nodes with hover tooltip previews
// Definitions ([^N]: content) live in the # Notes section and are NOT parsed by this plugin

import { editorViewCtx } from '@milkdown/kit/core';
import type { Ctx, MilkdownPlugin } from '@milkdown/kit/ctx';
import type { Node } from '@milkdown/kit/prose/model';
import { Plugin, Selection, TextSelection } from '@milkdown/kit/prose/state';
import { $node, $prose, $remark, $view } from '@milkdown/kit/utils';
import type { Root } from 'mdast';
import { visit } from 'unist-util-visit';
import { getDocumentFootnoteCount, getEditorInstance, getIsZoomMode, setZoomFootnoteState } from './editor-state';
import { isSourceModeEnabled } from './source-mode-plugin';

// === Footnote Definitions State ===
// Module-level map of label → definition text, populated by FootnoteSyncService via setFootnoteDefinitions()
const footnoteDefinitions = new Map<string, string>();

/**
 * Update the footnote definitions map (called from window.FinalFinal.setFootnoteDefinitions)
 */
export function setFootnoteDefinitions(defs: Record<string, string>): void {
  footnoteDefinitions.clear();
  for (const [label, text] of Object.entries(defs)) {
    footnoteDefinitions.set(label, text);
  }
  // Dispatch event so existing NodeViews can update their tooltips
  document.dispatchEvent(new CustomEvent('footnote-definitions-updated'));
}

/**
 * Get the current footnote definitions map
 */
export function getFootnoteDefinitions(): Map<string, string> {
  return footnoteDefinitions;
}

// Regex for footnote references: [^N] where N is one or more digits
// Negative lookahead (?!:) prevents matching definitions [^N]:
const footnoteRefRegex = /\[\^(\d+)\](?!:)/g;

// Helper: recursively extract text content from MDAST children
function extractTextFromChildren(children: any[]): string {
  if (!children || children.length === 0) return '';
  return children
    .map((child: any) => {
      if (child.type === 'text') return child.value || '';
      if (child.children) return extractTextFromChildren(child.children);
      return '';
    })
    .join('');
}

// Remark plugin to convert footnote reference text to footnote_ref nodes
// Passes 1-2 handle GFM's micromark-parsed MDAST nodes (footnoteDefinition, footnoteReference)
// Pass 3 is the original text-node fallback for edge cases
const remarkFootnotePlugin = $remark('footnote', () => () => (tree: Root) => {
  // Pass 1: Convert GFM footnoteDefinition → plain paragraph
  // GFM parses `[^1]: text` as footnoteDefinition { identifier, children: [paragraph] }
  // Convert back so it renders as editable text in ProseMirror
  visit(tree, 'footnoteDefinition', (node: any, index: number | null, parent: any) => {
    if (!parent || typeof index !== 'number') return;
    const id = node.identifier || node.label || '?';
    const childText = extractTextFromChildren(node.children);
    const replacement: any = {
      type: 'paragraph',
      children: [{ type: 'text', value: `[^${id}]: ${childText}` }],
    };
    parent.children.splice(index, 1, replacement);
    return index; // revisit this index (new node inserted)
  });

  // Pass 2: Convert GFM footnoteReference → custom footnote_ref
  // GFM parses `[^1]` as footnoteReference { identifier, label }
  // Convert to our custom type that has a ProseMirror schema mapping
  visit(tree, 'footnoteReference', (node: any, index: number | null, parent: any) => {
    if (!parent || typeof index !== 'number') return;
    const label = node.identifier || node.label || '0';
    const replacement: any = {
      type: 'footnote_ref',
      data: { label },
    };
    parent.children.splice(index, 1, replacement);
    return index;
  });

  // Pass 3: Text-node fallback for edge cases where GFM doesn't intercept
  visit(tree, 'text', (node: any, index: number | null, parent: any) => {
    const value = node.value as string;
    if (!value || !value.includes('[^')) return;

    const matches: Array<{ start: number; end: number; label: string }> = [];

    let match;
    footnoteRefRegex.lastIndex = 0;
    while ((match = footnoteRefRegex.exec(value)) !== null) {
      matches.push({
        start: match.index,
        end: match.index + match[0].length,
        label: match[1],
      });
    }

    if (matches.length === 0) return;

    // Build new children array with text and footnote_ref nodes
    const newChildren: any[] = [];
    let lastEnd = 0;

    for (const m of matches) {
      // Add text before footnote ref
      if (m.start > lastEnd) {
        newChildren.push({
          type: 'text',
          value: value.slice(lastEnd, m.start),
        });
      }

      // Add footnote_ref node
      newChildren.push({
        type: 'footnote_ref',
        data: {
          label: m.label,
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

// Define the footnote_ref node (atomic, not editable inline)
export const footnoteRefNode = $node('footnote_ref', () => ({
  group: 'inline',
  inline: true,
  atom: true,
  selectable: false,
  draggable: false,

  attrs: {
    label: { default: '0' },
  },

  parseDOM: [
    {
      tag: 'sup.ff-footnote-ref',
      getAttrs: (dom: HTMLElement) => ({
        label: dom.dataset.label || '0',
      }),
    },
  ],

  toDOM: (node: Node) => {
    return [
      'sup',
      {
        class: 'ff-footnote-ref',
        'data-label': node.attrs.label,
      },
      node.attrs.label,
    ];
  },

  parseMarkdown: {
    match: (node: any) => node.type === 'footnote_ref',
    runner: (state: any, node: any, type: any) => {
      state.addNode(type, {
        label: node.data.label,
      });
    },
  },

  toMarkdown: {
    match: (node: Node) => node.type.name === 'footnote_ref',
    runner: (state: any, node: Node) => {
      const label = node.attrs.label;
      console.log(`[DIAG-FN] toMarkdown footnote_ref: label="${label}"`);
      // Use 'html' node type to output raw content without escaping
      // (text nodes escape [ to \[ which breaks footnote syntax)
      state.addNode('html', undefined, `[^${label}]`);
    },
  },
}));

// NodeView for custom rendering with superscript display and hover tooltip
// This must be in the same file as footnoteRefNode to maintain atom identity with $view
const footnoteRefNodeView = $view(footnoteRefNode, (_ctx: Ctx) => {
  return (node, _view, _getPos) => {
    const attrs = { label: node.attrs.label as string };

    // Track source mode at NodeView creation time
    const createdInSourceMode = isSourceModeEnabled();

    // Create DOM structure
    const dom = document.createElement('sup');
    dom.className = 'ff-footnote-ref';
    dom.dataset.label = attrs.label;

    // Tooltip element (created lazily on hover)
    let tooltip: HTMLDivElement | null = null;
    let hideTimeout: ReturnType<typeof setTimeout> | null = null;

    const showTooltip = () => {
      if (isSourceModeEnabled()) return;
      if (hideTimeout) {
        clearTimeout(hideTimeout);
        hideTimeout = null;
      }

      const defText = footnoteDefinitions.get(attrs.label);
      if (!defText) return;

      if (!tooltip) {
        tooltip = document.createElement('div');
        tooltip.className = 'ff-footnote-tooltip';
        dom.appendChild(tooltip);
      }

      tooltip.textContent = defText;
      tooltip.style.display = 'block';
    };

    const hideTooltip = () => {
      if (tooltip) {
        hideTimeout = setTimeout(() => {
          if (tooltip) tooltip.style.display = 'none';
        }, 150);
      }
    };

    const updateDisplay = () => {
      if (isSourceModeEnabled()) {
        // Source mode: show raw markdown syntax
        dom.textContent = `[^${attrs.label}]`;
        dom.className = 'ff-footnote-ref source-mode-footnote';
        return;
      }

      // WYSIWYG mode: show superscript number
      dom.textContent = attrs.label;
      dom.className = 'ff-footnote-ref';
      dom.dataset.label = attrs.label;
    };

    // Click handler — navigate to definition in #Notes
    dom.addEventListener('click', (e) => {
      if (isSourceModeEnabled()) return;
      e.preventDefault();
      e.stopPropagation();

      const editorInstance = getEditorInstance();
      if (!editorInstance) return;

      const view = editorInstance.ctx.get(editorViewCtx);
      const searchText = `[^${attrs.label}]:`;

      // Search ProseMirror doc for paragraph starting with [^N]:
      let targetPos = -1;
      view.state.doc.descendants((node: Node, pos: number) => {
        if (targetPos !== -1) return false;
        if (node.isTextblock && node.textContent.startsWith(searchText)) {
          targetPos = pos;
          return false;
        }
      });

      if (targetPos !== -1) {
        try {
          // Position cursor after "[^N]: " prefix for immediate typing
          const prefixLength = searchText.length + 1; // searchText is "[^N]:", +1 for the space
          const cursorPos = Math.min(
            targetPos + 1 + prefixLength,
            view.state.doc.resolve(targetPos + 1).end()
          );
          const sel = TextSelection.create(view.state.doc, cursorPos);
          view.dispatch(view.state.tr.setSelection(sel));
          const coords = view.coordsAtPos(targetPos);
          if (coords) {
            window.scrollTo({
              top: Math.max(0, coords.top + window.scrollY - 100),
              behavior: 'smooth',
            });
          }
          view.focus();
        } catch { /* scroll failed */ }
      }
    });

    // Hover handlers for tooltip
    dom.addEventListener('mouseenter', showTooltip);
    dom.addEventListener('mouseleave', hideTooltip);

    // Listen for definition updates to refresh tooltip content
    const onDefsUpdated = () => {
      // Tooltip content refreshed on next hover
    };
    document.addEventListener('footnote-definitions-updated', onDefsUpdated);

    // Initial render
    updateDisplay();

    return {
      dom,
      update: (updatedNode) => {
        if (updatedNode.type.name !== 'footnote_ref') return false;

        // Force recreation if source mode changed
        if (isSourceModeEnabled() !== createdInSourceMode) {
          return false;
        }

        // Update attrs
        attrs.label = updatedNode.attrs.label as string;
        updateDisplay();
        return true;
      },
      destroy: () => {
        document.removeEventListener('footnote-definitions-updated', onDefsUpdated);
        if (hideTimeout) clearTimeout(hideTimeout);
        if (tooltip) {
          tooltip.remove();
          tooltip = null;
        }
      },
      stopEvent: () => false,
      ignoreMutation: () => true,
    };
  };
});

/**
 * Insert a footnote reference at the given position (or current cursor).
 * Assigns sequential label based on cursor position among existing refs,
 * renumbers subsequent refs in one atomic transaction.
 * Returns the label string (e.g. "2") or null if editor is not ready.
 */
export function insertFootnote(atPosition?: number): string | null {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return null;

  const view = editorInstance.ctx.get(editorViewCtx);
  if (!view) return null;

  const insertPos = atPosition ?? view.state.selection.from;

  // Zoom mode: use next document-level label, no renumbering
  if (getIsZoomMode()) {
    const currentMax = getDocumentFootnoteCount();
    const newLabel = currentMax + 1;
    setZoomFootnoteState(true, newLabel); // increment for next insertion

    const nodeType = footnoteRefNode.type(editorInstance.ctx);
    const newNode = nodeType.create({ label: String(newLabel) });
    const tr = view.state.tr.insert(insertPos, newNode);
    view.dispatch(tr);

    footnoteDefinitions.set(String(newLabel), '');

    if (typeof (window as any).webkit?.messageHandlers?.footnoteInserted?.postMessage === 'function') {
      (window as any).webkit.messageHandlers.footnoteInserted.postMessage({ label: String(newLabel) });
    }

    console.log('[DIAG-FN] insertFootnote() zoom mode returning label:', String(newLabel));
    return String(newLabel);
  }

  // Collect all existing refs with positions
  const existingRefs: Array<{ pos: number; label: string }> = [];
  view.state.doc.descendants((node: Node, pos: number) => {
    if (node.type.name === 'footnote_ref') {
      existingRefs.push({ pos, label: node.attrs.label });
    }
  });
  console.log('[DIAG-FN] insertFootnote() called, insertPos:', insertPos, 'existingRefs:', existingRefs.length);

  // Sort by position to determine insertion index
  existingRefs.sort((a, b) => a.pos - b.pos);
  const insertionIndex = existingRefs.filter((r) => r.pos < insertPos).length;
  const newLabel = String(insertionIndex + 1);

  // Refs that need renumbering: those with label >= newLabel
  const toRenumber = existingRefs
    .filter((r) => parseInt(r.label) >= parseInt(newLabel))
    .sort((a, b) => b.pos - a.pos); // REVERSE order for safe setNodeMarkup

  // Single transaction: renumber FIRST (reverse order), then insert
  const tr = view.state.tr;

  for (const ref of toRenumber) {
    tr.setNodeMarkup(ref.pos, undefined, {
      label: String(parseInt(ref.label) + 1),
    });
  }

  const nodeType = footnoteRefNode.type(editorInstance.ctx);
  const newNode = nodeType.create({ label: newLabel });
  tr.insert(insertPos, newNode);

  view.dispatch(tr);

  // Shift definitions map
  const oldDefs = new Map(footnoteDefinitions);
  footnoteDefinitions.clear();
  for (const [label, def] of oldDefs) {
    const labelInt = parseInt(label, 10);
    if (labelInt < parseInt(newLabel)) {
      footnoteDefinitions.set(label, def);
    } else {
      footnoteDefinitions.set(String(labelInt + 1), def);
    }
  }
  footnoteDefinitions.set(newLabel, '');

  // Notify Swift immediately via postMessage (works for slash commands AND keyboard shortcuts)
  if (typeof (window as any).webkit?.messageHandlers?.footnoteInserted?.postMessage === 'function') {
    (window as any).webkit.messageHandlers.footnoteInserted.postMessage({ label: newLabel });
  }

  console.log('[DIAG-FN] insertFootnote() returning label:', newLabel);
  return newLabel;
}

/**
 * Insert a footnote reference while simultaneously deleting a range (e.g. slash command text).
 * All operations happen in a single ProseMirror transaction for atomic undo.
 * Returns the label string or null if editor is not ready.
 */
export function insertFootnoteWithDelete(
  view: any,
  editorInstance: any,
  deleteFrom: number,
  deleteTo: number
): string | null {
  // Zoom mode: use next document-level label, no renumbering
  if (getIsZoomMode()) {
    const currentMax = getDocumentFootnoteCount();
    const newLabel = currentMax + 1;
    setZoomFootnoteState(true, newLabel);

    const tr = view.state.tr;
    tr.delete(deleteFrom, deleteTo);
    const nodeType = footnoteRefNode.type(editorInstance.ctx);
    tr.insert(deleteFrom, nodeType.create({ label: String(newLabel) }));
    view.dispatch(tr);

    footnoteDefinitions.set(String(newLabel), '');

    if (typeof (window as any).webkit?.messageHandlers?.footnoteInserted?.postMessage === 'function') {
      (window as any).webkit.messageHandlers.footnoteInserted.postMessage({ label: String(newLabel) });
    }

    return String(newLabel);
  }

  // Collect existing refs
  const existingRefs: Array<{ pos: number; label: string }> = [];
  view.state.doc.descendants((node: Node, pos: number) => {
    if (node.type.name === 'footnote_ref') {
      existingRefs.push({ pos, label: node.attrs.label });
    }
  });
  existingRefs.sort((a, b) => a.pos - b.pos);

  // Insertion index based on deleteFrom (where slash text starts)
  const insertionIndex = existingRefs.filter((r) => r.pos < deleteFrom).length;
  const newLabel = String(insertionIndex + 1);

  const toRenumber = existingRefs
    .filter((r) => parseInt(r.label) >= parseInt(newLabel))
    .sort((a, b) => b.pos - a.pos);

  const tr = view.state.tr;

  // ORDER MATTERS:
  // 1. setNodeMarkup FIRST (doesn't change positions)
  for (const ref of toRenumber) {
    tr.setNodeMarkup(ref.pos, undefined, { label: String(parseInt(ref.label) + 1) });
  }
  // 2. delete SECOND (shifts positions after deleteFrom)
  tr.delete(deleteFrom, deleteTo);
  // 3. insert LAST (at deleteFrom, which is now the collapsed position)
  const nodeType = footnoteRefNode.type(editorInstance.ctx);
  tr.insert(deleteFrom, nodeType.create({ label: newLabel }));

  view.dispatch(tr);

  // Shift definitions map (same as insertFootnote)
  const oldDefs = new Map(footnoteDefinitions);
  footnoteDefinitions.clear();
  for (const [label, def] of oldDefs) {
    const labelInt = parseInt(label, 10);
    if (labelInt < parseInt(newLabel)) {
      footnoteDefinitions.set(label, def);
    } else {
      footnoteDefinitions.set(String(labelInt + 1), def);
    }
  }
  footnoteDefinitions.set(newLabel, '');

  // Notify Swift immediately via postMessage (works for slash commands AND keyboard shortcuts)
  if (typeof (window as any).webkit?.messageHandlers?.footnoteInserted?.postMessage === 'function') {
    (window as any).webkit.messageHandlers.footnoteInserted.postMessage({ label: newLabel });
  }

  return newLabel;
}

/**
 * Scroll to and focus the footnote definition [^N]: in the Notes section.
 * Reuses the click handler logic: find paragraph starting with [^N]:,
 * create TextSelection after prefix, scrollIntoView, focus.
 */
export function scrollToFootnoteDefinition(label: string): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;

  const view = editorInstance.ctx.get(editorViewCtx);
  if (!view) return;

  const searchText = `[^${label}]:`;

  // Search ProseMirror doc for paragraph starting with [^N]:
  let targetPos = -1;
  view.state.doc.descendants((node: Node, pos: number) => {
    if (targetPos !== -1) return false;
    if (node.isTextblock && node.textContent.startsWith(searchText)) {
      targetPos = pos;
      return false;
    }
  });

  if (targetPos !== -1) {
    try {
      // Position cursor after "[^N]: " prefix for immediate typing
      const prefixLength = searchText.length + 1; // +1 for the space
      const cursorPos = Math.min(targetPos + 1 + prefixLength, view.state.doc.resolve(targetPos + 1).end());
      const sel = TextSelection.create(view.state.doc, cursorPos);
      view.dispatch(view.state.tr.setSelection(sel));
      const coords = view.coordsAtPos(targetPos);
      if (coords) {
        window.scrollTo({
          top: Math.max(0, coords.top + window.scrollY - 100),
          behavior: 'smooth',
        });
      }
      view.focus();
    } catch {
      /* scroll failed */
    }
  }
}

/**
 * Renumber footnote references in the document using a mapping of old → new labels.
 * Uses targeted ProseMirror transaction (setNodeMarkup) to preserve cursor position.
 * Also updates the definitions map with renumbered keys.
 */
export function renumberFootnotes(mapping: Record<string, string>): void {
  const editorInstance = getEditorInstance();
  if (!editorInstance) return;

  const view = editorInstance.ctx.get(editorViewCtx);
  if (!view) return;

  // Collect all nodes that need renumbering (with positions)
  const changes: Array<{ pos: number; newLabel: string }> = [];
  view.state.doc.descendants((node: Node, pos: number) => {
    if (node.type.name === 'footnote_ref' && mapping[node.attrs.label]) {
      changes.push({ pos, newLabel: mapping[node.attrs.label] });
    }
  });

  if (changes.length === 0) return;

  // Apply in reverse position order to preserve positions
  const tr = view.state.tr;
  for (const change of changes.sort((a, b) => b.pos - a.pos)) {
    tr.setNodeMarkup(change.pos, undefined, { label: change.newLabel });
  }

  if (tr.docChanged) {
    view.dispatch(tr);
  }

  // Update the definitions map with renumbered keys
  const oldDefs = new Map(footnoteDefinitions);
  footnoteDefinitions.clear();
  for (const [oldLabel, def] of oldDefs) {
    const newLabel = mapping[oldLabel] || oldLabel;
    footnoteDefinitions.set(newLabel, def);
  }
}

// ProseMirror plugin for clicking footnote definitions [^N]: to navigate back to the reference
const footnoteClickPlugin = $prose(() => {
  return new Plugin({
    props: {
      handleClick(view, pos, _event) {
        if (isSourceModeEnabled()) return false;

        // Find the text node at click position
        const resolved = view.state.doc.resolve(pos);
        const parent = resolved.parent;
        if (!parent.isTextblock) return false;

        const text = parent.textContent;
        const defMatch = text.match(/^\[\^(\d+)\]:/);
        if (!defMatch) return false;

        // Only navigate when clicking the [^N] back-link, not the definition text
        const linkLength = defMatch[0].length - 1; // "[^1]:" → 4 ("[^1]")
        if (resolved.parentOffset >= linkLength) return false;

        const label = defMatch[1];

        // Find first footnote_ref node with matching label
        let refPos = -1;
        view.state.doc.descendants((node: Node, nodePos: number) => {
          if (refPos !== -1) return false;
          if (node.type.name === 'footnote_ref' && node.attrs.label === label) {
            refPos = nodePos;
            return false;
          }
        });

        if (refPos !== -1) {
          try {
            const sel = Selection.near(view.state.doc.resolve(refPos));
            view.dispatch(view.state.tr.setSelection(sel));
            const coords = view.coordsAtPos(refPos);
            if (coords) {
              window.scrollTo({
                top: Math.max(0, coords.top + window.scrollY - 100),
                behavior: 'smooth',
              });
            }
            view.focus();
          } catch { /* scroll failed */ }
          return true;
        }

        return false;
      },
    },
  });
});

// Export the plugin array — node view MUST be in same array to maintain atom identity
export const footnotePlugin: MilkdownPlugin[] = [
  remarkFootnotePlugin, footnoteRefNode, footnoteRefNodeView, footnoteClickPlugin,
].flat();
