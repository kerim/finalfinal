# Plan: Fix Duplicate NSSavePanel on New Project

## Problem

When pressing Cmd+N for "New Project", **two NSSavePanels** are created. The user discovered this by dragging one panel aside and seeing another identical panel behind it.

## Root Cause

**Duplicate notification observers.** Both AppDelegate and ContentView listen for `.newProject` and `.openProject` notifications, each calling `FileOperations.handleNewProject()` / `handleOpenProject()` independently.

### Observer #1: AppDelegate.swift (lines 64-78)
```swift
NotificationCenter.default.addObserver(forName: .newProject, ...) { _ in
    FileOperations.handleNewProject()
}
NotificationCenter.default.addObserver(forName: .openProject, ...) { _ in
    FileOperations.handleOpenProject()
}
```

### Observer #2: ContentView.swift (lines 1455-1460)
```swift
.onReceive(NotificationCenter.default.publisher(for: .newProject)) { _ in
    FileOperations.handleNewProject()
}
.onReceive(NotificationCenter.default.publisher(for: .openProject)) { _ in
    FileOperations.handleOpenProject()
}
```

### Flow
1. User presses Cmd+N
2. FileCommands posts `.newProject` notification
3. AppDelegate observer → creates save panel #1
4. ContentView observer → creates save panel #2

## Solution

**Remove the duplicate observers from ContentView.** Keep the AppDelegate observers because:
- AppDelegate always exists, even when no windows are open
- It handles File menu commands before any ContentView is created
- ContentView observers are redundant once AppDelegate handles these

## Files to Modify

`final final/Views/ContentView.swift`

## Changes

Remove the `.newProject` and `.openProject` handlers from the `withFileNotifications` modifier (around lines 1455-1460):

```swift
// REMOVE these two .onReceive handlers:
.onReceive(NotificationCenter.default.publisher(for: .newProject)) { _ in
    FileOperations.handleNewProject()
}
.onReceive(NotificationCenter.default.publisher(for: .openProject)) { _ in
    FileOperations.handleOpenProject()
}
```

Keep all other handlers in `withFileNotifications` (`.closeProject`, `.saveProject`, `.importMarkdown`, `.exportMarkdown`, `.projectDidOpen`, `.projectDidCreate`, `.projectDidClose`, `.projectIntegrityError`).

## Code Review Notes

**Validated by swift-code-reviewer:**
- Removing ContentView observers is correct - panel-opening operations are stateless
- AppDelegate always exists, handles commands even with zero windows
- ContentView observers for `.projectDidOpen`, `.projectDidCreate`, etc. should remain (they need view state)
- Only `.newProject` and `.openProject` are duplicated

**Optional improvement (not required for fix):** Store AppDelegate observer references for consistency:
```swift
private var newProjectObserver: Any?
private var openProjectObserver: Any?
```
This is a minor consistency improvement - AppDelegate lives forever so cleanup isn't strictly needed.

## Verification

1. Build: `xcodebuild -scheme "final final" -destination 'platform=macOS' build`
2. Launch the app
3. Press Cmd+N to open "New Project" dialog
4. Verify only ONE save panel appears
5. Enter a name and click Save
6. Verify dialog dismisses smoothly and project opens
7. Also test Cmd+O (Open Project) - should show only ONE open panel
