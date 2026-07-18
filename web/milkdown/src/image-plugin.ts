// Image Plugin for Milkdown
// Defines a figure node for block-level images with optional captions.
// Images are stored in the .ff package's media/ directory and served via projectmedia:// scheme.

import type { MilkdownPlugin } from '@milkdown/kit/ctx';
import type { Node as ProsemirrorNode } from '@milkdown/kit/prose/model';
import { NodeSelection, Plugin } from '@milkdown/kit/prose/state';
import type { EditorView, NodeView as ProsemirrorNodeView } from '@milkdown/kit/prose/view';
import { $node, $prose, $remark } from '@milkdown/kit/utils';
import type { Root } from 'mdast';
import { visit } from 'unist-util-visit';
import {
  escapeAltAttr,
  extractAltAttrValue,
  extractWidthAttrValue,
  isRecognizedAttrBlock,
  unescapeOnce,
} from '../../shared/image-caption-attrs';
import { getBlockIdAtPos } from './block-id-plugin';
import { isSourceModeEnabled } from './source-mode-plugin';
import { syncLog } from './sync-debug';

// ============================================================================
// Caption/alt attribute helpers
//
// Current format: `![caption](media/x.png){alt="..." width=N%}` — bracket
// text is the visible CAPTION, and the `alt="..."` attribute (emitted
// UNCONDITIONALLY, even empty — see toMarkdown below) carries the real
// accessibility alt text, separately. Its mere PRESENCE — not whether it's
// non-empty — self-marks a fragment as this current format; its absence
// self-marks a fragment as a pre-fix document, where bracket text is (as
// before) the alt, and any caption lives in a preceding
// `<!-- caption: ... -->` comment (see remarkFigurePlugin below).
//
// These helpers live in `../../shared/image-caption-attrs` so the CodeMirror
// source-mode editor (`codemirror/src/image-preview-plugin.ts`,
// `image-caption-popup.ts`, `api.ts`) reads/writes this exact same
// self-marking format and escaping scheme instead of a drifting duplicate.
// Re-exported here unchanged so existing imports of this module (and its
// tests) keep working.
// ============================================================================
export { escapeAltAttr, extractAltAttrValue, extractWidthAttrValue, isRecognizedAttrBlock, unescapeOnce };

// Remark plugin: convert standalone images with media/ URLs into figure nodes
// In mdast, a standalone ![alt](src) line produces paragraph > image.
// We detect paragraphs containing exactly one image child with media/ prefix
// and replace them with a custom 'figure' node.
const remarkFigurePlugin = $remark('figure', () => () => (tree: Root) => {
  // Legacy-only: <!-- caption: text --> comments before images. Still
  // recovered for documents saved before this fix (migration path); the new
  // alt="..." self-marking signal below always takes precedence when present.
  const captionMap = new Map<number, string>();
  // Collect nodes to remove after visit completes (avoids splice-during-visit bug)
  const toRemove: { parent: any; index: number }[] = [];

  visit(tree, (node: any, index: number | undefined, parent: any) => {
    // Collect caption comments
    if (node.type === 'html' && typeof node.value === 'string') {
      const match = node.value.match(/^<!--\s*caption:\s*(.+?)\s*-->$/);
      if (match && index !== undefined) {
        captionMap.set(index, match[1]);
      }
    }

    // Transform paragraphs containing an image with media/ URL
    // With {alt="..." width=N%} appended, remark parses as
    // [image, text("{alt=\"...\" width=50%}")] = 2 children
    if (node.type === 'paragraph' && node.children?.length >= 1) {
      const child = node.children[0];
      if (child.type === 'image' && child.url?.startsWith('media/')) {
        // Guard: only allow extra children that are a recognized {alt=.../width=N%} block
        let attrsText = '';
        if (node.children.length > 1) {
          const extra = node.children.slice(1);
          const allAttrs = extra.every((c: any) => c.type === 'text' && isRecognizedAttrBlock(c.value ?? ''));
          if (!allAttrs) return; // Not a figure, skip
          attrsText = extra.map((c: any) => c.value ?? '').join('');
        }

        const width = extractWidthAttrValue(attrsText);
        const altAttrValue = extractAltAttrValue(attrsText);
        const isNewFormat = altAttrValue !== null;

        let alt: string;
        let caption: string;
        if (isNewFormat) {
          // Current format: bracket text is the caption, the attribute
          // carries the real accessibility alt text.
          caption = child.alt || '';
          alt = altAttrValue;
        } else {
          // Pre-fix format: bracket text is the alt; recover any caption
          // from a preceding <!-- caption: ... --> comment (migration path).
          alt = child.alt || '';
          caption = '';
          if (index !== undefined && index > 0 && captionMap.has(index - 1)) {
            caption = captionMap.get(index - 1) || '';
            // Mark caption comment for removal after visit
            if (parent?.children) {
              toRemove.push({ parent, index: index - 1 });
            }
          }
        }

        // Transform in place to custom figure node
        node.type = 'figure';
        node.data = { src: child.url, alt, caption, width };
        delete node.children;
      }
    }
  });

  // Remove caption comments in reverse order (preserves indices)
  for (let i = toRemove.length - 1; i >= 0; i--) {
    const { parent, index } = toRemove[i];
    parent.children.splice(index, 1);
  }
});

