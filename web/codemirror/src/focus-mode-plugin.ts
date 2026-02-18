// Focus mode plugin for CodeMirror
// Dims all "blocks" (groups of consecutive non-empty lines) except the one
// containing the cursor, matching Milkdown's paragraph-dimming behavior.

import { RangeSetBuilder, StateEffect } from '@codemirror/state';
import { Decoration, type DecorationSet, type EditorView, ViewPlugin, type ViewUpdate } from '@codemirror/view';

// Module-level state (same pattern as Milkdown's focus-mode-plugin)
let focusModeEnabled = false;

export function setFocusModeEnabled(enabled: boolean) {
  focusModeEnabled = enabled;
}

export function isFocusModeEnabled(): boolean {
  return focusModeEnabled;
}

// StateEffect to signal toggle changes to the ViewPlugin
export const setFocusModeEffect = StateEffect.define<boolean>();

// Line decoration for dimmed lines
const dimmedDecoration = Decoration.line({ class: 'ff-dimmed' });

export const focusModePlugin = ViewPlugin.fromClass(
  class {
    decorations: DecorationSet;

    // Cache the current block's line range to avoid redundant rebuilds
    // when the cursor moves within the same block
    private currentBlockStart = -1;
    private currentBlockEnd = -1;

    constructor(view: EditorView) {
      this.decorations = this.buildDecorations(view);
    }

    update(update: ViewUpdate) {
      // Check for toggle effect
      const hasToggle = update.transactions.some((tr) => tr.effects.some((e) => e.is(setFocusModeEffect)));

      if (hasToggle || update.docChanged) {
        // Always rebuild on toggle or doc change
        this.decorations = this.buildDecorations(update.view);
        return;
      }

      if (update.selectionSet && focusModeEnabled) {
        // Only rebuild if cursor moved to a different block
        const cursorLine = update.view.state.doc.lineAt(update.view.state.selection.main.head).number;
        if (cursorLine < this.currentBlockStart || cursorLine > this.currentBlockEnd) {
          this.decorations = this.buildDecorations(update.view);
        }
      }
    }

    buildDecorations(view: EditorView): DecorationSet {
      if (!focusModeEnabled) {
        this.currentBlockStart = -1;
        this.currentBlockEnd = -1;
        return Decoration.none;
      }

      const doc = view.state.doc;
      const cursorPos = view.state.selection.main.head;
      const cursorLine = doc.lineAt(cursorPos);
      const cursorLineNum = cursorLine.number;

      // Find the block containing the cursor
      // A "block" is a group of consecutive non-empty lines separated by blank lines
      let blockStart: number;
      let blockEnd: number;

      if (cursorLine.text.trim() === '') {
        // Cursor is on a blank line — this single line is the "current block"
        blockStart = cursorLineNum;
        blockEnd = cursorLineNum;
      } else {
        // Walk backward to find block start
        blockStart = cursorLineNum;
        while (blockStart > 1) {
          const prevLine = doc.line(blockStart - 1);
          if (prevLine.text.trim() === '') break;
          blockStart--;
        }

        // Walk forward to find block end
        blockEnd = cursorLineNum;
        while (blockEnd < doc.lines) {
          const nextLine = doc.line(blockEnd + 1);
          if (nextLine.text.trim() === '') break;
          blockEnd++;
        }
      }

      // Cache for next update
      this.currentBlockStart = blockStart;
      this.currentBlockEnd = blockEnd;

      // Build decorations: dim all lines NOT in the current block
      // Iterate ALL lines (not just visibleRanges) to avoid scroll flicker
      const builder = new RangeSetBuilder<Decoration>();
      for (let i = 1; i <= doc.lines; i++) {
        if (i < blockStart || i > blockEnd) {
          const line = doc.line(i);
          builder.add(line.from, line.from, dimmedDecoration);
        }
      }

      return builder.finish();
    }
  },
  {
    decorations: (v) => v.decorations,
  }
);
