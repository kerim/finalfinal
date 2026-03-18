// Standalone utility functions for markdown text processing

/**
 * Strip markdown syntax from a line to get plain text content
 * Used for matching ProseMirror nodes to markdown lines
 */
export function stripMarkdownSyntax(line: string): string {
  return line
    .replace(/^\||\|$/g, '') // leading/trailing pipes (table)
    .replace(/\|/g, ' ') // internal pipes (table cells)
    .replace(/^#+\s*/, '') // headings
    .replace(/^\s*[-*+]\s*/, '') // unordered list items
    .replace(/^\s*\d+\.\s*/, '') // ordered list items
    .replace(/^\s*>\s*/, '') // blockquotes
    .replace(/~~(.+?)~~/g, '$1') // strikethrough
    .replace(/\*\*(.+?)\*\*/g, '$1') // bold
    .replace(/__(.+?)__/g, '$1') // bold alt
    .replace(/\*(.+?)\*/g, '$1') // italic
    .replace(/_([^_]+)_/g, '$1') // italic alt
    .replace(/`([^`]+)`/g, '$1') // inline code
    .replace(/!\[([^\]]*)\]\([^)]+\)/g, '$1') // images
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1') // links
    .trim()
    .replace(/\s+/g, ' '); // normalize whitespace
}

/**
 * Check if a markdown line is a table row (starts/ends with |)
 */
export function isTableLine(line: string): boolean {
  const trimmed = line.trim();
  // Ensure at least |x| structure (3 chars minimum)
  return trimmed.length >= 3 && trimmed.startsWith('|') && trimmed.endsWith('|');
}

/**
 * Check if a markdown line is a table separator (| --- | --- |)
 */
export function isTableSeparator(line: string): boolean {
  const trimmed = line.trim();
  return /^\|[\s:-]+\|$/.test(trimmed) || /^\|(\s*:?-+:?\s*\|)+$/.test(trimmed);
}

/**
 * Find the table structure in markdown: returns startLine for the table containing the given line
 */
export function findTableStartLine(lines: string[], targetLine: number): number | null {
  if (!isTableLine(lines[targetLine - 1])) return null;

  // Find table start (scan backwards)
  let startLine = targetLine;
  while (startLine > 1 && isTableLine(lines[startLine - 2])) {
    startLine--;
  }
  return startLine;
}
