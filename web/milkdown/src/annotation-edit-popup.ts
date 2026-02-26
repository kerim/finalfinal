// Annotation Edit Popup
// In-app popup for editing annotation text (type indicator with clickable task icon, textarea)
// Singleton pattern modeled on citation-edit-popup.ts

import type { EditorView } from '@milkdown/kit/prose/view';
import type { AnnotationAttrs, AnnotationType } from './annotation-plugin';
import { annotationMarkers, completedTaskMarker } from './annotation-plugin';

// Annotation edit popup state (module-level singleton)
let editPopup: HTMLElement | null = null;
let editPopupInput: HTMLTextAreaElement | null = null;
let editPopupTypeLabel: HTMLElement | null = null;
let editPopupTypeIcon: HTMLElement | null = null;
let editingNodePos: number | null = null;
let editingView: EditorView | null = null;
let editPopupBlurTimeout: ReturnType<typeof setTimeout> | null = null;
let editPopupCompleted = false;
let currentEditType: AnnotationType = 'comment';

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
  typeIcon.style.cssText = 'font-size: 14px; transition: transform 0.15s ease; display: inline-block;';
  editPopupTypeIcon = typeIcon;

  const typeLabel = document.createElement('span');
  typeLabel.style.cssText = 'font-weight: 500;';
  editPopupTypeLabel = typeLabel;

  typeRow.appendChild(typeIcon);
  typeRow.appendChild(typeLabel);

  // Type icon click handler (toggles completion for tasks)
  typeIcon.addEventListener('click', () => {
    if (currentEditType !== 'task') return;
    editPopupCompleted = !editPopupCompleted;
    typeIcon.textContent = editPopupCompleted ? completedTaskMarker : annotationMarkers.task;
  });

  // Hover effect for task icon
  typeIcon.addEventListener('mouseenter', () => {
    if (currentEditType === 'task') {
      typeIcon.style.transform = 'scale(1.2)';
    }
  });
  typeIcon.addEventListener('mouseleave', () => {
    typeIcon.style.transform = 'scale(1)';
  });

  // Textarea input
  const textarea = document.createElement('textarea');
  textarea.className = 'ff-annotation-edit-input';
  textarea.placeholder = 'Annotation text...';
  textarea.spellcheck = true;
  textarea.rows = 3;
  textarea.style.cssText = `
    width: 100%;
    padding: 6px 8px;
    border: 1px solid var(--border-color, #ccc);
    border-radius: 4px;
    font-size: 13px;
    background: var(--bg-secondary, #f5f5f5);
    color: var(--text-primary, #333);
    box-sizing: border-box;
    resize: vertical;
    max-height: 150px;
    overflow-y: auto;
    font-family: inherit;
  `;
  editPopupInput = textarea;

  // Hint
  const hint = document.createElement('div');
  hint.textContent = 'Enter to save \u2022 Shift+Enter for new line \u2022 Escape to cancel';
  hint.style.cssText = `
    margin-top: 6px;
    font-size: 11px;
    color: var(--text-tertiary, #999);
    text-align: center;
  `;

  // Assemble popup
  popup.appendChild(typeRow);
  popup.appendChild(textarea);
  popup.appendChild(hint);

  // Event handlers
  textarea.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      commitAnnotationEdit();
    } else if (e.key === 'Escape') {
      e.preventDefault();
      cancelAnnotationEdit();
    }
    // Shift+Enter falls through — default textarea newline behavior
  });

  textarea.addEventListener('blur', () => {
    editPopupBlurTimeout = setTimeout(() => {
      if (editPopup?.style.display !== 'none') {
        commitAnnotationEdit();
      }
    }, 150);
  });

  textarea.addEventListener('focus', () => {
    if (editPopupBlurTimeout) {
      clearTimeout(editPopupBlurTimeout);
      editPopupBlurTimeout = null;
    }
  });

  // Prevent popup clicks from triggering blur commit
  popup.addEventListener('mousedown', (e) => {
    // Don't prevent default on the textarea itself
    if (e.target !== textarea) {
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

  // Update type indicator and completion state
  const type = attrs.type;
  currentEditType = type;
  editPopupCompleted = type === 'task' ? attrs.isCompleted : false;

  if (editPopupTypeIcon) {
    let marker = annotationMarkers[type];
    if (type === 'task' && editPopupCompleted) {
      marker = completedTaskMarker;
    }
    editPopupTypeIcon.textContent = marker;
    // Set cursor style based on type
    editPopupTypeIcon.style.cursor = type === 'task' ? 'pointer' : 'default';
  }
  if (editPopupTypeLabel) {
    editPopupTypeLabel.textContent = typeLabels[type];
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
  const isCompleted = editPopupCompleted;

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
