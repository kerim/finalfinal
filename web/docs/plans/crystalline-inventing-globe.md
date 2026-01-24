# Plan: Simple Table Cursor Handling (v0.1.35)

## Context

After extensive debugging (v0.1.29 → v0.1.34), precise table cursor mapping proved unreliable due to:
- `table_header_row` vs `table_row` type differences
- Complex row/cell index calculations
- Multiple tables with identical content
- ProseMirror structure not matching markdown line numbers

**Decision:** Abandon precise mapping. Use a simpler approach - place cursor at the START or END of the table, similar to how complex block elements (images, code blocks) are often handled.

## Approach

When switching editors and the cursor is in a table:
1. **Detect table context** (already working via `isTableLine`)
2. **Find the table boundaries** in markdown (start line, end line)
3. **Place cursor at table start** (first character of header row)

This ensures:
- User stays near the table (not jumping to unrelated content)
- Predictable behavior
- Simple implementation

## Implementation

### Changes to `setCursorPosition` in `web/milkdown/src/main.ts`

Replace the complex table navigation logic with:

```javascript
// Check if target line is a table row (non-separator)
if (isTableLine(targetLine) && !isTableSeparator(targetLine)) {
  // SIMPLE APPROACH: Find the table and place cursor at the start
  const tableInfo = findTableAtLine(lines, line);
  if (tableInfo) {
    // Navigate to the first table row's first cell
    // Find this table in PM by ordinal
    let tableOrdinal = 0;
    for (let i = 0; i < tableInfo.startLine; i++) {
      if (isTableLine(lines[i]) && !isTableSeparator(lines[i])) {
        if (i === 0 || !isTableLine(lines[i - 1])) {
          tableOrdinal++;
        }
      }
    }
    tableOrdinal++; // Count the current table

    // Find the table in PM and place cursor at its start
    let currentTableOrdinal = 0;
    view.state.doc.descendants((node, pos) => {
      if (found) return false;
      if (node.type.name === 'table') {
        currentTableOrdinal++;
        if (currentTableOrdinal === tableOrdinal) {
          // Place cursor at start of table (position just inside first cell)
          pmPos = pos + 3; // table > header_row > first_cell > content
          found = true;
          diag.branchUsed = 'table';
          return false;
        }
      }
      return true;
    });
  }
}
```

### Also fix `getCursorPosition`

When cursor is in a table, return the table's START line instead of trying to calculate exact row:

```javascript
if (inTable) {
  // Find table start in markdown and return that line
  // ... existing tableStartLine logic ...
  if (tableStartLine > 0) {
    line = tableStartLine;
    matched = true;
  }
}
```

## Files to Modify

- `web/milkdown/src/main.ts`: Simplify table handling in both `setCursorPosition` and `getCursorPosition`
- `web/package.json`: 0.1.34 → 0.1.35
- `project.yml`: 0.1.34 → 0.1.35

## Verification

1. Build: `cd web && pnpm build`
2. Rebuild in Xcode
3. Test:
   - Place cursor in middle of a table row
   - Toggle to other editor
   - Verify cursor is at the START of the same table (not jumping elsewhere)
   - Toggle back and verify stability

## Trade-offs

**Pros:**
- Simple, predictable behavior
- No more random jumps to unrelated content
- Easier to maintain

**Cons:**
- Loses exact row/column position within tables
- User must re-navigate to their position within the table

This is acceptable because the current complex implementation doesn't work anyway, and being at the table start is far better than jumping to random list items or paragraphs.
