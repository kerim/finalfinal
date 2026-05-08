/**
 * Shared GFM pipe table formatting utility.
 *
 * Provides column-width padding for GFM pipe tables, plus parsers for
 * TSV and HTML table content. Used by the Milkdown block-sync serializer,
 * both paste handlers, and the CodeMirror formatTable() command.
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
 * Returns the display width of a string, counted in Unicode code points.
 * Handles emoji correctly; CJK characters count as 1 (known limitation).
 */
function codePointLength(str: string): number {
  return [...str].length;
}

/**
 * Pad a string to the target width with trailing spaces.
 * If the string is already at or beyond targetWidth, it is returned as-is.
 */
function padEnd(str: string, targetWidth: number): string {
  const len = codePointLength(str);
  if (len >= targetWidth) return str;
  return str + ' '.repeat(targetWidth - len);
}

/**
 * Build the separator cell string for a given alignment and column width.
 * The dashes section is padded so the total entry fills the column width.
 *
 * Minimum column widths (to satisfy GFM's 3-dash minimum inside colons):
 *   null       → 3  (e.g. `---`)
 *   left/right → 4  (e.g. `:---` or `---:`)
 *   center     → 5  (e.g. `:---:`)
 */
function buildSeparatorCell(align: Align, columnWidth: number): string {
  switch (align) {
    case 'left': {
      // colon + dashes = columnWidth
      const dashes = columnWidth - 1;
      return ':' + '-'.repeat(dashes);
    }
    case 'right': {
      // dashes + colon = columnWidth
      const dashes = columnWidth - 1;
      return '-'.repeat(dashes) + ':';
    }
    case 'center': {
      // colon + dashes + colon = columnWidth; minimum 3 dashes
      const dashes = columnWidth - 2;
      return ':' + '-'.repeat(dashes) + ':';
    }
    default: {
      // null — just dashes
      return '-'.repeat(columnWidth);
    }
  }
}

/**
 * Minimum column width required for a given alignment to satisfy GFM's
 * 3-dash rule (the dashes portion inside any colons must be >= 3).
 */
function minColumnWidth(align: Align): number {
  switch (align) {
    case 'center':
      return 5; // :---: = 2 colons + 3 dashes
    case 'left':
    case 'right':
      return 4; // :--- or ---: = 1 colon + 3 dashes
    default:
      return 3; // --- = 3 dashes
  }
}

/**
 * Format a ParsedTable into a GFM pipe table string.
 *
 * Each column is padded to the maximum code-point width across all cells
 * (header + body), with a floor set by the alignment type.
 */
export function formatTable(table: ParsedTable): string {
  const { header, separator, rows } = table;
  const columnCount = header.length;

  // Compute per-column widths
  const widths: number[] = new Array(columnCount).fill(0);

  for (let col = 0; col < columnCount; col++) {
    const align = separator[col] ?? null;
    let width = minColumnWidth(align);
    width = Math.max(width, codePointLength(header[col] ?? ''));
    for (const row of rows) {
      width = Math.max(width, codePointLength(row[col] ?? ''));
    }
    widths[col] = width;
  }

  const formatRow = (cells: string[]): string => {
    const padded = widths.map((w, i) => padEnd(cells[i] ?? '', w));
    return '| ' + padded.join(' | ') + ' |';
  };

  const headerLine = formatRow(header);

  const separatorLine =
    '| ' +
    widths.map((w, i) => buildSeparatorCell(separator[i] ?? null, w)).join(' | ') +
    ' |';

  const bodyLines = rows.map(formatRow);

  return [headerLine, separatorLine, ...bodyLines].join('\n');
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
  const counts = rawRows.map(r => r.length);
  const columnCount = mode(counts);
  const rows = rawRows.map(row => {
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
  const headerIndex = parsedRows.findIndex(r => r.hasHeader);
  const effectiveHeaderIndex = headerIndex === -1 ? 0 : headerIndex;

  // Split into header and body
  const headerCells = parsedRows[effectiveHeaderIndex].cells;
  const bodyRows = parsedRows
    .slice(effectiveHeaderIndex + 1)
    .filter(r => !r.hasHeader || effectiveHeaderIndex === 0)
    .map(r => r.cells);

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
