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

## SwiftUI Gesture Modifier Order

### Double-Tap Must Be Attached Before Single-Tap

When using both `.onTapGesture(count: 2)` and `.onTapGesture` (count: 1), SwiftUI requires the double-tap modifier to be attached **first** (inner modifier). If single-tap is attached first, it fires immediately and the double-tap never triggers.

```swift
// WRONG — single-tap always fires, double-tap never triggers
.onTapGesture { handleSingleTap() }
.onTapGesture(count: 2) { handleDoubleTap() }

// RIGHT — double-tap gets priority
.onTapGesture(count: 2) { handleDoubleTap() }
.onTapGesture { handleSingleTap() }
```

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

---

## TaskGroup.addTask Does NOT Inherit @MainActor Isolation

**Problem:** Main Thread Checker violation: `[WKWebView evaluateJavaScript:completionHandler:]` called on a background thread from within `fetchContentFromWebView()`.

**Root Cause:** The function used `withTaskGroup` + `group.addTask { }`. Unlike `Task { }` (which inherits the caller's actor isolation), `TaskGroup.addTask` always runs its closure on the cooperative thread pool, even when called from a `@MainActor` context.

```swift
// WRONG - addTask runs on cooperative pool, not main actor
@MainActor func example() async {
    await withTaskGroup(of: String?.self) { group in
        group.addTask {
            // This runs on a background thread!
            webView.evaluateJavaScript(...) // Main Thread Checker violation
        }
    }
}
```

**Failed fix:** Using `group.addTask { @MainActor in }` with the async `evaluateJavaScript` overload caused a **deadlock** during app startup. The `@MainActor` task needed the main actor, but the parent `withTaskGroup` was suspended on the main actor waiting for `group.next()`. While Swift's cooperative threading should handle this (the suspend releases the actor), in practice this stalled long enough during startup to prevent the window from appearing.

**Working fix:** Use `DispatchQueue.main.async` inside `withCheckedContinuation` to dispatch the one main-thread call without requiring actor isolation on the task:

```swift
group.addTask {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async {
            webView.evaluateJavaScript("...") { result, error in
                continuation.resume(returning: result as? String)
            }
        }
    }
}
```

**Why this works:** `DispatchQueue.main.async` is non-blocking — it enqueues the work and returns immediately. The continuation bridges the callback result back to the async world. No actor isolation needed on the task itself.

**Key distinction:**
- `Task { }` — inherits caller's actor isolation (safe for @MainActor calls)
- `TaskGroup.addTask { }` — always runs on cooperative pool (NOT safe for @MainActor calls)
- `DispatchQueue.main.async { }` inside `withCheckedContinuation` — correct bridging pattern for main-thread API calls from non-isolated task group children

---

## Editor Toggle Cursor Sync

### Two-Phase Toggle with `batchInitialize` Race Prevention

**Problem:** Cursor position was lost when switching from Milkdown to CodeMirror (MD→CM). The cursor was correctly saved and passed via the binding, but always reset to position 0.

**Root Cause:** `batchInitialize()` queues JS `initialize({content, cursor})` which sets the cursor correctly. But it didn't update `lastPushedContent`, so the immediately-following `updateNSView` cycle saw `lastPushedContent == ""`, decided `shouldPushContent()` was true, and called `setContent()` — which reset the cursor to 0. Both JS calls execute in order: `initialize()` sets cursor, then `setContent()` wipes it.

**Why CM→MD worked by accident:** Milkdown's `batchInitialize()` does an async `typeof window.FinalFinal` check before calling `initialize()`. This delay pushes `initialize()` past `updateNSView`'s `setContent()`, so `initialize()` (with cursor) runs last and wins.

**Solution:** Set `lastPushedContent = content` and `lastPushTime = Date()` in `batchInitialize()` *before* the JS call. This makes `shouldPushContent()` return false in `updateNSView`, preventing the redundant `setContent()`. Applied to both CodeMirror and Milkdown for consistency.

```swift
func batchInitialize() {
    let content = contentBinding.wrappedValue
    // ...read theme, cursor...

    // CRITICAL: Prevent updateNSView from re-pushing content
    lastPushedContent = content
    lastPushTime = Date()

    // Now queue initialize() with cursor
    webView.evaluateJavaScript("window.FinalFinal.initialize({...})")
}
```

**Error recovery:** If `initialize()` fails, reset `lastPushedContent = ""` so `updateNSView` can retry the content push on the next cycle.

### Two-Phase Toggle Flow

The toggle uses a two-phase notification pattern to ensure cursor is saved before the editor switch:

1. **Phase 1 (`willToggleEditorMode`):** Outgoing editor saves cursor position, posts `didSaveCursorPosition`
2. **Phase 2 (`didSaveCursorPosition`):** Sets `cursorRestore` binding, then posts `toggleEditorMode` to do the actual switch
3. **`dismantleNSView`:** Skips redundant cursor save if Phase 1 already set the binding

This prevents the race where the old editor is torn down before its cursor position can be read.

**General principle:** When `NSViewRepresentable` lifecycle methods (`makeNSView`, `updateNSView`) interact with async JS calls, ensure shared state guards (like `lastPushedContent`) are set synchronously *before* the async call, not in its callback.

### `initialize()` vs `setContentWithBlockIds()` Race (Image Metadata Loss)

**Problem:** Image width and caption were lost when switching from CodeMirror back to Milkdown, even though the database correctly preserved image metadata via `ImageMeta` struct matching in `replaceBlocks()`.

**Root Cause:** In `webView(_:didFinish:)`, two content-pushing paths start simultaneously:

1. **`batchInitialize()`** → async `typeof window.FinalFinal` check → callback fires → `performBatchInitialize()` → queues `initialize({content, theme, cursor})` — replaces entire ProseMirror doc **without** image metadata
2. **`onWebViewReady` callback** → `Task { setContentWithBlockIds(markdown, blockIds, {imageMeta}) }` — replaces doc **with** image width/caption

Due to the async typeof check, the JS execution order was:
1. `typeof window.FinalFinal` (from path A)
2. `setContentWithBlockIds(...)` (from path B — Task body runs)
3. `initialize(...)` (from path A — typeof callback fires, dispatches initialize)

So `setContentWithBlockIds()` correctly applied image width, then `initialize()` overwrote the entire document without width. Width was lost.

**Solution:** When `isResettingContent` is true (meaning `onWebViewReady` will push content via `setContentWithBlockIds()`), skip content in `performBatchInitialize()`:

```swift
let effectiveContent = isResettingContentBinding.wrappedValue ? "" : content

// Always set lastPushedContent to REAL content to prevent updateNSView re-push
lastPushedContent = content

var options: [String: Any] = ["content": effectiveContent, "theme": theme]
```

JS `initialize()` also guards against empty content:

```typescript
if (options.content.length > 0) {
    setContent(options.content);
}
```

And cursor binding clearing is skipped when content was empty (cursor will be restored later by `restoreCursorPositionIfNeeded()` after `setContentWithBlockIds()` loads the real content).

**General principle:** When multiple async paths converge on the same JS thread, the "last write wins" race depends on callback timing. Guard against overwrites by skipping redundant pushes when a more complete path (with metadata) is already in flight.

### Scroll Position Sync: Why Text Matching Drifts

**Problem:** V1 scroll sync used `pmPosToMdLine()` (text matching) and `mdLineToPmPos()` (reverse text matching) to convert between scroll position and markdown line numbers. This drifted — especially further down the document — because:

1. Text matching scans from line 1 and always matches the first occurrence of duplicate text (e.g., repeated paragraph openings like "The" or "In this section")
2. Block-counting fallback counts ALL PM blocks (including nested table cells, list items) vs non-empty markdown lines — these don't align 1:1
3. Integer line numbers lack sub-line precision for blocks with different rendered heights (images vs text)

**Solution:** Anchor map with type-dispatch matching (`scroll-map.ts`). Instead of searching for text, walk PM doc top-level nodes and markdown lines in parallel using a type-dispatch table that matches each node type by its markdown pattern (headings by `#` prefix, tables by `|`, code blocks by `` ``` ``, etc.). This avoids false matches from duplicate text content. Linear interpolation between anchor points provides sub-line precision via floating-point `topLine`.

**General principle:** When mapping between two document representations (PM tree and markdown text), dispatch on structural type rather than matching text content. Text matching has O(n) false-positive risk that grows with document length.
