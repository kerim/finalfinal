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

## Build

### Vite emptyOutDir: false

Changes to source `index.html` won't sync to output. Either manually sync or set `emptyOutDir: true`.
