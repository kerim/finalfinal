# Plan: Fix /cite Command After Merge

## Problem

The `/cite` command stopped working after merging `zotero-exploration` into `main`.

## Root Cause

The `EditorPreloader` was added during the merge to improve startup speed, but the preloaded WebView path is **missing the `openCitationPicker` message handler**.

**How `/cite` works:**
1. User types `/cite` → slash menu appears
2. User selects cite → `openCAYWPicker()` is called in JS
3. JS calls `window.webkit.messageHandlers.openCitationPicker.postMessage(cmdStart)` (main.ts:609-611)
4. Swift receives message and opens Zotero CAYW picker

**Normal WebView path** (lines 98-100 in MilkdownEditor.swift):
```swift
configuration.userContentController.add(context.coordinator, name: "errorHandler")
configuration.userContentController.add(context.coordinator, name: "searchCitations")
configuration.userContentController.add(context.coordinator, name: "openCitationPicker")  // ✓ Present
```

**Preloaded WebView path** (lines 41-43 in MilkdownEditor.swift):
```swift
controller.add(context.coordinator, name: "errorHandler")
controller.add(context.coordinator, name: "searchCitations")
// openCitationPicker is MISSING!
```

## Fix 1: Add Missing Message Handler

**File:** `final final/Editors/MilkdownEditor.swift`

Add the missing `openCitationPicker` handler to the preloaded WebView path (around line 43):

```swift
controller.add(context.coordinator, name: "errorHandler")
controller.add(context.coordinator, name: "searchCitations")
controller.add(context.coordinator, name: "openCitationPicker")  // ADD THIS LINE
```

## Fix 2: Add Missing Citation Library Push

The `handlePreloadedView()` function is also missing the `pushCachedCitationLibrary()` call that exists in `webView didFinish`. This ensures citations render with proper formatting (Author, Year) instead of raw citekeys.

**File:** `final final/Editors/MilkdownEditor.swift`

Update `handlePreloadedView()` (around line 487-491):

```swift
func handlePreloadedView() {
    isEditorReady = true
    batchInitialize()
    startPolling()
    pushCachedCitationLibrary()  // ADD THIS LINE
}
```

## Verification

1. Rebuild macOS app:
   ```bash
   xcodebuild -scheme "final final" -destination 'platform=macOS' build
   ```

2. Manual testing:
   - Open the app
   - Type `/cite` in the Milkdown editor
   - Verify Zotero CAYW picker opens
   - Press `Cmd+Shift+K` - should also open citation picker
   - Insert a citation and verify it formats correctly
