# Incremental Refactoring Plan: File Splitting (No Architecture Changes)

## Context

The codebase has 9 files over 800 lines. The goal is to split them into smaller files (target ~500 lines, hard cap 800) to make them more manageable for AI coding agents. **No design or architectural changes** — only move code into extension files (Swift) or separate modules (TypeScript). Work from the `main` branch on a new `refactor/file-splits` branch.

## Approach

Each step is: extract code → build → verify app works. One file at a time. If a build breaks, the extract was wrong — revert and try again.

**Swift pattern:** Move methods into `extension ContentView { }` in a new file. No behavior change.
**TypeScript pattern:** Extract functions to a new module, re-export from main.ts. No behavior change.

### Known Swift Constraint: `private` → `internal`

When methods move to extension files, `private` access no longer works across file boundaries. This is an **expected side effect**, not a bug. All moved methods and the properties they access must change from `private` to `internal`. This broadens visibility within the module but does not change runtime behavior. Approximately ~130 access level changes are expected across all Swift steps.

### Known Swift Constraint: Nested Types

Swift does not allow defining a nested type (like `Coordinator`) inside an extension in a separate file. For Steps 4 and 9 (editor Coordinators), the `Coordinator` class definition with all stored properties stays in the original file. Only methods are moved to extension files via `extension MilkdownEditor.Coordinator { }`.

### Known TypeScript Constraint: Shared Mutable State

The Milkdown `main.ts` has module-level mutable variables (`editorInstance`, `currentContent`, `isSettingContent`) accessed by many functions. When splitting, create a shared `editor-state.ts` module that holds these singletons, imported by all extracted modules. Do NOT use circular imports.

## Files to Split (ordered by size)

### Step 1: `web/milkdown/src/main.ts` (2488 lines → 10 files)

The `window.FinalFinal` API object starts at line 1172 and spans ~1,316 lines. After extracting standalone functions (slash, CAYW, find/replace), the API object itself must also be split — each extracted module exports implementation functions, and `main.ts` delegates to them.

| New File | What to Extract | ~Lines |
|----------|----------------|--------|
| `editor-state.ts` | Shared mutable state: `editorInstance`, `currentContent`, `isSettingContent`, slash undo tracking. Export getter/setter functions. | ~30 |
| `types.ts` | All interfaces (FindOptions, FindResult, SearchState, Block, CAYWCallbackData, etc.) + window.FinalFinal type declaration | ~110 |
| `utils.ts` | `stripMarkdownSyntax()`, `isTableLine()`, `isTableSeparator()`, `findTableStartLine()` | ~60 |
| `slash-commands.ts` | SlashCommand interface, `slashCommands` array, `createSlashMenu()`, `createMenuItem()`, `updateSlashMenu()`, `updateMenuSelection()`, `executeSlashCommand()`, `handleSlashKeydown()`, `configureSlash()` | ~430 |
| `cayw.ts` | Lazy citation resolution state, `requestCitationResolutionInternal()`, `openCAYWPicker()`, all `handleCAYW*` callbacks, `handleEditCitationCallback()` | ~250 |
| `find-replace.ts` | Search state variables, `findAllMatches()`, `goToMatch()`, `updateSearchDecorations()`, all `find()`/`findNext()`/`replaceCurrent()`/`replaceAll()`/`clearSearch()`/`getSearchState()` API methods | ~300 |
| `api-content.ts` | `setContent()`, `getContent()`, `resetEditorState()`, `applyBlocks()`, block sync methods — import from `editor-state.ts` | ~300 |
| `api-annotations.ts` | `setAnnotationDisplayModes()`, `getAnnotations()`, `scrollToAnnotation()`, `insertAnnotation()`, `setHideCompletedTasks()`, `toggleHighlight()`, plus citation callback methods | ~200 |
| `api-modes.ts` | `setEditorMode()` (~108 lines), `setTheme()`, `setFocusMode()`, `setCursorPosition()` (~148 lines), `getCursorPosition()` (~129 lines), `scrollToOffset()`, `scrollCursorToCenter()`, `getStats()`, `insertAtCursor()`, `insertBreak()`, `focus()`, `initialize()` | ~530 |
| `main.ts` (remaining) | Imports, `initEditor()`, thin `window.FinalFinal` API object delegating to extracted modules | ~220 |

