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
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { formatTable, parseHTMLTable, parseTSV } from '../../shared/format-table';
import type { ParsedTable } from '../../shared/format-table';

// MARK: - Constants

const MAX_ROWS = 1000;
const MAX_COLS = 100;

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

          // Detection: HTML table first, then TSV.
          let parsed: ParsedTable | null = null;

          const html = clipboard.getData('text/html');
          if (html && html.includes('<table')) {
            parsed = parseHTMLTable(html);
          }

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

          if (isInsideTable(view)) {
            // Inside a cell: flatten multi-row content to plain text.
            const allCells = [table.header, ...table.rows].flat().join(' ');
            const plainText = allCells.replace(/\s+/g, ' ').trim();
            const tr = view.state.tr.insertText(plainText);
            view.dispatch(tr);
          } else {
            // Outside a table: insert as real PM table nodes.
            try {
              const succeeded = insertTableNode(view, table);
              if (!succeeded) {
                insertTableMarkdown(view, table);
              }
            } catch (schemaErr) {
              console.error('[table-paste] schema-based insertion failed, falling back:', schemaErr);
              insertTableMarkdown(view, table);
            }
          }

          if (truncated) {
            (window as any).webkit?.messageHandlers?.tableInsertTruncated?.postMessage({
              rows: origRows,
              cols: origCols,
            });
          }

          return true;
        } catch (err) {
          console.error('[table-paste] handlePaste error:', err);
          return false;
        }
      },
    },
  })
);
