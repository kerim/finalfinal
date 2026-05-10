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

import type { Node as PMNode, Schema } from '@milkdown/kit/prose/model';
import { Plugin, PluginKey, TextSelection } from '@milkdown/kit/prose/state';
import type { EditorView } from '@milkdown/kit/prose/view';
import { $prose } from '@milkdown/kit/utils';
import type { ParsedTable } from '../../shared/format-table';
import { formatTable, parseHTMLTable, parseTSV, truncateParsedTable } from '../../shared/format-table';

// MARK: - Helpers

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
  const tableType = schema.nodes.table;
  const tableRowType = schema.nodes.table_row;
  const tableHeaderType = schema.nodes.table_header;
  const tableCellType = schema.nodes.table_cell;
  const paragraphType = schema.nodes.paragraph;

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
  const bodyRows = table.rows.map((row) =>
    tableRowType.create(
      null,
      row.map((cell, i) => tableCellType.create({ align: table.separator[i] ?? null }, toInlineNodes(cell)))
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
  const paragraphType = schema.nodes.paragraph;
  const tableStr = formatTable(table);
  const { from } = view.state.selection;
  const $from = view.state.doc.resolve(from);
  const insertPos = $from.after(1);

  if (paragraphType) {
    const fallbackPara = paragraphType.create(null, schema.text(tableStr));
    view.dispatch(view.state.tr.insert(insertPos, fallbackPara));
  } else {
    // Last resort: raw insertText
    view.dispatch(view.state.tr.insertText(`\n\n${tableStr}\n`, insertPos));
  }
}

// MARK: - Inline link builders

// Primary path: extract text + link marks from text/html clipboard data.
// Milkdown (and all rendered sources) puts the link href only in text/html <a> elements;
// text/plain carries just the visible label with no URL.
function buildInlineContentFromHTML(html: string, schema: Schema): PMNode[] | null {
  if (!html.includes('<a ')) return null;
  try {
    const doc = new DOMParser().parseFromString(html, 'text/html');
    const linkMark = schema.marks.link;
    const nodes: PMNode[] = [];
    let hasLinks = false;

    const walkNode = (node: globalThis.Node): void => {
      if (node.nodeType === 3 /* TEXT_NODE */) {
        const t = (node.textContent ?? '').replace(/\s+/g, ' ');
        if (t.trim()) nodes.push(schema.text(t));
      } else if ((node as Element).tagName === 'A') {
        const href = (node as HTMLAnchorElement).getAttribute('href') ?? '';
        const t = (node.textContent ?? '').replace(/\s+/g, ' ').trim();
        if (t) {
          hasLinks = true;
          nodes.push(schema.text(t, linkMark && href ? [linkMark.create({ href })] : []));
        }
      } else {
        Array.from(node.childNodes).forEach(walkNode);
      }
    };

    Array.from(doc.body.childNodes).forEach(walkNode);
    return hasLinks ? nodes : null;
  } catch {
    return null;
  }
}

// Fallback path: scan text/plain for [text](url) markdown syntax or bare https?:// URLs.
// Used when the source is a plain-text editor (CodeMirror, terminal, TextEdit).
function buildInlineContent(text: string, schema: Schema): PMNode[] {
  // Matches [text](url "title"), OR bare https?:// URLs.
  // Alternation is left-to-right: markdown link is tried first, so a URL inside
  // [text](url) is consumed by group 2 and never re-matched by group 4.
  const re = /\[([^\]]+)\]\(([^)\s]+)(?:\s+"([^"]*)")?\)|(https?:\/\/[^\s]+)/g;
  const nodes: PMNode[] = [];
  let last = 0;
  const linkMark = schema.marks.link;
  for (const m of text.matchAll(re)) {
    const idx = m.index;
    if (idx > last) nodes.push(schema.text(text.slice(last, idx)));
    if (m[4] !== undefined) {
      // bare URL
      nodes.push(schema.text(m[4], linkMark ? [linkMark.create({ href: m[4] })] : []));
    } else {
      // [text](url) markdown link
      // m[3] is empty-string for title="" syntax; omitting matches remark/cmark behavior
      const attrs = m[3] ? { href: m[2], title: m[3] } : { href: m[2] };
      nodes.push(schema.text(m[1], linkMark ? [linkMark.create(attrs)] : []));
    }
    last = idx + m[0].length;
  }
  if (last < text.length) nodes.push(schema.text(text.slice(last)));
  return nodes;
}