**Pattern for API splitting:** Extract method implementations to modules. `main.ts` assembles the `window.FinalFinal` object with thin delegates:
```typescript
// api-content.ts
import { getEditorInstance, getCurrentContent } from './editor-state';
export function setContentImpl(markdown: string, options?: { scrollToStart?: boolean }) { /* moved implementation */ }

// main.ts
import { setContentImpl } from './api-content';
window.FinalFinal = { setContent: setContentImpl, ... };
```

**Verify:** `cd web && pnpm build` succeeds, app loads, WYSIWYG editing works.

### Step 2: `final final/Views/ContentView.swift` (1978 lines → 6 files)

Note: `withEditorNotifications()`, `withFindNotifications()`, etc. are `extension View` methods (not `ContentView` methods). The file for these should reflect that.

| New File | What to Extract | ~Lines |
|----------|----------------|--------|
| `ContentView+SectionManagement.swift` | `scrollToSection()`, `updateSection()`, `reorderSection()`, `reorderSingleSection()`, `reorderSubtree()`, `finalizeSectionReorder()`, `persistReorderedBlocks()`, `persistReorderedBlocks_legacySections()`, `promoteOrphanedChildrenInPlace()` | ~340 |
| `ContentView+HierarchyEnforcement.swift` | `recalculateParentRelationships()`, `findParentByLevel()`, `hasHierarchyViolations()`, `enforceHierarchyConstraintsIfNeeded()`, `enforceHierarchyConstraintsStatic()`, `rebuildDocumentContentStatic()`, `enforceHierarchyAsync()`, `persistEnforcedSections()`, `enforceHierarchyConstraints()` | ~270 |
| `ViewNotificationModifiers.swift` | `withEditorNotifications()`, `withFindNotifications()`, `withFileNotifications()`, `withVersionNotifications()`, `withContentObservers()`, `withSidebarSync()`, `saveDocumentGoalSettings()` (all are `extension View` methods, NOT `ContentView` methods) | ~350 |
| `ContentView+ProjectLifecycle.swift` | `initializeProject()`, `configureForCurrentProject()`, `connectToZotero()`, `handleProjectOpened()`, `handleProjectClosed()`, `performProjectClose()`, `handleCreateFromGettingStarted()`, `handleSaveVersion()`, `handleRepair()`, `handleOpenAnyway()`, `handleIntegrityCancel()` | ~390 |
| `ContentView+ContentRebuilding.swift` | `rebuildDocumentContent()`, `filterBlocksForZoom()`, `filterBlocksForZoomStatic()`, `updateSourceContentIfNeeded()`, `detailView`, `toggleAnnotationCompletion()`, `handleAnnotationTextUpdate()`, `editorView` | ~280 |
| `ContentView.swift` (remaining) | `CursorPosition`, `FocusModeToast`, all `@State`/`@Environment` properties, `body`, layout views (`mainContentView`, `sidebarView`, toolbar) | ~350 |

**Access level changes:** All `@State private var` properties accessed by methods in extension files must become `@State var` (drop `private`). All `@Environment(...) private var` properties (e.g., `themeManager`, `versionHistoryCoordinator`, `openWindow`) must also drop `private`. All `private func` methods being moved must become `func` (internal).

**Verify:** `xcodegen generate && xcodebuild -scheme "final final" build` succeeds.

### Step 3: `web/codemirror/src/main.ts` (1310 lines → 5 files)

| New File | What to Extract | ~Lines |
|----------|----------------|--------|
| `citation.ts` | `mergeCitations()`, `getCitationAtCursor()`, `createCitationAddButton()`, `handleAddCitationClick()`, `showCitationAddButton()`, `hideCitationAddButton()`, `updateCitationAddButton()` | ~150 |
| `decorations.ts` | `customHighlightStyle`, `headingDecorationPlugin` | ~120 |
| `slash-completions.ts` | `slashCompletions()` function (handles /cite, /task, /comment, /ref, /find, /h1-h6) | ~160 |
| `find-replace.ts` | `countMatches()`, `findCurrentMatchIndex()`, search state vars (`currentSearchQuery`, `currentSearchOptions`, `currentMatchIndex`), `find()`, `findNext()`, `findPrevious()`, `replaceCurrent()`, `replaceAll()`, `clearSearch()`, `getSearchState()` implementations | ~170 |
| `main.ts` (remaining) | Imports, `initEditor()`, `window.FinalFinal` API (delegating to extracted modules), `wrapSelection()`, `insertLink()`, `countWords()` | ~710 |

