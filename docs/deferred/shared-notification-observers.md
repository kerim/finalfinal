# Shared Notification Observer Extraction (Deferred)

Step 10b of the file-splitting refactoring plan (`docs/deferred/refactored-splashing-hammock.md`) proposed extracting shared notification observer setup from both editor coordinators into a common helper. This was deferred.

## What Would Be Shared

Both `MilkdownEditor.Coordinator` and `CodeMirrorEditor.Coordinator` register these 5 identical notification observers in `init`:

1. `.willToggleEditorMode` → calls `saveAndNotify()`
2. `.insertSectionBreak` → calls `insertSectionBreak()`
3. `.annotationDisplayModesChanged` → calls `setAnnotationDisplayModes(_:isPanelOnly:hideCompletedTasks:)`
4. `.insertAnnotation` → calls `insertAnnotation(type:)`
5. `.toggleHighlight` → calls `toggleHighlight()`

Both coordinators also have matching cleanup code in `deinit` (5 `if let observer` blocks each).

## MilkdownEditor-Only Observers

MilkdownEditor.Coordinator registers 3 additional observers that CodeMirrorEditor does not:

1. `.citationLibraryChanged` → calls `setCitationLibrary(_:)`
2. `.refreshAllCitations` → calls `refreshAllCitations()`
3. `.editorAppearanceModeChanged` → calls `setEditorAppearanceMode(_:)`

## Why Deferred

Each observer uses `[weak self]` closures calling methods on its own coordinator. Without a shared `EditorCoordinator` protocol defining those 5 methods, there's no way to share the registration code. Adding such a protocol is an architectural change, beyond the scope of a pure file-splitting refactor.

## When to Revisit

- If/when a third editor type is added to the codebase
- When a shared `EditorCoordinator` protocol is introduced for other reasons (e.g., unifying polling logic or content handling)

## Current State

Both editors have identical but independent observer registration in `init` and cleanup in `deinit`. The duplication is ~40 lines per editor — manageable and easy to keep in sync manually.
