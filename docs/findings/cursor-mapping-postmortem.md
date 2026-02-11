# Cursor Mapping Post-Mortem

Two deferred cursor mapping issues: precise table cursor mapping (abandoned) and escaped asterisks in bold text (still deferred).

---

## Precise Table Cursor Mapping

**Status:** Abandoned in v0.1.35 in favor of simple "table start" approach
**Original versions:** v0.1.29 -> v0.1.34
**Date deferred:** 2026-01-24

### Goal

Preserve exact cursor position (row and column/cell) when switching between Milkdown (WYSIWYG) and CodeMirror (source) editors while the cursor is inside a markdown table.

### Approach Attempted

**getCursorPosition (Milkdown -> CodeMirror):**
1. Detect if cursor is in a table by walking ProseMirror ancestor nodes
2. Find `table_cell` or `table_header` to get cell index within row
3. Find `table_row` or `table_header_row` to get row index within table
4. Match the table to markdown by searching for cell content matches or falling back to first table
5. Calculate markdown line: `tableStartLine + rowIndex + (1 if after separator)`

**setCursorPosition (CodeMirror -> Milkdown):**
1. Detect if target markdown line is a table row (starts/ends with `|`)
2. Handle separator rows by redirecting to first data row
3. Count table ordinal (which table in document)
4. Calculate target row index by counting non-separator lines from table start
5. Calculate target cell index by parsing pipe positions
6. Navigate ProseMirror: find Nth table -> find Nth row -> find Nth cell -> position inside

### Why It Failed

- **Type Mismatches**: Milkdown uses `table_header_row` for header and `table_row` for data rows; row index calculation differed between getting and setting; `table_header` vs `table_cell` type differences for cells
- **Ordinal Counting Issues**: Multiple tables with identical content couldn't be distinguished reliably; off-by-one errors in counting tables before target line
- **Structural Mismatches**: ProseMirror table structure doesn't map 1:1 to markdown lines; separator row exists in markdown but not in ProseMirror; cell content stripping lost information needed for precise positioning
- **Observed Failures**: Cursor jumping to unrelated content (list items, paragraphs); wrong table selected when multiple tables exist; row index off by 1-2 rows

### Potential Future Approaches

If revisiting this:
1. **Debug with actual ProseMirror inspection** -- Use Web Inspector to examine actual node structure for specific tables
2. **Content hashing** -- Hash table content to uniquely identify tables across representations
3. **Bidirectional markers** -- Store cursor context (table ID, row content hash) during switch
4. **Simpler scope** -- Only support single-table documents initially
5. **Different editor** -- Consider editors with better markdown <-> WYSIWYG cursor mapping

### Current Solution (v0.1.35)

Simple approach: when cursor is in a table, place it at the **start** of the table (first cell of header row). User must re-navigate within the table, but:
- Predictable behavior
- No jumps to unrelated content
- Simple to maintain

---

## Escaped Asterisks in Bold Text

**Status:** Deferred
**Priority:** Low

### Examples that don't work:
```markdown
This is **text with \* a single asterisk** inside.
And **text with \*\* two asterisks** inside.
```

### Root Cause
The cursor mapping regex patterns don't account for escaped characters (`\*`) within formatted content. The escape sequence takes 2 characters in markdown but renders as 1 character, throwing off offset calculations.

### Potential Fix
In `cursor-mapping.ts`, add handling for escaped characters within formatted content:
1. Before processing bold/italic content, scan for `\*` sequences
2. Adjust content length calculations to account for escape sequences
3. May need recursive escape handling for nested cases

### Why Deferred
- Edge case: escaped asterisks inside bold are rare in normal writing
- Complex to implement correctly with nested formatting
- Current behavior (cursor offset by escape count) is tolerable
