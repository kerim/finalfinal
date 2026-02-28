/**
 * Image preview plugin for CodeMirror 6
 *
 * Renders inline image previews below ![alt](media/...) lines.
 * Uses Decoration.widget with block: true to insert preview widgets
 * below image markdown lines. Images are served via projectmedia:// scheme.
 *
 * Supports:
 * - Caption display from preceding <!-- caption: text --> comments
 * - Orientation-aware sizing (landscape uncapped, portrait max 400px)
 * - Centered images
 */

import { type EditorState, RangeSetBuilder, StateField } from '@codemirror/state';
import { Decoration, type DecorationSet, EditorView, WidgetType } from '@codemirror/view';

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

  constructor(src: string, alt: string, caption: string) {
    super();
    this.src = src;
    this.alt = alt;
    this.caption = caption;
  }

  eq(other: ImagePreviewWidget): boolean {
    return this.src === other.src && this.alt === other.alt && this.caption === other.caption;
  }

  toDOM(): HTMLElement {
    const wrapper = document.createElement('div');
    wrapper.className = 'cm-image-preview';

    const img = document.createElement('img');
    // Rewrite media/ path to projectmedia:// scheme
    img.src = `projectmedia://${this.src.slice(6)}`;
    img.alt = this.alt;
    img.draggable = false;

    // Notify CM6 to re-measure after image loads, apply orientation-aware sizing
    img.onload = () => {
      // Orientation-aware sizing
      if (img.naturalWidth >= img.naturalHeight) {
        // Landscape: remove height cap, show at natural aspect ratio
        img.style.maxHeight = '';
      } else {
        // Portrait: cap at 400px
        img.style.maxHeight = '400px';
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

    // Add caption if present
    if (this.caption) {
      const captionEl = document.createElement('div');
      captionEl.className = 'cm-image-caption';
      captionEl.textContent = this.caption;
      wrapper.appendChild(captionEl);
    }

    return wrapper;
  }

  ignoreEvent(): boolean {
    return false;
  }
}

// --- Decoration builder ---

function buildDecorations(state: EditorState): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const doc = state.doc;
  const widgets: { pos: number; widget: ImagePreviewWidget }[] = [];

  // Iterate line-by-line to check for caption comments on preceding lines
  for (let i = 1; i <= doc.lines; i++) {
    const line = doc.line(i);
    const imageMatch = IMAGE_REGEX.exec(line.text);
    if (!imageMatch) continue;

    const alt = imageMatch[1];
    const src = imageMatch[2];

    // Check preceding line for caption comment
    let caption = '';
    if (i > 1) {
      const prevLine = doc.line(i - 1);
      const captionMatch = CAPTION_REGEX.exec(prevLine.text.trim());
      if (captionMatch) {
        caption = captionMatch[1];
      }
    }

    widgets.push({
      pos: line.to,
      widget: new ImagePreviewWidget(src, alt, caption),
    });
  }

  // Sort by position (required by RangeSetBuilder)
  widgets.sort((a, b) => a.pos - b.pos);

  for (const w of widgets) {
    builder.add(
      w.pos,
      w.pos,
      Decoration.widget({
        widget: w.widget,
        block: true,
        side: 1, // After the line
      })
    );
  }

  return builder.finish();
}

// --- Plugin ---

export function imagePreviewPlugin() {
  return StateField.define<DecorationSet>({
    create(state) {
      return buildDecorations(state);
    },
    update(value, tr) {
      if (tr.docChanged) {
        return buildDecorations(tr.state);
      }
      return value;
    },
    provide: (f) => EditorView.decorations.from(f),
  });
}