**Verify:** `cd web && pnpm build` succeeds, source editor works, find/replace works.

### Step 4: `final final/Editors/MilkdownEditor.swift` (1267 lines → 3 files)

**Important:** The `Coordinator` class definition (with all stored properties) stays in the original file. Only methods are moved via `extension MilkdownEditor.Coordinator { }`.

| New File | What to Extract | ~Lines |
|----------|----------------|--------|
| `MilkdownCoordinator+MessageHandlers.swift` | `extension MilkdownEditor.Coordinator`: `webView(didFinish:)`, `userContentController(didReceive:)`, all message handler methods, polling logic | ~500 |
| `MilkdownCoordinator+Content.swift` | `extension MilkdownEditor.Coordinator`: Content setter, focus mode, theme, scroll, cursor methods, `cleanup()`, `insertSectionBreak()`, `setEditorAppearanceMode()`, `setAnnotationDisplayModes()`, `insertAnnotation()`, `toggleHighlight()`, `setCitationLibrary()`, `setCitationStyle()`, `getBibliographyCitekeys()`, `saveCursorPositionBeforeCleanup()`, `saveAndNotify()`, `saveCursorAndNotify()` | ~350 |
| `MilkdownEditor.swift` (remaining) | NSViewRepresentable struct + Coordinator class definition (stored properties, init, deinit) + `makeNSView()`, `updateNSView()`, `makeCoordinator()` | ~400 |

**Access level changes:** All `private` properties/methods on `Coordinator` that are accessed from extension files must become `internal`.

**Verify:** Build succeeds, WYSIWYG editing + citation search work.

### Step 5: `final final/Views/Sidebar/OutlineSidebar.swift` (1051 lines → 4 files)

| New File | What to Extract | ~Lines |
|----------|----------------|--------|
| `OutlineSidebar+Models.swift` | `SectionTransfer`, `UTType` extension, `DropPosition`, `SectionReorderRequest`, `SectionLevelInfo`, `calculateZoneLevel()` free function | ~140 |
| `OutlineSidebar+DropDelegates.swift` | `SectionDropDelegate`, `EndDropDelegate` (these are top-level structs, not nested — no access issues) | ~230 |
| `OutlineSidebar+Components.swift` | `DragLevelBadge`, `DropIndicatorLine`, `SubtreeDragPreview`, `SubtreeDragHint`, `ZoomBreadcrumb` (top-level structs) | ~200 |
| `OutlineSidebar.swift` (remaining) | Main `OutlineSidebar` view struct with body, drag helpers | ~480 |

**Verify:** Build succeeds, sidebar drag-drop works, zoom breadcrumb works.

### Step 6: `final final/ViewState/EditorViewState.swift` (985 lines → 4 files)

| New File | What to Extract | ~Lines |
|----------|----------------|--------|
| `EditorViewState+Types.swift` | `FocusModeSnapshot`, `Notification.Name` extension, `EditorMode`, `ZoomMode`, `EditorContentState` enums | ~70 |
| `EditorViewState+FocusMode.swift` | `toggleFocusMode()`, `enterFocusMode()`, `exitFocusMode()` + FullScreenManager calls | ~100 |
| `EditorViewState+Zoom.swift` | `zoomToSection()`, `zoomOut()`, `zoomOutSync()`, `flushCodeMirrorSyncIfNeeded()`, `waitForContentAcknowledgement()`, `acknowledgeContent()`, `getDescendantIds()`, `getShallowDescendantIds()`, `filterToSubtree()`, zoom-related helpers | ~350 |
| `EditorViewState.swift` (remaining) | All stored properties (including `@Observable`-tracked ones), observation, annotation filtering, stats, project reset | ~465 |

**Critical:** All stored properties MUST stay in the main file (the `@Observable` macro only transforms stored properties in the primary class declaration). `private` methods being moved (`getDescendantIds`, `getShallowDescendantIds`, etc.) become `internal`.

**Verify:** Build succeeds, zoom in/out works, focus mode works.

### Step 7: `final final/Models/Database+Blocks.swift` (905 lines → 4 files)

