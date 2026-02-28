// Footnote Plugin for Milkdown
// Parses markdown footnote references: [^1], [^2], etc.
// Renders as inline atomic superscript nodes with hover tooltip previews
// Definitions ([^N]: content) live in the # Notes section and are NOT parsed by this plugin

import { editorViewCtx } from '@milkdown/kit/core';
import type { Ctx, MilkdownPlugin } from '@milkdown/kit/ctx';
import { InputRule, inputRules } from '@milkdown/kit/prose/inputrules';
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
  // Pass 1: Convert GFM footnoteDefinition → paragraph with footnote_def node + text
  // GFM parses `[^1]: text` as footnoteDefinition { identifier, children: [paragraph] }
  // Convert to footnote_def atom node followed by the definition text
  visit(tree, 'footnoteDefinition', (node: any, index: number | null, parent: any) => {
    if (!parent || typeof index !== 'number') return;
    const id = node.identifier || node.label || '?';
    const childText = extractTextFromChildren(node.children);
    const replacement: any = {
      type: 'paragraph',
      children: [
        { type: 'footnote_def', data: { label: id } },
        { type: 'text', value: ` ${childText}` },
      ],
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

  // Pass 4: Text-node fallback for footnote definitions [^N]: at paragraph start
  // Handles cases where GFM didn't intercept (e.g., Swift-inserted raw text via setContent())
  const defAtStartRegex = /^\[\^(\d+)\]:\s?/;
  visit(tree, 'text', (node: any, index: number | null, parent: any) => {
    if (!parent || typeof index !== 'number') return;
    // Only match at the first child of a paragraph
    if (parent.type !== 'paragraph' || index !== 0) return;
    const value = node.value as string;
    if (!value) return;
    const defMatch = value.match(defAtStartRegex);
    if (!defMatch) return;

    const label = defMatch[1];
    const remaining = value.slice(defMatch[0].length);
    const newChildren: any[] = [{ type: 'footnote_def', data: { label } }];
    newChildren.push({ type: 'text', value: remaining.length > 0 ? ` ${remaining}` : ' ' });
    parent.children.splice(index, 1, ...newChildren);
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
      // Use 'html' node type to output raw content without escaping
      // (text nodes escape [ to \[ which breaks footnote syntax)
      state.addNode('html', undefined, `[^${label}]`);
    },
  },
}));

// Define the footnote_def node (atomic pill at definition sites)
export const footnoteDefNode = $node('footnote_def', () => ({
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
      tag: 'span.ff-footnote-def',
      getAttrs: (dom: HTMLElement) => ({
        label: dom.dataset.label || '0',
      }),
    },
  ],

  toDOM: (node: Node) => {
    return [
      'span',
      {
        class: 'ff-footnote-def',
        'data-label': node.attrs.label,
      },
      node.attrs.label,
    ];
  },

  parseMarkdown: {
    match: (node: any) => node.type === 'footnote_def',
    runner: (state: any, node: any, type: any) => {
      state.addNode(type, {
        label: node.data.label,
      });
    },
  },

  toMarkdown: {
    match: (node: Node) => node.type.name === 'footnote_def',
    runner: (state: any, node: Node) => {
      const label = node.attrs.label;
      // Use 'html' node type to output raw content without escaping
      state.addNode('html', undefined, `[^${label}]:`);
    },
  },
}));

