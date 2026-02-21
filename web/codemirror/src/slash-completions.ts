import type { CompletionContext, CompletionResult } from '@codemirror/autocomplete';
import type { EditorView } from '@codemirror/view';
import { getEditorView, setPendingCAYWRange, setPendingSlashUndo } from './editor-state';

// Slash command completions for section breaks and other commands
export function slashCompletions(context: CompletionContext): CompletionResult | null {
  const word = context.matchBefore(/\/\w*/);
  if (!word) return null;
  if (word.from === word.to && !context.explicit) return null;

  return {
    from: word.from,
    options: [
      {
        label: '/break',
        detail: 'Insert section break',
        apply: (_view: EditorView, _completion: any, from: number, to: number) => {
          getEditorView()?.dispatch({
            changes: { from, to, insert: '<!-- ::break:: -->\n\n' },
          });
          setPendingSlashUndo(true);
        },
      },
      {
        label: '/h1',
        detail: 'Heading 1',
        apply: (view: EditorView, _completion: any, from: number, to: number) => {
          // Transform entire line to heading
          const line = view.state.doc.lineAt(from);
          const lineText = line.text;

          // Calculate slash position from `from` parameter
          const slashPosInLine = from - line.from;
          // Use actual matched length (to - from) instead of hardcoded command length
          const matchedLength = to - from;

          // Extract text before slash and after the matched command
          const textBeforeSlash = lineText.slice(0, slashPosInLine);
          const textAfterCommand = lineText.slice(slashPosInLine + matchedLength);

          // Remove existing heading markers, concatenate directly (no join with space)
          const cleanBefore = textBeforeSlash.replace(/^#+\s*/, '');
          const combinedText = (cleanBefore + textAfterCommand).trim();

          // Replace entire line with new heading
          view.dispatch({
            changes: { from: line.from, to: line.to, insert: `# ${combinedText}` },
          });
          setPendingSlashUndo(true);
        },
      },
      {
        label: '/h2',
        detail: 'Heading 2',
        apply: (view: EditorView, _completion: any, from: number, to: number) => {
          // Transform entire line to heading
          const line = view.state.doc.lineAt(from);
          const lineText = line.text;

          // Calculate slash position from `from` parameter
          const slashPosInLine = from - line.from;
          // Use actual matched length (to - from) instead of hardcoded command length
          const matchedLength = to - from;

          // Extract text before slash and after the matched command
          const textBeforeSlash = lineText.slice(0, slashPosInLine);
          const textAfterCommand = lineText.slice(slashPosInLine + matchedLength);

          // Remove existing heading markers, concatenate directly (no join with space)
          const cleanBefore = textBeforeSlash.replace(/^#+\s*/, '');
          const combinedText = (cleanBefore + textAfterCommand).trim();

          // Replace entire line with new heading
          view.dispatch({
            changes: { from: line.from, to: line.to, insert: `## ${combinedText}` },
          });
          setPendingSlashUndo(true);
        },
      },
      {
        label: '/h3',
        detail: 'Heading 3',
        apply: (view: EditorView, _completion: any, from: number, to: number) => {
          // Transform entire line to heading
          const line = view.state.doc.lineAt(from);
          const lineText = line.text;

          // Calculate slash position from `from` parameter
          const slashPosInLine = from - line.from;
          // Use actual matched length (to - from) instead of hardcoded command length
          const matchedLength = to - from;

          // Extract text before slash and after the matched command
          const textBeforeSlash = lineText.slice(0, slashPosInLine);
          const textAfterCommand = lineText.slice(slashPosInLine + matchedLength);

          // Remove existing heading markers, concatenate directly (no join with space)
          const cleanBefore = textBeforeSlash.replace(/^#+\s*/, '');
          const combinedText = (cleanBefore + textAfterCommand).trim();

          // Replace entire line with new heading
          view.dispatch({
            changes: { from: line.from, to: line.to, insert: `### ${combinedText}` },
          });
          setPendingSlashUndo(true);
        },
      },
      {
        label: '/task',
        detail: 'Insert task annotation',
        apply: (view: EditorView, _completion: any, from: number, to: number) => {
          view.dispatch({
            changes: { from, to, insert: '<!-- ::task:: [ ]  -->' },
            selection: { anchor: from + 17 }, // Position cursor inside the task
          });
          setPendingSlashUndo(true);
        },
      },
      {
        label: '/comment',
        detail: 'Insert comment annotation',
        apply: (view: EditorView, _completion: any, from: number, to: number) => {
          view.dispatch({
            changes: { from, to, insert: '<!-- ::comment::  -->' },
            selection: { anchor: from + 17 }, // Position cursor inside the comment
          });
          setPendingSlashUndo(true);
        },
      },
      {
        label: '/reference',
        detail: 'Insert reference annotation',
        apply: (view: EditorView, _completion: any, from: number, to: number) => {
          view.dispatch({
            changes: { from, to, insert: '<!-- ::reference::  -->' },
            selection: { anchor: from + 19 }, // Position cursor inside the reference
          });
          setPendingSlashUndo(true);
        },
      },
      {
        label: '/footnote',
        detail: 'Insert footnote',
        apply: (view: EditorView, _completion: any, from: number, to: number) => {
          // Scan document for existing [^N] references to find max label
          const content = view.state.doc.toString();
          const refRegex = /\[\^(\d+)\](?!:)/g;
          let maxLabel = 0;
          let match;
          while ((match = refRegex.exec(content)) !== null) {
            const label = Number.parseInt(match[1], 10);
            if (!Number.isNaN(label) && label > maxLabel) {
              maxLabel = label;
            }
          }
          const newLabel = String(maxLabel + 1);
          console.log(`[DIAG-FN] CM /footnote: ${content.length} chars, maxLabel=${maxLabel}, newLabel=${newLabel}`);
          const firstRef = content.match(/\[\^(\d+)\](?!:)/);
          if (firstRef) {
            console.log(`[DIAG-FN] CM /footnote: first ref="${firstRef[0]}" at pos=${firstRef.index}`);
          } else {
            console.log('[DIAG-FN] CM /footnote: NO refs found!');
            const ni = content.indexOf('Notes');
            if (ni !== -1) console.log(`[DIAG-FN] CM Notes preview: ${JSON.stringify(content.slice(Math.max(0, ni - 50), ni + 150))}`);
          }
          const insertText = `[^${newLabel}]`;

          view.dispatch({
            changes: { from, to, insert: insertText },
            selection: { anchor: from + insertText.length },
          });
          setPendingSlashUndo(true);
        },
      },
      {
        label: '/cite',
        detail: 'Insert citation from Zotero',
        apply: (_view: EditorView, _completion: any, from: number, to: number) => {
          // Store the range to replace (the /cite text)
          setPendingCAYWRange({ start: from, end: to });
          // Call Swift to open CAYW picker
          if ((window as any).webkit?.messageHandlers?.openCitationPicker) {
            (window as any).webkit.messageHandlers.openCitationPicker.postMessage(from);
          } else {
            setPendingCAYWRange(null);
          }
        },
      },
    ],
  };
}