// Define the figure node
const figureNode = $node('figure', () => ({
  group: 'block',
  atom: true,
  selectable: true,
  draggable: true,

  attrs: {
    src: { default: '' },
    alt: { default: '' },
    caption: { default: '' },
    width: { default: null },
    blockId: { default: '' },
  },

  parseDOM: [
    {
      tag: 'figure[data-image]',
      getAttrs: (dom: HTMLElement) => ({
        src: dom.getAttribute('data-src') || '',
        alt: dom.querySelector('img')?.getAttribute('alt') || '',
        caption: dom.querySelector('figcaption')?.textContent || '',
        width: dom.getAttribute('data-width') ? Number(dom.getAttribute('data-width')) : null,
        blockId: dom.getAttribute('data-block-id') || '',
      }),
    },
  ],

  toDOM: (node: ProsemirrorNode) => {
    const attrs: Record<string, string> = {
      'data-image': 'true',
      'data-src': node.attrs.src || '',
      class: 'figure-node',
    };
    if (node.attrs.width) {
      attrs['data-width'] = String(node.attrs.width);
    }
    if (node.attrs.blockId) {
      attrs['data-block-id'] = node.attrs.blockId;
    }

    const children: any[] = [
      'img',
      {
        src: node.attrs.src || '',
        alt: node.attrs.alt || '',
        ...(node.attrs.width ? { width: String(node.attrs.width) } : {}),
      },
    ];

    const result: any[] = ['figure', attrs, children];
    if (node.attrs.caption) {
      result.push(['figcaption', {}, node.attrs.caption]);
    }
    return result;
  },

  parseMarkdown: {
    match: (node: any) => node.type === 'figure',
    runner: (state: any, node: any, type: any) => {
      state.addNode(type, {
        src: node.data?.src || '',
        alt: node.data?.alt || '',
        caption: node.data?.caption || '',
        width: node.data?.width ?? null,
      });
    },
  },

  toMarkdown: {
    match: (node: ProsemirrorNode) => node.type.name === 'figure',
    runner: (state: any, node: ProsemirrorNode) => {
      const caption = node.attrs.caption || '';
      const alt = node.attrs.alt || '';

      // Wrap image in paragraph to produce a flow-level mdast node.
      // Without this, `image` (phrasing content) at the root level
      // triggers remark-stringify's containerPhrasing for the ENTIRE
      // document, collapsing all \n\n block separators.
      state.openNode('paragraph');
      // Bracket text is the CAPTION (not alt) — mdast-util-to-markdown's own
      // image serializer already escapes whatever needs escaping (e.g. `]`)
      // for safe round-tripping, so no manual escaping is applied here.
      state.addNode('image', undefined, undefined, {
        url: node.attrs.src || '',
        alt: caption,
        title: null,
      });
      // Combined {alt="..." width=N%} attribute block. `alt=` is emitted
      // UNCONDITIONALLY (even when empty) — its mere PRESENCE (not whether
      // it's non-empty) is the self-marking signal that distinguishes this
      // format from a pre-fix document on the next read (see
      // remarkFigurePlugin above). Emitting it only when non-empty would
      // make a captioned image with an empty alt round-trip ambiguously
      // with a pre-fix bare-alt image — silently losing the typed caption.
      // MUST be inside paragraph, before closeNode() — placing it after
      // closeNode() would emit phrasing content at document root,
      // collapsing all block separators.
      const attrs = [`alt="${escapeAltAttr(alt)}"`];
      if (node.attrs.width) {
        attrs.push(`width=${node.attrs.width}%`);
      }
      state.addNode('text', undefined, undefined, {
        value: `{${attrs.join(' ')}}`,
      });
      state.closeNode();
    },
  },
}));

