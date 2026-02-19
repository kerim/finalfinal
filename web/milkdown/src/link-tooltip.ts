// Custom Link Tooltip Plugin for Milkdown
// Replaces @milkdown/components/link-tooltip (which bundles Vue 3, incompatible with WKWebView IIFE)
// Follows citation-edit-popup.ts pattern: singleton DOM, position: fixed, coordsAtPos(), blur-with-delay

import type { MilkdownPlugin } from '@milkdown/kit/ctx';
import type { Mark } from '@milkdown/kit/prose/model';
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { $prose } from '@milkdown/kit/utils';
import { isSourceModeEnabled } from './source-mode-plugin';

// --- Helpers ---

interface LinkRange {
  from: number;
  to: number;
  href: string;
  mark: Mark;
}

/**
 * Find the full range of a link mark at a given position.
 * Walks the parent node's children to find contiguous text covered by the same link href.
 */
function findLinkMarkRange(view: EditorView, pos: number): LinkRange | null {
  const $pos = view.state.doc.resolve(pos);
  const parent = $pos.parent;
  const parentOffset = pos - $pos.parentOffset;

  // Find link mark at this position
  const marks = parent.child($pos.index()).marks;
  const linkMark = marks.find((m: Mark) => m.type.name === 'link');
  if (!linkMark) return null;

  const href = linkMark.attrs.href as string;

  // Walk children to find contiguous range with same href
  let from = parentOffset;
  let to = parentOffset;
  let foundStart = false;

  parent.forEach((child, offset) => {
    const childHasLink = child.marks.some((m: Mark) => m.type.name === 'link' && m.attrs.href === href);
    if (childHasLink) {
      if (!foundStart) {
        // Only start if this child contains or precedes our position
        if (parentOffset + offset + child.nodeSize > pos) {
          from = parentOffset + offset;
          foundStart = true;
        }
      }
      if (foundStart) {
        to = parentOffset + offset + child.nodeSize;
      }
    } else if (foundStart) {
      // Stop: non-link child after we started
      return;
    }
  });

  // Verify the found range actually contains pos
  if (!foundStart || pos < from || pos > to) {
    // Retry: just find any link range containing pos
    parent.forEach((child, offset) => {
      const childStart = parentOffset + offset;
      const childEnd = childStart + child.nodeSize;
      const childHasLink = child.marks.some((m: Mark) => m.type.name === 'link' && m.attrs.href === href);
      if (childHasLink && childStart <= pos && childEnd >= pos) {
        from = childStart;
        to = childEnd;
        // Expand backwards
        parent.forEach((pc, po) => {
          const pcStart = parentOffset + po;
          if (pcStart < from && pc.marks.some((m: Mark) => m.type.name === 'link' && m.attrs.href === href)) {
            from = pcStart;
          }
        });
        // Expand forwards
        parent.forEach((pc, po) => {
          const pcStart = parentOffset + po;
          const pcEnd = pcStart + pc.nodeSize;
          if (pcStart >= to && pc.marks.some((m: Mark) => m.type.name === 'link' && m.attrs.href === href)) {
            to = pcEnd;
          }
        });
      }
    });
    if (pos < from || pos > to) return null;
  }

  return { from, to, href, mark: linkMark };
}

// --- Singleton popup DOM ---

let previewEl: HTMLElement | null = null;
let editEl: HTMLElement | null = null;
let blurTimeout: ReturnType<typeof setTimeout> | null = null;
let activeView: EditorView | null = null;
let activeLinkRange: LinkRange | null = null;

function createPreviewPopup(): HTMLElement {
  if (previewEl) return previewEl;

  const el = document.createElement('div');
  el.className = 'ff-link-preview';
  el.style.cssText = `
    position: fixed;
    z-index: 10000;
    background: var(--bg-primary, #fff);
    border: 1px solid var(--border-color, #ccc);
    border-radius: 6px;
    padding: 6px 8px;
    box-shadow: 0 4px 12px rgba(0,0,0,0.15);
    display: none;
    align-items: center;
    gap: 6px;
    max-width: 400px;
    font-size: 13px;
  `;

  // URL display
  const urlSpan = document.createElement('span');
  urlSpan.className = 'ff-link-url';
  urlSpan.style.cssText = `
    color: var(--accent-color, #007aff);
    max-width: 220px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    flex: 1;
  `;

  // Separator
  const sep = document.createElement('span');
  sep.style.cssText = `
    width: 1px;
    height: 16px;
    background: var(--border-color, #ccc);
    flex-shrink: 0;
  `;

  // Buttons
  const editBtn = makeIconButton('Edit', () => {
    if (activeView && activeLinkRange) {
      hidePreview();
      showEdit(activeView, activeLinkRange);
    }
  });
  const copyBtn = makeIconButton('Copy', () => {
    if (activeLinkRange) {
      navigator.clipboard.writeText(activeLinkRange.href);
      hidePreview();
    }
  });
  const removeBtn = makeIconButton('Remove', () => {
    if (activeView && activeLinkRange) {
      const { from, to, mark } = activeLinkRange;
      const tr = activeView.state.tr.removeMark(from, to, mark);
      activeView.dispatch(tr);
      hidePreview();
      activeView.focus();
    }
  });

  el.appendChild(urlSpan);
  el.appendChild(sep);
  el.appendChild(editBtn);
  el.appendChild(copyBtn);
  el.appendChild(removeBtn);

  document.body.appendChild(el);
  previewEl = el;
  return el;
}

