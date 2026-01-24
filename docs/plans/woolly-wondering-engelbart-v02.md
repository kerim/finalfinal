# Cursor Position Fix Implementation

**Reference:** `docs/plans/cursor-position-fix.md`

## Summary

Implement line-based cursor position mapping to fix cursor jumping when toggling between WYSIWYG and Source modes. The current implementation uses raw character offsets which don't map correctly between ProseMirror (tree-based positions) and markdown (flat text).

## Solution

Use `{line, column}` coordinates instead of raw positions. Both editors can accurately convert to/from line-based coordinates, making cursor position portable.

## Changes Required

### 1. CodeMirror (`web/codemirror/src/main.ts`)

Replace `getCursorPosition()` and `setCursorPosition()` to return/accept `{line, column}` objects using CodeMirror's `lineAt()` and `line()` APIs.

### 2. Milkdown (`web/milkdown/src/main.ts`)

Replace `getCursorPosition()` and `setCursorPosition()` to return/accept `{line, column}` objects using ProseMirror's `nodesBetween()` to count block nodes as lines.

### 3. Swift Editors

- Add `CursorPosition` struct with `line` and `column` properties
- Update `MilkdownEditor.swift` to use JSON parsing for position objects
- Update `CodeMirrorEditor.swift` similarly
- Update `ContentView.swift` state from `Int?` to `CursorPosition?`

## Build & Verification

```bash
cd web && pnpm build
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

**Automated verification before user testing:**
1. Build succeeds with no errors
2. Console logs show `line X col Y` format (not raw positions)
3. Line numbers match between editors when toggling

## Files to Modify

- `web/codemirror/src/main.ts`
- `web/milkdown/src/main.ts`
- `final final/Editors/MilkdownEditor.swift`
- `final final/Editors/CodeMirrorEditor.swift`
- `final final/Views/ContentView.swift`
