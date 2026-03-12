# WebKit Debug Logging (JS → Xcode Console)

How to get JavaScript debug output into Xcode's console without Safari Web Inspector.

---

## Why Not console.log?

`console.log()` and `console.error()` in WKWebView are **not bridged** to Xcode's debug console. They only appear in Safari's Web Inspector, which:

- Requires `webView.isInspectable = true` and Safari → Develop menu
- Loses context when the WebView reloads (e.g., switching between Milkdown and CodeMirror)
- Can't be left running for passive diagnostics

## The errorHandler Bridge

Both editors register a `WKScriptMessageHandler` named `"errorHandler"`:

```swift
// In CodeMirrorEditor.swift / MilkdownEditor.swift — makeNSView()
controller.add(context.coordinator, name: "errorHandler")
```

The coordinator routes messages through `DebugLog` categories (debug builds only):

```swift
// In CodeMirrorCoordinator+Handlers.swift / MilkdownCoordinator+MessageHandlers.swift
if message.name == "errorHandler", let body = message.body as? [String: Any] {
    let msgType = body["type"] as? String ?? "unknown"
    let msg = body["message"] as? String ?? "unknown"
    switch msgType {
    case "sync-diag":
        DebugLog.log(.sync, "[CodeMirrorEditor] JS SYNC-DIAG: \(msg)")
    case "debug", "slash-diag":
        DebugLog.log(.editor, "[CodeMirrorEditor] JS \(msgType.uppercased()): \(msg)")
    case "plugin-error", "unhandledrejection", "error":
        DebugLog.log(.editor, "[CodeMirrorEditor] JS ERROR: \(msg)")
    default:
        DebugLog.log(.editor, "[CodeMirrorEditor] JS \(msgType.uppercased()): \(msg)")
    }
}
```

Enable `.sync` to see sync diagnostics, or `.editor` to see JS errors and debug messages. See [debug-logging.md](debug-logging.md) for the full category system.

## Usage in JavaScript/TypeScript

### Inline (one-off diagnostics)

```typescript
(window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
  type: 'debug',
  message: `[MyPlugin] some value: ${someVar}`,
});
```

The optional chaining (`?.`) ensures this is a no-op outside WKWebView (e.g., in a browser dev environment).

### Helper function (repeated use)

For modules that need many log calls, wrap it in a helper:

```typescript
function myLog(...args: unknown[]) {
  const msg = args
    .map((a) => {
      if (a instanceof Error) return `${a.message}\n${a.stack}`;
      if (typeof a === 'string') return a;
      return JSON.stringify(a);
    })
    .join(' ');
  (window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
    type: 'my-diag',
    message: msg,
  });
}
```

See `slash-completions.ts:slashLog()` for a working example.

### Type field conventions

| `type` value | Used for | Swift `DebugLog` category |
|---|---|---|
| `sync-diag` | Block sync diagnostics | `.sync` |
| `debug` | General diagnostics | `.editor` |
| `error` | JS errors, catch blocks | `.editor` |
| `slash-diag` | Slash command diagnostics | `.editor` |
| `plugin-error` | CodeMirror exception sink | `.editor` |
| `unhandledrejection` | Unhandled promise rejections | `.editor` |

The Swift side uppercases the type in the log prefix, e.g. `[CodeMirrorEditor] JS DEBUG: ...`.

## Canary Pattern

To confirm a new JS bundle is loaded after a build, add a module-level canary:

```typescript
(window as any).webkit?.messageHandlers?.errorHandler?.postMessage({
  type: 'debug',
  message: '[MyPlugin] Module loaded — v2 canary',
});
```

This fires once at module load time. If you don't see it in Xcode console after Cmd+R, the old bundle is cached.

## Practical Example: Image Caption Debugging

The image-preview-plugin used this pattern to diagnose why captions were never found at runtime:

```typescript
// Entry: log how many lines the document has
message: `[ImagePreview] buildDecorations called, lines: ${doc.lines}`

// Per-image: log when a caption is found
message: `[ImagePreview] Found caption: "${caption}" on line ${checkLineNum} for image on line ${i}`

// Summary: count replace vs widget decorations
message: `[ImagePreview] Built ${replaceCount} replace + ${widgetCount} widget decorations`
```

Output in Xcode console:
```
[CodeMirrorEditor] JS DEBUG: [ImagePreview] buildDecorations called, lines: 24
[CodeMirrorEditor] JS DEBUG: [ImagePreview] Built 0 replace + 3 widget decorations
```

The "0 replace" immediately showed that no captions were being found, pointing to the blank-line skip issue.

## When to Remove Diagnostic Logs

With the `DebugLog` category system, diagnostic logs can remain in the codebase permanently — they only print when their category is enabled. No need to remove them after debugging; they serve as documentation and can be re-enabled for future investigations.
