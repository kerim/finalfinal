# Deferred Cursor Mapping Issues

Issues identified during cursor mapping work that are tracked for future fixes.

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

---

## Markdown Tables

**Status:** In Progress (v0.1.25)
**Priority:** Medium

### Symptom
Clicking in a table cell in CodeMirror (line 122), then toggling to Milkdown results in cursor jumping to line 150.

### Example Log
```
[CodeMirrorEditor] saveAndNotify: line 122 col 71
[MilkdownEditor] setCursorPosition called with: line 122 col 71
[MilkdownEditor] saveAndNotify: line 150 col 24
CURSOR DIAGNOSTICS: {"parentTextPreview":"path to data files...","matched":false,"fallback":{"blockCount":88,"resultLine":150}}
```

### Root Cause
Tables in markdown span multiple lines:
```markdown
| Option | Description |        ← line 1 of table
| ------ | ----------- |        ← line 2 (separator)
| data   | path to...  |        ← line 3
| engine | engine...   |        ← line 4
```

But ProseMirror represents the entire table as a single table node with nested table_row and table_cell nodes. The content-line counting fallback counts each PM block, but a table is just 1 block containing multiple rows.

Additionally, the text matching fails because:
- PM cell contains just "path to data files..."
- MD line contains "| data   | path to data files... |"
- `stripMarkdownSyntax()` doesn't handle table pipe syntax

### Potential Fix
1. Detect table nodes in PM and handle specially
2. When cursor is in a table_cell, find which row/column
3. Map back to the correct MD line within the table
4. Add table pipe stripping to `stripMarkdownSyntax()`
