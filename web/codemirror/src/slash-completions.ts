// Custom slash menu plugin for CodeMirror — matches Milkdown's visual appearance
// Uses shared slash-menu.css classes for consistent styling between editors

import { type EditorView, ViewPlugin, type ViewUpdate } from '@codemirror/view';
import '../../shared/slash-menu.css';
import { insertFootnoteReplacingRange } from './api';
import { setPendingCAYWRange, setPendingSlashUndo } from './editor-state';

/** Route diagnostic messages through the WKWebView errorHandler bridge.
 *  JS console.log/error are NOT bridged to Xcode — this is the only visible channel. */
function slashLog(...args: unknown[]) {
  const msg = args
    .map((a) => {
      if (a instanceof Error) return `${a.message}\n${a.stack}`;
      if (typeof a === 'string') return a;
      return JSON.stringify(a);
    })
    .join(' ');
  (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
    type: 'slash-diag',
    message: msg,
  });
}

// === Slash command definitions (same order as Milkdown) ===
interface SlashCommand {
  label: string;
  description: string;
  apply: (view: EditorView, from: number, to: number) => void;
}

/** Helper: replace the /command text with a heading transformation */
function applyHeading(view: EditorView, from: number, to: number, level: number) {
  const line = view.state.doc.lineAt(from);
  const slashPosInLine = from - line.from;
  const matchedLength = to - from;
  const textBeforeSlash = line.text.slice(0, slashPosInLine);
  const textAfterCommand = line.text.slice(slashPosInLine + matchedLength);
  const cleanBefore = textBeforeSlash.replace(/^#+\s*/, '');
  const combinedText = (cleanBefore + textAfterCommand).trim();
  const prefix = '#'.repeat(level);
  view.dispatch({
    changes: { from: line.from, to: line.to, insert: `${prefix} ${combinedText}` },
  });
  setPendingSlashUndo(true);
}

/** Helper: replace the /command text with a line prefix (bullet, number, quote) */
function applyLinePrefix(view: EditorView, from: number, to: number, prefix: string) {
  const line = view.state.doc.lineAt(from);
  const slashPosInLine = from - line.from;
  const matchedLength = to - from;
  const textBeforeSlash = line.text.slice(0, slashPosInLine);
  const textAfterCommand = line.text.slice(slashPosInLine + matchedLength);
  const combinedText = (textBeforeSlash + textAfterCommand).trim();
  view.dispatch({
    changes: { from: line.from, to: line.to, insert: `${prefix}${combinedText}` },
  });
  setPendingSlashUndo(true);
}

const slashCommands: SlashCommand[] = [
  {
    label: '/break',
    description: 'Insert section break',
    apply: (view, from, to) => {
      view.dispatch({ changes: { from, to, insert: '<!-- ::break:: -->\n\n' } });
      setPendingSlashUndo(true);
    },
  },
  { label: '/h1', description: 'Heading 1', apply: (v, f, t) => applyHeading(v, f, t, 1) },
  { label: '/h2', description: 'Heading 2', apply: (v, f, t) => applyHeading(v, f, t, 2) },
  { label: '/h3', description: 'Heading 3', apply: (v, f, t) => applyHeading(v, f, t, 3) },
  { label: '/h4', description: 'Heading 4', apply: (v, f, t) => applyHeading(v, f, t, 4) },
  { label: '/h5', description: 'Heading 5', apply: (v, f, t) => applyHeading(v, f, t, 5) },
  { label: '/h6', description: 'Heading 6', apply: (v, f, t) => applyHeading(v, f, t, 6) },
  { label: '/bullet', description: 'Bullet list', apply: (v, f, t) => applyLinePrefix(v, f, t, '- ') },
  { label: '/number', description: 'Numbered list', apply: (v, f, t) => applyLinePrefix(v, f, t, '1. ') },
  { label: '/quote', description: 'Blockquote', apply: (v, f, t) => applyLinePrefix(v, f, t, '> ') },
  {
    label: '/code',
    description: 'Code block',
    apply: (view, from, to) => {
      view.dispatch({ changes: { from, to, insert: '```\n\n```' }, selection: { anchor: from + 4 } });
      setPendingSlashUndo(true);
    },
  },
  {
    label: '/link',
    description: 'Insert link',
    apply: (view, from, to) => {
      view.dispatch({
        changes: { from, to, insert: '[link text](url)' },
        selection: { anchor: from + 1, head: from + 10 },
      });
      setPendingSlashUndo(true);
    },
  },
  {
    label: '/highlight',
    description: 'Toggle highlight',
    apply: (view, from, to) => {
      view.dispatch({ changes: { from, to, insert: '' } });
      window.FinalFinal.toggleHighlight();
      setPendingSlashUndo(true);
    },
  },
  {
    label: '/task',
    description: 'Insert task annotation',
    apply: (view, from, to) => {
      view.dispatch({
        changes: { from, to, insert: '<!-- ::task:: [ ]  -->' },
        selection: { anchor: from + 17 },
      });
      setPendingSlashUndo(true);
    },
  },
  {
    label: '/comment',
    description: 'Insert comment annotation',
    apply: (view, from, to) => {
      view.dispatch({
        changes: { from, to, insert: '<!-- ::comment::  -->' },
        selection: { anchor: from + 17 },
      });
      setPendingSlashUndo(true);
    },
  },
  {
    label: '/reference',
    description: 'Insert reference annotation',
    apply: (view, from, to) => {
      view.dispatch({
        changes: { from, to, insert: '<!-- ::reference::  -->' },
        selection: { anchor: from + 19 },
      });
      setPendingSlashUndo(true);
    },
  },
  {
    label: '/footnote',
    description: 'Insert footnote',
    apply: (_view, from, to) => {
      insertFootnoteReplacingRange(from, to);
      setPendingSlashUndo(true);
    },
  },
  {
    label: '/cite',
    description: 'Insert citation from Zotero',
    apply: (_view, from, to) => {
      setPendingCAYWRange({ start: from, end: to });
      if ((window as any).webkit?.messageHandlers?.openCitationPicker) {
        (window as any).webkit.messageHandlers.openCitationPicker.postMessage(from);
      } else {
        setPendingCAYWRange(null);
      }
    },
  },
];

// === Custom slash menu ViewPlugin ===

class SlashMenuPlugin {
  private menuEl: HTMLElement | null = null;
  private selectedIndex = 0;
  private filteredCommands: SlashCommand[] = [];
  private slashFrom = 0; // Position of the `/` in the doc
  private slashTo = 0; // End position of the matched text
  private isVisible = false;

  constructor(private view: EditorView) {
    slashLog('[SlashMenu] Plugin constructed');
    this.handleKeydown = this.handleKeydown.bind(this);
    document.addEventListener('keydown', this.handleKeydown, true);
  }

  update(update: ViewUpdate) {
    try {
      if (!update.docChanged && !update.selectionSet) return;
      slashLog('[SlashMenu] update() called, docChanged:', update.docChanged, 'selectionSet:', update.selectionSet);

      const { head } = update.view.state.selection.main;
      const line = update.view.state.doc.lineAt(head);
      const textBefore = update.view.state.sliceDoc(line.from, head);

      // Match `/` followed by optional word chars at end of text
      const slashMatch = textBefore.match(/\/(\w*)$/);
      slashLog('[SlashMenu] textBefore:', JSON.stringify(textBefore), 'slashMatch:', slashMatch);
      if (slashMatch) {
        const slashPos = textBefore.length - slashMatch[0].length;
        const query = slashMatch[1].toLowerCase();
        this.slashFrom = line.from + slashPos;
        this.slashTo = head;
        this.selectedIndex = 0;

        this.filteredCommands = slashCommands.filter((cmd) => cmd.label.toLowerCase().startsWith(`/${query}`));

        if (this.filteredCommands.length > 0) {
          this.show();
          this.renderItems();
          // Defer layout reads — coordsAtPos and defaultLineHeight call
          // readMeasured(), which throws during update() (updateState == 2).
          // Use requestMeasure to schedule reads after the update cycle.
          this.view.requestMeasure({
            read: (view) => ({
              coords: view.coordsAtPos(this.slashFrom),
              lineHeight: view.defaultLineHeight,
            }),
            write: (measured) => {
              slashLog('[SlashMenu] position() coords:', measured.coords, 'slashFrom:', this.slashFrom);
              if (!measured.coords) return;
              const menu = this.ensureMenu();
              menu.style.left = `${measured.coords.left}px`;
              menu.style.top = `${measured.coords.bottom + measured.lineHeight * 0.1}px`;
            },
          });
        } else {
          this.hide();
        }
      } else {
        this.hide();
      }
    } catch (e) {
      slashLog('[SlashMenu] update error:', e);
    }
  }

  destroy() {
    slashLog('[SlashMenu] Plugin DESTROYED');
    document.removeEventListener('keydown', this.handleKeydown, true);
    if (this.menuEl) {
      this.menuEl.remove();
      this.menuEl = null;
    }
  }

  private ensureMenu(): HTMLElement {
    if (!this.menuEl) {
      this.menuEl = document.createElement('div');
      this.menuEl.className = 'slash-menu';
      this.menuEl.setAttribute('data-show', 'false');

      // Prevent clicks from stealing editor focus
      this.menuEl.addEventListener('mousedown', (e) => e.preventDefault());

      document.body.appendChild(this.menuEl);
    }
    return this.menuEl;
  }

  private show() {
    slashLog('[SlashMenu] show() called');
    const menu = this.ensureMenu();
    menu.setAttribute('data-show', 'true');
    this.isVisible = true;
  }

  private hide() {
    if (this.menuEl) {
      this.menuEl.setAttribute('data-show', 'false');
    }
    this.isVisible = false;
    this.selectedIndex = 0;
    this.filteredCommands = [];
  }

  private renderItems() {
    const menu = this.ensureMenu();

    // Clear existing content
    while (menu.firstChild) {
      menu.removeChild(menu.firstChild);
    }

    if (this.filteredCommands.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'slash-menu-empty';
      empty.textContent = 'No commands found';
      menu.appendChild(empty);
      return;
    }

    this.filteredCommands.forEach((cmd, i) => {
      const item = document.createElement('div');
      item.className = `slash-menu-item${i === this.selectedIndex ? ' selected' : ''}`;
      item.dataset.index = String(i);

      const labelSpan = document.createElement('span');
      labelSpan.className = 'slash-menu-item-label';
      labelSpan.textContent = cmd.label;

      const descSpan = document.createElement('span');
      descSpan.className = 'slash-menu-item-description';
      descSpan.textContent = cmd.description;

      item.appendChild(labelSpan);
      item.appendChild(descSpan);

      item.addEventListener('click', () => {
        this.executeCommand(i);
      });
      item.addEventListener('mouseenter', () => {
        this.selectedIndex = i;
        this.updateSelection();
      });

      menu.appendChild(item);
    });
  }

  private updateSelection() {
    if (!this.menuEl) return;
    const items = this.menuEl.querySelectorAll('.slash-menu-item');
    items.forEach((item, i) => {
      item.classList.toggle('selected', i === this.selectedIndex);
    });
  }

  private executeCommand(index: number) {
    if (index >= this.filteredCommands.length) return;
    const cmd = this.filteredCommands[index];
    cmd.apply(this.view, this.slashFrom, this.slashTo);
    this.hide();
  }

  private handleKeydown(e: KeyboardEvent) {
    if (!this.isVisible || this.filteredCommands.length === 0) return;

    if (e.key === 'ArrowDown') {
      e.preventDefault();
      e.stopPropagation();
      this.selectedIndex = (this.selectedIndex + 1) % this.filteredCommands.length;
      this.updateSelection();
      this.scrollToSelected();
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      e.stopPropagation();
      this.selectedIndex = (this.selectedIndex - 1 + this.filteredCommands.length) % this.filteredCommands.length;
      this.updateSelection();
      this.scrollToSelected();
    } else if (e.key === 'Enter' || e.key === 'Tab') {
      e.preventDefault();
      e.stopPropagation();
      this.executeCommand(this.selectedIndex);
    } else if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      this.hide();
    }
  }

  private scrollToSelected() {
    if (!this.menuEl) return;
    const selectedItem = this.menuEl.querySelector('.slash-menu-item.selected');
    if (selectedItem) {
      selectedItem.scrollIntoView({ block: 'nearest' });
    }
  }
}

export const slashMenuPlugin = ViewPlugin.fromClass(SlashMenuPlugin);