// NodeView for interactive figure rendering
class FigureNodeView implements ProsemirrorNodeView {
  dom: HTMLElement;
  private img: HTMLImageElement;
  private captionEl: HTMLElement | null = null;
  private resizeHandle: HTMLElement | null = null;
  private node: ProsemirrorNode;
  private view: EditorView;
  private getPos: () => number | undefined;
  private isResizing = false;
  private startX = 0;
  private startWidth = 0;
  private startContainerWidth = 0;
  private resizeTooltip: HTMLElement | null = null;

  constructor(node: ProsemirrorNode, view: EditorView, getPos: () => number | undefined) {
    this.node = node;
    this.view = view;
    this.getPos = getPos;

    // Check source mode
    if (isSourceModeEnabled()) {
      this.dom = document.createElement('div');
      this.dom.className = 'figure-source-mode';
      // Bracket text mirrors the persisted format: caption, not alt.
      const base = `![${node.attrs.caption || ''}](${node.attrs.src || ''})`;
      this.dom.textContent = node.attrs.width ? `${base}{width=${node.attrs.width}%}` : base;
      this.img = document.createElement('img'); // placeholder, not displayed
      return;
    }

    this.dom = document.createElement('figure');
    this.dom.className = 'figure-node';
    this.dom.contentEditable = 'false';

    // Image
    this.img = document.createElement('img');
    const displaySrc = this.rewriteUrl(node.attrs.src || '');
    this.img.src = displaySrc;
    this.img.alt = node.attrs.alt || '';
    if (node.attrs.width) {
      this.img.style.width = `${node.attrs.width}%`;
    } else {
      this.img.style.maxWidth = '100%';
    }
    this.img.draggable = false;
    this.dom.appendChild(this.img);

    // Resize handle
    this.resizeHandle = document.createElement('div');
    this.resizeHandle.className = 'figure-resize-handle';
    this.resizeHandle.addEventListener('mousedown', this.onResizeStart);
    this.dom.appendChild(this.resizeHandle);

    // Caption (editable)
    this.captionEl = document.createElement('figcaption');
    this.captionEl.className = 'figure-caption';
    this.captionEl.contentEditable = 'true';
    this.captionEl.textContent = node.attrs.caption || '';
    this.captionEl.setAttribute('placeholder', 'Add caption...');
    this.captionEl.addEventListener('blur', this.onCaptionBlur);
    this.captionEl.addEventListener('keydown', this.onCaptionKeydown);
    // Prevent ProseMirror from capturing events inside caption
    this.captionEl.addEventListener('mousedown', (e) => e.stopPropagation());
    this.dom.appendChild(this.captionEl);

    // Selection styling
    this.dom.addEventListener('click', (e) => {
      e.preventDefault();
      const pos = this.getPos();
      if (pos !== undefined) {
        const tr = this.view.state.tr.setSelection(NodeSelection.create(this.view.state.doc, pos));
        this.view.dispatch(tr);
      }
    });

    // Alt text edit on double-click
    this.img.addEventListener('dblclick', (e) => {
      e.stopPropagation();
      this.showAltTextPopup();
    });
  }

