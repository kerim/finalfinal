/**
 * Image Caption Edit Popup for CodeMirror 6
 *
 * Singleton popup for editing image captions in source mode.
 * Pattern modeled on Milkdown's annotation-edit-popup.ts.
 *
 * Current format: bracket text is the caption, e.g.
 * `![caption](media/x.png){alt="..." width=N%}` — committing an edit always
 * (re-)writes this format, migrating a legacy `<!-- caption: text -->`
 * fragment (bracket text = alt) to the new format on first edit, exactly
 * mirroring the Milkdown editor's migrate-on-save behavior. See
 * `../../shared/image-caption-attrs` for the shared self-marking format.
 */

import type { EditorView } from '@codemirror/view';
import { escapeAltAttr } from '../../shared/image-caption-attrs';
import { positionPopup } from '../../shared/position-popup';
import { parseImageLine } from './image-line-parser';

// --- Constants ---

const CAPTION_REGEX = /^<!--\s*caption:\s*(.+?)\s*-->$/;

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
  const parsed = parseImageLine(imageLine.text);
  if (!parsed) {
    dismissImageCaptionPopup();
    return;
  }

  const isNewFormat = parsed.altAttrValue !== null;
  const hasExistingCaption = isNewFormat ? parsed.bracketText !== '' : editingCaptionLineNumber !== null;

  // True no-op: nothing existing and nothing typed — avoid rewriting/
  // migrating the fragment just from opening and dismissing the
  // "Add caption..." popup without typing anything.
  if (!hasExistingCaption && !newText) {
    dismissImageCaptionPopup();
    view.focus();
    return;
  }

  // Legacy format: verify the caption comment line still matches before
  // touching anything (mirrors the pre-fix safety check above).
  let legacyCaptionLine: { from: number; to: number } | null = null;
  if (!isNewFormat && editingCaptionLineNumber !== null) {
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
    legacyCaptionLine = captionLine;
  }

  isCommittingCaption = true;

  try {
    // Rewrite the image line's bracket text in place as the caption.
    // Accessibility alt text and width are always preserved unchanged —
    // only the caption (bracket text) changes here. A legacy fragment
    // (bracket text = alt) migrates to the new format on this first edit,
    // exactly mirroring the Milkdown editor's migrate-on-save behavior.
    const currentAlt = parsed.altAttrValue !== null ? parsed.altAttrValue : parsed.bracketText;
    const widthPart = parsed.width ? ` width=${parsed.width}%` : '';
    const newFragment = `![${newText}](${parsed.src}){alt="${escapeAltAttr(currentAlt)}"${widthPart}}`;

    const matchStart = imageLine.from + parsed.matchIndex;
    const matchEnd = matchStart + parsed.matchLength;
    const changes: { from: number; to: number; insert: string }[] = [
      { from: matchStart, to: matchEnd, insert: newFragment },
    ];

    if (legacyCaptionLine) {
      // Remove the old <!-- caption: ... --> comment (+ trailing newline
      // if present) now that its caption has migrated onto the image line.
      const deleteTo = legacyCaptionLine.to + 1 <= doc.length ? legacyCaptionLine.to + 1 : legacyCaptionLine.to;
      changes.push({ from: legacyCaptionLine.from, to: deleteTo, insert: '' });
    }

    changes.sort((a, b) => a.from - b.from);
    view.dispatch({ changes });
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

  input.value = currentCaption;
  el.style.display = 'block';

  // Position below the clicked caption element
  positionPopup(el, rect);

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
