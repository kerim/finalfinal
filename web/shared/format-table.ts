/**
 * Shared GFM pipe table formatting utility.
 *
 * Provides compact (unpadded) GFM pipe table output, plus parsers for
 * TSV and HTML table content. Used by the Milkdown block-sync serializer,
 * both paste handlers, and the CodeMirror formatTable() command.
 *
 * Separator cells use single-dash forms (`-`, `:-`, `-:`, `:-:`) to match
 * the output of mdast-util-gfm-table when tablePipeAlign: false.
 */

// MARK: - Types

export type Align = 'left' | 'center' | 'right' | null;

export interface ParsedTable {
  /** Cell text strings for the header row (already-serialized inline content). */
  header: string[];
  /** Per-column alignment. */
  separator: Align[];
  /** Body rows: array of arrays of cell text strings. */
  rows: string[][];
}

// MARK: - Formatting

/**
 * Format a ParsedTable into a compact GFM pipe table string.
 *
 * Cells are not padded. Separator cells use single-dash forms to match
 * mdast-util-gfm-table's tablePipeAlign: false output (markdown-table@3.0.4
 * uses size=1 when alignDelimiters=false).
 */
export function formatTable(table: ParsedTable): string {
  const { header, separator, rows } = table;

  const formatRow = (cells: string[]): string => `| ${cells.map((c) => c ?? '').join(' | ')} |`;

  const formatSeparator = (align: Align): string => {
    switch (align) {
      case 'left':
        return ':-';
      case 'right':
        return '-:';
      case 'center':
        return ':-:';
      default:
        return '-';
    }
  };

  const headerLine = formatRow(header);
  const separatorLine = `| ${separator.map(formatSeparator).join(' | ')} |`;
  const bodyLines = rows.map(formatRow);

  return [headerLine, separatorLine, ...bodyLines].join('\n');
}

// MARK: - Truncation

export const MAX_TABLE_ROWS = 1000;
export const MAX_TABLE_COLS = 100;

/**
 * Truncate a ParsedTable to MAX_TABLE_ROWS × MAX_TABLE_COLS.
 * Returns the (possibly truncated) table and a flag indicating whether
 * truncation occurred. The originals' dimensions are the caller's
 * responsibility to capture before calling this function if needed for
 * reporting.
 */
export function truncateParsedTable(table: ParsedTable): { table: ParsedTable; truncated: boolean } {
  let header = table.header;
  let separator = table.separator;
  let rows = table.rows;
  let truncated = false;

  if (header.length > MAX_TABLE_COLS) {
    header = header.slice(0, MAX_TABLE_COLS);
    separator = separator.slice(0, MAX_TABLE_COLS);
    rows = rows.map((r) => r.slice(0, MAX_TABLE_COLS));
    truncated = true;
  }
  if (rows.length > MAX_TABLE_ROWS) {
    rows = rows.slice(0, MAX_TABLE_ROWS);
    truncated = true;
  }

  return { table: { header, separator, rows }, truncated };
}

// MARK: - TSV Parser

/**
 * Compute the mode (most common value) of an array of numbers.
 * If there is a tie, returns the value that was first seen.
 * Map preserves insertion order, so first-seen wins on ties.
 */
function mode(values: number[]): number {
  const counts = new Map<number, number>();
  for (const v of values) {
    counts.set(v, (counts.get(v) ?? 0) + 1);
  }
  let modeValue = values[0];
  let maxCount = 0;
  for (const [v, count] of counts) {
    if (count > maxCount) {
      maxCount = count;
      modeValue = v;
    }
  }
  return modeValue;
}

/**
 * Strip trailing empty strings from a cell array.
 * Handles spreadsheet apps that emit trailing tab characters.
 */
function trimTrailingEmpty(cells: string[]): string[] {
  let end = cells.length;
  while (end > 0 && cells[end - 1] === '') {
    end--;
  }
  return cells.slice(0, end);
}

/**
 * Normalize an array of rows to a consistent column count using the mode.
 * Rows with fewer cells are padded with empty strings; rows with more are
 * truncated.
 */
function normalizeColumnCount(rawRows: string[][]): { rows: string[][]; columnCount: number } {
  const counts = rawRows.map((r) => r.length);
  const columnCount = mode(counts);
  const rows = rawRows.map((row) => {
    if (row.length === columnCount) return row;
    if (row.length < columnCount) {
      return [...row, ...new Array(columnCount - row.length).fill('')];
    }
    return row.slice(0, columnCount);
  });
  return { rows, columnCount };
}

/**
 * Parse tab-delimited text into a ParsedTable.
 *
 * Returns null if the input has fewer than 2 rows or fewer than 1 column.
 * All alignment values are null (TSV carries no alignment information).
 *
 * Column count is determined by the mode across all rows, so a stray
 * trailing tab does not widen the whole table.
 */
