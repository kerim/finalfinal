# Focus Mode Enhancement Plan - Architecture Review

**Reviewed:** 2026-02-05
**Plan File:** `/Users/niyaro/Documents/Code/final final/docs/plans/majestic-booping-sunbeam.md`
**Reviewer:** Swift Feature Architect

---

## Executive Summary

The plan is well-structured and addresses a genuine UX need for distraction-free writing. However, several architectural issues need attention before implementation:

1. **Critical:** macOS full screen API approach is incomplete
2. **Important:** State restoration on launch has race condition potential
3. **Important:** Missing `Sendable` conformance for `FocusModeSnapshot`
4. **Moderate:** Toast implementation should use native SwiftUI patterns

---

## 1. macOS Full Screen API Correctness

### Issue

The plan mentions:
```swift
func isInFullScreen() -> Bool
func enterFullScreen()
func exitFullScreen()
```

But macOS full screen is controlled via `NSWindow`, not pure SwiftUI. The plan does not specify how to access the window.

### Recommended Approach

```swift
// In a WindowAccessor or similar utility
@MainActor
struct FullScreenManager {
    static func enterFullScreen() {
        guard let window = NSApp.mainWindow else { return }
        if !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    static func exitFullScreen() {
        guard let window = NSApp.mainWindow else { return }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    static func isInFullScreen() -> Bool {
        NSApp.mainWindow?.styleMask.contains(.fullScreen) ?? false
    }
}
```

### Gotcha: Full Screen Transition Is Animated

`toggleFullScreen(_:)` is asynchronous - the window animates into full screen over ~500ms. The plan assumes immediate state change, but:

1. `wasInFullScreen` capture might be incorrect if checked during animation
2. Other UI changes (sidebar hiding) might race with the full screen animation

**Recommendation:** Use `NSWindowDelegate.windowDidEnterFullScreen(_:)` and `windowDidExitFullScreen(_:)` to know when transitions complete, or use `NSWindow.isZoomed` check with a small delay.

---

## 2. State Management Patterns

### Current EditorViewState Analysis

The existing `EditorViewState` is `@MainActor @Observable` which is correct. The proposed additions are:

```swift
struct FocusModeSnapshot {
    let wasInFullScreen: Bool
    let outlineSidebarVisible: Bool
    let annotationPanelVisible: Bool
    let annotationDisplayModes: [AnnotationType: AnnotationDisplayMode]
}

var focusModeEnabled: Bool = false  // Persisted
var preFocusModeState: FocusModeSnapshot?  // Session-only
var showFocusModeToast: Bool = false
```

### Issues

**Issue 1: `FocusModeSnapshot` needs `Sendable` conformance**

If this struct crosses actor boundaries (e.g., during persistence), it must be `Sendable`. Since it contains only value types and the dictionary's key/value types should also be `Sendable`:

```swift
struct FocusModeSnapshot: Sendable {
    // ... fields
}
```

**Issue 2: Persistence of `focusModeEnabled` is mentioned but not specified**

The plan says `focusModeEnabled` persists between sessions but doesn't specify how. Options:

