/**
 * Image preview plugin for CodeMirror 6
 *
 * Renders inline image previews below ![alt](media/...) lines.
 * Uses Decoration.widget with block: true to insert preview widgets
 * below image markdown lines. Images are served via projectmedia:// scheme.
 *
 * Supports:
 * - Caption display from preceding <!-- caption: text --> comments
 * - Caption comment hiding via Decoration.replace()
 * - Click-to-edit captions via popup
 * - "Add caption" placeholder on hover for captionless images
 * - Images display at full width (max-width: 100%), matching Milkdown
 * - Centered images
 * - atomicRanges for cursor skip over hidden caption lines
 */

import { type EditorState, type Extension, RangeSetBuilder, StateEffect, StateField } from '@codemirror/state';
import { Decoration, type DecorationSet, EditorView, ViewPlugin, type ViewUpdate, WidgetType } from '@codemirror/view';
import { getEditorView } from './editor-state';
import {
  dismissImageCaptionPopup,
  isCommittingCaption,
  isImageCaptionPopupOpen,
  showImageCaptionPopup,
} from './image-caption-popup';

// --- Image metadata StateEffect/StateField ---

const setImageMetaEffect = StateEffect.define<Array<{ src: string; width?: number | null }>>();

const imageMetaField = StateField.define<Map<string, number>>({
  create: () => new Map(),
  update(value, tr) {
    for (const effect of tr.effects) {
      if (effect.is(setImageMetaEffect)) {
        const next = new Map<string, number>();
        for (const m of effect.value) {
          if (m.width) next.set(m.src, m.width);
        }
        return next;
      }
    }
    return value;
  },
});

/** Push image metadata (widths by src) into the editor state */
export function setImageMeta(meta: Array<{ src: string; width?: number | null }>): void {
  const view = getEditorView();
  if (!view) return;
  view.dispatch({ effects: setImageMetaEffect.of(meta) });
}

// --- Constants ---

/** Matches image markdown: ![alt](media/filename.ext) */
const IMAGE_REGEX = /!\[([^\]]*)\]\((media\/[^)]+)\)/;

/** Matches caption comment: <!-- caption: text --> */
const CAPTION_REGEX = /^<!--\s*caption:\s*(.+?)\s*-->$/;

// --- Widget ---

class ImagePreviewWidget extends WidgetType {
  private src: string;
  private alt: string;
  private caption: string;
  private width: number | null;
  readonly imageLineNumber: number;
  readonly captionLineNumber: number | null;

  constructor(
    src: string,
    alt: string,
    caption: string,
    imageLineNumber: number,
    captionLineNumber: number | null,
    width: number | null = null
  ) {
    super();
    this.src = src;
    this.alt = alt;
    this.caption = caption;
    this.width = width;
    this.imageLineNumber = imageLineNumber;
    this.captionLineNumber = captionLineNumber;
  }

  eq(other: ImagePreviewWidget): boolean {
    return (
      this.src === other.src &&
      this.alt === other.alt &&
      this.caption === other.caption &&
      this.width === other.width &&
      this.imageLineNumber === other.imageLineNumber &&
      this.captionLineNumber === other.captionLineNumber
    );
  }

  toDOM(): HTMLElement {
    const wrapper = document.createElement('div');
    wrapper.className = 'cm-image-preview';

    const img = document.createElement('img');
    // Rewrite media/ path to projectmedia:// scheme
    img.src = `projectmedia://${this.src.slice(6)}`;
    img.alt = this.alt;
    img.draggable = false;

    // Apply explicit width before onload (cached images may not fire onload)
    if (this.width) {
      img.style.width = `${this.width}px`;
      img.style.maxHeight = 'none';
    }

    // Notify CM6 to re-measure after image loads, apply orientation-aware sizing
    img.onload = () => {
      if (!this.width) {
        img.style.maxHeight = '';
      }

      const editorRoot = wrapper.closest('.cm-editor');
      if (editorRoot) {
        EditorView.findFromDOM(editorRoot as HTMLElement)?.requestMeasure();
      }
    };

    img.onerror = () => {
      wrapper.textContent = `[Image not found: ${this.src}]`;
      wrapper.className = 'cm-image-preview cm-image-preview-error';
      const editorRoot = wrapper.closest('.cm-editor');
      if (editorRoot) {
        EditorView.findFromDOM(editorRoot as HTMLElement)?.requestMeasure();
      }
    };

    wrapper.appendChild(img);

    // Always create caption element (for click-to-edit or add-caption)
    const captionEl = document.createElement('div');
    if (this.caption) {
      captionEl.className = 'cm-image-caption';
      captionEl.textContent = this.caption;
    } else {
      captionEl.className = 'cm-image-caption cm-image-add-caption';
      captionEl.textContent = 'Add caption\u2026';
    }
    // Store metadata as data attributes for the click handler
    captionEl.dataset.imageLineNumber = String(this.imageLineNumber);
    if (this.captionLineNumber !== null) {
      captionEl.dataset.captionLineNumber = String(this.captionLineNumber);
    }
    captionEl.dataset.caption = this.caption;
    wrapper.appendChild(captionEl);

    return wrapper;
  }