function makeIconButton(label: string, onClick: () => void): HTMLElement {
  const btn = document.createElement('button');
  btn.textContent = label;
  btn.style.cssText = `
    cursor: pointer;
    padding: 2px 6px;
    border-radius: 4px;
    font-size: 12px;
    border: none;
    background: transparent;
    color: var(--text-secondary, #666);
    white-space: nowrap;
    line-height: 1.4;
  `;
  btn.addEventListener('mouseenter', () => {
    btn.style.background = 'var(--editor-selection, rgba(0,122,255,0.1))';
    btn.style.color = 'var(--text-primary, #333)';
  });
  btn.addEventListener('mouseleave', () => {
    btn.style.background = 'transparent';
    btn.style.color = 'var(--text-secondary, #666)';
  });
  btn.addEventListener('mousedown', (e) => {
    e.preventDefault(); // Prevent editor blur
  });
  btn.addEventListener('click', (e) => {
    e.preventDefault();
    e.stopPropagation();
    onClick();
  });
  return btn;
}

function createEditPopup(): HTMLElement {
  if (editEl) return editEl;

  const el = document.createElement('div');
  el.className = 'ff-link-edit';
  el.style.cssText = `
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

  const input = document.createElement('input');
  input.type = 'text';
  input.placeholder = 'Paste URL...';
  input.spellcheck = false;
  input.style.cssText = `
    width: 100%;
    padding: 6px 8px;
    border: 1px solid var(--border-color, #ccc);
    border-radius: 4px;
    font-family: var(--font-mono, monospace);
    font-size: 13px;
    background: var(--bg-secondary, #f5f5f5);
    color: var(--text-primary, #333);
    box-sizing: border-box;
    outline: none;
  `;

  const hint = document.createElement('div');
  hint.textContent = 'Enter to save \u00b7 Escape to cancel';
  hint.style.cssText = `
    margin-top: 6px;
    font-size: 11px;
    color: var(--text-tertiary, #999);
    text-align: center;
  `;

  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      commitLinkEdit(input.value);
    } else if (e.key === 'Escape') {
      e.preventDefault();
      cancelLinkEdit();
    }
  });

  input.addEventListener('focus', () => {
    if (blurTimeout) {
      clearTimeout(blurTimeout);
      blurTimeout = null;
    }
    input.style.borderColor = 'var(--accent-color, #007aff)';
    input.style.boxShadow = '0 0 0 2px rgba(0,122,255,0.2)';
  });

  input.addEventListener('blur', () => {
    input.style.borderColor = 'var(--border-color, #ccc)';
    input.style.boxShadow = 'none';
    blurTimeout = setTimeout(() => {
      if (editEl?.style.display !== 'none') {
        commitLinkEdit(input.value);
      }
    }, 150);
  });

  el.appendChild(input);
  el.appendChild(hint);

  document.body.appendChild(el);
  editEl = el;
  return el;
}

// --- Show / Hide ---

function showPreview(view: EditorView, linkRange: LinkRange): void {
  hideAll();
  activeView = view;
  activeLinkRange = linkRange;

  const popup = createPreviewPopup();
  const urlSpan = popup.querySelector('.ff-link-url') as HTMLElement;
  urlSpan.textContent = linkRange.href;

  const coords = view.coordsAtPos(linkRange.from);
  popup.style.left = `${coords.left}px`;
  popup.style.top = `${coords.bottom + 4}px`;
  popup.style.display = 'flex';
}

function hidePreview(): void {
  if (previewEl) previewEl.style.display = 'none';
  activeLinkRange = null;
}

function showEdit(view: EditorView, linkRange: LinkRange | null): void {
  hidePreview();
  activeView = view;
  activeLinkRange = linkRange;

  const popup = createEditPopup();
  const input = popup.querySelector('input') as HTMLInputElement;

  input.value = linkRange?.href || '';

  // Position below the link or cursor
  const pos = linkRange?.from ?? view.state.selection.from;
  const coords = view.coordsAtPos(pos);
  popup.style.left = `${coords.left}px`;
  popup.style.top = `${coords.bottom + 4}px`;
  popup.style.display = 'block';

  input.focus();
  input.select();
}

function hideEdit(): void {
  if (editEl) editEl.style.display = 'none';
  if (blurTimeout) {
    clearTimeout(blurTimeout);
    blurTimeout = null;
  }
}

function hideAll(): void {
  hidePreview();
  hideEdit();
}

// --- Edit commit / cancel ---

function commitLinkEdit(url: string): void {
  const view = activeView;
  const range = activeLinkRange;
  hideEdit();

  if (!view) return;

  const trimmedUrl = url.trim();

  if (range) {
    // Editing existing link
    if (!trimmedUrl) {
      // Empty URL = remove link
      const tr = view.state.tr.removeMark(range.from, range.to, range.mark);
      view.dispatch(tr);
    } else {
      // Update href
      const linkType = view.state.schema.marks.link;
      const tr = view.state.tr
        .removeMark(range.from, range.to, range.mark)
        .addMark(range.from, range.to, linkType.create({ href: trimmedUrl }));
      view.dispatch(tr);
    }
  } else if (trimmedUrl) {
    // New link with no prior range — insert link at cursor
    const { from, to } = view.state.selection;
    const linkType = view.state.schema.marks.link;

    if (from === to) {
      // No selection — insert URL as both text and link
      const linkMark = linkType.create({ href: trimmedUrl });
      const textNode = view.state.schema.text(trimmedUrl, [linkMark]);
      const tr = view.state.tr.insert(from, textNode);
      view.dispatch(tr);
    } else {
      // Selection exists — wrap in link
      const tr = view.state.tr.addMark(from, to, linkType.create({ href: trimmedUrl }));
      view.dispatch(tr);
    }
  }

  view.focus();
  activeLinkRange = null;
}

function cancelLinkEdit(): void {
  const view = activeView;
  hideEdit();
  view?.focus();
  activeLinkRange = null;
}

// --- ProseMirror Plugin ---

const linkTooltipPluginKey = new PluginKey('ff-link-tooltip');

const linkTooltipProsPlugin = $prose(() => {
  return new Plugin({
    key: linkTooltipPluginKey,

    props: {
      handleClick(view: EditorView, pos: number, event: MouseEvent): boolean {
        // Skip in source mode
        if (isSourceModeEnabled()) return false;

        // Cmd+click is handled by link-click-handler.ts (opens in browser)
        if (event.metaKey || event.ctrlKey) return false;

        // Check if click is on a link
        const linkRange = findLinkMarkRange(view, pos);
        if (linkRange) {
          showPreview(view, linkRange);
          return false; // Don't consume — let ProseMirror place the cursor
        }

        // Click outside link — dismiss
        hideAll();
        return false;
      },
    },

    view() {
      return {
        update(view: EditorView) {
          // Dismiss if selection moved outside active link range
          if (activeLinkRange && (previewEl?.style.display !== 'none' || editEl?.style.display !== 'none')) {
            const { from } = view.state.selection;
            if (from < activeLinkRange.from || from > activeLinkRange.to) {
              hideAll();
            }
          }
        },
        destroy() {
          hideAll();
        },
      };
    },
  });
});

// --- Exports ---

/**
 * Open the link edit popup for Cmd+K handler.
 * If cursor is on an existing link, opens edit with pre-filled URL.
 * If text is selected, opens edit to wrap selection in a link.
 * If nothing selected, inserts a new empty link at cursor.
 */
export function openLinkEdit(view: EditorView): void {
  if (isSourceModeEnabled()) return;

  const { from, to } = view.state.selection;

  // Check if cursor is on an existing link
  const linkRange = findLinkMarkRange(view, from);
  if (linkRange) {
    hideAll();
    showEdit(view, linkRange);
    return;
  }

  // No existing link — open edit for new link
  if (from !== to) {
    // Selection exists — will wrap selected text
    hideAll();
    activeLinkRange = null;
    activeView = view;
    showEdit(view, null);
  } else {
    // No selection, no existing link — open edit to insert new link at cursor
    hideAll();
    activeLinkRange = null;
    activeView = view;
    showEdit(view, null);
  }
}

/** Hide all link popups (for external callers) */
export function hideLinkPopups(): void {
  hideAll();
}

export const linkTooltipPlugin: MilkdownPlugin[] = [linkTooltipProsPlugin].flat();
