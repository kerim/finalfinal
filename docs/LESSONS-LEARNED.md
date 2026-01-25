# Lessons Learned

Technical patterns and pitfalls. Consult before writing new code.

---

## ProseMirror / Milkdown

### Use Decoration System, Not DOM Manipulation

Direct DOM manipulation breaks ProseMirror's reconciliation. Use `Decoration` system:

```typescript
// Wrong
document.querySelectorAll('.paragraph').forEach(el => el.classList.add('dimmed'));

// Right
const decorations = DecorationSet.create(doc, [
  Decoration.node(from, to, { class: 'dimmed' })
]);
```

---

## SwiftUI / WebKit

### AppDelegate.shared Pattern

`NSApp.delegate as? YourAppDelegate` returns `nil` with `@NSApplicationDelegateAdaptor`. Store static reference:

```swift
class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
    }
}
```

### WKWebView Web Inspector

Enable with `webView.isInspectable = true`. Connect via Safari → Develop menu.

---

## JavaScript

### Keyboard Shortcuts with Shift

`e.key` returns uppercase when Shift held. Always normalize:

```typescript
if (e.key.toLowerCase() === 'e') { ... }
```

---

## Cursor Position Mapping (Milkdown ↔ CodeMirror)

### ProseMirror textBetween() Returns Plain Text

`doc.textBetween()` strips all markdown syntax (`**`, `*`, `` ` ``, etc.). Searching for this plain text in markdown source will fail because the markdown contains the syntax characters.

**Wrong approach (text anchor):**
```typescript
const textBefore = doc.textBetween(start, head, '\n');
markdown.indexOf(textBefore); // Fails - textBefore has no syntax
```

**Right approach (line matching + offset mapping):**
1. Match paragraph text content to markdown lines (strip syntax from both sides)
2. Use bidirectional offset mapping that accounts for inline syntax length

### Bidirectional Offset Mapping Required

Converting cursor positions between WYSIWYG and source requires accounting for inline syntax:

| Markdown | Text Length | Markdown Length |
|----------|-------------|-----------------|
| `**bold**` | 4 ("bold") | 8 |
| `*italic*` | 6 ("italic") | 8 |
| `` `code` `` | 4 ("code") | 6 |
| `[link](url)` | 4 ("link") | 12 |

Functions needed:
- `textToMdOffset(mdLine, textOffset)` - ProseMirror → CodeMirror
- `mdToTextOffset(mdLine, mdOffset)` - CodeMirror → ProseMirror

### Line-Start Syntax Must Be Handled Separately

Headers, lists, and blockquotes have line-start syntax that affects column calculation:

```typescript
const syntaxMatch = line.match(/^(#+\s*|\s*[-*+]\s*|\s*\d+\.\s*|\s*>\s*)/);
const syntaxLength = syntaxMatch ? syntaxMatch[0].length : 0;
const contentAfterSyntax = line.slice(syntaxLength);
```

Apply offset mapping only to content after syntax, then add syntax length back.

---

## macOS Event Handling

### Ctrl-Click vs Right-Click Are Different Events

On macOS, ctrl+left-click and physical right-click generate **different event types**:

- **Physical right-click** (two-finger tap, right mouse button) → `.rightMouseDown` event
- **Ctrl+left-click** → `.leftMouseDown` event with `event.modifierFlags.contains(.control) == true`

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

## Build

### Vite emptyOutDir: false

Changes to source `index.html` won't sync to output. Either manually sync or set `emptyOutDir: true`.
