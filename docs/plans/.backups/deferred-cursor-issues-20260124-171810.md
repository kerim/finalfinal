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
