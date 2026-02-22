// Slash command definitions, UI, keyboard handling, and plugin setup

import { type Ctx, editorViewCtx } from '@milkdown/kit/core';
import { redo, undo } from '@milkdown/kit/prose/history';
import { Selection } from '@milkdown/kit/prose/state';
import { SlashProvider, slashFactory } from '@milkdown/plugin-slash';
import { type AnnotationType, annotationNode } from './annotation-plugin';
import { openCAYWPicker } from './cayw';
import {
  getEditorInstance,
  getPendingSlashRedo,
  getPendingSlashUndo,
  setPendingSlashRedo,
  setPendingSlashUndo,
} from './editor-state';
import { insertFootnoteWithDelete } from './footnote-plugin';
import { sectionBreakNode } from './section-break-plugin';

// === Slash command definitions ===
interface SlashCommand {
  label: string;
  replacement: string;
  description: string;
  isNodeInsertion?: boolean; // If true, uses custom node insertion instead of text
  headingLevel?: 1 | 2 | 3; // For heading commands, transforms paragraph to heading node
}

const slashCommands: SlashCommand[] = [
  { label: '/break', replacement: '', description: 'Insert section break', isNodeInsertion: true },
  { label: '/h1', replacement: '', description: 'Heading 1', headingLevel: 1 },
  { label: '/h2', replacement: '', description: 'Heading 2', headingLevel: 2 },
  { label: '/h3', replacement: '', description: 'Heading 3', headingLevel: 3 },
  { label: '/task', replacement: '', description: 'Insert task annotation', isNodeInsertion: true },
  { label: '/comment', replacement: '', description: 'Insert comment annotation', isNodeInsertion: true },
  { label: '/reference', replacement: '', description: 'Insert reference annotation', isNodeInsertion: true },
  { label: '/cite', replacement: '', description: 'Insert citation', isNodeInsertion: true },
  { label: '/footnote', replacement: '', description: 'Insert footnote', isNodeInsertion: true },
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
  menu.setAttribute('data-show', 'false'); // Prevent flash on load
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
  item.className = `slash-menu-item${isSelected ? ' selected' : ''}`;
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
    updateMenuSelection(); // Only update styles, don't recreate DOM
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
  filteredCommands = slashCommands.filter(
    (cmd) => cmd.label.toLowerCase().includes(query) || cmd.description.toLowerCase().includes(query)
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
    (item as HTMLElement).style.background = isSelected ? 'var(--editor-selection, #e8f0fe)' : '';
  });
}

function executeSlashCommand(index: number) {
  const editorInstance = getEditorInstance();
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
        tr = tr.delete(cmdStart, from); // Delete the "/break" text
        tr = tr.insert(parentStart, node); // Insert section_break BEFORE the paragraph
      }
      view.dispatch(tr);
    } else if (cmd.headingLevel) {
      // Transform to heading (works for both paragraphs and existing headings)
      const headingType = view.state.schema.nodes.heading;

      if (!headingType) {
        console.error('[Milkdown] Heading schema not found');
        return;
      }

      // Get parent block boundaries and full text content
      const parentStart = $from.before($from.depth);
      const parentEnd = $from.after($from.depth);
      const fullText = view.state.doc.textBetween(parentStart + 1, parentEnd - 1, '\n');

      // Calculate slash position within fullText directly (not textBefore)
      const slashPosInFull = fullText.lastIndexOf('/');

      // Preserve text before AND after the slash command (without adding space)
      const textBeforeSlash = fullText.slice(0, slashPosInFull);
      const textAfterCommand = fullText.slice(slashPosInFull + currentFilter.length);

      // Concatenate directly (don't use join(' ') which adds unwanted space)
      const combinedText = (textBeforeSlash + textAfterCommand).trim();

      // Create heading node with level attribute
      const heading = combinedText
        ? headingType.create({ level: cmd.headingLevel }, view.state.schema.text(combinedText))
        : headingType.create({ level: cmd.headingLevel });

      // Replace parent block (works for both paragraph and heading nodes)
      let tr = view.state.tr.replaceWith(parentStart, parentEnd, heading);

      // Position cursor at end of heading content
      const cursorPos = parentStart + 1 + (combinedText ? combinedText.length : 0);
      tr = tr.setSelection(Selection.near(tr.doc.resolve(Math.min(cursorPos, tr.doc.content.size - 1))));

      view.dispatch(tr);
    } else if (cmd.isNodeInsertion && ['/task', '/comment', '/reference'].includes(cmd.label)) {
      // Insert annotation node with empty text content
      const annotationType = cmd.label.slice(1) as AnnotationType; // Remove leading '/'
      const nodeType = annotationNode.type(editorInstance.ctx);

      // Create annotation node with no text content (enables :empty placeholder CSS)
      const node = nodeType.create(
        { type: annotationType, isCompleted: false }
        // No text content - allows CSS :empty::before placeholder to show
      );

      // Delete the slash command and insert the annotation node inline
      let tr = view.state.tr.delete(cmdStart, from);
      tr = tr.insert(cmdStart, node);

      // Position cursor inside the annotation's content area
      // cmdStart = start of annotation node, cmdStart + 1 = inside node's content
      tr = tr.setSelection(Selection.near(tr.doc.resolve(cmdStart + 1)));

      view.dispatch(tr);
    } else if (cmd.label === '/footnote') {
      // Insert footnote reference node — single transaction (delete slash + insert + renumber)
      insertFootnoteWithDelete(view, editorInstance, cmdStart, from);
    } else if (cmd.label === '/cite') {
      // Open Zotero's native CAYW picker via Swift bridge
      // Pass both cmdStart (position of /) and from (cursor at end of /cite)
      openCAYWPicker(cmdStart, from);
      // Don't dispatch transaction - the callback will handle insertion
      // Just hide the slash menu and reset state
      if (slashProviderInstance) {
        slashProviderInstance.hide();
      }
      filteredCommands = [];
      // Re-enable slash menu after picker closes (handled by callback)
      requestAnimationFrame(() => {
        suppressSlashMenu = false;
      });
      return; // Early return - don't set pendingSlashUndo
    } else {
      // Standard text replacement (fallback for future commands)
      const tr = view.state.tr.delete(cmdStart, from).insertText(cmd.replacement, cmdStart);
      view.dispatch(tr);
    }

    // Mark for smart undo
    setPendingSlashUndo(true);
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

