# Debugging Plan: Milkdown Editor Not Loading

## Problem Summary

The Milkdown editor fails to render. The user's console shows:
- `[EditorSchemeHandler] Served: /milkdown.html (text/html, 829 bytes)`
- `[EditorSchemeHandler] Served: /milkdown.js (text/javascript, 451253 bytes)`
- `[EditorSchemeHandler] Served: /milkdown.css (text/css, 1263 bytes)`
- `[MilkdownEditor] WebView finished loading`

**Critical observation:** No JavaScript console logs appear. The JavaScript code should log `[Milkdown] Initializing editor...` immediately on load, but this never appears in Safari Web Inspector.

## Hypothesis

The Swift/resource-serving side works. The JavaScript side either:
1. Isn't executing at all
2. Encounters a fatal error before logging
3. Console output isn't being captured/displayed

## Diagnostic Logging Plan

### Phase 1: Verify JavaScript Execution (Simplest First)

**Goal:** Confirm whether any JavaScript executes at all.

**Location:** `web/milkdown/src/main.ts`

Add at the very top of the file (before any imports):
```typescript
// Line 1 - FIRST THING IN FILE
(window as any).__MILKDOWN_SCRIPT_STARTED__ = Date.now();
console.log('[Milkdown] SCRIPT TAG EXECUTED - timestamp:', Date.now());
```

Add immediately after imports but before any other code:
```typescript
console.log('[Milkdown] IMPORTS COMPLETED');
```

**Why:** If neither log appears, JavaScript isn't executing at all. If the first appears but not the second, imports are failing.

---

### Phase 2: Swift-Side JavaScript Execution Verification

**Goal:** Verify JavaScript state from Swift without relying on console capture.

**Location:** `final final/Editors/MilkdownEditor.swift`

In the `webView(_:didFinish:)` method, after the existing log, add:
```swift
// Verify JavaScript executed at all
webView.evaluateJavaScript("typeof window.__MILKDOWN_SCRIPT_STARTED__") { result, error in
    if let error = error {
        print("[MilkdownEditor] JS check error: \(error)")
    } else {
        print("[MilkdownEditor] JS execution check: \(result ?? "nil")")
        // Should print "number" if script ran, "undefined" if not
    }
}

// Check if window.FinalFinal exists
webView.evaluateJavaScript("typeof window.FinalFinal") { result, error in
    if let error = error {
        print("[MilkdownEditor] FinalFinal check error: \(error)")
    } else {
        print("[MilkdownEditor] window.FinalFinal type: \(result ?? "nil")")
        // Should print "object" if API registered, "undefined" if not
    }
}

// Check if editor element exists
webView.evaluateJavaScript("document.querySelector('#editor') !== null") { result, error in
    print("[MilkdownEditor] #editor element exists: \(result ?? "unknown")")
}
```

**Why:** This bypasses console capture issues and directly reports from Swift whether JavaScript executed.

---

### Phase 3: HTML Template Verification

**Goal:** Confirm the HTML template has required elements.

**Location:** Examine served HTML content

In `EditorSchemeHandler.swift`, in the `webView(_:start:)` method, add after reading file data:
```swift
// Log first 500 chars of HTML to verify content
if url.path.hasSuffix(".html"), let htmlString = String(data: data, encoding: .utf8) {
    let preview = String(htmlString.prefix(500))
    print("[EditorSchemeHandler] HTML preview:\n\(preview)")
}
```

**Why:** Confirms the HTML being served contains expected structure (`<div id="editor">`, script tags, etc.)

---

### Phase 4: Capture JavaScript Errors in Swift

**Goal:** Capture JS errors that may not show in Web Inspector.

**Location:** `final final/Editors/MilkdownEditor.swift`

Add a WKScriptMessageHandler to capture errors:

1. In `makeNSView()`, before creating WebView, add:
```swift
let errorScript = WKUserScript(
    source: """
        window.onerror = function(msg, url, line, col, error) {
            window.webkit.messageHandlers.errorHandler.postMessage({
                message: msg,
                url: url,
                line: line,
                column: col,
                error: error ? error.toString() : null
            });
            return false;
        };
        window.addEventListener('unhandledrejection', function(e) {
            window.webkit.messageHandlers.errorHandler.postMessage({
                message: 'Unhandled Promise Rejection: ' + e.reason,
                url: '',
                line: 0,
                column: 0,
                error: e.reason ? e.reason.toString() : null
            });
        });
    """,
    injectionTime: .atDocumentStart,
    forMainFrameOnly: true
)
config.userContentController.addUserScript(errorScript)
config.userContentController.add(context.coordinator, name: "errorHandler")
```