| New File | What to Extract | ~Lines |
|----------|----------------|--------|
| `Database+BlocksReorder.swift` | `HeadingUpdate`, `HeadingMetadata`, `reorderAllBlocks()`, `reorderBlock()`, `normalizeSortOrders()`, `replaceBlocks()`, `replaceBlocksInRange()` (both replace functions + `HeadingMetadata` must be in the same file since `HeadingMetadata` is private) | ~340 |
| `Database+BlocksWordCount.swift` | `recalculateBlockWordCounts()`, `totalWordCount()`, `wordCountForHeading()` | ~80 |
| `Database+BlocksObservation.swift` | `observeBlocks()`, `observeOutlineBlocks()` | ~70 |
| `Database+Blocks.swift` (remaining) | `BlockUpdates`, fetch operations, insert/update/delete, `applyBlockChangesFromEditor()` | ~415 |

**Verify:** Build succeeds, section metadata persists, word counts update.

### Step 8: `web/milkdown/src/citation-plugin.ts` (854 lines → 2 files)

Note: CSL/citeproc rendering is already in a separate `citeproc-engine.ts`. What can be extracted is the edit popup DOM construction and interaction logic.

| New File | What to Extract | ~Lines |
|----------|----------------|--------|
| `citation-edit-popup.ts` | `createEditPopup()`, `showCitationEditPopup()`, `updateEditPreview()`, `commitEdit()`, `cancelEdit()`, `hideEditPopup()`, edit popup DOM construction | ~265 |
| `citation-plugin.ts` (remaining) | Plugin definition, node schema, `parseCitationBracket()`, `serializeCitation()`, `mergeCitations()`, transaction handlers | ~589 |

**Verify:** `cd web && pnpm build` succeeds, citations render correctly, citation editing works.

### Step 9: `final final/Editors/CodeMirrorEditor.swift` (805 lines → 2 files)

**Important:** Same constraint as Step 4 — `Coordinator` class definition stays in original file.

| New File | What to Extract | ~Lines |
|----------|----------------|--------|
| `CodeMirrorCoordinator+Handlers.swift` | `extension CodeMirrorEditor.Coordinator`: message handlers, JS evaluation, polling, annotation handlers | ~500 |
| `CodeMirrorEditor.swift` (remaining) | NSViewRepresentable struct + Coordinator class definition + `makeNSView()`, `updateNSView()` | ~305 |

**Access level changes:** All `private` Coordinator members accessed from extension file become `internal`.

**Verify:** Build succeeds, source editing works, annotations work in source mode.

## Step 10: Code Quality Fixes (small changes, big gains)

Applied during the relevant file-splitting steps, not as separate steps.

### 10a. Shared JS String Escaping (during Steps 4 & 9)

**Problem:** MilkdownEditor has a clean `String.escapedForJSTemplateLiteral` extension. CodeMirrorEditor uses inline `.replacingOccurrences()` chains instead.

**Warning:** These may NOT be equivalent. MilkdownEditor's extension escapes `${` sequences; CodeMirrorEditor's inline code escapes ALL `$` characters. Before unifying, verify that the MilkdownEditor extension covers all cases CodeMirrorEditor needs. If they differ, create a shared file with BOTH escape strategies and use the appropriate one in each editor.

**Fix:** Move the extension to a shared file (`Editors/StringExtensions.swift`), verify equivalence, use it in both editors.

### 10b. Shared Notification Observer Setup (during Steps 4 & 9)

**Problem:** Both editor coordinators register 5 identical notification observers and have identical cleanup code (5 `if let observer` blocks each).

