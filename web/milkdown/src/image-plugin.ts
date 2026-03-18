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
import { getBlockIdAtPos } from './block-id-plugin';
import { isSourceModeEnabled } from './source-mode-plugin';
import { syncLog } from './sync-debug';

// Remark plugin: convert standalone images with media/ URLs into figure nodes
// In mdast, a standalone ![alt](src) line produces paragraph > image.
// We detect paragraphs containing exactly one image child with media/ prefix
// and replace them with a custom 'figure' node.
const remarkFigurePlugin = $remark('figure', () => () => (tree: Root) => {
  // Also handle <!-- caption: text --> comments before images
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
    // With {width=N%} appended, remark parses as [image, text("{width=50%}")] = 2 children
    if (node.type === 'paragraph' && node.children?.length >= 1) {
      const child = node.children[0];
      if (child.type === 'image' && child.url?.startsWith('media/')) {
        // Guard: only allow extra children that are {width=N%} attribute text
        if (node.children.length > 1) {
          const extra = node.children.slice(1);
          const allAttrs = extra.every(
            (c: any) => c.type === 'text' && /^\s*\{[^}]*width=\d+%[^}]*\}\s*$/.test(c.value?.trim() ?? '')
          );
          if (!allAttrs) return; // Not a figure, skip
        }

        // Parse width from trailing attribute text node
        let width: number | null = null;
        if (node.children.length > 1) {
          const lastChild = node.children[node.children.length - 1];
          if (lastChild.type === 'text') {
            const m = lastChild.value?.match(/\{[^}]*width=(\d+)%[^}]*\}/);
            if (m) width = parseInt(m[1], 10);
          }
        }

        // Check for preceding caption comment
        let caption = '';
        if (index !== undefined && index > 0 && captionMap.has(index - 1)) {
          caption = captionMap.get(index - 1) || '';
          // Mark caption comment for removal after visit
          if (parent?.children) {
            toRemove.push({ parent, index: index - 1 });
          }
        }

        // Transform in place to custom figure node
        node.type = 'figure';
        node.data = {
          src: child.url,
          alt: child.alt || '',
          caption,
          width,
        };
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
      // Emit caption comment before the image if present
      const caption = node.attrs.caption || '';
      if (caption) {
        state.addNode('html', undefined, undefined, {
          value: `<!-- caption: ${caption} -->`,
        });
      }

      // Wrap image in paragraph to produce a flow-level mdast node.
      // Without this, `image` (phrasing content) at the root level
      // triggers remark-stringify's containerPhrasing for the ENTIRE
      // document, collapsing all \n\n block separators.
      state.openNode('paragraph');
      state.addNode('image', undefined, undefined, {
        url: node.attrs.src || '',
        alt: node.attrs.alt || '',
        title: null,
      });
      if (node.attrs.width) {
        // MUST be inside paragraph, before closeNode() — placing it after closeNode()
        // would emit phrasing content at document root, collapsing all block separators
        state.addNode('text', undefined, undefined, {
          value: `{width=${node.attrs.width}%}`,
        });
      }
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
      const base = `![${node.attrs.alt || ''}](${node.attrs.src || ''})`;
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
      const base = `![${node.attrs.alt || ''}](${node.attrs.src || ''})`;
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

// Module-level: pending drop position for async image insertion
let pendingDropPos: number | null = null;

// Guard against macOS kDragIPCCompleted firing twice for a single drop.
// The two events arrive within ~5ms; 200ms window safely catches them
// without blocking legitimate successive drops by the user.
let lastDropTime = 0;
export function consumePendingDropPos(): number | null {
  const pos = pendingDropPos;
  pendingDropPos = null;
  return pos;
}

// Paste/drop interception plugin
// Intercepts paste/drop containing image data, sends to Swift via pasteImage message
const imagePasteDropPlugin = $prose(() => {
  return new Plugin({
    props: {
      handlePaste(_view: EditorView, event: ClipboardEvent): boolean {
        const items = event.clipboardData?.items;
        if (!items) return false;

        for (const item of items) {
          if (item.type.startsWith('image/')) {
            event.preventDefault();
            const file = item.getAsFile();
            if (!file) return true;

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
        if (!files || files.length === 0) return false;

        const imageFile = Array.from(files).find((f) => f.type.startsWith('image/'));
        if (!imageFile) return false;

        const now = Date.now();
        if (now - lastDropTime < 200) {
          syncLog('ImageDrop', `DEDUP: ignoring duplicate drop (${now - lastDropTime}ms)`);
          event.preventDefault();
          return true;
        }
        lastDropTime = now;

        event.preventDefault();
        event.stopPropagation();

        // Capture drop position before async processing
        const coords = view.posAtCoords({ left: event.clientX, top: event.clientY });
        const docSizeAtDrop = view.state.doc.content.size;
        if (coords) {
          try {
            const $pos = view.state.doc.resolve(coords.pos);
            // $pos.after(1) requires depth >= 1; at doc boundary depth may be 0
            pendingDropPos = $pos.depth >= 1 ? $pos.after(1) : docSizeAtDrop;
          } catch {
            pendingDropPos = docSizeAtDrop;
          }
        }
        syncLog('ImageDrop', `captured dropPos=${pendingDropPos} docSize=${docSizeAtDrop}`);
        // Clear stale drop position after 10 seconds (covers failed imports)
        setTimeout(() => {
          if (pendingDropPos !== null) {
            syncLog('ImageDrop', `10s timeout clearing pendingDropPos=${pendingDropPos}`);
          }
          pendingDropPos = null;
        }, 10000);

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