2. In the Coordinator class, add:
```swift
func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    if message.name == "errorHandler", let body = message.body as? [String: Any] {
        print("[MilkdownEditor] JS ERROR: \(body["message"] ?? "unknown")")
        print("  URL: \(body["url"] ?? "")")
        print("  Line: \(body["line"] ?? ""), Col: \(body["column"] ?? "")")
        if let error = body["error"] {
            print("  Error: \(error)")
        }
    }
}
```

3. Make Coordinator conform to `WKScriptMessageHandler` in its declaration.

**Why:** Captures JavaScript errors that may not appear in Web Inspector due to sandbox issues.

---

### Phase 5: Trace Milkdown Initialization Steps

**Goal:** Pinpoint exactly where initialization stops.

**Location:** `web/milkdown/src/main.ts`

Add numbered logging throughout `initEditor()`:
```typescript
async function initEditor(): Promise<void> {
  console.log('[Milkdown] INIT STEP 1: Function entered');

  const root = document.querySelector('#editor');
  console.log('[Milkdown] INIT STEP 2: querySelector result:', root);

  if (!root) {
    console.error('[Milkdown] INIT STEP 2 FAILED: Editor root element not found');
    return;
  }

  console.log('[Milkdown] INIT STEP 3: Starting Editor.make()');

  try {
    editor = await Editor.make()
      .config((ctx) => {
        console.log('[Milkdown] INIT STEP 4: Inside config callback');
        ctx.set(rootCtx, root as HTMLElement);
        ctx.set(defaultValueCtx, '');
      })
      .use(commonmark)
      .use(gfm)
      .use(history)
      .use(focusModePlugin)
      .create();

    console.log('[Milkdown] INIT STEP 5: Editor.make().create() completed');
    console.log('[Milkdown] INIT STEP 6: Editor instance:', editor);
  } catch (e) {
    console.error('[Milkdown] INIT STEP FAILED at create:', e);
    throw e;
  }

  // ... rest of initialization with similar numbered logging
}
```

**Why:** Even if only Swift-side logging works, we can call `window.FinalFinal.getDebugState()` to retrieve stored state.

---

### Phase 6: Add Debug State API

**Goal:** Store initialization state that Swift can query.

**Location:** `web/milkdown/src/main.ts`

Add near the top:
```typescript
const debugState = {
  scriptLoaded: false,
  importsComplete: false,
  apiRegistered: false,
  initStarted: false,
  initSteps: [] as string[],
  errors: [] as string[],
  editorCreated: false
};

(window as any).__MILKDOWN_DEBUG__ = debugState;
```

Update throughout initialization:
```typescript
debugState.scriptLoaded = true;
// ... after imports
debugState.importsComplete = true;
// ... etc
debugState.initSteps.push('Step N: description');
```

Add to window.FinalFinal:
```typescript
getDebugState: () => JSON.stringify((window as any).__MILKDOWN_DEBUG__, null, 2)
```

**Swift-side query** in `webView(_:didFinish:)`:
```swift
webView.evaluateJavaScript("window.__MILKDOWN_DEBUG__ ? JSON.stringify(window.__MILKDOWN_DEBUG__) : 'not defined'") { result, error in
    print("[MilkdownEditor] Debug state: \(result ?? "nil")")
}
```

**Why:** Provides structured diagnostic data even if console logging fails.

---

## Implementation Order

1. **Phase 1 + 2** - Minimal changes to verify if JS runs at all
2. **Phase 4** - Capture JS errors in Swift
3. **Phase 3** - Verify HTML content
4. **Phases 5 + 6** - Only if JS executes but fails during init

## Files to Modify

| File | Changes |
|------|---------|
| `web/milkdown/src/main.ts` | Add logging, debug state object |
| `final final/Editors/MilkdownEditor.swift` | Add JS verification, error handler |
| `final final/Editors/EditorSchemeHandler.swift` | Add HTML preview logging |

## After Adding Logging

Rebuild both web and app:
```bash
cd web && pnpm build && cd .. && xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

Run the app and collect:
1. Xcode console output (all `[MilkdownEditor]` logs)
2. Safari Web Inspector console (if any JS logs appear)

Report the collected logs before attempting any fixes.
