// Annotation Edit Popup
// In-app popup for editing annotation text (type indicator, checkbox for tasks, text input)
// Singleton pattern modeled on citation-edit-popup.ts

import type { EditorView } from '@milkdown/kit/prose/view';
import type { AnnotationAttrs, AnnotationType } from './annotation-plugin';
import { annotationMarkers, completedTaskMarker } from './annotation-plugin';

// Annotation edit popup state (module-level singleton)
let editPopup: HTMLElement | null = null;
let editPopupInput: HTMLInputElement | null = null;
let editPopupCheckbox: HTMLInputElement | null = null;
let editPopupCheckboxRow: HTMLElement | null = null;
let editPopupTypeLabel: HTMLElement | null = null;
let editPopupTypeIcon: HTMLElement | null = null;
let editingNodePos: number | null = null;
let editingView: EditorView | null = null;
let editPopupBlurTimeout: ReturnType<typeof setTimeout> | null = null;

// Type display labels
const typeLabels: Record<AnnotationType, string> = {
  task: 'Task',
  comment: 'Comment',
  reference: 'Reference',
};

// Create the edit popup structure (singleton, reused)
function createAnnotationEditPopup(): HTMLElement {
  if (editPopup) return editPopup;

  const popup = document.createElement('div');
  popup.className = 'ff-annotation-edit-popup';
  popup.style.cssText = `
    position: fixed;
    z-index: 10000;
    background: var(--bg-primary, #fff);
    border: 1px solid var(--border-color, #ccc);
    border-radius: 6px;
    padding: 8px;
    box-shadow: 0 4px 12px rgba(0,0,0,0.15);
    min-width: 250px;
    display: none;
  `;

  // Type indicator row
  const typeRow = document.createElement('div');
  typeRow.style.cssText = `
    display: flex;
    align-items: center;
    gap: 6px;
    margin-bottom: 6px;
    font-size: 12px;
    color: var(--text-secondary, #666);
  `;

  const typeIcon = document.createElement('span');
  typeIcon.style.cssText = 'font-size: 14px;';
  editPopupTypeIcon = typeIcon;

  const typeLabel = document.createElement('span');
  typeLabel.style.cssText = 'font-weight: 500;';
  editPopupTypeLabel = typeLabel;

  typeRow.appendChild(typeIcon);
  typeRow.appendChild(typeLabel);

  // Checkbox row (visible only for tasks)
  const checkboxRow = document.createElement('label');
  checkboxRow.style.cssText = `
    display: none;
    align-items: center;
    gap: 6px;
    margin-bottom: 6px;
    font-size: 13px;
    color: var(--text-primary, #333);
    cursor: pointer;
  `;

  const checkbox = document.createElement('input');
  checkbox.type = 'checkbox';
  checkbox.style.cssText = 'margin: 0;';
  editPopupCheckbox = checkbox;

  const checkboxLabel = document.createElement('span');
  checkboxLabel.textContent = 'Completed';

  checkboxRow.appendChild(checkbox);
  checkboxRow.appendChild(checkboxLabel);
  editPopupCheckboxRow = checkboxRow;

  // Text input
  const input = document.createElement('input');
  input.type = 'text';
  input.className = 'ff-annotation-edit-input';
  input.placeholder = 'Annotation text...';
  input.spellcheck = true;
  input.style.cssText = `
    width: 100%;
    padding: 6px 8px;
    border: 1px solid var(--border-color, #ccc);
    border-radius: 4px;
    font-size: 13px;
    background: var(--bg-secondary, #f5f5f5);
    color: var(--text-primary, #333);
    box-sizing: border-box;
  `;
  editPopupInput = input;

  // Hint
  const hint = document.createElement('div');
  hint.textContent = 'Enter to save \u2022 Escape to cancel';
  hint.style.cssText = `
    margin-top: 6px;
    font-size: 11px;
    color: var(--text-tertiary, #999);
    text-align: center;
  `;

  // Assemble popup
  popup.appendChild(typeRow);
  popup.appendChild(checkboxRow);
  popup.appendChild(input);
  popup.appendChild(hint);

  // Event handlers
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      commitAnnotationEdit();
    } else if (e.key === 'Escape') {
      e.preventDefault();
      cancelAnnotationEdit();
    }
  });

  input.addEventListener('blur', () => {
    editPopupBlurTimeout = setTimeout(() => {
      if (editPopup?.style.display !== 'none') {
        commitAnnotationEdit();
      }
    }, 150);
  });

  input.addEventListener('focus', () => {
    if (editPopupBlurTimeout) {
      clearTimeout(editPopupBlurTimeout);
      editPopupBlurTimeout = null;
    }
  });

  // Prevent popup clicks from triggering blur commit
  popup.addEventListener('mousedown', (e) => {
    // Don't prevent default on the input itself
    if (e.target !== input) {
      e.preventDefault();
    }
  });

  editPopup = popup;
  document.body.appendChild(popup);
  return popup;
}

// Show the annotation edit popup
export function showAnnotationEditPopup(pos: number, view: EditorView, attrs: AnnotationAttrs): void {
  // If popup already open, commit current edit first
  if (editingNodePos !== null && editingView && editPopupInput) {
    commitAnnotationEdit();
  }

  // Store editing context
  editingNodePos = pos;
  editingView = view;

  // Create popup if needed
  const popup = createAnnotationEditPopup();
  const input = editPopupInput!;

  // Update type indicator
  const type = attrs.type;
  if (editPopupTypeIcon) {
    let marker = annotationMarkers[type];
    if (type === 'task' && attrs.isCompleted) {
      marker = completedTaskMarker;
    }
    editPopupTypeIcon.textContent = marker;
  }
  if (editPopupTypeLabel) {
    editPopupTypeLabel.textContent = typeLabels[type];
  }

  // Show/hide checkbox row
  if (editPopupCheckboxRow) {
    editPopupCheckboxRow.style.display = type === 'task' ? 'flex' : 'none';
  }
  if (editPopupCheckbox) {
    editPopupCheckbox.checked = attrs.isCompleted;
  }

  // Position popup below the annotation
  const coords = view.coordsAtPos(pos);
  popup.style.left = `${coords.left}px`;
  popup.style.top = `${coords.bottom + 4}px`;

  // Populate and show
  input.value = attrs.text || '';
  popup.style.display = 'block';

  // Focus and select all
  input.focus();
  input.select();
}

// Commit the edit
function commitAnnotationEdit(): void {
  const pos = editingNodePos;
  const view = editingView;

  if (pos === null || !view) {
    hideAnnotationEditPopup();
    return;
  }

  const newText = editPopupInput?.value || '';
  const isCompleted = editPopupCheckbox?.checked || false;

  // Verify node still exists at position
  const currentNode = view.state.doc.nodeAt(pos);
  if (currentNode && currentNode.type.name === 'annotation') {
    const tr = view.state.tr.setNodeMarkup(pos, undefined, {
      ...currentNode.attrs,
      text: newText,
      isCompleted,
    });
    view.dispatch(tr);
  }

  hideAnnotationEditPopup();
  view.focus();
}

// Cancel the edit
function cancelAnnotationEdit(): void {
  const view = editingView;
  hideAnnotationEditPopup();
  view?.focus();
}

// Hide the popup and clear state
export function hideAnnotationEditPopup(): void {
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

// Check if popup is currently open
export function isAnnotationEditPopupOpen(): boolean {
  return editPopup !== null && editPopup.style.display !== 'none';
}
