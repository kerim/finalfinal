# Cursor Position Diagnostic Implementation

**Reference:** `docs/plans/cursor-position-diagnostic.md`

## Summary

Add diagnostic logging to cursor position functions in both editors to debug why cursor position doesn't map correctly between CodeMirror and Milkdown when toggling modes.

## Changes Required

### 1. CodeMirror (`web/codemirror/src/main.ts`)

**File:** `web/codemirror/src/main.ts`
**Lines:** 163-176

Add context logging to both functions:

- `getCursorPosition()` (line 163): Add text context showing 20 chars before/after cursor
- `setCursorPosition()` (line 168): Add text context showing what position maps to

### 2. Milkdown (`web/milkdown/src/main.ts`)

**File:** `web/milkdown/src/main.ts`
**Lines:** 209-226

Add context logging using ProseMirror's `textBetween()`:

- `getCursorPosition()` (line 209): Add text context showing 20 chars before/after cursor
- `setCursorPosition()` (line 215): Add text context showing what position maps to

## Build Steps

```bash
cd web && pnpm build
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

## Verification

1. Run the app
2. Open Safari Web Inspector (Develop → final final)
3. Type text, place cursor at a known location
4. Press Cmd+/ to toggle mode
5. Observe console output showing position and context

**Expected output pattern:**
```
[CodeMirror] getCursorPosition: 157, context: "* Markdown support|"
[Milkdown] setCursorPosition: 157 -> 157, context: "*|Multiple themes"
```

This confirms the position number is preserved but maps to different text, validating the root cause hypothesis.