export function parseTSV(tsv: string): ParsedTable | null {
  const lines = tsv.split('\n');

  const rawRows: string[][] = [];
  for (const line of lines) {
    if (line === '') continue;
    const cells = trimTrailingEmpty(line.split('\t'));
    if (cells.length === 0) continue;
    rawRows.push(cells);
  }

  // Need at least header + 1 body row, and at least 1 column
  if (rawRows.length < 2) return null;

  const { rows: normalizedRows, columnCount } = normalizeColumnCount(rawRows);
  if (columnCount < 1) return null;

  const [headerRow, ...bodyRows] = normalizedRows;
  const separator: Align[] = new Array(columnCount).fill(null);

  return {
    header: headerRow,
    separator,
    rows: bodyRows,
  };
}

// MARK: - HTML Table Parser

/**
 * Strip all HTML tags from a string.
 */
function stripTags(html: string): string {
  return html.replace(/<[^>]+>/g, '');
}

/**
 * Decode common HTML entities.
 */
function decodeEntities(str: string): string {
  return str
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'");
}

/**
 * Extract the text content of an HTML cell string (tag-stripped, decoded, trimmed).
 */
function cellText(cellHtml: string): string {
  return decodeEntities(stripTags(cellHtml)).trim();
}

/**
 * Extract all occurrences of content between a given HTML tag pair using
 * indexOf-based string splitting (no DOMParser — works in Node and WebView).
 *
 * Returns an array of inner-HTML strings (without the wrapping tags).
 */
function extractTags(html: string, tag: string): string[] {
  const results: string[] = [];
  const lowerHtml = html.toLowerCase();
  const lowerTag = tag.toLowerCase();
  const closeTag = `</${lowerTag}>`;

  let searchFrom = 0;

  while (searchFrom < html.length) {
    // Find the next opening tag (may have attributes)
    const openStart = lowerHtml.indexOf(`<${lowerTag}`, searchFrom);
    if (openStart === -1) break;

    // Find the closing '>' of the opening tag
    const openEnd = lowerHtml.indexOf('>', openStart);
    if (openEnd === -1) break;

    const innerStart = openEnd + 1;

    // Find the matching closing tag
    const closeStart = lowerHtml.indexOf(closeTag, innerStart);
    if (closeStart === -1) {
      // Unclosed tag — take everything to end of string
      results.push(html.slice(innerStart));
      break;
    }

    results.push(html.slice(innerStart, closeStart));
    searchFrom = closeStart + closeTag.length;
  }

  return results;
}

/**
 * Parse an HTML `<table>` string into a ParsedTable.
 *
 * Rules:
 * - Uses the first `<table>` found in the input.
 * - The first `<tr>` that contains `<th>` cells is the header row.
 * - If no `<th>` is found, the first `<tr>` is treated as the header.
 * - Column count is normalized using the mode across all rows.
 * - Returns null if no rows or no cells are found.
 *
 * This implementation uses string splitting only — no DOMParser —
 * so it works in both Node (tests) and WebView contexts.
 */
export function parseHTMLTable(html: string): ParsedTable | null {
  // Extract the first <table>...</table>
  const tableContents = extractTags(html, 'table');
  if (tableContents.length === 0) return null;
  const tableHtml = tableContents[0];

  // Extract all <tr> rows
  const trContents = extractTags(tableHtml, 'tr');
  if (trContents.length === 0) return null;

  // For each row, extract <th> and <td> cells
  const parsedRows: Array<{ cells: string[]; hasHeader: boolean }> = [];
  for (const trHtml of trContents) {
    const thCells = extractTags(trHtml, 'th').map(cellText);
    const tdCells = extractTags(trHtml, 'td').map(cellText);

    if (thCells.length > 0 && tdCells.length === 0) {
      // Pure header row
      parsedRows.push({ cells: thCells, hasHeader: true });
    } else if (thCells.length > 0 && tdCells.length > 0) {
      // Mixed row — treat all as one row, th first
      parsedRows.push({ cells: [...thCells, ...tdCells], hasHeader: true });
    } else if (tdCells.length > 0) {
      parsedRows.push({ cells: tdCells, hasHeader: false });
    }
    // Skip empty rows
  }

  if (parsedRows.length === 0) return null;

  // Determine header row: first row with hasHeader, else first row
  const headerIndex = parsedRows.findIndex((r) => r.hasHeader);
  const effectiveHeaderIndex = headerIndex === -1 ? 0 : headerIndex;

  // Split into header and body
  const headerCells = parsedRows[effectiveHeaderIndex].cells;
  const bodyRows = parsedRows
    .slice(effectiveHeaderIndex + 1)
    .filter((r) => !r.hasHeader || effectiveHeaderIndex === 0)
    .map((r) => r.cells);

  if (headerCells.length === 0) return null;

  // Normalize column count using mode across header + body
  const allRaw = [headerCells, ...bodyRows];
  const { rows: normalized, columnCount } = normalizeColumnCount(allRaw);

  if (columnCount < 1 || normalized.length < 1) return null;

  const [normalizedHeader, ...normalizedBody] = normalized;
  const separator: Align[] = new Array(columnCount).fill(null);

  return {
    header: normalizedHeader,
    separator,
    rows: normalizedBody,
  };
}