// MARK: - Inside-cell paste handler (shared between DOM listener and handlePaste)

// Returns true if we handled the paste, false if the caller should fall through.
// Caller is responsible for stopping the event when this returns true.
function handleInsideCellPaste(view: EditorView, html: string, text: string): boolean {
  let parsed: ParsedTable | null = null;
  if (html?.includes('<table')) parsed = parseHTMLTable(html);
  if (!parsed && text && text.includes('\t')) parsed = parseTSV(text);

  const plain = parsed
    ? [parsed.header, ...parsed.rows].flat().join(' ').replace(/\s+/g, ' ').trim()
    : (text || html.replace(/<[^>]+>/g, '')).replace(/\s+/g, ' ').trim();

  // Forward bias (1) keeps the resolved position inside the cell
  // at table-closing boundaries where default bias could jump outside.
  const $head = view.state.doc.resolve(view.state.selection.head);
  let tr = view.state.tr.setSelection(TextSelection.near($head, 1));
  if (plain) {
    const { from, to } = tr.selection;
    // HTML extraction first: handles Milkdown-internal copies and all rendered
    // sources where the href lives in text/html <a> elements, not text/plain.
    // Markdown regex fallback: handles plain-text sources (CodeMirror, terminal).
    // Skip HTML extraction for table pastes — plain is already flattened cells.
    const inlineNodes =
      (!parsed && buildInlineContentFromHTML(html, view.state.schema)) || buildInlineContent(plain, view.state.schema);
    tr = tr.replaceWith(from, to, inlineNodes);
  }
  view.dispatch(tr);
  return true;
}

// MARK: - Plugin

export const tablePastePlugin = $prose(() => {
  return new Plugin({
    key: new PluginKey('table-paste'),
    // view() installs a DOM-level paste listener with capture:true so we run BEFORE
    // ProseMirror's plugin chain. Necessary because handlePaste (below) is never
    // invoked for inside-cell pastes — some upstream plugin or ProseMirror itself
    // short-circuits the chain. The listener handles only inside-cell pastes;
    // outside-cell table-creation stays in handlePaste because it is not the
    // failing path.
    view(editorView) {
      const handler = (e: ClipboardEvent) => {
        const clipboard = e.clipboardData;
        if (!clipboard) return;
        if (!isInsideTable(editorView)) return;

        // Defer image pastes to imagePasteDropPlugin. Use clipboardData.items
        // (matching imagePasteDropPlugin's detection in image-plugin.ts:556-563),
        // not clipboardData.types — Safari/WebKit can surface a payload with
        // types: ["Files"] and no `image/*` entry while items still contains
        // type: "image/png".
        const hasImage = Array.from(clipboard.items ?? []).some((item) => item.type.startsWith('image/'));
        if (hasImage) return;

        const html = clipboard.getData('text/html');
        const text = clipboard.getData('text/plain');

        e.preventDefault();
        e.stopImmediatePropagation();

        handleInsideCellPaste(editorView, html, text);
      };

      editorView.dom.addEventListener('paste', handler, true);
      return {
        destroy() {
          editorView.dom.removeEventListener('paste', handler, true);
        },
      };
    },
    props: {
      handlePaste(view, event, _slice) {
        try {
          const clipboard = event.clipboardData;
          if (!clipboard) return false;

          const html = clipboard.getData('text/html');
          const text = clipboard.getData('text/plain');

          // Defense-in-depth: if ProseMirror does invoke handlePaste for an
          // inside-cell paste despite the DOM listener, handle it here rather
          // than falling through to Milkdown's clipboard plugin.
          if (isInsideTable(view)) {
            return handleInsideCellPaste(view, html, text);
          }

          // Outside a table: only insert a column-creating table for genuine sources.
          // Require ≥2 columns AND ≥1 data row so single-line "col1\tcol2" pastes
          // don't create header-only zero-row tables.
          let parsed: ParsedTable | null = null;
          if (html?.includes('<table')) parsed = parseHTMLTable(html);
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
          } catch {
            insertTableMarkdown(view, table);
          }

          if (truncated) {
            (window as any).webkit?.messageHandlers?.tableInsertTruncated?.postMessage({
              rows: origRows,
              cols: origCols,
            });
          }

          return true;
        } catch {
          return false;
        }
      },
    },
  });
});
