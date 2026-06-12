// Math Edit Popup for Milkdown
// Floating popup for editing LaTeX equations with live KaTeX preview.
// Mirrors citation-edit-popup.ts: monospace input + live preview + blur-timeout commit.

import type { EditorView } from '@milkdown/kit/prose/view';
import katex from 'katex';
import { positionPopup } from '../../shared/position-popup';

// Module-level singleton state
let editPopup: HTMLElement | null = null;
let editInput: HTMLTextAreaElement | null = null;
let editPreview: HTMLElement | null = null;
let editingNodePos: number | null = null;
let editingView: EditorView | null = null;
let editingIsDisplay = false;
let blurTimeout: ReturnType<typeof setTimeout> | null = null;

// Create the popup structure (singleton, reused)
function createEditPopup(): HTMLElement {
  if (editPopup) return editPopup;

  const popup = document.createElement('div');
  popup.className = 'ff-math-edit-popup';
  popup.style.cssText = `
    position: fixed;
    z-index: 10000;
    background: var(--editor-bg, #fff);
    border: 1px solid var(--editor-selection, rgba(128,128,128,0.25));
    border-radius: 6px;
    padding: 8px;
    box-shadow: 0 4px 12px rgba(0,0,0,0.15);
    min-width: 280px;
    max-width: min(420px, calc(100vw - 16px));
    display: none;
  `;

  // Monospace textarea for LaTeX input
  const textarea = document.createElement('textarea');
  textarea.className = 'ff-math-edit-input';
  textarea.spellcheck = false;
  textarea.rows = 3;
  textarea.style.cssText = `
    width: 100%;
    padding: 6px 8px;
    border: 1px solid var(--editor-selection, rgba(128,128,128,0.25));
    border-radius: 4px;
    font-family: monospace;
    font-size: 13px;
    background: var(--editor-bg, #fff);
    color: var(--editor-text, #1a1a1a);
    box-sizing: border-box;
    resize: vertical;
  `;

  // Live KaTeX preview area
  const preview = document.createElement('div');
  preview.className = 'ff-math-edit-preview';
  preview.style.cssText = `
    margin-top: 6px;
    padding: 12px;
    background: var(--editor-bg, #fff);
    color: var(--editor-text, #1a1a1a);
    border: 1px solid var(--editor-selection, rgba(128,128,128,0.25));
    border-radius: 4px;
    font-size: 1.15em;
    min-height: 44px;
    overflow-x: auto;
    text-align: center;
  `;

  // Keyboard hint
  const hint = document.createElement('div');
  hint.textContent = 'Enter to save • Escape to cancel';
  hint.style.cssText = `
    margin-top: 6px;
    font-size: 11px;
    color: var(--editor-muted, #888);
    text-align: center;
  `;

  popup.appendChild(textarea);
  popup.appendChild(preview);
  popup.appendChild(hint);

  // Live preview on input
  textarea.addEventListener('input', () => {
    renderPreview(textarea.value);
  });

  // Enter commits, Escape cancels (Shift+Enter inserts newline in textarea)
  textarea.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      commitEdit(textarea.value);
    } else if (e.key === 'Escape') {
      e.preventDefault();
      cancelEdit();
    }
  });

  // Blur-timeout commit (150ms guard — same as citation-edit-popup.ts:229-240)
  textarea.addEventListener('blur', () => {
    blurTimeout = setTimeout(() => {
      if (editPopup?.style.display !== 'none') {
        commitEdit(textarea.value);
      }
    }, 150);
  });

  textarea.addEventListener('focus', () => {
    if (blurTimeout) {
      clearTimeout(blurTimeout);
      blurTimeout = null;
    }
  });

  editPopup = popup;
  editInput = textarea;
  editPreview = preview;

  document.body.appendChild(popup);
  return popup;
}

function renderPreview(latex: string): void {
  if (!editPreview) return;
  const trimmed = latex.trim();
  if (!trimmed) {
    editPreview.textContent = 'Enter LaTeX…';
    editPreview.style.color = 'var(--editor-muted, #888)';
    return;
  }
  try {
    katex.render(trimmed, editPreview, {
      displayMode: editingIsDisplay,
      throwOnError: true,
      output: 'html',
    });
    editPreview.style.color = '';
  } catch (err: any) {
    editPreview.textContent = err?.message || 'Parse error';
    editPreview.style.color = '#e5484d';
  }
}

export function showMathEditPopup(pos: number, view: EditorView, latex: string, isDisplay: boolean): void {
  // Commit any open edit first
  if (editingNodePos !== null && editingView && editInput) {
    commitEdit(editInput.value);
  }

  editingNodePos = pos;
  editingView = view;
  editingIsDisplay = isDisplay;

  const popup = createEditPopup();
  const input = editInput!;

  input.value = latex;
  popup.style.display = 'block';
  renderPreview(latex);

  // Position relative to the node (coordsAtPos can throw for out-of-bounds pos)
  let coords: { left: number; top: number; bottom: number; right: number };
  try {
    coords = view.coordsAtPos(pos);
  } catch {
    // Fall back to center of viewport
    coords = {
      left: window.innerWidth / 2,
      top: window.innerHeight / 2,
      bottom: window.innerHeight / 2,
      right: window.innerWidth / 2,
    };
  }
  positionPopup(popup, coords);

  input.focus();
  input.select();
}

function commitEdit(newLatex: string): void {
  const pos = editingNodePos;
  const view = editingView;
  const isDisplay = editingIsDisplay;

  if (pos === null || !view) {
    hidePopup();
    return;
  }

  const latex = newLatex.trim();
  const typeName = isDisplay ? 'math_display' : 'math_inline';
  const currentNode = view.state.doc.nodeAt(pos);

  if (currentNode && currentNode.type.name === typeName) {
    const tr = view.state.tr.setNodeMarkup(pos, undefined, { latex });
    view.dispatch(tr);
  }

  hidePopup();
  view.focus();
}

function cancelEdit(): void {
  const view = editingView;
  hidePopup();
  view?.focus();
}

function hidePopup(): void {
  if (editPopup) {
    editPopup.style.display = 'none';
  }
  if (blurTimeout) {
    clearTimeout(blurTimeout);
    blurTimeout = null;
  }
  editingNodePos = null;
  editingView = null;
  editingIsDisplay = false;
}
