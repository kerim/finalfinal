// Milkdown WYSIWYG Editor for final final
// Uses window.FinalFinal API for Swift ↔ JS communication

import { Editor, defaultValueCtx, editorViewCtx, parserCtx, Ctx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { history } from '@milkdown/kit/plugin/history';
import { getMarkdown } from '@milkdown/kit/utils';
import { Slice } from '@milkdown/kit/prose/model';
import { Selection } from '@milkdown/kit/prose/state';
import { slashFactory, SlashProvider } from '@milkdown/plugin-slash';

import { focusModePlugin, setFocusModeEnabled } from './focus-mode-plugin';
import { sectionBreakPlugin, sectionBreakNode } from './section-break-plugin';
import { textToMdOffset, mdToTextOffset } from './cursor-mapping';
import './styles.css';

/**
 * Strip markdown syntax from a line to get plain text content
 * Used for matching ProseMirror nodes to markdown lines
 */
function stripMarkdownSyntax(line: string): string {
  return line
    .replace(/^\||\|$/g, '')            // leading/trailing pipes (table)
    .replace(/\|/g, ' ')                // internal pipes (table cells)
    .replace(/^#+\s*/, '')              // headings
    .replace(/^\s*[-*+]\s*/, '')        // unordered list items
    .replace(/^\s*\d+\.\s*/, '')        // ordered list items
    .replace(/^\s*>\s*/, '')            // blockquotes
    .replace(/~~(.+?)~~/g, '$1')        // strikethrough
    .replace(/\*\*(.+?)\*\*/g, '$1')    // bold
    .replace(/__(.+?)__/g, '$1')        // bold alt
    .replace(/\*(.+?)\*/g, '$1')        // italic
    .replace(/_([^_]+)_/g, '$1')        // italic alt
    .replace(/`([^`]+)`/g, '$1')        // inline code
    .replace(/!\[([^\]]*)\]\([^)]+\)/g, '$1') // images
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')  // links
    .trim()
    .replace(/\s+/g, ' ');              // normalize whitespace
}

/**
 * Check if a markdown line is a table row (starts/ends with |)
 */
function isTableLine(line: string): boolean {
  const trimmed = line.trim();
  // Ensure at least |x| structure (3 chars minimum)
  return trimmed.length >= 3 && trimmed.startsWith('|') && trimmed.endsWith('|');
}

/**
 * Check if a markdown line is a table separator (| --- | --- |)
 */
function isTableSeparator(line: string): boolean {
  const trimmed = line.trim();
  return /^\|[\s:-]+\|$/.test(trimmed) || /^\|(\s*:?-+:?\s*\|)+$/.test(trimmed);
}

/**
 * Find the table structure in markdown: returns startLine for the table containing the given line
 */
function findTableStartLine(lines: string[], targetLine: number): number | null {
  if (!isTableLine(lines[targetLine - 1])) return null;

  // Find table start (scan backwards)
  let startLine = targetLine;
  while (startLine > 1 && isTableLine(lines[startLine - 2])) {
    startLine--;
  }
  return startLine;
}


declare global {
  interface Window {
    FinalFinal: {
      setContent: (markdown: string) => void;
      getContent: () => string;
      setFocusMode: (enabled: boolean) => void;
      getStats: () => { words: number; characters: number };
      scrollToOffset: (offset: number) => void;
      setTheme: (cssVariables: string) => void;
      getCursorPosition: () => { line: number; column: number };
      setCursorPosition: (pos: { line: number; column: number }) => void;
      scrollCursorToCenter: () => void;
      insertAtCursor: (text: string) => void;
      insertBreak: () => void;
    };
  }
}

let editorInstance: Editor | null = null;
let currentContent = '';
let isSettingContent = false;

// === Slash command definitions ===
interface SlashCommand {
  label: string;
  replacement: string;
  description: string;
  isNodeInsertion?: boolean; // If true, uses custom node insertion instead of text
}

const slashCommands: SlashCommand[] = [
  { label: '/break', replacement: '', description: 'Insert section break', isNodeInsertion: true },
  { label: '/h1', replacement: '# ', description: 'Heading 1' },
  { label: '/h2', replacement: '## ', description: 'Heading 2' },
  { label: '/h3', replacement: '### ', description: 'Heading 3' },
];

// === Slash menu UI state ===
let slashMenuElement: HTMLElement | null = null;
let selectedIndex = 0;
let filteredCommands: SlashCommand[] = [];
let slashProviderInstance: SlashProvider | null = null;
let currentFilter = '';
let suppressSlashMenu = false; // Prevents re-showing menu during command execution
let lastSlashShowTime = 0; // Debounce: prevents immediate hide after show

function createSlashMenu(): HTMLElement {
  const menu = document.createElement('div');
  menu.className = 'slash-menu';
  menu.setAttribute('data-show', 'false');  // Prevent flash on load
  menu.style.cssText = `
    position: absolute;
    padding: 4px 0;
    background: var(--editor-bg, white);
    border: 1px solid var(--editor-border, #e0e0e0);
    box-shadow: 0 2px 8px rgba(0,0,0,0.15);
    border-radius: 6px;
    font-size: 14px;
    min-width: 220px;
    z-index: 1000;
    color: var(--editor-text, #333);
  `;
  return menu;
}

function createMenuItem(cmd: SlashCommand, index: number, isSelected: boolean): HTMLElement {
  const item = document.createElement('div');
  item.className = 'slash-menu-item' + (isSelected ? ' selected' : '');
  item.dataset.index = String(index);
  item.style.cssText = `
    padding: 6px 12px;
    cursor: pointer;
    display: flex;
    gap: 8px;
    align-items: center;
    ${isSelected ? 'background: var(--editor-selection, #e8f0fe);' : ''}
  `;

  const labelSpan = document.createElement('span');
  labelSpan.style.cssText = 'font-weight: 500; min-width: 60px;';
  labelSpan.textContent = cmd.label;

  const descSpan = document.createElement('span');
  descSpan.style.cssText = 'color: var(--editor-muted, #666);';
  descSpan.textContent = cmd.description;

  item.appendChild(labelSpan);
  item.appendChild(descSpan);

  item.addEventListener('click', () => {
    executeSlashCommand(index);
  });
  item.addEventListener('mouseenter', () => {
    selectedIndex = index;
    updateMenuSelection();  // Only update styles, don't recreate DOM
  });

  return item;
}

function updateSlashMenu(filter: string) {
  if (!slashMenuElement) return;
  currentFilter = filter;

  // Clear existing content
  while (slashMenuElement.firstChild) {
    slashMenuElement.removeChild(slashMenuElement.firstChild);
  }

  // Filter commands based on what user typed after /
  const query = filter.slice(1).toLowerCase(); // Remove leading /
  filteredCommands = slashCommands.filter(cmd =>
    cmd.label.toLowerCase().includes(query) ||
    cmd.description.toLowerCase().includes(query)
  );

  if (filteredCommands.length === 0) {
    const noResults = document.createElement('div');
    noResults.style.cssText = 'padding: 8px 12px; color: #999;';
    noResults.textContent = 'No commands found';
    slashMenuElement.appendChild(noResults);
    return;
  }

  selectedIndex = Math.min(selectedIndex, filteredCommands.length - 1);

  filteredCommands.forEach((cmd, i) => {
    slashMenuElement!.appendChild(createMenuItem(cmd, i, i === selectedIndex));
  });
}

/**
 * Update menu selection state without recreating DOM nodes.
 * This prevents the race condition where mouseenter destroys the click target.
 */
function updateMenuSelection() {
  if (!slashMenuElement) return;
  const items = slashMenuElement.querySelectorAll('.slash-menu-item');
  items.forEach((item, i) => {
    const isSelected = i === selectedIndex;
    item.classList.toggle('selected', isSelected);
    (item as HTMLElement).style.background = isSelected
      ? 'var(--editor-selection, #e8f0fe)'
      : '';
  });
}

function executeSlashCommand(index: number) {
  if (!editorInstance) return;
  if (index >= filteredCommands.length) return;

  suppressSlashMenu = true; // Prevent SlashProvider from re-showing during transaction

  const cmd = filteredCommands[index];
  const view = editorInstance.ctx.get(editorViewCtx);
  const { from } = view.state.selection;
  const $from = view.state.doc.resolve(from);

  // Find the start of the slash command
  const lineStart = $from.start($from.depth);
  const textBefore = view.state.doc.textBetween(lineStart, from, '\n');
  const slashIndex = textBefore.lastIndexOf('/');

  if (slashIndex >= 0) {
    const cmdStart = lineStart + slashIndex;

    if (cmd.isNodeInsertion && cmd.label === '/break') {
      // Insert section_break node
      const nodeType = sectionBreakNode.type(editorInstance.ctx);
      const node = nodeType.create();

      // Delete the slash command text, then replace the parent paragraph with the break node
      // We need to replace the entire paragraph if it only contains the slash
      const parentStart = $from.before($from.depth);
      const parentEnd = $from.after($from.depth);
      const parentContent = view.state.doc.textBetween(parentStart + 1, parentEnd - 1, '\n').trim();

      let tr = view.state.tr;
      if (parentContent === textBefore.trim()) {
        // Paragraph only contains the slash command - replace the whole paragraph
        tr = tr.replaceWith(parentStart, parentEnd, node);
      } else {
        // Paragraph has other content - insert break BEFORE paragraph, delete only /break text
        tr = tr.delete(cmdStart, from);           // Delete the "/break" text
        tr = tr.insert(parentStart, node);        // Insert section_break BEFORE the paragraph
      }
      view.dispatch(tr);
    } else {
      // Standard text replacement
      const tr = view.state.tr
        .delete(cmdStart, from)
        .insertText(cmd.replacement, cmdStart);
      view.dispatch(tr);
    }
  }

  // Hide menu - rely solely on SlashProvider's data-show attribute
  if (slashProviderInstance) {
    slashProviderInstance.hide();
  }
  filteredCommands = [];

  // Re-enable slash menu after transaction settles
  requestAnimationFrame(() => {
    suppressSlashMenu = false;
  });
}

// Keyboard navigation for slash menu
function handleSlashKeydown(e: KeyboardEvent): boolean {
  if (!slashMenuElement || !slashProviderInstance) return false;

  // Check if menu is visible via SlashProvider's data-show attribute
  if (slashMenuElement.getAttribute('data-show') === 'false') return false;

  // Check if menu has items
  if (filteredCommands.length === 0) return false;

  if (e.key === 'ArrowDown') {
    e.preventDefault();
    e.stopPropagation();
    selectedIndex = (selectedIndex + 1) % filteredCommands.length;
    updateMenuSelection();  // Only update styles, don't recreate DOM
    return true;
  }
  if (e.key === 'ArrowUp') {
    e.preventDefault();
    e.stopPropagation();
    selectedIndex = (selectedIndex - 1 + filteredCommands.length) % filteredCommands.length;
    updateMenuSelection();  // Only update styles, don't recreate DOM
    return true;
  }
  if (e.key === 'Enter' || e.key === 'Tab') {
    e.preventDefault();
    e.stopPropagation();
    executeSlashCommand(selectedIndex);
    return true;
  }
  if (e.key === 'Escape') {
    e.preventDefault();
    e.stopPropagation();
    slashProviderInstance.hide();
    return true;
  }
  return false;
}

// === Slash plugin setup ===
const slash = slashFactory('main');

function configureSlash(ctx: Ctx) {
  slashMenuElement = createSlashMenu();
  document.body.appendChild(slashMenuElement);

  slashProviderInstance = new SlashProvider({
    content: slashMenuElement,
    shouldShow(view) {
      const content = this.getContent(view);
      const now = Date.now();

      // Suppress re-showing during command execution
      if (suppressSlashMenu) return false;

      if (!content) {
        // Debounce: if we just showed the menu, don't hide immediately
        if (now - lastSlashShowTime < 100) return true;
        return false;
      }

      // Show menu when text ends with / or /followed-by-letters
      const match = content.match(/\/\w*$/);
      if (match) {
        lastSlashShowTime = now;
        selectedIndex = 0;
        updateSlashMenu(match[0]);
        return filteredCommands.length > 0;
      }
      return false;
    },
    offset: 8,
  });

  ctx.set(slash.key, {
    view: () => ({
      update: (view: any, prevState: any) => {
        slashProviderInstance!.update(view, prevState);
      },
      destroy: () => {
        slashProviderInstance!.destroy();
        if (slashMenuElement) {
          slashMenuElement.remove();
          slashMenuElement = null;
        }
        document.removeEventListener('keydown', handleSlashKeydown, true);
      },
    }),
  });

  // Add keyboard listener for menu navigation
  document.addEventListener('keydown', handleSlashKeydown, true);
}

async function initEditor() {
  const root = document.getElementById('editor');
  if (!root) {
    console.error('[Milkdown] Editor root element not found');
    return;
  }

  try {
    editorInstance = await Editor.make()
      .config((ctx) => {
        ctx.set(defaultValueCtx, '');
      })
      .config(configureSlash)
      .use(sectionBreakPlugin)  // BEFORE commonmark to intercept HTML before filtering
      .use(commonmark)
      .use(gfm)
      .use(history)
      .use(focusModePlugin)
      .use(slash)
      .create();

    root.appendChild(editorInstance.ctx.get(editorViewCtx).dom);
  } catch (e) {
    console.error('[Milkdown] Init failed:', e);
    throw e;
  }

  // Track content changes
  const view = editorInstance.ctx.get(editorViewCtx);
  const originalDispatch = view.dispatch.bind(view);
  view.dispatch = (tr) => {
    originalDispatch(tr);
    if (tr.docChanged && !isSettingContent) {
      currentContent = editorInstance!.action(getMarkdown());
    }
  };

}

window.FinalFinal = {
  setContent(markdown: string) {
    if (!editorInstance) {
      currentContent = markdown;
      return;
    }
    if (currentContent === markdown) {
      return;
    }

    isSettingContent = true;
    try {
      editorInstance.action((ctx) => {
        const view = ctx.get(editorViewCtx);
        const parser = ctx.get(parserCtx);
        const doc = parser(markdown);
        if (!doc) {
          return;
        }

        const { from } = view.state.selection;
        const docSize = view.state.doc.content.size;
        let tr = view.state.tr.replace(0, docSize, new Slice(doc.content, 0, 0));

        const safeFrom = Math.min(from, Math.max(0, doc.content.size - 1));
        try {
          tr = tr.setSelection(Selection.near(tr.doc.resolve(safeFrom)));
        } catch {
          tr = tr.setSelection(Selection.atStart(tr.doc));
        }
        view.dispatch(tr);
      });
      currentContent = markdown;
    } finally {
      isSettingContent = false;
    }
  },

  getContent() {
    return editorInstance ? editorInstance.action(getMarkdown()) : currentContent;
  },

  setFocusMode(enabled: boolean) {
    setFocusModeEnabled(enabled);
    if (editorInstance) {
      const view = editorInstance.ctx.get(editorViewCtx);
      view.dispatch(view.state.tr);
    }
  },

  getStats() {
    const content = this.getContent();
    const words = content.split(/\s+/).filter(w => w.length > 0).length;
    return { words, characters: content.length };
  },

  scrollToOffset(offset: number) {
    if (!editorInstance) return;

    const view = editorInstance.ctx.get(editorViewCtx);
    const docSize = view.state.doc.content.size;
    const pos = Math.min(offset, Math.max(0, docSize - 1));

    try {
      const selection = Selection.near(view.state.doc.resolve(pos));
      view.dispatch(view.state.tr.setSelection(selection));

      const coords = view.coordsAtPos(pos);
      if (coords) {
        const targetScrollY = coords.top + window.scrollY - 100;
        window.scrollTo({ top: Math.max(0, targetScrollY), behavior: 'smooth' });
      }

      view.focus();
    } catch {
      // Scroll failed, ignore
    }
  },

  setTheme(cssVariables: string) {
    const root = document.documentElement;
    cssVariables.split(';').filter(s => s.trim()).forEach(pair => {
      const [key, value] = pair.split(':').map(s => s.trim());
      if (key && value) root.style.setProperty(key, value);
    });
  },

  getCursorPosition(): { line: number; column: number } {
    if (!editorInstance) {
      return { line: 1, column: 0 };
    }

    try {
      const view = editorInstance.ctx.get(editorViewCtx);
      const { head } = view.state.selection;
      const markdown = editorInstance.action(getMarkdown());
      const mdLines = markdown.split('\n');
      const $head = view.state.doc.resolve(head);

      // Get parent node text for line matching
      const parentNode = $head.parent;
      const parentText = parentNode.textContent;

      let line = 1;
      let matched = false;

      // Check if cursor is in a table by looking at ancestor nodes
      let inTable = false;
      for (let d = $head.depth; d > 0; d--) {
        if ($head.node(d).type.name === 'table') {
          inTable = true;
          break;
        }
      }

      // SIMPLE TABLE HANDLING: When cursor is in a table, return the table's START line
      if (inTable) {
        let pmTableOrdinal = 0;
        let foundTablePos = false;
        view.state.doc.descendants((node, pos) => {
          if (foundTablePos) return false;
          if (node.type.name === 'table') {
            pmTableOrdinal++;
            if (head > pos && head < pos + node.nodeSize) {
              foundTablePos = true;
              return false;
            }
          }
          return true;
        });

        // Find the pmTableOrdinal-th table in markdown
        if (pmTableOrdinal > 0) {
          let mdTableCount = 0;
          for (let i = 0; i < mdLines.length; i++) {
            if (isTableLine(mdLines[i]) && !isTableSeparator(mdLines[i])) {
              if (i === 0 || !isTableLine(mdLines[i - 1])) {
                mdTableCount++;
                if (mdTableCount === pmTableOrdinal) {
                  line = i + 1;
                  matched = true;
                  break;
                }
              }
            }
          }
        }
      }

      // Standard text matching (skip if already matched via table)
      for (let i = 0; i < mdLines.length && !matched; i++) {
        const stripped = stripMarkdownSyntax(mdLines[i]);

        if (stripped === parentText) {
          line = i + 1;
          matched = true;
          break;
        }

        // Partial match (for long lines)
        if (stripped && parentText &&
            parentText.startsWith(stripped) &&
            stripped.length >= 10) {
          line = i + 1;
          matched = true;
          break;
        }

        // Reverse partial match
        if (stripped && parentText &&
            stripped.startsWith(parentText) &&
            parentText.length >= 10) {
          line = i + 1;
          matched = true;
          break;
        }
      }

      // Fallback: count blocks from document start
      if (!matched) {
        let blockCount = 0;
        view.state.doc.descendants((node, pos) => {
          if (pos >= head) return false;
          if (node.isBlock && node.type.name !== 'doc') {
            blockCount++;
          }
          return true;
        });

        let contentLinesSeen = 0;
        for (let i = 0; i < mdLines.length; i++) {
          if (mdLines[i].trim() !== '') {
            contentLinesSeen++;
            if (contentLinesSeen === blockCount) {
              line = i + 1;
              break;
            }
          }
        }
        if (contentLinesSeen < blockCount) {
          line = mdLines.length;
        }
      }

      // Calculate column with inline markdown offset mapping
      const blockStart = $head.start($head.depth);
      const offsetInBlock = head - blockStart;
      const lineContent = mdLines[line - 1] || '';

      const syntaxMatch = lineContent.match(/^(#+\s*|\s*[-*+]\s*|\s*\d+\.\s*|\s*>\s*)/);
      const syntaxLength = syntaxMatch ? syntaxMatch[0].length : 0;
      const afterSyntax = lineContent.slice(syntaxLength);
      const column = syntaxLength + textToMdOffset(afterSyntax, offsetInBlock);

      return { line, column };
    } catch {
      return { line: 1, column: 0 };
    }
  },

  setCursorPosition(lineCol: { line: number; column: number; scrollFraction?: number }) {
    if (!editorInstance) {
      return;
    }

    try {
      const view = editorInstance.ctx.get(editorViewCtx);
      let { line, column } = lineCol;
      const markdown = editorInstance.action(getMarkdown());
      const lines = markdown.split('\n');

      // Handle separator rows - redirect to first data row
      let targetLine = lines[line - 1] || '';

      if (isTableLine(targetLine) && isTableSeparator(targetLine)) {
        const tableStart = findTableStartLine(lines, line);
        if (tableStart) {
          let dataRowLine = line + 1;
          while (dataRowLine <= lines.length && isTableSeparator(lines[dataRowLine - 1])) {
            dataRowLine++;
          }
          if (dataRowLine <= lines.length && isTableLine(lines[dataRowLine - 1])) {
            line = dataRowLine;
            column = 1;
            targetLine = lines[line - 1];
          }
        }
      }

      // Calculate text offset for column positioning
      const syntaxMatch = targetLine.match(/^(#+\s*|\s*[-*+]\s*|\s*\d+\.\s*|\s*>\s*)/);
      const syntaxLength = syntaxMatch ? syntaxMatch[0].length : 0;
      const afterSyntax = targetLine.slice(syntaxLength);
      const mdColumnInContent = Math.max(0, column - syntaxLength);
      const textOffset = mdToTextOffset(afterSyntax, mdColumnInContent);

      const targetText = stripMarkdownSyntax(targetLine);

      let pmPos = 1;
      let found = false;

      // SIMPLE TABLE HANDLING: Place cursor at the START of the table
      if (isTableLine(targetLine) && !isTableSeparator(targetLine)) {
        // Find which table this is in markdown (ordinal counting)
        // Count tables up to and including the target line
        let tableOrdinal = 0;
        for (let i = 0; i <= line - 1; i++) {
          if (isTableLine(lines[i]) && !isTableSeparator(lines[i])) {
            if (i === 0 || !isTableLine(lines[i - 1])) {
              tableOrdinal++;
            }
          }
        }

        // Find the tableOrdinal-th table in ProseMirror and place cursor at its start
        let currentTableOrdinal = 0;
        view.state.doc.descendants((node, pos) => {
          if (found) return false;
          if (node.type.name === 'table') {
            currentTableOrdinal++;
            if (currentTableOrdinal === tableOrdinal) {
              // Place cursor at start of table (position just inside first cell)
              pmPos = pos + 3;
              found = true;
              return false;
            }
          }
          return true;
        });
      }

      // Standard text matching
      if (!found) {
        view.state.doc.descendants((node, pos) => {
          if (found) return false;

          if (node.isBlock && node.textContent.trim() === targetText) {
            pmPos = pos + 1 + Math.min(textOffset, node.content.size);
            found = true;
            return false;
          }
          return true;
        });
      }

      // Fallback: map markdown line to PM block via content line index
      if (!found) {
        let contentLineIndex = 0;
        let inTableBlock = false;
        for (let i = 0; i < line; i++) {
          const currentLine = lines[i];
          if (isTableLine(currentLine)) {
            if (!inTableBlock) {
              contentLineIndex++;
              inTableBlock = true;
            }
          } else {
            inTableBlock = false;
            if (currentLine.trim() !== '') {
              contentLineIndex++;
            }
          }
        }

        let blockCount = 0;
        view.state.doc.descendants((node, pos) => {
          if (found) return false;
          if (node.isBlock && node.type.name !== 'doc') {
            blockCount++;
            if (blockCount === contentLineIndex) {
              pmPos = pos + 1 + Math.min(textOffset, node.content.size);
              found = true;
              return false;
            }
            if (node.type.name === 'table') {
              return false;
            }
          }
          return true;
        });
      }

      const selection = Selection.near(view.state.doc.resolve(pmPos));
      view.dispatch(view.state.tr.setSelection(selection).scrollIntoView());
      view.focus();

      // Restore scroll position if provided
      if (lineCol.scrollFraction !== undefined) {
        requestAnimationFrame(() => {
          try {
            const cursorCoords = view.coordsAtPos(pmPos);
            const editorRect = view.dom.getBoundingClientRect();
            if (cursorCoords && editorRect.height > 0) {
              const targetTop = editorRect.height * lineCol.scrollFraction!;
              const cursorInView = cursorCoords.top - editorRect.top;
              const scrollAdjust = cursorInView - targetTop;
              view.dom.scrollTop += scrollAdjust;
            }
          } catch {
            // Scroll adjustment failed, ignore
          }
        });
      }
    } catch {
      // Cursor positioning failed, ignore
    }
  },

  scrollCursorToCenter() {
    if (!editorInstance) return;
    try {
      const view = editorInstance.ctx.get(editorViewCtx);
      const { head } = view.state.selection;
      const coords = view.coordsAtPos(head);
      if (coords) {
        const viewportHeight = window.innerHeight;
        const targetScrollY = coords.top + window.scrollY - (viewportHeight / 2);
        window.scrollTo({ top: Math.max(0, targetScrollY), behavior: 'instant' });
      }
    } catch {
      // Scroll failed, ignore
    }
  },

  insertAtCursor(text: string) {
    if (!editorInstance) return;
    try {
      const view = editorInstance.ctx.get(editorViewCtx);
      const { from, to } = view.state.selection;
      const tr = view.state.tr.replaceWith(from, to, view.state.schema.text(text));
      view.dispatch(tr);
      view.focus();
    } catch {
      // Insert failed, ignore
    }
  },

  insertBreak() {
    // Insert a section break node
    if (!editorInstance) return;
    try {
      const view = editorInstance.ctx.get(editorViewCtx);
      const { from } = view.state.selection;
      const nodeType = sectionBreakNode.type(editorInstance.ctx);
      const node = nodeType.create();
      const tr = view.state.tr.insert(from, node);
      view.dispatch(tr);
      view.focus();
    } catch {
      // Insert failed, ignore
    }
  },
};

// Initialize editor
initEditor().catch((e) => {
  console.error('[Milkdown] Init failed:', e);
});
