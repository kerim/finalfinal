// Citation Edit Popup
// In-app popup for editing citation attributes (citekeys, locators, prefix, suffix)

import type { EditorView } from '@milkdown/kit/prose/view';
import type { CitationAttrs } from './citation-types';
import { serializeCitation } from './citation-types';
import { getCiteprocEngine } from './citeproc-engine';

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
  const suffix = '';
  let suppressAuthor = false;

  // Split by semicolon for multiple citations
  const parts = inner.split(';').map((p) => p.trim());

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

// Append mode state for adding citations to existing ones
let pendingAppendMode = false;
let pendingAppendBase = '';

// Export append mode state for main.ts to access
export function isPendingAppendMode(): boolean {
  return pendingAppendMode;
}

export function getPendingAppendBase(): string {
  return pendingAppendBase;
}

export function clearAppendMode(): void {
  pendingAppendMode = false;
  pendingAppendBase = '';
}

export function getEditPopupInput(): HTMLInputElement | null {
  return editPopupInput;
}

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
  hint.textContent = 'Enter to save \u2022 Escape to cancel';
  hint.style.cssText = `
    margin-top: 6px;
    font-size: 11px;
    color: var(--text-tertiary, #999);
    text-align: center;
  `;

  // Create "Add Citation" button
  const addButton = document.createElement('button');
  addButton.textContent = '+ Add Citation';
  addButton.className = 'ff-citation-add-button';
  addButton.style.cssText = `
    width: 100%;
    margin-top: 6px;
    padding: 6px 8px;
    border: 1px solid var(--border-color, #ccc);
    border-radius: 4px;
    background: var(--bg-secondary, #f5f5f5);
    color: var(--text-primary, #333);
    cursor: pointer;
    font-size: 13px;
    font-weight: 500;
  `;
  addButton.addEventListener('mouseenter', () => {
    addButton.style.background = 'var(--bg-tertiary, #e0e0e0)';
  });
  addButton.addEventListener('mouseleave', () => {
    addButton.style.background = 'var(--bg-secondary, #f5f5f5)';
  });
  addButton.addEventListener('click', (e) => {
    e.preventDefault();
    e.stopPropagation();

    // Cancel any pending blur commit - critical to prevent the popup from being
    // closed while the Zotero picker is open
    if (editPopupBlurTimeout) {
      clearTimeout(editPopupBlurTimeout);
      editPopupBlurTimeout = null;
    }

    // Store current input for merging later
    pendingAppendMode = true;
    pendingAppendBase = editPopupInput?.value || '';
    // Call native picker via Swift bridge
    // Pass -1 to indicate append mode (not a fresh insertion)
    if (typeof (window as any).webkit?.messageHandlers?.openCitationPicker?.postMessage === 'function') {
      (window as any).webkit.messageHandlers.openCitationPicker.postMessage(-1);
    } else {
      pendingAppendMode = false;
      pendingAppendBase = '';
    }
  });

  // Assemble popup
  popup.appendChild(input);
  popup.appendChild(addButton);
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

// Update preview based on current input (exported for append mode callback)
export function updateEditPreview(): void {
  if (!editPopupInput || !editPopupPreview) return;

  const text = editPopupInput.value;
  const parsed = parseEditedCitation(text);

  if (parsed && parsed.citekeys.length > 0) {
    const engine = getCiteprocEngine();
    const allResolved = parsed.citekeys.every((k) => engine.hasItem(k));

    if (allResolved) {
      try {
        const formatted = engine.formatCitation(parsed.citekeys, {
          suppressAuthors: parsed.suppressAuthor ? parsed.citekeys.map(() => true) : undefined,
          locators: parsed.locators.length > 0 ? parsed.locators : undefined,
          prefix: parsed.prefix,
          suffix: parsed.suffix,
        });
        editPopupPreview.textContent = formatted;
        editPopupPreview.style.color = 'var(--text-secondary, #666)';
      } catch (_e) {
        editPopupPreview.textContent = `(${parsed.citekeys.join('; ')})`;
        editPopupPreview.style.color = 'var(--text-secondary, #666)';
      }
    } else {
      // Show unresolved keys with ?
      const display = parsed.citekeys.map((k) => (engine.hasItem(k) ? engine.getShortCitation(k) : `${k}?`)).join('; ');
      editPopupPreview.textContent = `(${display})`;
      editPopupPreview.style.color = 'var(--warning-color, #c9a227)';
    }
  } else {
    editPopupPreview.textContent = 'Invalid citation syntax';
    editPopupPreview.style.color = 'var(--error-color, #c00)';
  }
}

// Show the citation edit popup
export function showCitationEditPopup(pos: number, view: EditorView, attrs: CitationAttrs): void {
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