  /** Resolve the block ID for this figure node.
   * The node attr may be empty ('') when first inserted — BlockSyncService
   * assigns the real ID asynchronously.  Fall back to the block-id-plugin
   * position map which always has the confirmed ID after the first poll. */
  private resolveBlockId(): string {
    const id = this.node.attrs.blockId;
    if (id) return id;
    const pos = this.getPos();
    if (pos !== undefined) {
      return getBlockIdAtPos(pos) || '';
    }
    return '';
  }

  private rewriteUrl(src: string): string {
    // media/file.png → projectmedia://file.png
    if (src.startsWith('media/')) {
      return `projectmedia://${src.slice(6)}`;
    }
    return src;
  }

  private onResizeStart = (e: MouseEvent) => {
    e.preventDefault();
    e.stopPropagation();
    this.isResizing = true;
    this.startX = e.clientX;
    this.startWidth = this.img.offsetWidth;
    this.startContainerWidth = this.dom.parentElement?.clientWidth || this.dom.offsetWidth;

    // Create percentage tooltip
    if (!this.resizeTooltip) {
      this.resizeTooltip = document.createElement('div');
      this.resizeTooltip.className = 'figure-resize-tooltip';
      this.dom.appendChild(this.resizeTooltip);
    }
    this.resizeTooltip.style.display = 'block';

    document.addEventListener('mousemove', this.onResizeMove);
    document.addEventListener('mouseup', this.onResizeEnd);
    this.dom.classList.add('resizing');
  };

  private onResizeMove = (e: MouseEvent) => {
    if (!this.isResizing) return;
    const diff = e.clientX - this.startX;
    const newWidth = Math.max(50, this.startWidth + diff);
    const pct = Math.max(5, Math.round((newWidth / this.startContainerWidth) * 100));
    this.img.style.width = `${pct}%`;

    // Show percentage tooltip
    if (this.resizeTooltip) {
      this.resizeTooltip.textContent = `${pct}%`;
    }
  };

  private onResizeEnd = (_e: MouseEvent) => {
    if (!this.isResizing) return;
    this.isResizing = false;
    document.removeEventListener('mousemove', this.onResizeMove);
    document.removeEventListener('mouseup', this.onResizeEnd);
    this.dom.classList.remove('resizing');

    // Hide tooltip
    if (this.resizeTooltip) {
      this.resizeTooltip.style.display = 'none';
    }

    // Read the percentage already applied during drag
    const newPercent = Math.max(5, Math.round((this.img.offsetWidth / this.startContainerWidth) * 100));

    const blockId = this.resolveBlockId();

    // Update ProseMirror node attrs with percentage
    const pos = this.getPos();
    if (pos !== undefined) {
      const tr = this.view.state.tr.setNodeMarkup(pos, undefined, {
        ...this.node.attrs,
        width: newPercent,
      });
      this.view.dispatch(tr);
    }

    // Send percentage to Swift — retry if temp ID
    if (blockId && !blockId.startsWith('temp-')) {
      window.webkit?.messageHandlers?.updateImageMeta?.postMessage({
        blockId,
        width: newPercent,
      });
    } else {
      const retryWidth = newPercent;
      setTimeout(() => {
        const currentPos = this.getPos();
        if (currentPos === undefined) return;
        const retryId = getBlockIdAtPos(currentPos);
        if (retryId && !retryId.startsWith('temp-')) {
          window.webkit?.messageHandlers?.updateImageMeta?.postMessage({
            blockId: retryId,
            width: retryWidth,
          });
        }
      }, 3000);
    }
  };

  private onCaptionBlur = () => {
    const newCaption = this.captionEl?.textContent || '';
    if (newCaption === this.node.attrs.caption) return;

    const blockId = this.resolveBlockId();
    const pos = this.getPos();

    // Update ProseMirror node attrs
    if (pos !== undefined) {
      const tr = this.view.state.tr.setNodeMarkup(pos, undefined, {
        ...this.node.attrs,
        caption: newCaption,
      });
      this.view.dispatch(tr);
    }

    // Send to Swift — retry if temp ID
    if (blockId && !blockId.startsWith('temp-')) {
      window.webkit?.messageHandlers?.updateImageMeta?.postMessage({
        blockId,
        caption: newCaption,
      });
    } else {
      const retryCaption = newCaption;
      setTimeout(() => {
        const currentPos = this.getPos();
        if (currentPos === undefined) return;
        const retryId = getBlockIdAtPos(currentPos);
        if (retryId && !retryId.startsWith('temp-')) {
          window.webkit?.messageHandlers?.updateImageMeta?.postMessage({
            blockId: retryId,
            caption: retryCaption,
          });
        }
      }, 3000);
    }
  };