  ignoreEvent(): boolean {
    return false;
  }
}

// --- Decoration builder ---

function buildDecorations(state: EditorState): DecorationSet {
  const doc = state.doc;
  const metaStore = state.field(imageMetaField);
  const decorations: { from: number; to: number; deco: Decoration }[] = [];

  // Iterate line-by-line to check for caption comments on preceding lines
  for (let i = 1; i <= doc.lines; i++) {
    const line = doc.line(i);
    const imageMatch = IMAGE_REGEX.exec(line.text);
    if (!imageMatch) continue;

    const alt = imageMatch[1];
    const src = imageMatch[2];
    const width = metaStore.get(src) ?? null;

    // Check preceding lines for caption comment, skipping blank lines
    // Database-loaded images have a blank line between caption and image:
    //   <!-- caption: text -->
    //   (blank line)
    //   ![alt](media/file.jpg)
    // Popup-inserted captions have no blank line (degrades to i-1 check).
    let caption = '';
    let captionLineNumber: number | null = null;
    if (i > 1) {
      let checkLineNum = i - 1;
      const minLine = Math.max(1, i - 3);
      while (checkLineNum >= minLine && doc.line(checkLineNum).text.trim() === '') {
        checkLineNum--;
      }
      if (checkLineNum >= 1) {
        const captionLine = doc.line(checkLineNum);
        const captionMatch = CAPTION_REGEX.exec(captionLine.text.trim());
        if (captionMatch) {
          caption = captionMatch[1];
          captionLineNumber = checkLineNum;

          // Hide from caption line start through image line start
          // This covers the caption comment and any intervening blank lines
          decorations.push({
            from: captionLine.from,
            to: line.from,
            deco: Decoration.replace({}),
          });
        }
      }
    }

    // Widget decoration below the image line
    decorations.push({
      from: line.to,
      to: line.to,
      deco: Decoration.widget({
        widget: new ImagePreviewWidget(src, alt, caption, i, captionLineNumber, width),
        block: true,
        side: 1,
      }),
    });
  }

  // Sort by position, then by range length (replace before zero-width widget at same pos)
  decorations.sort((a, b) => a.from - b.from || a.to - a.from - (b.to - b.from));

  const builder = new RangeSetBuilder<Decoration>();
  for (const d of decorations) {
    builder.add(d.from, d.to, d.deco);
  }
  return builder.finish();
}

// --- StateField ---

const imageDecorationField = StateField.define<DecorationSet>({
  create(state) {
    return buildDecorations(state);
  },
  update(value, tr) {
    if (tr.docChanged || tr.effects.some((e) => e.is(setImageMetaEffect))) {
      return buildDecorations(tr.state);
    }
    return value;
  },
  provide: (f) => EditorView.decorations.from(f),
});

// --- Atomic ranges (cursor skips hidden caption lines) ---

const atomicImageRanges = EditorView.atomicRanges.of((view) => {
  return view.state.field(imageDecorationField);
});

// --- Click handler ViewPlugin + auto-dismiss ---

const imageCaptionClickPlugin = ViewPlugin.fromClass(
  class {
    update(update: ViewUpdate) {
      // Auto-dismiss popup when document changes externally
      if (update.docChanged && isImageCaptionPopupOpen()) {
        if (!isCommittingCaption) {
          dismissImageCaptionPopup();
        }
      }
    }
  },
  {
    eventHandlers: {
      click(event: MouseEvent, view: EditorView) {
        const target = event.target as HTMLElement;
        if (!target.classList.contains('cm-image-caption') && !target.classList.contains('cm-image-add-caption')) {
          return false;
        }
        event.preventDefault();
        event.stopPropagation();

        // Extract metadata from data attributes
        const imageLineNum = parseInt(target.dataset.imageLineNumber || '', 10);
        if (Number.isNaN(imageLineNum)) return false;

        const captionLineStr = target.dataset.captionLineNumber;
        const captionLineNum = captionLineStr ? parseInt(captionLineStr, 10) : null;
        const currentCaption = target.dataset.caption || '';

        const rect = target.getBoundingClientRect();
        showImageCaptionPopup(view, rect, currentCaption, imageLineNum, captionLineNum);
        return true;
      },
    },
  }
);

// --- Plugin export ---

export function imagePreviewPlugin(): Extension[] {
  return [imageMetaField, imageDecorationField, atomicImageRanges, imageCaptionClickPlugin];
}