// Keyboard navigation for slash menu AND smart undo/redo handling
function handleSlashKeydown(e: KeyboardEvent): boolean {
  const editorInstance = getEditorInstance();

  // Smart undo: after slash command, undo removes both the result AND the "/" trigger
  if (e.key === 'z' && (e.metaKey || e.ctrlKey) && !e.shiftKey) {
    if (getPendingSlashUndo() && editorInstance) {
      e.preventDefault();
      e.stopPropagation();

      // Suppress menu during undo operations
      suppressSlashMenu = true;

      const view = editorInstance.ctx.get(editorViewCtx);

      // Perform first undo (removes the slash command result)
      undo(view.state, view.dispatch);

      // Check if "/" pattern remains at cursor
      const { from } = view.state.selection;
      const $from = view.state.doc.resolve(from);
      const lineStart = $from.start($from.depth);
      const textBefore = view.state.doc.textBetween(lineStart, from, '\n');

      if (/\/\w*$/.test(textBefore)) {
        // Perform second undo (removes the "/" trigger)
        undo(view.state, view.dispatch);
        setPendingSlashRedo(true); // Enable smart redo
      }

      setPendingSlashUndo(false);

      // Re-enable menu after transaction settles
      requestAnimationFrame(() => {
        suppressSlashMenu = false;
      });

      return true;
    }
  }

  // Smart redo: after smart undo, redo restores both steps
  if (e.key === 'z' && (e.metaKey || e.ctrlKey) && e.shiftKey) {
    if (getPendingSlashRedo() && editorInstance) {
      e.preventDefault();
      e.stopPropagation();

      // Suppress menu during redo operations
      suppressSlashMenu = true;

      const view = editorInstance.ctx.get(editorViewCtx);

      // Perform two redos to restore both "/" and the command result
      redo(view.state, view.dispatch);
      redo(view.state, view.dispatch);

      setPendingSlashRedo(false);
      setPendingSlashUndo(true); // Allow smart undo again

      // Re-enable menu after transaction settles
      requestAnimationFrame(() => {
        suppressSlashMenu = false;
      });

      return true;
    }
  }

  // Reset flags on any editing key (typing, backspace, delete)
  if (e.key.length === 1 || e.key === 'Backspace' || e.key === 'Delete') {
    setPendingSlashUndo(false);
    setPendingSlashRedo(false);
  }

  if (!slashMenuElement || !slashProviderInstance) return false;

  // Check if menu is visible via SlashProvider's data-show attribute
  if (slashMenuElement.getAttribute('data-show') === 'false') return false;

  // Check if menu has items
  if (filteredCommands.length === 0) return false;

  if (e.key === 'ArrowDown') {
    e.preventDefault();
    e.stopPropagation();
    selectedIndex = (selectedIndex + 1) % filteredCommands.length;
    updateMenuSelection(); // Only update styles, don't recreate DOM
    return true;
  }
  if (e.key === 'ArrowUp') {
    e.preventDefault();
    e.stopPropagation();
    selectedIndex = (selectedIndex - 1 + filteredCommands.length) % filteredCommands.length;
    updateMenuSelection(); // Only update styles, don't recreate DOM
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
export const slash = slashFactory('main');

export function configureSlash(ctx: Ctx) {
  slashMenuElement = createSlashMenu();
  document.body.appendChild(slashMenuElement);

  slashProviderInstance = new SlashProvider({
    content: slashMenuElement,
    shouldShow(view) {
      // Pass custom matchNode to allow slash commands in both paragraphs and headings
      const content = this.getContent(view, (node) => node.type.name === 'paragraph' || node.type.name === 'heading');
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