  private onCaptionKeydown = (e: KeyboardEvent) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      this.captionEl?.blur();
    }
    // Prevent ProseMirror from handling these keys
    e.stopPropagation();
  };

  private showAltTextPopup() {
    const currentAlt = this.node.attrs.alt || '';
    const newAlt = prompt('Alt text (accessibility description):', currentAlt);
    if (newAlt === null) return; // cancelled

    const pos = this.getPos();
    if (pos !== undefined) {
      const tr = this.view.state.tr.setNodeMarkup(pos, undefined, {
        ...this.node.attrs,
        alt: newAlt,
      });
      this.view.dispatch(tr);
    }

    // Update img element
    this.img.alt = newAlt;

    // Send to Swift — retry if temp ID
    const blockId = this.resolveBlockId();
    if (blockId && !blockId.startsWith('temp-')) {
      window.webkit?.messageHandlers?.updateImageMeta?.postMessage({
        blockId,
        alt: newAlt,
      });
    } else {
      const retryAlt = newAlt;
      setTimeout(() => {
        const currentPos = this.getPos();
        if (currentPos === undefined) return;
        const retryId = getBlockIdAtPos(currentPos);
        if (retryId && !retryId.startsWith('temp-')) {
          window.webkit?.messageHandlers?.updateImageMeta?.postMessage({
            blockId: retryId,
            alt: retryAlt,
          });
        }
      }, 3000);
    }
  }

  update(node: ProsemirrorNode): boolean {
    if (node.type.name !== 'figure') return false;
    this.node = node;

    // Source mode check
    if (isSourceModeEnabled()) {
      // Bracket text mirrors the persisted format: caption, not alt.
      const base = `![${node.attrs.caption || ''}](${node.attrs.src || ''})`;
      this.dom.textContent = node.attrs.width ? `${base}{width=${node.attrs.width}%}` : base;
      return true;
    }

    // Update image
    const displaySrc = this.rewriteUrl(node.attrs.src || '');
    if (this.img.src !== displaySrc) {
      this.img.src = displaySrc;
    }
    this.img.alt = node.attrs.alt || '';
    if (node.attrs.width) {
      this.img.style.width = `${node.attrs.width}%`;
    } else {
      this.img.style.maxWidth = '100%';
      this.img.style.width = '';
    }

    // Update caption
    if (this.captionEl && this.captionEl.textContent !== (node.attrs.caption || '')) {
      this.captionEl.textContent = node.attrs.caption || '';
    }

    return true;
  }

  stopEvent(event: Event): boolean {
    // Allow events inside caption to be handled by the caption itself
    if (this.captionEl?.contains(event.target as HTMLElement)) {
      return true;
    }
    // Allow resize handle events
    if (this.resizeHandle?.contains(event.target as HTMLElement)) {
      return true;
    }
    return false;
  }

  ignoreMutation(): boolean {
    return true;
  }

  destroy() {
    this.resizeHandle?.removeEventListener('mousedown', this.onResizeStart);
    document.removeEventListener('mousemove', this.onResizeMove);
    document.removeEventListener('mouseup', this.onResizeEnd);
    if (this.captionEl) {
      this.captionEl.removeEventListener('blur', this.onCaptionBlur);
      this.captionEl.removeEventListener('keydown', this.onCaptionKeydown);
    }
  }
}

// NodeView plugin — registers FigureNodeView via ProseMirror plugin nodeViews option
const figureNodeViewPlugin = $prose(() => {
  return new Plugin({
    props: {
      nodeViews: {
        figure: (node: ProsemirrorNode, view: EditorView, getPos: () => number | undefined) => {
          return new FigureNodeView(node, view, getPos);
        },
      },
    },
  });
});

