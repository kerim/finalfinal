# Debug Code Cleanup & Linting Plan

## Overview

Clean up debugging code from Swift and TypeScript sources, then run linting tools to catch any code quality issues.

## Findings Summary

### Swift Debug Code (260+ print statements)
- **Unguarded print() statements**: 257+ across the codebase
- **Properly guarded (#if DEBUG)**: 3 instances of `isInspectable = true` (safe)
- **High-volume files**: ContentView.swift (50+), MilkdownEditor.swift (40+), BibliographySyncService.swift (34+)

### TypeScript Debug Code (92 console statements)
- `main.ts` (Milkdown): 52 statements - heavy CAYW and citation debugging
- `main.ts` (CodeMirror): 40 statements - slash command and citation debugging
- `citation-search.ts`: 14 statements
- `citeproc-engine.ts`: 11 statements
- `citation-plugin.ts`: 11 statements
- `annotation-plugin.ts`: 9 statements + commented-out code

### Linting Tools Available
- **TypeScript/CSS**: Biome (`pnpm lint`, `pnpm lint:fix`)
- **Swift**: SwiftLint (`swiftlint`, `swiftlint --fix`)

---

## What Gets Removed vs Kept

### REMOVE (problem-specific debugging from recent work):

**Tagged debug logs** - These were added to debug specific issues and are now noise:
- `[REBUILD-DEBUG]` - ContentView section rebuilding
- `[REORDER]` / `[PERSIST]` / `[HIERARCHY]` - Drag-drop reordering
- `[CAYW DEBUG]` / `[SLASH DEBUG]` - Citation picker integration
- `[MilkdownEditor DEBUG]` - Citation resolution
- `[EDITOR-TOGGLE]` - Editor mode switching
- `[CitationResolution]` / `[Citation Search]` - Citation flow
- Raw JSON/data dumps (ZoteroService debug output)

**Unused infrastructure**:
- CodeMirror `_debugSeq`, `_debugLog`, `debugLog()` - Never used
- Commented-out MutationObserver in annotation-plugin.ts

**Placeholder logs in preview code**:
- Print statements in SwiftUI preview closures (AnnotationCardView, ChevronButton, etc.)

### KEEP (general operational logging):

**Service lifecycle** (wrap in `#if DEBUG`):
- "Database initialized at path..."
- "Editor preloaded"
- "Project opened: ..."

**Error conditions** (keep as-is):
- `console.error()` in TypeScript
- `print("Failed to...")` / `print("Error:...")` in Swift

**State diagnostics** (wrap in `#if DEBUG`):
- Section counts, content lengths
- Sync service status

---

## Implementation Plan

### Phase 1: Run Linters (Read-Only First)

1. Run TypeScript linter to see current issues:
   ```bash
   cd web && pnpm lint
   ```

2. Run SwiftLint to see current issues:
   ```bash
   swiftlint
   ```

### Phase 2: Clean TypeScript Console Statements

**Remove problem-specific debug logs** from these files:

| File | Remove | Keep |
|------|--------|------|
| `main.ts` (Milkdown) | `[CAYW DEBUG]`, `[CitationResolution]`, verbose logs | `console.error()` |
| `main.ts` (CodeMirror) | `[SLASH DEBUG]`, debug infrastructure | `console.error()` |
| `citation-search.ts` | `[Citation Search]` tagged logs | `console.error()` |
| `citeproc-engine.ts` | `[CiteprocEngine]` tagged logs | `console.error()` |
| `citation-plugin.ts` | Citation popup debugging | `console.warn()` for edge cases |
| `annotation-plugin.ts` | Node view creation logs, commented code | None specific |

### Phase 3: Clean Swift Print Statements

**Remove entirely:**
- All tagged debug logs: `[REBUILD-DEBUG]`, `[REORDER]`, `[PERSIST]`, `[HIERARCHY]`, `[EDITOR-TOGGLE]`, `[MilkdownEditor DEBUG]`
- Placeholder prints in preview closures
- Raw data dumps (JSON output, response previews)

**Wrap in `#if DEBUG`:**
- Service initialization logs (AppDelegate, DocumentManager, EditorPreloader)
- Sync status logs (BibliographySyncService, SectionSyncService)
- Theme/appearance change logs

**Keep as-is:**
- Error messages ("Failed to...", "Error:...")
- Warning messages about unexpected states

### Phase 4: Run Auto-Fix and Verify

1. Run TypeScript auto-fix:
   ```bash
   cd web && pnpm lint:fix && pnpm format
   ```

2. Run SwiftLint auto-fix:
   ```bash
   swiftlint --fix
   ```

3. Build to verify no regressions:
   ```bash
   cd web && pnpm build
   xcodebuild -scheme "final final" -destination 'platform=macOS' build
   ```

---

## Files to Modify

### TypeScript (6 files)
- `web/milkdown/src/main.ts`
- `web/milkdown/src/citation-search.ts`
- `web/milkdown/src/citeproc-engine.ts`
- `web/milkdown/src/citation-plugin.ts`
- `web/milkdown/src/annotation-plugin.ts`
- `web/codemirror/src/main.ts`

### Swift (25+ files - key ones listed)
- `final final/Views/ContentView.swift`
- `final final/Editors/MilkdownEditor.swift`
- `final final/Editors/CodeMirrorEditor.swift`
- `final final/Services/BibliographySyncService.swift`
- `final final/Services/ZoteroService.swift`
- `final final/Services/DocumentManager.swift`
- `final final/Views/Sidebar/AnnotationCardView.swift`
- `final final/Views/Sidebar/AnnotationPanel.swift`
- `final final/Views/Components/ChevronButton.swift`
- `final final/Views/Sidebar/SectionCardView.swift`
- `final final/Views/Sidebar/OutlineSidebar.swift`

---

## Verification

1. **Linting passes**: Both `pnpm lint` and `swiftlint` return clean
2. **Build succeeds**: Web and Xcode builds complete without errors
3. **App launches**: Manual test that app opens and basic editing works
4. **No console spam**: Open Safari Web Inspector and Xcode console - verify minimal/no debug output during normal operations

---

## Notes

- Swift `isInspectable = true` settings are already properly guarded with `#if DEBUG` - no changes needed
- Some error logging (console.error in TS, print for actual errors in Swift) may be appropriate to keep
- Test files can retain print statements for test output
