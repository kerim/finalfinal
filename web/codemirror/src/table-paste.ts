import type { EditorView } from '@codemirror/view';
import type { ParsedTable } from '../../shared/format-table';
import { formatTable, parseHTMLTable, parseTSV } from '../../shared/format-table';

// MARK: - Constants

const MAX_ROWS = 1000;
const MAX_COLS = 100;

// MARK: - Helpers

function truncateParsedTable(table: ParsedTable): { table: ParsedTable; truncated: boolean } {
  const origRows = table.rows.length;
  const origCols = table.header.length;
  let truncated = false;

  let header = table.header;
  let separator = table.separator;
  let rows = table.rows;

  if (origCols > MAX_COLS) {
    header = header.slice(0, MAX_COLS);
    separator = separator.slice(0, MAX_COLS);
    rows = rows.map((r) => r.slice(0, MAX_COLS));
    truncated = true;
  }

  if (origRows > MAX_ROWS) {
    rows = rows.slice(0, MAX_ROWS);
    truncated = true;
  }

  return { table: { header, separator, rows }, truncated };
}

// MARK: - Public Handler

/**
 * Handle a ClipboardEvent for TSV or HTML table content.
 *
 * Detection precedence:
 * 1. text/html containing <table> → parseHTMLTable
 * 2. text/plain containing \t with ≥2 rows → parseTSV
 *
 * Returns true if the paste was handled (caller should call event.preventDefault()).
 * Returns false to fall through to default paste handling.
 */
export function handleTablePaste(event: ClipboardEvent, view: EditorView): boolean {
  const clipboard = event.clipboardData;
  if (!clipboard) return false;

  let parsed: ParsedTable | null = null;

  // Try HTML first
  const html = clipboard.getData('text/html');
  if (html && html.includes('<table')) {
    parsed = parseHTMLTable(html);
  }

  // Fall back to TSV
  if (!parsed) {
    const text = clipboard.getData('text/plain');
    if (text && text.includes('\t')) {
      parsed = parseTSV(text);
    }
  }

  if (!parsed) return false;

  const origRows = parsed.rows.length;
  const origCols = parsed.header.length;

  const { table, truncated } = truncateParsedTable(parsed);

  const { head } = view.state.selection.main;
  const curLine = view.state.doc.lineAt(head);
  const insideTable = curLine.text.trimStart().startsWith('|');

  if (insideTable) {
    // Inside a cell: flatten multi-row content to plain text
    const allCells = [table.header, ...table.rows].flat().join(' ');
    const plainText = allCells.replace(/\s+/g, ' ').trim();
    view.dispatch({ changes: { from: head, to: head, insert: plainText } });
  } else {
    // Outside a table: insert as a new block after the current line
    const tableStr = formatTable(table);
    const insertPos = curLine.to;
    view.dispatch({
      changes: { from: insertPos, to: insertPos, insert: '\n\n' + tableStr },
      selection: { anchor: insertPos + 2 },
    });
  }

  if (truncated) {
    (window as any).webkit?.messageHandlers?.tableInsertTruncated?.postMessage({
      rows: origRows,
      cols: origCols,
    });
  }

  return true;
}
