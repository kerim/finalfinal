/**
 * Table paste plugin for Milkdown.
 *
 * Intercepts clipboard paste events before the clipboard plugin, detects
 * TSV and HTML table content, and inserts GFM tables as real ProseMirror
 * table nodes. Falls back to raw markdown text if the schema-based path
 * fails (e.g. schema does not declare expected node types).
 *
 * Registration: must appear BEFORE .use(clipboard) in main.ts.
 */

import { $prose } from '@milkdown/kit/utils';
import { Plugin, PluginKey, TextSelection } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { formatTable, parseHTMLTable, parseTSV } from '../../shared/format-table';
import type { ParsedTable } from '../../shared/format-table';

// MARK: - Constants

const MAX_ROWS = 1000;
const MAX_COLS = 100;

// MARK: - Diagnostics (mirrors table-tools-plugin.ts pattern)

const log = (...args: unknown[]) => {
  const msg = '[table-paste] ' + args
    .map((a) => {
      if (typeof a === 'string') return a;
      try { return JSON.stringify(a); } catch { return String(a); }
    })
    .join(' ');
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const handler = (window as any).webkit?.messageHandlers?.errorHandler;
  if (handler?.postMessage) handler.postMessage({ type: 'debug', message: msg });
  else console.log(msg);
};

// MARK: - Helpers

function truncateParsedTable(table: ParsedTable): { table: ParsedTable; truncated: boolean } {
  let header = table.header;
  let separator = table.separator;
  let rows = table.rows;
  let truncated = false;

  if (header.length > MAX_COLS) {
    header = header.slice(0, MAX_COLS);
    separator = separator.slice(0, MAX_COLS);
    rows = rows.map(r => r.slice(0, MAX_COLS));
    truncated = true;
  }
  if (rows.length > MAX_ROWS) {
    rows = rows.slice(0, MAX_ROWS);
    truncated = true;
  }

  return { table: { header, separator, rows }, truncated };
}

function isInsideTable(view: EditorView): boolean {
  const { head } = view.state.selection;
  const $head = view.state.doc.resolve(head);
  for (let d = $head.depth; d >= 0; d--) {
    if ($head.node(d).type.name === 'table') return true;
  }
  return false;
}

// MARK: - Schema-based insertion

/**
 * Build and insert a real ProseMirror table node using the editor schema.
 * Returns true if insertion succeeded, false if the schema lacks required types.
 */
function insertTableNode(view: EditorView, table: ParsedTable): boolean {
  const { schema } = view.state;
  const tableType = schema.nodes['table'];
  const tableRowType = schema.nodes['table_row'];
  const tableHeaderType = schema.nodes['table_header'];
  const tableCellType = schema.nodes['table_cell'];
  const paragraphType = schema.nodes['paragraph'];

  if (!tableType || !tableRowType || !tableHeaderType || !tableCellType || !paragraphType) {
    return false;
  }

  // Wrap inline text in a paragraph; empty cell gets an empty paragraph.
  const toInlineNodes = (text: string) => {
    if (!text) return [paragraphType.create()];
    return [paragraphType.create(null, schema.text(text))];
  };

  // Header row
  const headerCells = table.header.map((h, i) =>
    tableHeaderType.create({ align: table.separator[i] ?? null }, toInlineNodes(h))
  );
  const headerRow = tableRowType.create(null, headerCells);

  // Body rows
  const bodyRows = table.rows.map(row =>
    tableRowType.create(
      null,
      row.map((cell, i) =>
        tableCellType.create({ align: table.separator[i] ?? null }, toInlineNodes(cell))
      )
    )
  );

  const tableNode = tableType.create(null, [headerRow, ...bodyRows]);

  const { from } = view.state.selection;
  const $from = view.state.doc.resolve(from);
  const insertPos = $from.after(1);
  const tr = view.state.tr.insert(insertPos, tableNode);
  view.dispatch(tr);
  return true;
}

/**
 * Fallback: insert the table as raw markdown text in a paragraph.
 * Block-sync will re-parse it on the next poll cycle.
 */
function insertTableMarkdown(view: EditorView, table: ParsedTable): void {
  const { schema } = view.state;
  const paragraphType = schema.nodes['paragraph'];
  const tableStr = formatTable(table);
  const { from } = view.state.selection;
  const $from = view.state.doc.resolve(from);
  const insertPos = $from.after(1);

  if (paragraphType) {
    const fallbackPara = paragraphType.create(null, schema.text(tableStr));
    view.dispatch(view.state.tr.insert(insertPos, fallbackPara));
  } else {
    // Last resort: raw insertText
    view.dispatch(view.state.tr.insertText('\n\n' + tableStr + '\n', insertPos));
  }
}

// MARK: - Plugin

export const tablePastePlugin = $prose(() =>
  new Plugin({
    key: new PluginKey('table-paste'),
    props: {
      handlePaste(view, event, _slice) {
        try {
          const clipboard = event.clipboardData;
          if (!clipboard) return false;

          const html = clipboard.getData('text/html');
          const text = clipboard.getData('text/plain');
          const insideCell = isInsideTable(view);
          log('handlePaste', {
            insideCell,
            htmlLen: html.length,
            textLen: text.length,
            hasTable: html.includes('<table'),
            hasTab: text.includes('\t'),
            sel: { from: view.state.selection.from, to: view.state.selection.to },
          });

          if (insideCell) {
            // Always handle inside a cell — never let Milkdown's clipboard plugin run.
            // Handles both plain-text pastes (parsed=null) and table/TSV pastes.
            let parsed: ParsedTable | null = null;
            if (html && html.includes('<table')) parsed = parseHTMLTable(html);
            if (!parsed && text && text.includes('\t')) parsed = parseTSV(text);

            const plain = parsed
              ? [parsed.header, ...parsed.rows].flat().join(' ').replace(/\s+/g, ' ').trim()
              : (text || html.replace(/<[^>]+>/g, '')).replace(/\s+/g, ' ').trim();

            // Forward bias (1) keeps the resolved position inside the cell
            // at table-closing boundaries where default bias could jump outside.
            const $head = view.state.doc.resolve(view.state.selection.head);
            let tr = view.state.tr.setSelection(TextSelection.near($head, 1));
            tr = tr.insertText(plain);
            view.dispatch(tr);
            log('inside-cell handled', { plainLen: plain.length });
            return true;
          }

          // Outside a table: only insert a column-creating table for genuine sources.
          // Require ≥2 columns AND ≥1 data row so single-line "col1\tcol2" pastes
          // don't create header-only zero-row tables.
          let parsed: ParsedTable | null = null;
          if (html && html.includes('<table')) parsed = parseHTMLTable(html);
          if (!parsed && text && text.includes('\t')) {
            const tsv = parseTSV(text);
            if (tsv && tsv.header.length >= 2 && tsv.rows.length >= 1) parsed = tsv;
          }
          if (!parsed) return false;

          const origRows = parsed.rows.length;
          const origCols = parsed.header.length;
          const { table, truncated } = truncateParsedTable(parsed);

          try {
            const succeeded = insertTableNode(view, table);
            if (!succeeded) insertTableMarkdown(view, table);
          } catch (schemaErr) {
            log('schema insertion failed, falling back', schemaErr);
            insertTableMarkdown(view, table);
          }

          if (truncated) {
            (window as any).webkit?.messageHandlers?.tableInsertTruncated?.postMessage({
              rows: origRows,
              cols: origCols,
            });
          }

          return true;
        } catch (err) {
          log('handlePaste error', err);
          return false;
        }
      },
    },
  })
);
