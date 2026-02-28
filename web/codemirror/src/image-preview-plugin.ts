/**
 * Image preview plugin for CodeMirror 6
 *
 * Renders inline image previews below ![alt](media/...) lines.
 * Uses Decoration.widget with block: true to insert preview widgets
 * below image markdown lines. Images are served via projectmedia:// scheme.
 */

import { type EditorState, RangeSetBuilder, StateField } from '@codemirror/state';
import { Decoration, type DecorationSet, EditorView, WidgetType } from '@codemirror/view';

// --- Constants ---

/** Matches image markdown: ![alt](media/filename.ext) */
const IMAGE_REGEX = /!\[([^\]]*)\]\((media\/[^)]+)\)/g;

// --- Widget ---

class ImagePreviewWidget extends WidgetType {
  private src: string;
  private alt: string;

  constructor(src: string, alt: string) {
    super();
    this.src = src;
    this.alt = alt;
  }

  eq(other: ImagePreviewWidget): boolean {
    return this.src === other.src && this.alt === other.alt;
  }

  toDOM(): HTMLElement {
    const wrapper = document.createElement('div');
    wrapper.className = 'cm-image-preview';

    const img = document.createElement('img');
    // Rewrite media/ path to projectmedia:// scheme
    img.src = `projectmedia://${this.src.slice(6)}`;
    img.alt = this.alt;
    img.style.maxWidth = '100%';
    img.style.maxHeight = '300px';
    img.style.display = 'block';
    img.style.margin = '4px 0 8px 0';
    img.style.borderRadius = '4px';
    img.draggable = false;

    // Notify CM6 to re-measure after image loads (fixes blank display)
    img.onload = () => {
      const editorRoot = wrapper.closest('.cm-editor');
      if (editorRoot) {
        EditorView.findFromDOM(editorRoot as HTMLElement)?.requestMeasure();
      }
    };

    img.onerror = () => {
      wrapper.textContent = `[Image not found: ${this.src}]`;
      wrapper.style.color = 'var(--text-secondary, #888)';
      wrapper.style.fontStyle = 'italic';
      wrapper.style.padding = '4px 0';
      const editorRoot = wrapper.closest('.cm-editor');
      if (editorRoot) {
        EditorView.findFromDOM(editorRoot as HTMLElement)?.requestMeasure();
      }
    };

    wrapper.appendChild(img);
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
  const text = doc.toString();
  const widgets: { pos: number; widget: ImagePreviewWidget }[] = [];

  IMAGE_REGEX.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = IMAGE_REGEX.exec(text)) !== null) {
    const alt = match[1];
    const src = match[2];

    // Find the end of the line containing this image
    const line = doc.lineAt(match.index);
    widgets.push({
      pos: line.to,
      widget: new ImagePreviewWidget(src, alt),
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
