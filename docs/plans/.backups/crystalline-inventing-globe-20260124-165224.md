# Plan: Fix Cursor Position Race Condition (v0.1.21)

## Problem Summary

When toggling MD→CM, the cursor jumps to line 1 instead of preserving position.

**Root cause:** Race condition between async JavaScript cursor save and SwiftUI view creation.

## Evidence from Logs

```
[MilkdownEditor] setCursorPosition called with: line 47 col 88   ← User is on line 47 in Milkdown
[CodeMirrorEditor] restoreCursorPositionIfNeeded: cursorPositionToRestore=...line: 1, column: 2  ← CodeMirror gets stale (1,2)!
```

The same pattern sometimes works (line 9→9) and sometimes fails (line 47→1), confirming it's a race condition.

## Root Cause Analysis

Current flow:
1. User toggles Milkdown→CodeMirror
2. `toggleEditorMode()` changes `editorMode` immediately
3. SwiftUI dismantles MilkdownEditor, calls `saveCursorPositionBeforeCleanup()` (async JS call)
4. SwiftUI creates CodeMirrorEditor
5. CodeMirror reads `cursorPositionToRestore` - **but async callback hasn't finished yet!**
6. CodeMirror sees stale value `(1, 2)`
7. (Later) Async callback finally sets `cursorPositionToRestore` - too late

**The problem:** `saveCursorPositionBeforeCleanup()` is async but the toggle doesn't wait for it.

---

## Solution: Two-Phase Toggle

Change toggle flow to wait for cursor save before switching editors.

### Files to Modify

| File | Action |
|------|--------|
| `final final/ViewState/EditorViewState.swift` | Add two-phase toggle with callback |
| `final final/Views/ContentView.swift` | Wire up toggle to wait for cursor save |
| `final final/Editors/MilkdownEditor.swift` | Expose getCursorPosition as public, add toggle notification handler |
| `final final/Editors/CodeMirrorEditor.swift` | Expose getCursorPosition as public, add toggle notification handler |
| `web/package.json` | Bump to 0.1.21 |
| `project.yml` | Bump to 0.1.21 |

---

## Implementation

### Task 1: Add pre-toggle cursor save notification

Create notification for editors to save cursor position before toggle:

```swift
// In a Notification extension file or at top of EditorViewState.swift
extension Notification.Name {
    static let willToggleEditorMode = Notification.Name("willToggleEditorMode")
    static let didSaveCursorPosition = Notification.Name("didSaveCursorPosition")
}
```

### Task 2: Modify EditorViewState toggle logic

Add a method that requests cursor save first:

```swift
// In EditorViewState.swift
func requestEditorModeToggle() {
    // Post notification - current editor should save cursor and respond
    NotificationCenter.default.post(name: .willToggleEditorMode, object: nil)
}

func completeEditorModeToggle(with position: CursorPosition) {
    // This will be called after cursor is saved
    // Position is passed via notification userInfo
    editorMode = editorMode == .wysiwyg ? .source : .wysiwyg
}
```

### Task 3: Update ContentView to handle two-phase toggle

```swift
// In ContentView.swift
.onReceive(NotificationCenter.default.publisher(for: .toggleEditorMode)) { _ in
    // Request toggle - don't toggle immediately
    editorState.requestEditorModeToggle()
}
.onReceive(NotificationCenter.default.publisher(for: .didSaveCursorPosition)) { notification in
    // Cursor saved - now complete the toggle
    if let position = notification.userInfo?["position"] as? CursorPosition {
        cursorPositionToRestore = position
    }
    editorState.toggleEditorMode()  // Actually switch now
}
```

### Task 4: Update MilkdownEditor coordinator to respond to toggle notification

Add notification observer in the coordinator:

```swift
// In MilkdownEditor.Coordinator init
NotificationCenter.default.addObserver(
    forName: .willToggleEditorMode,
    object: nil,
    queue: .main
) { [weak self] _ in
    self?.saveAndNotify()
}

private func saveAndNotify() {
    guard isEditorReady, let webView, !isCleanedUp else {
        // Editor not ready - post notification with start position
        NotificationCenter.default.post(
            name: .didSaveCursorPosition,
            object: nil,
            userInfo: ["position": CursorPosition.start]
        )
        return
    }

    webView.evaluateJavaScript("JSON.stringify(window.FinalFinal.getCursorPosition())") { result, _ in
        var position = CursorPosition.start
        if let json = result as? String,
           let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let line = dict["line"] as? Int,
           let column = dict["column"] as? Int {
            position = CursorPosition(line: line, column: column)
        }

        NotificationCenter.default.post(
            name: .didSaveCursorPosition,
            object: nil,
            userInfo: ["position": position]
        )
    }
}
```

### Task 5: Apply same pattern to CodeMirrorEditor

Same notification observer pattern for symmetry (CM→MD toggle).

### Task 6: Bump Version

- `web/package.json`: 0.1.20 → 0.1.21
- `project.yml`: 0.1.20 → 0.1.21

---

## Verification

```bash
cd web && pnpm build
cd .. && xcodegen generate && xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

**Manual tests:**
1. Place cursor on line 47 in CM → toggle to MD → cursor should be on line 47
2. Place cursor on line 47 in MD → toggle to CM → cursor should be on line 47
3. Rapid toggling (Cmd+/ multiple times) should not lose position
4. Test at document start, middle, and end
