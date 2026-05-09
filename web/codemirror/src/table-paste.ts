import type { EditorView } from '@codemirror/view';
import type { ParsedTable } from '../../shared/format-table';
import { formatTable, parseHTMLTable, parseTSV, truncateParsedTable } from '../../shared/format-table';

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
  if (html?.includes('<table')) {
    parsed = parseHTMLTable(html);
  }

  // Fall back to TSV — require ≥2 columns AND ≥1 data row (mirrors MW table-paste-plugin).
  if (!parsed) {
    const text = clipboard.getData('text/plain');
    if (text?.includes('\t')) {
      const tsv = parseTSV(text);
      if (tsv && tsv.header.length >= 2 && tsv.rows.length >= 1) parsed = tsv;
    }
  }

  if (!parsed) return false;

  const origRows = parsed.rows.length;
  const origCols = parsed.header.length;

  const { table, truncated } = truncateParsedTable(parsed);

  const { head } = view.state.selection.main;
  const curLine = view.state.doc.lineAt(head);
  // A line beginning with | is a pipe-table row. Also check the previous
  // non-blank line for | to catch continuation lines that may not start with |.
  const prevLineText = (() => {
    let lineNo = curLine.number - 1;
    while (lineNo >= 1) {
      const prev = view.state.doc.line(lineNo);
      if (prev.text.trim().length > 0) return prev.text;
      lineNo--;
    }
    return '';
  })();
  const insideTable = curLine.text.trimStart().startsWith('|') || prevLineText.trimStart().startsWith('|');

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
      changes: { from: insertPos, to: insertPos, insert: `\n\n${tableStr}` },
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
