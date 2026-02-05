# Focus Mode Enhancement Plan

## Overview

Enhance focus mode from simple paragraph highlighting to a comprehensive distraction-free writing experience.

## Current State

- Cmd+Shift+F toggles `focusModeEnabled` boolean
- Milkdown applies `.ff-dimmed` (opacity 0.3) to non-current paragraphs
- CodeMirror ignores focus mode (WYSIWYG-only feature)

## New Behavior

### On Enter Focus Mode

1. **Capture pre-focus state** into `FocusModeSnapshot`
2. **Enter macOS native full screen** (if not already)
3. **Hide both sidebars** (outline + annotation panel) with animation
4. **Save annotation display modes**, set all to `.collapsed`
5. **Enable paragraph highlighting** (existing)
6. **Show toast**: "Press Esc or Cmd+Shift+F to exit focus mode" (auto-dismiss after 3s)

### During Focus Mode

- User can freely toggle sidebars (Cmd+[, Cmd+])
- User can change annotation display modes
- These changes are temporary — exit restores pre-focus state

### On Exit Focus Mode

1. **Exit full screen** only if focus mode entered it (respect user's original state)
2. **Restore sidebar visibility** from snapshot with animation
3. **Restore annotation display modes** from snapshot
4. **Disable paragraph highlighting**
5. **Clear snapshot**

### Persistence

- `focusModeEnabled` persists via UserDefaults
- If user quits while in focus mode, restore on next launch
- On restore: wait 500ms for window stability, capture fresh pre-state, then apply focus mode

## State Model

```swift
struct FocusModeSnapshot: Sendable {
    let wasInFullScreen: Bool
    let outlineSidebarVisible: Bool
    let annotationPanelVisible: Bool
    let annotationDisplayModes: [AnnotationType: AnnotationDisplayMode]
}

// In EditorViewState
var focusModeEnabled: Bool = false {
    didSet {
        UserDefaults.standard.set(focusModeEnabled, forKey: "focusModeEnabled")
    }
}
var preFocusModeState: FocusModeSnapshot?  // Session-only
var showFocusModeToast: Bool = false
```

## Full Screen Manager

NSWindow access required for full screen control (SwiftUI doesn't provide direct API):

```swift
// Utilities/FullScreenManager.swift
@MainActor
struct FullScreenManager {
    static func isInFullScreen() -> Bool {
        NSApp.mainWindow?.styleMask.contains(.fullScreen) ?? false
    }

    static func enterFullScreen() {
        guard let window = NSApp.mainWindow,
              !window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }

    static func exitFullScreen() {
        guard let window = NSApp.mainWindow,
              window.styleMask.contains(.fullScreen) else { return }
        window.toggleFullScreen(nil)
    }
}
```

**Important:** `toggleFullScreen(_:)` is animated (~500ms). Methods that call it must be `async` and wait for animation.

## Async Enter/Exit Methods

```swift
@MainActor
func enterFocusMode() async {
    guard !focusModeEnabled else { return }

    // 1. Capture pre-state
    preFocusModeState = FocusModeSnapshot(
        wasInFullScreen: FullScreenManager.isInFullScreen(),
        outlineSidebarVisible: isOutlineSidebarVisible,
        annotationPanelVisible: isAnnotationPanelVisible,
        annotationDisplayModes: annotationDisplayModes
    )

    // 2. Enter full screen (if not already)
    if !FullScreenManager.isInFullScreen() {
        FullScreenManager.enterFullScreen()
        try? await Task.sleep(nanoseconds: 600_000_000)  // Wait for animation
    }

    // 3. Hide sidebars with animation
    withAnimation(.easeInOut(duration: 0.3)) {
        isOutlineSidebarVisible = false
        isAnnotationPanelVisible = false
    }

    // 4. Collapse annotations
    for type in AnnotationType.allCases {
        annotationDisplayModes[type] = .collapsed
    }

    // 5. Enable focus mode
    focusModeEnabled = true

    // 6. Show toast
    showFocusModeToast = true
}

@MainActor
func exitFocusMode() async {
    guard focusModeEnabled else { return }
    guard let snapshot = preFocusModeState else {
        focusModeEnabled = false
        return
    }

    // 1. Exit full screen ONLY if focus mode entered it
    if FullScreenManager.isInFullScreen() && !snapshot.wasInFullScreen {
        FullScreenManager.exitFullScreen()
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    // 2. Restore sidebar visibility with animation
    withAnimation(.easeInOut(duration: 0.3)) {
        isOutlineSidebarVisible = snapshot.outlineSidebarVisible
        isAnnotationPanelVisible = snapshot.annotationPanelVisible
    }

    // 3. Restore annotation display modes
    annotationDisplayModes = snapshot.annotationDisplayModes

    // 4. Disable focus mode
    focusModeEnabled = false

    // 5. Clear snapshot
    preFocusModeState = nil
}
```

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| Cmd+Shift+F | Toggle focus mode |
| Esc | Exit focus mode (only when active) |

### Esc Key Handling

`.onKeyPress(.escape)` is unreliable when WKWebView has focus. Use NSEvent local monitor instead:

```swift
// In AppDelegate or dedicated EventMonitor class
private var escMonitor: Any?

func setupEscapeMonitor(editorState: EditorViewState) {
    escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        if event.keyCode == 53 /* Esc */ && editorState.focusModeEnabled {
            Task { @MainActor in
                await editorState.exitFocusMode()
            }
            return nil  // Consume the event
        }
        return event
    }
}
```

## Toast Notification

```swift
struct FocusModeToast: View {
    @Binding var isShowing: Bool

    var body: some View {
        if isShowing {
            Text("Press Esc or Cmd+Shift+F to exit focus mode")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .transition(.opacity.combined(with: .move(edge: .top)))
                .task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    withAnimation {
                        isShowing = false
                    }
                }
        }
    }
}

// Usage in ContentView
.overlay(alignment: .top) {
    FocusModeToast(isShowing: $editorState.showFocusModeToast)
        .padding(.top, 60)
}
```

## Launch Restoration

Window state is not stable immediately on launch. Delay restoration:

```swift
// In ContentView .task
.task {
    // Wait for window to stabilize
    try? await Task.sleep(nanoseconds: 500_000_000)

    if editorState.focusModeEnabled && editorState.preFocusModeState == nil {
        // Restoring from previous session
        await editorState.enterFocusMode()
    }
}
```

## Files to Modify

| File | Changes |
|------|---------|
| `Utilities/FullScreenManager.swift` | **New file** - NSWindow full screen control |
| `ViewState/EditorViewState.swift` | Add `FocusModeSnapshot` (Sendable), state properties, async `enterFocusMode()`/`exitFocusMode()`, UserDefaults persistence |
| `Views/ContentView.swift` | Toast overlay, launch restoration with delay |
| `App/AppDelegate.swift` | NSEvent monitor for Esc key |
| `Commands/EditorCommands.swift` | Update Cmd+Shift+F to call async methods via Task |

## No Web Changes Required

- `setFocusMode()` already handles paragraph highlighting
- `setAnnotationDisplayModes()` already syncs display modes

## Implementation Order

1. Create `Utilities/FullScreenManager.swift`
2. Add `FocusModeSnapshot` struct with `Sendable` conformance
3. Add state properties to `EditorViewState` with UserDefaults persistence
4. Implement async `enterFocusMode()` and `exitFocusMode()`
5. Wire Cmd+Shift+F to new methods (via Task for async)
6. Add NSEvent monitor for Esc key in AppDelegate
7. Add `FocusModeToast` view to ContentView
8. Add launch restoration with 500ms delay

## Verification Checklist

- [ ] Cmd+Shift+F enters focus mode
- [ ] Full screen activates (if not already)
- [ ] Both sidebars hidden with smooth animation
- [ ] Annotations switch to collapsed
- [ ] Paragraph highlighting active
- [ ] Toast appears and auto-dismisses after 3s
- [ ] Esc exits focus mode (even when editor has focus)
- [ ] Cmd+Shift+F also exits focus mode
- [ ] Full screen exits only if focus mode entered it
- [ ] Sidebars restored to pre-focus state with animation
- [ ] Annotation modes restored to pre-focus state
- [ ] Manual sidebar toggles during focus mode work
- [ ] Exit still restores original sidebar state after manual toggles
- [ ] Quit while in focus mode, relaunch — focus mode restores after ~500ms
- [ ] Exit after restore returns to app's default state

## Edge Cases

- User manually exits full screen during focus mode (green button) — focus mode continues, won't try to exit full screen on exit
- Multiple windows — focus mode is per-EditorViewState (document-level)
- Space/Mission Control — full screen transitions may be interrupted; methods handle nil window gracefully
