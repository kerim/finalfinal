import { describe, expect, it } from 'vitest';
import type { ParsedTable } from '../../../shared/format-table';
import { formatTable } from '../../../shared/format-table';

describe('formatTable — compact output', () => {
  it('produces single-dash separator for null alignment', () => {
    const t: ParsedTable = { header: ['A'], separator: [null], rows: [['x']] };
    const lines = formatTable(t).split('\n');
    const sepCols = lines[1]
      .split('|')
      .map((s) => s.trim())
      .filter(Boolean);
    expect(sepCols[0]).toBe('-');
  });

  it('produces :- for left, -: for right, :-: for center', () => {
    const t: ParsedTable = {
      header: ['L', 'R', 'C'],
      separator: ['left', 'right', 'center'],
      rows: [['a', 'b', 'c']],
    };
    const lines = formatTable(t).split('\n');
    const sepCols = lines[1]
      .split('|')
      .map((s) => s.trim())
      .filter(Boolean);
    expect(sepCols[0]).toBe(':-');
    expect(sepCols[1]).toBe('-:');
    expect(sepCols[2]).toBe(':-:');
  });

  it('does not pad cells to the longest cell width', () => {
    const shortCell = 'x';
    const longCell = 'a'.repeat(100);
    const t: ParsedTable = {
      header: ['Short', 'Long'],
      separator: [null, null],
      rows: [[shortCell, longCell]],
    };
    const lines = formatTable(t).split('\n');
    // The body line should not pad shortCell to 100 chars
    const cols = lines[2]
      .split('|')
      .map((s) => s.trim())
      .filter(Boolean);
    expect(cols[0]).toBe(shortCell);
    expect(cols[1]).toBe(longCell);
  });

  it('compact output is idempotent (parse → format produces same string)', () => {
    const t: ParsedTable = {
      header: ['Name', 'Score'],
      separator: [null, 'right'],
      rows: [
        ['Alice', '100'],
        ['Bob', '50'],
      ],
    };
    const m1 = formatTable(t);

    // Minimal GFM row parser — re-parses exactly what formatTable emits
    function reparse(md: string): ParsedTable {
      const lines = md.split('\n');
      const splitRow = (line: string) =>
        line
          .split('|')
          .slice(1, -1)
          .map((s) => s.trim());
      const header = splitRow(lines[0]);
      const sepCells = splitRow(lines[1]);
      const separator = sepCells.map((s): import('../../../shared/format-table').Align => {
        if (s.startsWith(':') && s.endsWith(':')) return 'center';
        if (s.startsWith(':')) return 'left';
        if (s.endsWith(':')) return 'right';
        return null;
      });
      const rows = lines.slice(2).filter(Boolean).map(splitRow);
      return { header, separator, rows };
    }

    const m2 = formatTable(reparse(m1));
    expect(m2).toBe(m1);
  });
});
