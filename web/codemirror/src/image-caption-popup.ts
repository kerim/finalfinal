/**
 * Image Caption Edit Popup for CodeMirror 6
 *
 * Singleton popup for editing image captions in source mode.
 * Pattern modeled on Milkdown's annotation-edit-popup.ts.
 *
 * Captions are stored as <!-- caption: text --> comments
 * on the line preceding the image markdown.
 */

import type { EditorView } from '@codemirror/view';

// --- Constants ---

const CAPTION_REGEX = /^<!--\s*caption:\s*(.+?)\s*-->$/;
const IMAGE_REGEX = /!\[([^\]]*)\]\((media\/[^)]+)\)/;

// --- Module state (singleton) ---

let popup: HTMLElement | null = null;
let popupInput: HTMLInputElement | null = null;
let editingView: EditorView | null = null;
let editingImageLineNumber: number | null = null;
let editingCaptionLineNumber: number | null = null; // null = creating new caption
let blurTimeout: ReturnType<typeof setTimeout> | null = null;

/** Flag to prevent auto-dismiss during our own commit dispatch */
export let isCommittingCaption = false;

// --- Popup DOM ---

function createPopup(): HTMLElement {
  if (popup) return popup;

  const el = document.createElement('div');
  el.className = 'cm-caption-edit-popup';
  el.style.display = 'none';

  const input = document.createElement('input');
  input.type = 'text';
  input.placeholder = 'Image caption…';
  input.spellcheck = true;
  popupInput = input;

  const hint = document.createElement('div');
  hint.className = 'cm-caption-edit-hint';
  hint.textContent = 'Enter to save \u00b7 Escape to cancel';

  el.appendChild(input);
  el.appendChild(hint);

  // --- Event handlers ---

  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      commitEdit();
    } else if (e.key === 'Escape') {
      e.preventDefault();
      cancelEdit();
    }
  });

  input.addEventListener('blur', () => {
    blurTimeout = setTimeout(() => {
      if (popup?.style.display !== 'none') {
        commitEdit();
      }
    }, 150);
  });

  input.addEventListener('focus', () => {
    if (blurTimeout) {
      clearTimeout(blurTimeout);
      blurTimeout = null;
    }
  });

  // Prevent popup clicks from triggering blur
  el.addEventListener('mousedown', (e) => {
    if (e.target !== input) {
      e.preventDefault();
    }
  });

  popup = el;
  document.body.appendChild(el);
  return el;
}

// --- Commit logic ---

function commitEdit(): void {
  const view = editingView;
  const imageLineNum = editingImageLineNumber;

  if (!view || imageLineNum === null) {
    dismissImageCaptionPopup();
    return;
  }

  const newText = popupInput?.value.trim() || '';
  const doc = view.state.doc;

  // Safety: verify the image line still matches
  if (imageLineNum < 1 || imageLineNum > doc.lines) {
    dismissImageCaptionPopup();
    return;
  }
  const imageLine = doc.line(imageLineNum);
  if (!IMAGE_REGEX.test(imageLine.text)) {
    dismissImageCaptionPopup();
    return;
  }

  isCommittingCaption = true;

  try {
    if (editingCaptionLineNumber !== null) {
      // Editing existing caption
      const captionLineNum = editingCaptionLineNumber;
      if (captionLineNum < 1 || captionLineNum > doc.lines) {
        dismissImageCaptionPopup();
        return;
      }
      const captionLine = doc.line(captionLineNum);
      if (!CAPTION_REGEX.test(captionLine.text.trim())) {
        dismissImageCaptionPopup();
        return;
      }

      if (newText) {
        // Replace caption text
        view.dispatch({
          changes: {
            from: captionLine.from,
            to: captionLine.to,
            insert: `<!-- caption: ${newText} -->`,
          },
        });
      } else {
        // Delete caption line (+ trailing newline if present)
        const deleteTo = captionLine.to + 1 <= doc.length ? captionLine.to + 1 : captionLine.to;
        view.dispatch({
          changes: {
            from: captionLine.from,
            to: deleteTo,
            insert: '',
          },
        });
      }
    } else {
      // Adding new caption — insert before image line
      if (newText) {
        view.dispatch({
          changes: {
            from: imageLine.from,
            to: imageLine.from,
            insert: `<!-- caption: ${newText} -->\n`,
          },
        });
      }
      // Empty input on new caption = no-op
    }
  } finally {
    isCommittingCaption = false;
  }

  const v = editingView;
  dismissImageCaptionPopup();
  v?.focus();
}

function cancelEdit(): void {
  const v = editingView;
  dismissImageCaptionPopup();
  v?.focus();
}

// --- Public API ---

export function showImageCaptionPopup(
  view: EditorView,
  rect: DOMRect,
  currentCaption: string,
  imageLineNumber: number,
  captionLineNumber: number | null
): void {
  // If popup already open for a different image, commit current edit first
  if (editingImageLineNumber !== null && editingView && popupInput) {
    if (editingImageLineNumber !== imageLineNumber) {
      commitEdit();
    }
  }

  editingView = view;
  editingImageLineNumber = imageLineNumber;
  editingCaptionLineNumber = captionLineNumber;

  const el = createPopup();
  const input = popupInput!;

  // Position below the clicked caption element
  el.style.left = `${rect.left}px`;
  el.style.top = `${rect.bottom + 4}px`;

  input.value = currentCaption;
  el.style.display = 'block';

  input.focus();
  input.select();
}

export function dismissImageCaptionPopup(): void {
  if (popup) {
    popup.style.display = 'none';
  }
  if (blurTimeout) {
    clearTimeout(blurTimeout);
    blurTimeout = null;
  }
  editingView = null;
  editingImageLineNumber = null;
  editingCaptionLineNumber = null;
}

export function isImageCaptionPopupOpen(): boolean {
  return popup !== null && popup.style.display !== 'none';
}
