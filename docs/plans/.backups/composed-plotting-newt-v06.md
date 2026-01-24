# Debug: window.FinalFinal undefined error

## Problem

```
[MilkdownEditor] setContent error: TypeError: undefined is not an object
(evaluating 'window.FinalFinal.setContent')
```

## Hypothesis

`didFinish` navigation callback fires when HTML loads, but ES module (`type="module"`) executes asynchronously afterward. Swift calls `window.FinalFinal.setContent()` before the module finishes.

**Evidence supporting hypothesis:**
- Files ARE served (logs show milkdown.html, .js, .css served)
- No `[Milkdown] Initializing editor...` log appears (JS console.log never ran)
- Error occurs immediately after `[MilkdownEditor] WebView finished loading`

---

## Task 1: Add Diagnostic Instrumentation

**Goal:** Verify the hypothesis before fixing.

### Step 1: Add timing diagnostics to Swift

Modify `MilkdownEditor.swift` `webView(_:didFinish:)`:

```swift
func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    print("[MilkdownEditor] WebView finished loading")

    // DIAGNOSTIC: Check if window.FinalFinal exists immediately
    webView.evaluateJavaScript("typeof window.FinalFinal") { result, error in
        print("[MilkdownEditor] DIAGNOSTIC: window.FinalFinal type = \(result ?? "nil"), error = \(String(describing: error))")
    }

    // DIAGNOSTIC: Check after a delay
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        webView.evaluateJavaScript("typeof window.FinalFinal") { result, error in
            print("[MilkdownEditor] DIAGNOSTIC (500ms later): window.FinalFinal type = \(result ?? "nil")")
        }
    }

    isEditorReady = true
    setContent(contentBinding.wrappedValue)
    setTheme(ThemeManager.shared.cssVariables)
    startPolling()
}
```

### Step 2: Build and run

```bash
cd "/Users/niyaro/Documents/Code/final final" && xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

Run the app and observe the diagnostic output.

### Expected Results

**If hypothesis is correct (race condition):**
- First diagnostic: `window.FinalFinal type = undefined`
- Second diagnostic (500ms): `window.FinalFinal type = object`

**If hypothesis is wrong (JS not executing at all):**
- Both diagnostics show `undefined` → Different root cause (sandbox blocking JS?)

**If hypothesis is wrong (no race condition):**
- Both diagnostics show `object` → Different root cause

---

## Task 2: Fix Based on Diagnostic Results

**Only proceed after Task 1 confirms hypothesis.**

### If hypothesis confirmed (race condition):

Replace immediate `setContent` call with polling for readiness:

```swift
func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    print("[MilkdownEditor] WebView finished loading")
    waitForEditorReady()
}

private func waitForEditorReady(attempts: Int = 0) {
    guard let webView, attempts < 20 else {  // Max 2 seconds (20 * 100ms)
        print("[MilkdownEditor] Editor failed to initialize after \(attempts) attempts")
        return
    }

    webView.evaluateJavaScript("typeof window.FinalFinal === 'object'") { [weak self] result, _ in
        guard let self else { return }
        if result as? Bool == true {
            print("[MilkdownEditor] Editor ready after \(attempts) polls")
            self.isEditorReady = true
            self.setContent(self.contentBinding.wrappedValue)
            self.setTheme(ThemeManager.shared.cssVariables)
            self.startPolling()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.waitForEditorReady(attempts: attempts + 1)
            }
        }
    }
}
```

### If both diagnostics show undefined (JS not executing):

Need further investigation:
- Check if `crossorigin` attribute is blocking module loading
- Check Content Security Policy
- Check if WebContent sandbox errors are blocking JS

---

## Version Update

After fix verified:
- `project.yml`: Bump to `0.1.7`
- `web/milkdown/package.json`: Bump to `0.1.7`

---

## Files to Modify

| File | Purpose |
|------|---------|
| `final final/Editors/MilkdownEditor.swift` | Add diagnostic, then polling for editor readiness |

---

## Verification

- [ ] Diagnostic output confirms root cause
- [ ] App launches without `window.FinalFinal` errors
- [ ] Editor displays demo content
- [ ] Word count updates when typing
