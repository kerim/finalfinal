# Diagnostic: window.FinalFinal undefined error

## Problem

```
[MilkdownEditor] setContent error: TypeError: undefined is not an object
(evaluating 'window.FinalFinal.setContent')
```

## Hypothesis

`didFinish` navigation callback fires when HTML loads, but ES module (`type="module"`) executes asynchronously afterward. Swift calls `window.FinalFinal.setContent()` before the module finishes.

---

## Task 1: Add Diagnostic Instrumentation

**Goal:** Verify the hypothesis with evidence before attempting any fix.

### Step 1: Modify MilkdownEditor.swift

Add diagnostic logging to `webView(_:didFinish:)`:

```swift
func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    print("[MilkdownEditor] WebView finished loading")

    // DIAGNOSTIC: Check if window.FinalFinal exists immediately
    webView.evaluateJavaScript("typeof window.FinalFinal") { result, error in
        print("[MilkdownEditor] DIAGNOSTIC (immediate): window.FinalFinal type = \(result ?? "nil")")
    }

    // DIAGNOSTIC: Check after 500ms delay
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        webView.evaluateJavaScript("typeof window.FinalFinal") { result, error in
            print("[MilkdownEditor] DIAGNOSTIC (500ms later): window.FinalFinal type = \(result ?? "nil")")
        }
    }

    // Keep existing behavior to observe the error
    isEditorReady = true
    setContent(contentBinding.wrappedValue)
    setTheme(ThemeManager.shared.cssVariables)
    startPolling()
}
```

### Step 2: Build and run

```bash
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

### Step 3: Run app and capture output

Run the app and report back the diagnostic log lines.

---

## Expected Diagnostic Output

**If race condition hypothesis is correct:**
```
[MilkdownEditor] DIAGNOSTIC (immediate): window.FinalFinal type = undefined
[MilkdownEditor] DIAGNOSTIC (500ms later): window.FinalFinal type = object
```

**If JS is not executing at all:**
```
[MilkdownEditor] DIAGNOSTIC (immediate): window.FinalFinal type = undefined
[MilkdownEditor] DIAGNOSTIC (500ms later): window.FinalFinal type = undefined
```

**If there's no race condition:**
```
[MilkdownEditor] DIAGNOSTIC (immediate): window.FinalFinal type = object
[MilkdownEditor] DIAGNOSTIC (500ms later): window.FinalFinal type = object
```

---

## Next Steps

**After seeing diagnostic results**, we decide:
- If race condition confirmed → implement polling for readiness
- If JS not executing → investigate sandbox/CORS blocking
- If no race condition → investigate other causes

---

## Files to Modify

| File | Purpose |
|------|---------|
| `final final/Editors/MilkdownEditor.swift` | Add diagnostic logging only |
