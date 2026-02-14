import type { EditorView } from '@codemirror/view';
import {
  getCitationAddButton,
  getEditorView,
  setCitationAddButton,
  setPendingAppendMode,
  setPendingAppendRange,
} from './editor-state';

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

// Detect if cursor is inside a citation bracket [@...]
export function getCitationAtCursor(view: EditorView): { text: string; from: number; to: number } | null {
  const pos = view.state.selection.main.head;
  const doc = view.state.doc.toString();

  // Search backwards for '[' and forwards for ']'
  let bracketStart = -1;
  let bracketEnd = -1;

  // Find opening bracket before cursor
  for (let i = pos - 1; i >= 0; i--) {
    if (doc[i] === '[') {
      bracketStart = i;
      break;
    }
    if (doc[i] === ']') {
      // Found closing bracket before opening - not inside a bracket
      break;
    }
  }

  if (bracketStart === -1) return null;

  // Find closing bracket after cursor
  for (let i = pos; i < doc.length; i++) {
    if (doc[i] === ']') {
      bracketEnd = i + 1;
      break;
    }
    if (doc[i] === '[') {
      // Found another opening bracket - not a valid citation
      break;
    }
  }

  if (bracketEnd === -1) return null;

  // Extract the text and verify it's a citation (contains @)
  const text = doc.slice(bracketStart, bracketEnd);
  if (!text.includes('@')) return null;

  return { text, from: bracketStart, to: bracketEnd };
}

// Create the floating add citation button
export function createCitationAddButton(): HTMLElement {
  const existing = getCitationAddButton();
  if (existing) return existing;

  const button = document.createElement('button');
  button.textContent = '+';
  button.className = 'cm-citation-add-button';
  button.style.cssText = `
    position: fixed;
    z-index: 10000;
    width: 24px;
    height: 24px;
    border-radius: 4px;
    border: 1px solid var(--editor-border, #ccc);
    background: var(--editor-bg, white);
    color: var(--editor-text, #333);
    cursor: pointer;
    font-size: 16px;
    font-weight: bold;
    line-height: 1;
    display: none;
    align-items: center;
    justify-content: center;
    box-shadow: 0 2px 4px rgba(0,0,0,0.1);
  `;
  button.title = 'Add citation';

  button.addEventListener('mouseenter', () => {
    button.style.background = 'var(--editor-selection, #e8f0fe)';
  });
  button.addEventListener('mouseleave', () => {
    button.style.background = 'var(--editor-bg, white)';
  });
  button.addEventListener('click', (e) => {
    e.preventDefault();
    e.stopPropagation();
    handleAddCitationClick();
  });

  document.body.appendChild(button);
  setCitationAddButton(button);
  return button;
}

// Handle click on the add citation button
export function handleAddCitationClick(): void {
  const view = getEditorView();
  if (!view) return;

  const citation = getCitationAtCursor(view);
  if (!citation) {
    hideCitationAddButton();
    return;
  }

  // Store the range for merging later
  setPendingAppendMode(true);
  setPendingAppendRange({ start: citation.from, end: citation.to });

  // Call Swift to open CAYW picker
  // Pass -1 to indicate append mode
  if ((window as any).webkit?.messageHandlers?.openCitationPicker) {
    (window as any).webkit.messageHandlers.openCitationPicker.postMessage(-1);
  } else {
    setPendingAppendMode(false);
    setPendingAppendRange(null);
  }
}

// Show the add button near the citation
export function showCitationAddButton(view: EditorView, citation: { text: string; from: number; to: number }): void {
  const button = createCitationAddButton();

  // Get coordinates for the end of the citation
  const coords = view.coordsAtPos(citation.to);
  if (!coords) {
    button.style.display = 'none';
    return;
  }

  button.style.left = `${coords.right + 4}px`;
  button.style.top = `${coords.top}px`;
  button.style.display = 'flex';
}

// Hide the add button
export function hideCitationAddButton(): void {
  const button = getCitationAddButton();
  if (button) {
    button.style.display = 'none';
  }
}

// Update add button visibility based on cursor position
export function updateCitationAddButton(view: EditorView): void {
  const citation = getCitationAtCursor(view);
  if (citation) {
    showCitationAddButton(view, citation);
  } else {
    hideCitationAddButton();
  }
}