// How long a captured paste/drop position survives before self-clearing as
// "abandoned" (covers imports that fail before ever calling insertImage()).
// See the two setTimeout call sites below for why this isn't a few seconds:
// Swift's ImageImportService shows a blocking NSAlert for large images, which
// can easily outlast a short timeout while never actually abandoning the paste.
const PENDING_POS_TIMEOUT_MS = 120_000;

// Module-level: pending drop position for async image insertion
let pendingDropPos: number | null = null;

// Module-level: pending paste position for async image insertion (mirrors
// pendingDropPos above). One-shot consume via consumePendingPastePos().
let pendingPastePos: number | null = null;

// Guard against macOS kDragIPCCompleted firing twice for a single drop.
// The two events arrive within ~5ms; 200ms window safely catches them
// without blocking legitimate successive drops by the user.
let lastDropTime = 0;
export function consumePendingDropPos(): number | null {
  const pos = pendingDropPos;
  pendingDropPos = null;
  return pos;
}

export function consumePendingPastePos(): number | null {
  const pos = pendingPastePos;
  pendingPastePos = null;
  return pos;
}

// Paste/drop interception plugin
// Intercepts paste/drop containing image data, sends to Swift via pasteImage message
const imagePasteDropPlugin = $prose(() => {
  return new Plugin({
    props: {
      handlePaste(view: EditorView, event: ClipboardEvent): boolean {
        const items = event.clipboardData?.items;
        if (!items) return false;

        for (const item of items) {
          if (item.type.startsWith('image/')) {
            event.preventDefault();
            const file = item.getAsFile();
            if (!file) return true;

            // Capture paste position before the async FileReader/Swift round-trip.
            const capturedPastePos = view.state.selection.$from.pos;
            pendingPastePos = capturedPastePos;
            // Mutual clearing: a paste supersedes any stale pending drop position,
            // preventing an orphaned drop from later hijacking this paste.
            pendingDropPos = null;
            syncLog('ImagePaste', `captured pastePos=${pendingPastePos}`);
            // Clear stale paste position after PENDING_POS_TIMEOUT_MS (covers
            // failed imports where insertImage() never gets called at all).
            // Guarded by identity: only clear if pendingPastePos still holds THIS
            // capture — a second, still-legitimate paste within the window must
            // not have its own pending position wiped out by this timer.
            //
            // Was 10s until this was found to race against the REAL Swift-side
            // round trip: ImageImportService.importFromData() shows a blocking
            // NSAlert (`alert.runModal()`) for any image over warnSizeBytes
            // (10MB) — a real screenshot/photo paste routinely exceeds that.
            // runModal() blocks Swift's main thread but NOT this WebContent
            // process's JS timers, so a user taking more than 10s to notice/
            // dismiss that dialog let this timeout fire BEFORE insertImage()
            // ever ran — silently discarding the captured caret position and
            // making insertImage() fall back to the pre-fix, non-cursor-aware
            // "after the current top-level block" placement (see api-content.ts
            // insertImage()'s final `else` branch). 2 minutes comfortably covers
            // a user reading/dismissing that dialog, or any other slow disk/
            // decode step, while the mutual-clearing above still guarantees a
            // genuinely NEW paste or drop immediately supersedes a stale one.
            setTimeout(() => {
              if (pendingPastePos === capturedPastePos) {
                if (pendingPastePos !== null) {
                  syncLog('ImagePaste', `timeout clearing stale pendingPastePos=${pendingPastePos}`);
                }
                pendingPastePos = null;
              }
            }, PENDING_POS_TIMEOUT_MS);

            const reader = new FileReader();
            reader.onload = () => {
              const base64 = (reader.result as string).split(',')[1];
              window.webkit?.messageHandlers?.pasteImage?.postMessage({
                data: base64,
                type: file.type,
                name: file.name || null,
              });
            };
            reader.readAsDataURL(file);
            return true;
          }
        }
        return false;
      },

      handleDrop(view: EditorView, event: DragEvent): boolean {
        const files = event.dataTransfer?.files;
        const imageFile = files ? Array.from(files).find((f) => f.type.startsWith('image/')) : undefined;

        // Fix X: any drag whose gesture began inside this editor (a figure
        // move, a text-range drag) sets view.dragging in ProseMirror's own
        // dragstart handler (prosemirror-view/src/input.ts), cleared once the
        // matching drop finishes. Bail out and let PM's own native drop
        // handling (dropPoint()-based — already schema-correct) process it
        // end-to-end, regardless of what event.dataTransfer.files also
        // contains. Safe unconditionally: can only route MORE drags to PM's
        // already-correct native path, never fewer; zero effect on genuine
        // external file drops (view.dragging is guaranteed null there).
        if (view.dragging) return false;

        if (!files || files.length === 0) return false;
        if (!imageFile) return false;

        const now = Date.now();
        // Diagnostic only (no behavior change): log the gap since the last
        // drop on every drop, not just the ones the 200ms guard below
        // rejects. Needed to capture timing data if a legitimate-looking
        // second `drop` DOM event ever arrives just outside the window.
        syncLog('ImageDrop', `drop event, ${now - lastDropTime}ms since last drop`);
        if (now - lastDropTime < 200) {
          syncLog('ImageDrop', `DEDUP: ignoring duplicate drop (${now - lastDropTime}ms)`);
          event.preventDefault();
          return true;
        }
        lastDropTime = now;

        event.preventDefault();
        event.stopPropagation();

        // Capture drop position before async processing. Unlike the old
        // pre-escalation logic (depth 0 -> discarded for docSizeAtDrop), the raw,
        // clamped coords.pos is captured as-is — a depth-0 position (the gap
        // between two top-level blocks) is already a valid insertion point.
        // insertImage() (api-content.ts) routes this through
        // computeCursorAwareInsertPos() before actually inserting, exactly like
        // pastePos, so escalation for deeper/ambiguous positions happens there.
        const coords = view.posAtCoords({ left: event.clientX, top: event.clientY });
        const docSizeAtDrop = view.state.doc.content.size;
        pendingDropPos = coords ? Math.max(0, Math.min(coords.pos, docSizeAtDrop)) : docSizeAtDrop;
        // Mutual clearing: a drop supersedes any stale pending paste position,
        // preventing an orphaned paste from later hijacking this drop.
        pendingPastePos = null;
        syncLog('ImageDrop', `captured dropPos=${pendingDropPos} docSize=${docSizeAtDrop}`);
        // Clear stale drop position after PENDING_POS_TIMEOUT_MS (covers failed
        // imports). Guarded by identity: only clear if pendingDropPos still
        // holds THIS capture — a second, still-legitimate drop within the
        // window must not have its own pending position wiped out by this
        // timer. See the matching comment in handlePaste above for why this is
        // no longer 10s — the same blocking "Large Image" NSAlert on the Swift
        // side applies equally to drop-originated imports.
        const capturedDropPos = pendingDropPos;
        setTimeout(() => {
          if (pendingDropPos === capturedDropPos) {
            if (pendingDropPos !== null) {
              syncLog('ImageDrop', `timeout clearing stale pendingDropPos=${pendingDropPos}`);
            }
            pendingDropPos = null;
          }
        }, PENDING_POS_TIMEOUT_MS);

        const dropCaptureTime = Date.now();
        const reader = new FileReader();
        reader.onload = () => {
          syncLog('ImageDrop', `FileReader complete in ${Date.now() - dropCaptureTime}ms`);
          const base64 = (reader.result as string).split(',')[1];
          window.webkit?.messageHandlers?.pasteImage?.postMessage({
            data: base64,
            type: imageFile.type,
            name: imageFile.name || null,
          });
        };
        reader.readAsDataURL(imageFile);
        return true;
      },
    },
  });
});

// Export the plugin array
export const imagePlugin: MilkdownPlugin[] = [
  remarkFigurePlugin,
  figureNode,
  figureNodeViewPlugin,
  imagePasteDropPlugin,
].flat();

// Export the node for use in block sync
export { figureNode };
