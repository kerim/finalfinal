# SwiftUI / WebKit Patterns

Patterns for SwiftUI integration with WKWebView. Consult before writing related code.

---

## AppDelegate.shared Pattern

`NSApp.delegate as? YourAppDelegate` returns `nil` with `@NSApplicationDelegateAdaptor`. Store static reference:

```swift
class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
    }
}
```

## WKWebView Web Inspector

Enable with `webView.isInspectable = true`. Connect via Safari -> Develop menu.

---

## macOS Event Handling

### Ctrl-Click vs Right-Click Are Different Events

On macOS, ctrl+left-click and physical right-click generate **different event types**:

- **Physical right-click** (two-finger tap, right mouse button) -> `.rightMouseDown` event
- **Ctrl+left-click** -> `.leftMouseDown` event with `event.modifierFlags.contains(.control) == true`

To handle both as "secondary click", monitor both event types:

```swift
eventMonitor = NSEvent.addLocalMonitorForEvents(
    matching: [.rightMouseDown, .leftMouseDown]
) { event in
    let isRightClick = event.type == .rightMouseDown
    let isCtrlClick = event.type == .leftMouseDown && event.modifierFlags.contains(.control)

    guard isRightClick || isCtrlClick else { return event }
    // Handle secondary click...
    return nil  // Consume event
}
```

SwiftUI's `.onTapGesture` consumes ctrl+click before custom handlers can intercept it, so use `NSEvent.addLocalMonitorForEvents` with event consumption (`return nil`) to prevent click-through.

### Use `.overlay()` Not `.background()` for Event-Intercepting NSViews

An `NSViewRepresentable` placed as `.background()` never receives click events because `NSView.hitTest(_:)` traverses subviews front-to-back. The foreground SwiftUI view is checked first and consumes the event silently. Use `.overlay()` to place the NSView in front.

When the overlay should only intercept *some* events (e.g., right-clicks but not left-clicks), override `hitTest` to pass through selectively:

```swift
override func hitTest(_ point: NSPoint) -> NSView? {
    if let event = NSApp.currentEvent {
        if event.type == .rightMouseDown { return super.hitTest(point) }
        if event.type == .leftMouseDown && event.modifierFlags.contains(.control) {
            return super.hitTest(point)
        }
    }
    return nil  // Pass left-clicks through to views behind
}
```

See `DraggableCardView.swift` (`PassthroughHostingView`) for a working example.

---

## Performance

### Console Print Statements Cause UI Freezes

**Problem:** During drag-drop reordering, the UI would freeze/stutter noticeably.

**Root Cause:** Print statements scattered throughout the code path were causing synchronous console I/O. Even "small" prints in frequently-called functions compound:

- SectionSyncService printing "[SectionSyncService] Not configured" 11 times per drop
- SectionCardView printing status/level changes on every render
- Editor coordinators printing cursor position debug info during content changes

**Why it matters:**
- `print()` is synchronous - blocks the main thread
- Drag-drop triggers many rapid state updates
- Each update cascades through multiple components with prints
- Console I/O latency (especially with Xcode attached) compounds

**Solution:**
1. Remove all debug prints from hot code paths
2. Wrap essential debug logging in `#if DEBUG` guards
3. For expected conditions (like "not configured" in demo mode), fail silently

**Pattern to avoid:**
```swift
// Bad - prints on every content change
func contentChanged(_ markdown: String) {
    print("[Service] Content changed: \(markdown.prefix(50))...")
    // process...
}
```

**Pattern to use:**
```swift
// Good - only print actual errors in debug builds
func contentChanged(_ markdown: String) {
    #if DEBUG
    if unexpectedCondition {
        print("[Service] Warning: \(reason)")
    }
    #endif
    // process...
}
```

---

## SwiftUI Data Flow

### Use IDs Not Indices When Communicating Between Filtered and Full Arrays

**Problem:** Drag-drop reordering worked correctly when viewing all sections, but moved sections to wrong positions when the sidebar was zoomed/filtered to show only a subset.

**Root Cause:** The drop handler calculated an `insertionIndex` based on the **filtered** array (`filteredSections` with 5 items), but the reorder function interpreted that index against the **full** array (`sections` with 17 items).

```swift
// In OutlineSidebar (filtered view):
let insertionIndex = 4  // Position in filteredSections

// In ContentView (full array):
let targetIdx = insertionIndex - 1  // = 3
let target = sections[targetIdx]    // WRONG! Index 3 in full array != index 3 in filtered array
```

**Solution:** Pass the **target section ID** instead of an index. IDs are stable across both arrays:

```swift
// Before (ambiguous)
struct SectionReorderRequest {
    let sectionId: String
    let insertionIndex: Int  // Filtered or full array? Unclear!
}

// After (unambiguous)
struct SectionReorderRequest {
    let sectionId: String
    let targetSectionId: String?  // Insert AFTER this section (nil = beginning)
}
```

The receiver uses `sections.firstIndex(where: { $0.id == targetId })` to find the correct position in its own array.

**General principle:** When passing position information between components that may have different views of the same data (filtered, sorted, paginated), use stable identifiers rather than indices.

---

## WKWebView Compositor Caching on Content Change

**Problem:** When zooming into a long section (2000+ words), the WebView showed the **wrong content** (previous section or full document). Scrolling in any direction "fixed" the display.

**Root Cause:** WKWebView's compositor layer caches the rendered content. When the DOM is updated via `setContent()`, the DOM and scroll position are correct (verified via JavaScript logging), but the compositor layer still shows cached content from the previous state. The browser's rendering pipeline hasn't flushed the compositor cache.

This is NOT a DOM issue (the DOM is correct) or a scroll position issue (scrollY is 0). It's a compositor-level caching issue specific to WKWebView.

**Evidence:** User-triggered scroll (any direction, any amount) immediately fixes the display. This indicates the compositor cache is invalidated on scroll events.

**Solution:** Trigger a programmatic micro-scroll after content update to force compositor refresh:

```typescript
// In setContent() zoom transition handler, after double RAF
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    // CRITICAL: Force compositor refresh with micro-scroll
    // WKWebView's compositor caches the previous content.
    // A scroll triggers compositor refresh, showing the new content.
    window.scrollTo({ top: 1, left: 0, behavior: 'instant' });
    window.scrollTo({ top: 0, left: 0, behavior: 'instant' });
    view.dom.scrollTop = 0;

    // Signal Swift that paint is complete
    webkit.messageHandlers.paintComplete.postMessage({ ... });
  });
});
```

**Why double RAF isn't enough:** The double `requestAnimationFrame` pattern waits for the browser to render the new content, but this only ensures the DOM is painted -- it doesn't guarantee the compositor layer is updated. WKWebView's compositor operates independently and may still serve cached tiles.

**Why micro-scroll works:** Scrolling invalidates the compositor cache because the browser must re-composite the visible viewport. By scrolling 1px down then immediately back to 0, we force cache invalidation without visible UI change.

**What didn't work:**
- `alphaValue = 0/1` hiding/showing the WebView (hides the view but doesn't touch compositor)
- `display: none` / `display: block` (same issue)
- Forcing layout with `void element.offsetHeight` (triggers layout, not compositor refresh)
- Longer delays (the compositor cache persists indefinitely until invalidated)

**General principle:** When WKWebView shows stale content despite correct DOM state, trigger a micro-scroll to force compositor cache invalidation.
