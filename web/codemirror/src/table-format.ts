import type { EditorView } from '@codemirror/view';
import type { Align, ParsedTable } from '../../shared/format-table';
import { formatTable } from '../../shared/format-table';
import { getEditorView } from './editor-state';

// MARK: - Helpers

function isTableLine(text: string): boolean {
  return text.trimStart().startsWith('|');
}

function findTableRange(view: EditorView): { from: number; to: number } | null {
  const { head } = view.state.selection.main;
  const doc = view.state.doc;
  const curLine = doc.lineAt(head);
  if (!isTableLine(curLine.text)) return null;

  let startNum = curLine.number;
  while (startNum > 1 && isTableLine(doc.line(startNum - 1).text)) startNum--;

  let endNum = curLine.number;
  while (endNum < doc.lines && isTableLine(doc.line(endNum + 1).text)) endNum++;

  return { from: doc.line(startNum).from, to: doc.line(endNum).to };
}

function parseGFMTable(md: string): ParsedTable | null {
  const lines = md.split('\n').filter((l) => isTableLine(l));
  if (lines.length < 2) return null;

  const splitRow = (line: string): string[] =>
    line
      .split('|')
      .slice(1, -1)
      .map((s) => s.trim());

  const header = splitRow(lines[0]);
  const sepCells = splitRow(lines[1]);

  // Validate separator row
  if (!sepCells.every((s) => /^:?-+:?$/.test(s.replace(/\s/g, '')))) return null;

  const separator: Align[] = sepCells.map((s) => {
    const t = s.trim();
    if (t.startsWith(':') && t.endsWith(':')) return 'center';
    if (t.startsWith(':')) return 'left';
    if (t.endsWith(':')) return 'right';
    return null;
  });

  const rows = lines.slice(2).map(splitRow);
  return { header, separator, rows };
}

// MARK: - Public Commands

/**
 * Walk lines outward from cursor to find the table block, parse it as a GFM
 * table, reformat with aligned columns, and replace in one transaction.
 */
export function formatTableCommand(): void {
  const view = getEditorView();
  if (!view) return;
  const range = findTableRange(view);
  if (!range) return;
  const tableStr = view.state.sliceDoc(range.from, range.to);
  const parsed = parseGFMTable(tableStr);
  if (!parsed) return;
  const formatted = formatTable(parsed);
  if (formatted === tableStr) return;
  view.dispatch({ changes: { from: range.from, to: range.to, insert: formatted } });
}

/**
 * Insert a default GFM table with the given dimensions after the current line.
 * Columns are named "Column 1", "Column 2", etc. Body cells are empty.
 */
export function insertTableCommand(rows: number, cols: number): void {
  const view = getEditorView();
  if (!view) return;

  const safeRows = Math.max(2, rows);
  const safeCols = Math.max(1, cols);

  const header: string[] = Array.from({ length: safeCols }, (_, i) => `Column ${i + 1}`);
  const separator: Align[] = Array.from({ length: safeCols }, () => null);
  const bodyRows: string[][] = Array.from({ length: safeRows - 1 }, () => Array.from({ length: safeCols }, () => ''));

  const tableStr = formatTable({ header, separator, rows: bodyRows });

  const { head } = view.state.selection.main;
  const line = view.state.doc.lineAt(head);
  const insertPos = line.to;

  view.dispatch({
    changes: { from: insertPos, to: insertPos, insert: `\n\n${tableStr}` },
    selection: { anchor: insertPos + 2 },
  });
}
