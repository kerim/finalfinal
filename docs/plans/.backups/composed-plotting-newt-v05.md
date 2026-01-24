# Bug Fix: Milkdown Editor Race Condition

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Problem:** Editor shows blank white screen. `window.FinalFinal.setContent` fails with "undefined is not an object".

**Root Cause:** Race condition between WKWebView's `didFinish navigation` callback and ES module execution. WKWebView fires `didFinish` when the HTML document loads, but the JavaScript module (`type="module"`) hasn't executed yet, so `window.FinalFinal` is undefined.

**Evidence from logs:**
```
[EditorSchemeHandler] Served: /milkdown.html
[EditorSchemeHandler] Served: /milkdown.js
[MilkdownEditor] WebView finished loading   ← Swift thinks ready
setContent error: TypeError: undefined is not an object (evaluating 'window.FinalFinal.setContent')
```

**Solution:** Implement condition-based waiting. Swift must poll to check if `window.FinalFinal` exists before calling methods on it.

---

## Version Updates

Update versions to 0.1.7:
- `project.yml`: `CURRENT_PROJECT_VERSION: "0.1.7"`
- `web/milkdown/package.json`: `"version": "0.1.7"`

---

## Task 1: Update Swift to wait for JS readiness

**File:** `final final/Editors/MilkdownEditor.swift`

**Problem:** `didFinish navigation` fires before `window.FinalFinal` exists.

**Fix:** Replace immediate calls with condition-based polling.

**Changes to Coordinator class:**

1. Replace `webView(_:didFinish:)` to NOT immediately call `setContent`:

```swift
func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    print("[MilkdownEditor] WebView finished loading, waiting for JS...")
    waitForJavaScriptReady()
}
```

2. Add `waitForJavaScriptReady()` method that polls until `window.FinalFinal` exists:

```swift
private func waitForJavaScriptReady(attempts: Int = 0) {
    guard !isCleanedUp, let webView else { return }

    // Check if window.FinalFinal exists
    webView.evaluateJavaScript("typeof window.FinalFinal !== 'undefined'") { [weak self] result, error in
        guard let self, !self.isCleanedUp else { return }

        if let isReady = result as? Bool, isReady {
            print("[MilkdownEditor] JS API ready after \(attempts) attempts")
            self.isEditorReady = true
            self.setContent(self.contentBinding.wrappedValue)
            self.setTheme(ThemeManager.shared.cssVariables)
            self.startPolling()
        } else if attempts < 50 { // Max 5 seconds (50 * 100ms)
            // Not ready yet, try again in 100ms
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.waitForJavaScriptReady(attempts: attempts + 1)
            }
        } else {
            print("[MilkdownEditor] ERROR: JS API never became ready after \(attempts) attempts")
        }
    }
}
```

3. Update `setContent`, `setFocusMode`, `setTheme` methods to silently skip if not ready (they already have `guard isEditorReady` - no change needed).

---

## Task 2: Rebuild web and Swift

**Step 1:** Build web layer (may not need changes, but good to verify)
```bash
cd "/Users/niyaro/Documents/Code/final final/web" && pnpm build
```

**Step 2:** Build Swift app
```bash
cd "/Users/niyaro/Documents/Code/final final" && xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

---

## Task 3: Verify fix

**Run the app and verify:**
- [ ] App launches without "undefined is not an object" errors
- [ ] Editor content displays after brief initialization
- [ ] Console shows: `[MilkdownEditor] JS API ready after N attempts`
- [ ] Typing updates word count
- [ ] Focus mode (Cmd+Shift+F) works
- [ ] Theme switching works

---

## Task 4: Commit

```bash
git add .
git commit -m "fix: Wait for JS API readiness before calling window.FinalFinal"
```

---

## Critical File

| File | Change |
|------|--------|
| `final final/Editors/MilkdownEditor.swift` | Add `waitForJavaScriptReady()` polling |

---

## Why This Fixes It

The issue is timing:
1. HTML loads → `didFinish` fires
2. ES module starts loading
3. Swift calls `setContent` → FAILS because module hasn't executed
4. Module executes, creates `window.FinalFinal` → too late

With the fix:
1. HTML loads → `didFinish` fires
2. ES module starts loading
3. Swift polls: "is `window.FinalFinal` defined?" → No
4. Module executes, creates `window.FinalFinal`
5. Swift polls: "is `window.FinalFinal` defined?" → Yes!
6. Swift calls `setContent` → SUCCESS