**Fix:** Extract a shared helper for the common 5 observers (MilkdownEditor's 3 extra citation observers stay in its own code). Also extract observer cleanup into a `cleanupObservers()` helper. ~15 minutes.

## Safety Protocol

### Before Starting

1. **Create branch:** `git checkout main && git checkout -b refactor/file-splits`
2. **Verify baseline:** Run full build + tests on main to confirm clean starting point.

### Before Each Step

1. **Tag the commit:** `git tag pre-refactor-stepN`
2. **Record baseline metrics:**
   ```bash
   # Swift: count functions and total lines
   grep -cE '^\s*(@\w+\s+)*(private |internal |public |open |override |static |nonisolated |class )*func ' "path/to/file.swift"
   wc -l "path/to/file.swift"

   # TypeScript: count exports, functions, and total lines
   grep -cE 'function |export |const .* = ' "path/to/file.ts"
   wc -l "path/to/file.ts"
   ```

### After Each Step — 6 Mandatory Checks

Run ALL before committing. If any fail, revert: `git reset --hard pre-refactor-stepN`

**Check 1: No lines lost**
```bash
# Sum of all split files >= original (new imports/extensions add lines)
wc -l original.swift split1.swift split2.swift ...
```

**Check 2: No symbols lost**
```bash
# Function count across all split files must equal original
# Pattern covers: private func, @MainActor func, @objc func, static func, nonisolated func, etc.
grep -cE '^\s*(@\w+\s+)*(private |internal |public |open |override |static |nonisolated |class )*func ' original.swift
cat split1.swift split2.swift ... | grep -cE '^\s*(@\w+\s+)*(private |internal |public |open |override |static |nonisolated |class )*func '
# Note: This pattern is approximate. Build success + smoke tests are the real safety net.
```

**Check 3: Build succeeds**
```bash
# Swift
xcodegen generate && xcodebuild -scheme "final final" -destination 'platform=macOS' build
# TypeScript
cd web && pnpm build
```

**Check 4: No accidental deletions**
```bash
# Every line deleted from original must appear as addition in a new file
git diff --stat HEAD
git diff HEAD -- "path/to/original"  # Review manually
```

**Check 5: Tests pass**
```bash
xcodebuild test -scheme "final final" -destination 'platform=macOS' 2>&1 | tail -20
```

**Check 6: Smoke test the app**
- Editor loads content
- Can type and edit
- Sidebar shows sections
- No console errors/crashes

### If Any Check Fails

```bash
git reset --hard pre-refactor-stepN
```
Do NOT fix forward. Revert, understand what went wrong, try again.

### After All Steps

Compare total function count across entire codebase:
```bash
git stash && git checkout main
find "final final" -name "*.swift" -exec grep -c '^\s*func ' {} + | awk -F: '{sum+=$2} END {print "main:", sum}'
git checkout refactor/file-splits
find "final final" -name "*.swift" -exec grep -c '^\s*func ' {} + | awk -F: '{sum+=$2} END {print "refactored:", sum}'
# Must be equal (or refactored slightly higher from new extension declarations)
```

## Execution Rules

1. **One step per session.** Complete all safety checks, then commit before starting the next.
2. **No logic changes.** Code moves verbatim. Only `import` statements, `extension` declarations, and `private` → `internal` access changes are allowed.
3. **Run `xcodegen generate`** after every Swift file move.
4. **Run `cd web && pnpm build`** after every TypeScript change.
5. **If a build fails**, revert to pre-step tag. Don't add workarounds.
6. **If function count changes**, revert. Something was accidentally deleted.
7. **Commit message format:** `refactor: split <FileName> into N files (no behavior change)`

## Recommended Execution Order

TypeScript steps build faster (`pnpm build` takes seconds vs `xcodebuild` taking minutes). Run them first to build methodology confidence:

**Phase A (TypeScript):** Steps 1, 3, 8
**Phase B (Swift):** Steps 2, 4, 5, 6, 7, 9

## Files Left Alone (under 800 lines)

- SectionSyncService.swift (741), DocumentManager.swift (715), ZoteroService.swift (625)
- PreferencesView.swift (516), citation-search.ts (507), AppearanceSettings.swift (499)
- VersionHistoryWindow.swift (498), RadixScales.swift (497), AnnotationSyncService.swift (464)
- Database+Sections.swift (443), SectionCardView.swift (423), block-sync-plugin.ts (421)
- FileCommands.swift (413), VersionHistorySheet.swift (410)

## Verification Checklist (after all steps)

- [ ] WYSIWYG editing works (Milkdown)
- [ ] Source editing works (CodeMirror)
- [ ] Cmd+/ toggles modes, cursor preserved
- [ ] Sidebar shows sections, drag-drop reorder works
- [ ] Single click scrolls, double click zooms
- [ ] Focus mode enters/exits with full-screen, sidebar hide, toast
- [ ] Find/replace works (Cmd+F, Cmd+Shift+H)
- [ ] Citations render, /cite command works
- [ ] Annotations (task, comment, reference) work
- [ ] Word counts don't include annotation markup
- [ ] Section metadata (status, tags, goals) persists
- [ ] Project switch cleans up state
- [ ] Content persists after restart
- [ ] Getting Started guide loads for new projects
- [ ] Themes switch correctly
- [ ] Zoom into section → edit → zoom out → edits preserved
- [ ] Re-zoom (zoom A, then directly zoom B) → content correct
- [ ] Zoom in source mode → anchors handled correctly
- [ ] Option+double-click → shallow zoom works