// NodeView for footnote definition pill with click-to-navigate-back
const footnoteDefNodeView = $view(footnoteDefNode, (_ctx: Ctx) => {
  return (node, _view, _getPos) => {
    const attrs = { label: node.attrs.label as string };

    // Track source mode at NodeView creation time
    const createdInSourceMode = isSourceModeEnabled();

    // Create DOM structure
    const dom = document.createElement('span');
    dom.className = 'ff-footnote-def';
    dom.dataset.label = attrs.label;

    const updateDisplay = () => {
      if (isSourceModeEnabled()) {
        // Source mode: show raw markdown syntax
        dom.textContent = `[^${attrs.label}]:`;
        dom.className = 'ff-footnote-def source-mode-footnote-def';
        return;
      }

      // WYSIWYG mode: show number in pill
      dom.textContent = attrs.label;
      dom.className = 'ff-footnote-def';
      dom.dataset.label = attrs.label;
    };

    // Click handler — navigate back to matching footnote_ref
    dom.addEventListener('click', (e) => {
      if (isSourceModeEnabled()) return;
      e.preventDefault();
      e.stopPropagation();

      const editorInstance = getEditorInstance();
      if (!editorInstance) return;

      const view = editorInstance.ctx.get(editorViewCtx);
      const label = attrs.label;

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
          view.dispatch(view.state.tr.setSelection(sel).scrollIntoView());
          const coords = view.coordsAtPos(refPos);
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
    });

    // Initial render
    updateDisplay();

    return {
      dom,
      update: (updatedNode) => {
        if (updatedNode.type.name !== 'footnote_def') return false;

        // Force recreation if source mode changed
        if (isSourceModeEnabled() !== createdInSourceMode) {
          return false;
        }

        // Update attrs
        attrs.label = updatedNode.attrs.label as string;
        updateDisplay();
        return true;
      },
      destroy: () => {},
      stopEvent: () => false,
      ignoreMutation: () => true,
    };
  };
});

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
      tooltip.classList.add('ff-footnote-tooltip-visible');
    };

    const hideTooltip = () => {
      if (tooltip) {
        hideTimeout = setTimeout(() => {
          if (tooltip) tooltip.classList.remove('ff-footnote-tooltip-visible');
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

      // Search for footnote_def node with matching label
      let targetPos = -1;
      let usedTextFallback = false;
      view.state.doc.descendants((node: Node, pos: number) => {
        if (targetPos !== -1) return false;
        if (node.type.name === 'footnote_def' && node.attrs.label === attrs.label) {
          targetPos = pos;
          return false;
        }
      });

      // Fallback: text-based search for transition safety
      if (targetPos === -1) {
        const searchText = `[^${attrs.label}]:`;
        view.state.doc.descendants((node: Node, pos: number) => {
          if (targetPos !== -1) return false;
          if (node.isTextblock && node.textContent.startsWith(searchText)) {
            targetPos = pos;
            usedTextFallback = true;
            return false;
          }
        });
      }

      if (targetPos !== -1) {
        try {
          let cursorPos: number;
          if (usedTextFallback) {
            // Text-based: targetPos is paragraph position, content starts at +1
            const searchText = `[^${attrs.label}]:`;
            const contentStart = targetPos + 1;
            const paragraphEnd = view.state.doc.resolve(contentStart).end();
            // Place cursor after "[^N]: " (prefix + space)
            cursorPos = Math.min(contentStart + searchText.length + 1, paragraphEnd);
          } else {
            // Node-based: targetPos is the atom node position
            const resolvedTarget = view.state.doc.resolve(targetPos);
            const parentStart = resolvedTarget.start(resolvedTarget.depth);
            const parentEnd = view.state.doc.resolve(parentStart).end();
            // Place cursor after atom (1) + space (1) = offset 2 from inside paragraph
            cursorPos = Math.min(parentStart + 2, parentEnd);
          }
          const sel = TextSelection.create(view.state.doc, cursorPos);
          view.dispatch(view.state.tr.setSelection(sel).scrollIntoView());
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

    return String(newLabel);
  }

  // Collect all existing refs with positions
  const existingRefs: Array<{ pos: number; label: string }> = [];
  view.state.doc.descendants((node: Node, pos: number) => {
    if (node.type.name === 'footnote_ref') {
      existingRefs.push({ pos, label: node.attrs.label });
    }
  });
  // Sort by position to determine insertion index
  existingRefs.sort((a, b) => a.pos - b.pos);
  const insertionIndex = existingRefs.filter((r) => r.pos < insertPos).length;
  const newLabel = String(insertionIndex + 1);

  // Refs that need renumbering: those with label >= newLabel
  const toRenumber = existingRefs
    .filter((r) => parseInt(r.label, 10) >= parseInt(newLabel, 10))
    .sort((a, b) => b.pos - a.pos); // REVERSE order for safe setNodeMarkup

  // Single transaction: renumber FIRST (reverse order), then insert
  const tr = view.state.tr;

  for (const ref of toRenumber) {
    tr.setNodeMarkup(ref.pos, undefined, {
      label: String(parseInt(ref.label, 10) + 1),
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
    if (labelInt < parseInt(newLabel, 10)) {
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
    .filter((r) => parseInt(r.label, 10) >= parseInt(newLabel, 10))
    .sort((a, b) => b.pos - a.pos);

  const tr = view.state.tr;

  // ORDER MATTERS:
  // 1. setNodeMarkup FIRST (doesn't change positions)
  for (const ref of toRenumber) {
    tr.setNodeMarkup(ref.pos, undefined, { label: String(parseInt(ref.label, 10) + 1) });
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
    if (labelInt < parseInt(newLabel, 10)) {
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

  // Search for footnote_def node with matching label
  let targetPos = -1;
  let usedTextFallback = false;
  view.state.doc.descendants((node: Node, pos: number) => {
    if (targetPos !== -1) return false;
    if (node.type.name === 'footnote_def' && node.attrs.label === label) {
      targetPos = pos;
      return false;
    }
  });

  // Fallback: text-based search for transition safety
  if (targetPos === -1) {
    const searchText = `[^${label}]:`;
    view.state.doc.descendants((node: Node, pos: number) => {
      if (targetPos !== -1) return false;
      if (node.isTextblock && node.textContent.startsWith(searchText)) {
        targetPos = pos;
        usedTextFallback = true;
        return false;
      }
    });
  }

  if (targetPos !== -1) {
    try {
      let cursorPos: number;
      if (usedTextFallback) {
        // Text-based: targetPos is paragraph position, content starts at +1
        const searchText = `[^${label}]:`;
        const contentStart = targetPos + 1;
        const paragraphEnd = view.state.doc.resolve(contentStart).end();
        cursorPos = Math.min(contentStart + searchText.length + 1, paragraphEnd);
      } else {
        // Node-based: targetPos is the atom node position
        const resolvedTarget = view.state.doc.resolve(targetPos);
        const parentStart = resolvedTarget.start(resolvedTarget.depth);
        const parentEnd = view.state.doc.resolve(parentStart).end();
        cursorPos = Math.min(parentStart + 2, parentEnd);
      }
      const sel = TextSelection.create(view.state.doc, cursorPos);
      view.dispatch(view.state.tr.setSelection(sel).scrollIntoView());
      // Defer focus + scroll to next frame so WebKit completes layout
      // after document replacement (footnote creation replaces entire
      // document via setContentWithBlockIds before calling this)
      requestAnimationFrame(() => {
        try {
          view.focus();
          const coords = view.coordsAtPos(targetPos);
          if (coords) {
            window.scrollTo({
              top: Math.max(0, coords.top + window.scrollY - 100),
              behavior: 'smooth',
            });
          }
        } catch {
          /* focus/scroll failed */
        }
      });
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

  // Collect all nodes that need renumbering (refs and defs, with positions)
  const changes: Array<{ pos: number; newLabel: string }> = [];
  view.state.doc.descendants((node: Node, pos: number) => {
    if ((node.type.name === 'footnote_ref' || node.type.name === 'footnote_def') && mapping[node.attrs.label]) {
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

// Input rule: typing [^N]: at paragraph start converts to footnote_def pill + space
const footnoteDefInputRule = $prose((ctx) => {
  const defInputRule = new InputRule(/^\[\^(\d+)\]:\s$/, (state, match, start, end) => {
    const label = match[1];
    const defNodeType = footnoteDefNode.type(ctx);
    const defNode = defNodeType.create({ label });
    // Replace the typed text with the footnote_def atom node + space
    return state.tr
      .delete(start, end)
      .insert(start, defNode)
      .insertText(' ', start + 1);
  });

  return inputRules({ rules: [defInputRule] });
});

// Safety net: handle clicks on raw [^N]: text during transitions before remark plugin processes
const footnoteClickPlugin = $prose((_ctx) => {
  return new Plugin({
    props: {
      handleClick(view, pos, _event) {
        if (pos < 0) return false;
        const $pos = view.state.doc.resolve(pos);
        const parent = $pos.parent;
        if (!parent.isTextblock) return false;

        const text = parent.textContent;
        const defMatch = text.match(/^\[\^(\d+)\]:/);
        if (!defMatch) return false;

        // Only handle clicks within the [^N]: prefix
        const parentStart = $pos.start();
        const clickOffset = pos - parentStart;
        if (clickOffset > defMatch[0].length) return false;

        const label = defMatch[1];

        // Navigate to the corresponding footnote_ref
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
            view.dispatch(view.state.tr.setSelection(sel).scrollIntoView());
            const coords = view.coordsAtPos(refPos);
            if (coords) {
              window.scrollTo({
                top: Math.max(0, coords.top + window.scrollY - 100),
                behavior: 'smooth',
              });
            }
            view.focus();
          } catch {
            /* navigation failed */
          }
          return true;
        }

        return false;
      },
    },
  });
});

// Export the plugin array — node view MUST be in same array to maintain atom identity
export const footnotePlugin: MilkdownPlugin[] = [
  remarkFootnotePlugin,
  footnoteRefNode,
  footnoteRefNodeView,
  footnoteDefNode,
  footnoteDefNodeView,
  footnoteDefInputRule,
  footnoteClickPlugin,
].flat();