1. **UserDefaults** (simple, recommended for single boolean)
2. **Database** (unnecessary complexity for a preference)
3. **AppStorage** (SwiftUI native, but doesn't work directly with `@Observable`)

**Recommended approach:**

```swift
// In EditorViewState
var focusModeEnabled: Bool {
    didSet {
        UserDefaults.standard.set(focusModeEnabled, forKey: "focusModeEnabled")
    }
}

init() {
    self.focusModeEnabled = UserDefaults.standard.bool(forKey: "focusModeEnabled")
    // ... other init
}
```

**Issue 3: Launch restoration race condition**

The plan states:
> If user quits while in focus mode, restore on next launch
> On restore: capture fresh pre-state (app's default launch state), then apply focus mode

The problem: On launch, the "default state" isn't stable until views have appeared. If `enterFocusMode()` is called too early:

- `isInFullScreen()` returns `false` (window hasn't restored yet)
- Sidebar visibility might not be loaded
- ContentView's `.task` runs before window state is ready

**Recommendation:** Delay focus mode restoration until after window appearance is stable:

```swift
// In ContentView .task or .onAppear
.task {
    // Wait for window to be ready
    try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms

    if editorState.focusModeEnabled && editorState.preFocusModeState == nil {
        // Restoring from previous session - capture current state as "default"
        await editorState.restoreFocusModeFromLaunch()
    }
}
```

---

## 3. Enter/Exit Focus Mode Methods

### Proposed Implementation Review

The plan outlines:

```swift
func enterFocusMode() {
    // Capture snapshot
    // Hide sidebars
    // Collapse annotations
    // Set focusModeEnabled = true
    // Trigger toast
}
```

### Issues

**Issue 1: Methods should be `async` for full screen transitions**

Since full screen is animated and sidebar changes might need UI settling:

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
        // Wait for animation
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    // 3. Hide sidebars
    isOutlineSidebarVisible = false
    isAnnotationPanelVisible = false

    // 4. Collapse annotations
    for type in AnnotationType.allCases {
        annotationDisplayModes[type] = .collapsed
    }

    // 5. Enable focus mode
    focusModeEnabled = true

    // 6. Show toast
    showFocusModeToast = true
}
```

**Issue 2: Exit should respect `wasInFullScreen`**

```swift
@MainActor
func exitFocusMode() async {
    guard focusModeEnabled else { return }
    guard let snapshot = preFocusModeState else {
        // No snapshot - just disable focus mode
        focusModeEnabled = false
        return
    }

    // 1. Exit full screen ONLY if focus mode entered it
    if FullScreenManager.isInFullScreen() && !snapshot.wasInFullScreen {
        FullScreenManager.exitFullScreen()
        try? await Task.sleep(nanoseconds: 600_000_000)
    }

    // 2. Restore sidebar visibility
    isOutlineSidebarVisible = snapshot.outlineSidebarVisible
    isAnnotationPanelVisible = snapshot.annotationPanelVisible

    // 3. Restore annotation display modes
    annotationDisplayModes = snapshot.annotationDisplayModes

    // 4. Disable focus mode and paragraph dimming
    focusModeEnabled = false

    // 5. Clear snapshot
    preFocusModeState = nil
}
```

---

## 4. Keyboard Shortcut Handling

### Plan Approach

The plan correctly identifies Cmd+Shift+F and Esc as the shortcuts.

### Issues with Esc Handler

**Issue 1: `.onKeyPress(.escape)` placement matters**

The plan says to add Esc handler in ContentView, but `.onKeyPress` only works when the view (or a child) has focus. In a WKWebView-heavy app, the WebView often has keyboard focus.

**Options:**

1. **NSEvent local monitor** (reliable, works globally within app)
2. **Menu item with Esc shortcut** (standard macOS pattern)
3. **WebView intercept** (complex, not recommended)

**Recommended: Menu item approach**

```swift
// In EditorCommands.swift
Button("Exit Focus Mode") {
    NotificationCenter.default.post(name: .exitFocusMode, object: nil)
}
.keyboardShortcut(.escape, modifiers: [])
.disabled(!editorState.focusModeEnabled)  // Only active when in focus mode
```

However, this conflicts with other uses of Esc (e.g., closing dialogs). A better approach is conditional handling in a local event monitor:

```swift
// In AppDelegate or a dedicated EventMonitor class
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    if event.keyCode == 53 /* Esc */ && editorState.focusModeEnabled {
        Task { @MainActor in
            await editorState.exitFocusMode()
        }
        return nil  // Consume the event
    }
    return event
}
```

---

## 5. Toast Implementation

### Plan Approach

> Show toast: "Press Esc or Cmd+Shift+F to exit focus mode" (auto-dismiss after 3s)

### Better Approach: Use Native macOS Patterns

Rather than implementing a custom toast overlay, consider:

1. **Use `NSAlert` with timer** (heavyweight, not ideal)
2. **Use overlay with animation** (the plan's approach, acceptable)
3. **Use accessibility announcement** (silent alternative)

For a writing app, the overlay approach is fine. Here's a proper SwiftUI implementation:

```swift
// FocusModeToast.swift
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
        .padding(.top, 60)  // Below toolbar
}
```

---

## 6. Sidebar Visibility Sync

### Current Implementation Analysis

ContentView already has sidebar sync:

```swift
.onChange(of: editorState.isOutlineSidebarVisible) { _, newValue in
    sidebarVisibility.wrappedValue = newValue ? .all : .detailOnly
}
```

This pattern is correct and will work with focus mode changes.

### Potential Issue: Animation Timing

When entering focus mode, multiple state changes happen:
1. `isOutlineSidebarVisible = false`
2. `isAnnotationPanelVisible = false`
3. Full screen animation starts

These might cause visual jank. Consider using `withAnimation`:

```swift
withAnimation(.easeInOut(duration: 0.3)) {
    isOutlineSidebarVisible = false
    isAnnotationPanelVisible = false
}
```

---

## 7. Files to Modify - Review

The plan's file list is accurate:

| File | Purpose | Notes |
|------|---------|-------|
| `ViewState/EditorViewState.swift` | State + methods | Add `Sendable` to snapshot, use `async` methods |
| `Views/ContentView.swift` | Full screen helpers, toast, Esc handling | Consider NSEvent monitor instead of `.onKeyPress` |
| `Commands/EditorCommands.swift` | Update Cmd+Shift+F | Call async methods via Task |

### Missing Files

Consider adding:
- `Utilities/FullScreenManager.swift` - Encapsulate NSWindow full screen logic

---

## 8. Implementation Order - Revised

The plan's order is mostly good, but with adjustments:

1. Add `FocusModeSnapshot` struct with `Sendable` conformance
2. Add state properties to `EditorViewState`
3. **Add `FullScreenManager` utility** (before methods that use it)
4. Implement `enterFocusMode()` and `exitFocusMode()` as `async` methods
5. Add persistence (UserDefaults for `focusModeEnabled`)
6. Wire Cmd+Shift+F to new methods
7. Add Esc key handler (NSEvent monitor)
8. Add toast notification view
9. Add launch restoration with delay

---

## 9. Additional Recommendations

### Accessibility

Add VoiceOver announcements for focus mode transitions:

```swift
UIAccessibility.post(notification: .announcement, argument: "Focus mode enabled")
```

Note: On macOS, use `NSAccessibility.post(element:notification:)` instead.

### Testing Considerations

1. **Unit test** the snapshot capture/restore logic (no UI needed)
2. **UI test** the full screen transitions (challenging due to animations)
3. **Manual test** the launch restoration path

### Edge Cases to Handle

1. User manually exits full screen while in focus mode (via green button or Ctrl+Cmd+F)
2. User toggles sidebars manually during focus mode (plan addresses this)
3. Multiple windows scenario (focus mode should be per-window?)
4. Space/Mission Control interactions with full screen

---

## Summary of Required Changes

| Priority | Change | Reason |
|----------|--------|--------|
| Critical | Add `FullScreenManager` with proper NSWindow access | Full screen API requires NSWindow |
| Critical | Make `enterFocusMode()`/`exitFocusMode()` async | Full screen transitions are animated |
| Important | Add `Sendable` to `FocusModeSnapshot` | Swift 6 strict concurrency |
| Important | Use NSEvent monitor for Esc key | `.onKeyPress` unreliable with WebView focus |
| Important | Delay launch restoration | Window state not stable immediately on launch |
| Moderate | Add UserDefaults persistence for `focusModeEnabled` | Plan mentions persistence but no mechanism |
| Moderate | Use `withAnimation` for sidebar changes | Smoother visual transition |

---

## Conclusion

The plan is solid in its UX goals and overall structure. The main gaps are:

1. **macOS-specific full screen API** - needs NSWindow access
2. **Async handling** - full screen transitions are not instant
3. **Keyboard handling** - Esc key needs special consideration with WKWebView

With the adjustments outlined above, the implementation should be straightforward and maintainable.
