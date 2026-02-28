// Slash command definitions, UI, keyboard handling, and plugin setup

import '../../shared/slash-menu.css';
import { type Ctx, editorViewCtx } from '@milkdown/kit/core';
import { redo, undo } from '@milkdown/kit/prose/history';
import { Selection } from '@milkdown/kit/prose/state';
import { SlashProvider, slashFactory } from '@milkdown/plugin-slash';
import { showAnnotationEditPopup } from './annotation-edit-popup';
import type { AnnotationAttrs } from './annotation-plugin';
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
  headingLevel?: number; // For heading commands, transforms paragraph to heading node
  apiCommand?: string; // If set, calls window.FinalFinal[apiCommand]() instead of custom logic
}

const slashCommands: SlashCommand[] = [
  { label: '/break', replacement: '', description: 'Insert section break', isNodeInsertion: true },
  { label: '/h1', replacement: '', description: 'Heading 1', headingLevel: 1 },
  { label: '/h2', replacement: '', description: 'Heading 2', headingLevel: 2 },
  { label: '/h3', replacement: '', description: 'Heading 3', headingLevel: 3 },
  { label: '/h4', replacement: '', description: 'Heading 4', headingLevel: 4 },
  { label: '/h5', replacement: '', description: 'Heading 5', headingLevel: 5 },
  { label: '/h6', replacement: '', description: 'Heading 6', headingLevel: 6 },
  { label: '/bullet', replacement: '', description: 'Bullet list', apiCommand: 'toggleBulletList' },
  { label: '/number', replacement: '', description: 'Numbered list', apiCommand: 'toggleNumberList' },
  { label: '/quote', replacement: '', description: 'Blockquote', apiCommand: 'toggleBlockquote' },
  { label: '/code', replacement: '', description: 'Code block', apiCommand: 'toggleCodeBlock' },
  { label: '/link', replacement: '', description: 'Insert link', apiCommand: 'insertLink' },
  { label: '/highlight', replacement: '', description: 'Toggle highlight', apiCommand: 'toggleHighlight' },
  { label: '/task', replacement: '', description: 'Insert task annotation', isNodeInsertion: true },
  { label: '/comment', replacement: '', description: 'Insert comment annotation', isNodeInsertion: true },
  { label: '/reference', replacement: '', description: 'Insert reference annotation', isNodeInsertion: true },
  { label: '/cite', replacement: '', description: 'Insert citation', isNodeInsertion: true },
  { label: '/footnote', replacement: '', description: 'Insert footnote', isNodeInsertion: true },
  { label: '/image', replacement: '', description: 'Insert image', isNodeInsertion: true },
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
  return menu;
}

function createMenuItem(cmd: SlashCommand, index: number, isSelected: boolean): HTMLElement {
  const item = document.createElement('div');
  item.className = `slash-menu-item${isSelected ? ' selected' : ''}`;
  item.dataset.index = String(index);

  const labelSpan = document.createElement('span');
  labelSpan.className = 'slash-menu-item-label';
  labelSpan.textContent = cmd.label;

  const descSpan = document.createElement('span');
  descSpan.className = 'slash-menu-item-description';
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
  filteredCommands = slashCommands.filter((cmd) => cmd.label.toLowerCase().startsWith(`/${query}`));

  if (filteredCommands.length === 0) {
    const noResults = document.createElement('div');
    noResults.className = 'slash-menu-empty';
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
    item.classList.toggle('selected', i === selectedIndex);
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
      // Insert annotation atom node
      const annotationType = cmd.label.slice(1) as AnnotationType;
      const nodeType = annotationNode.type(editorInstance.ctx);

      const attrs: AnnotationAttrs = { type: annotationType, isCompleted: false, text: '' };
      const node = nodeType.create(attrs);

      // Delete the slash command and insert the annotation node inline
      let tr = view.state.tr.delete(cmdStart, from);
      tr = tr.insert(cmdStart, node);

      // Position cursor after the atom node
      tr = tr.setSelection(Selection.near(tr.doc.resolve(cmdStart + node.nodeSize)));

      view.dispatch(tr);

      // Open popup for editing after insertion
      showAnnotationEditPopup(cmdStart, view, attrs);

      // Don't set pendingSlashUndo - popup edit is a separate user action
      if (slashProviderInstance) {
        slashProviderInstance.hide();
      }
      filteredCommands = [];
      requestAnimationFrame(() => {
        suppressSlashMenu = false;
      });
      return; // Early return to skip pendingSlashUndo
    } else if (cmd.label === '/footnote') {
      // Insert footnote reference node — single transaction (delete slash + insert + renumber)
      insertFootnoteWithDelete(view, editorInstance, cmdStart, from);
    } else if (cmd.apiCommand) {
      // API-based commands: delete slash text, then call the FinalFinal API method
      const tr = view.state.tr.delete(cmdStart, from);
      view.dispatch(tr);
      // Call the API method after the slash text is deleted
      const fn = (window.FinalFinal as any)[cmd.apiCommand];
      if (typeof fn === 'function') fn();
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
    } else if (cmd.label === '/image') {
      // Delete the /image slash text from the document
      const tr = view.state.tr.delete(cmdStart, from);
      view.dispatch(tr);
      // Request native file picker via Swift bridge
      (window as any).webkit?.messageHandlers?.requestImagePicker?.postMessage({});
      // Hide menu and return early (file picker is async, not undoable)
      if (slashProviderInstance) {
        slashProviderInstance.hide();
      }
      filteredCommands = [];
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
