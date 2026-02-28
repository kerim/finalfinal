# Diagnostic: Capture Actual JS Exception in CodeMirror Initialization

## Context

After implementing fixes for mass deletes (queue: nil, remove contentState guard), CodeMirror still displays blank when image markdown is present. The Xcode console shows:

```
[CodeMirrorEditor] Initialize error: A JavaScript exception occurred
```

This is the generic `error.localizedDescription`. The actual JS error (message, line number, source) is in `error.userInfo` but never printed. We need to see the real exception to fix the blank display.

Safari Web Inspector is not viable: the CM WebView only appears in Develop menu AFTER the switch completes, by which time the console is empty.

## What the logs show

- The JS exception occurs during `batchInitialize()` which calls `window.FinalFinal.initialize({content: ..., theme: ..., cursorPosition: ...})`
- It ONLY happens when content contains image markdown `![alt](media/...)`
- Removing the image restores normal CM rendering
- The `initialize()` JS function calls `setContent()` which dispatches a CM6 transaction, triggering `imagePreviewPlugin.update()` → `buildDecorations(view)`

## Fix: Enhanced Error Logging

### File: `final final/Editors/CodeMirrorCoordinator+Handlers.swift` (line 258-264)

Replace the generic error print with full WKWebView JS exception details:

```swift
webView.evaluateJavaScript(script) { [weak self] _, error in
    if let error = error as? NSError {
        #if DEBUG
        print("[CodeMirrorEditor] Initialize error: \(error.localizedDescription)")
        if let message = error.userInfo["WKJavaScriptExceptionMessage"] {
            print("[CodeMirrorEditor] JS Exception: \(message)")
        }
        if let line = error.userInfo["WKJavaScriptExceptionLineNumber"] {
            print("[CodeMirrorEditor] JS Line: \(line)")
        }
        if let column = error.userInfo["WKJavaScriptExceptionColumnNumber"] {
            print("[CodeMirrorEditor] JS Column: \(column)")
        }
        if let sourceURL = error.userInfo["WKJavaScriptExceptionSourceURL"] {
            print("[CodeMirrorEditor] JS Source: \(sourceURL)")
        }
        #endif
        // Reset so updateNSView can retry content push
        self?.lastPushedContent = ""
    }
    self?.cursorPositionToRestoreBinding.wrappedValue = nil
}
```

## Files to Modify

| File | Change |
|------|--------|
| `final final/Editors/CodeMirrorCoordinator+Handlers.swift` | Enhanced JS error logging at line 258 |

## Verification

1. Build in Xcode
2. Open project with image content
3. Switch to CodeMirror (Cmd+/)
4. Read the Xcode console — should now show `[CodeMirrorEditor] JS Exception: <actual error message>` with line number
5. Share the output to diagnose the root cause
