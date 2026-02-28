# Code Review: Diagnosis Validation for CM->MW Content Destruction

## Verdict: CONFIRMED

The diagnosis in the plan file is correct in all material respects. The proposed fix is safe and addresses the root cause. Below is the detailed trace evidence.

---

## 1. CM->MW Switch Flow (ViewNotificationModifiers.swift, lines 122-147)

**CONFIRMED.** The `else` branch (switching FROM source TO WYSIWYG) does the following:

1. Sets `contentState = .editorTransition` (line 124)
2. Calls `flushContentToDatabase()` (line 126) -- parses `editorState.content` into blocks in the DB
3. Extracts anchors from `editorState.sourceContent` (line 129-131)
4. Sets `editorState.content = SectionSyncService.stripBibliographyMarker(from: cleaned)` (line 136)
5. Calls `toggleEditorMode()` (line 137) -- switches to `.wysiwyg`
6. Delays setting `contentState = .idle` by 1.5 seconds (lines 143-146)

The stripped content at line 136 is the value that becomes `editorState.content` and drives subsequent `updateNSView` calls.

### Source of `editorState.content`

During CM->MW switch, the CodeMirror `saveAndNotify()` (in `CodeMirrorCoordinator+Handlers.swift:113-158`) calls `window.FinalFinal.getContent()` on the CodeMirror JS, which strips anchors. This updates `self.contentBinding.wrappedValue` which is bound to `editorState.sourceContent` (NOT `editorState.content`). Then at line 136, `editorState.content` is set from the stripped+cleaned `sourceContent`.

---

## 2. handlePreloadedView() (MilkdownCoordinator+MessageHandlers.swift, lines 55-65)

**CONFIRMED.** The method calls:

```swift
func handlePreloadedView() {
    isEditorReady = true
    batchInitialize()             // starts async JS eval chain
    startPolling()
    pushCachedCitationLibrary()
    if let webView = webView {
        onWebViewReady?(webView)  // runs BEFORE batchInitialize's JS completes
    }
}
```

Crucially, `batchInitialize()` starts an async JavaScript call, but `onWebViewReady` is invoked synchronously in the same call stack.

---

## 3. performBatchInitialize() (MilkdownCoordinator+MessageHandlers.swift, lines 107-168)

**CONFIRMED.** At line 113:

```swift
lastPushedContent = content    // set SYNCHRONOUSLY before JS eval
lastPushTime = Date()
```

Where `content = contentBinding.wrappedValue` = `editorState.content` (the stripped source content from step 1, line 136). This sets `lastPushedContent` to the 1748-char version (hypothetically).

---

## 4. onWebViewReady Callback (ContentView+ContentRebuilding.swift, lines 323-341)

**CONFIRMED.** The callback:

1. Configures `BlockSyncService` with the WebView (line 328)
2. Sets `isResettingContent = true` (line 330) -- guards against `updateNSView` content push
3. Starts a `Task` that:
   a. Calls `fetchBlocksWithIds()` -> `BlockParser.assembleMarkdown(from: sorted)` (line 333)
   b. Calls `setContentWithBlockIds(markdown: result.markdown, blockIds: result.blockIds)` (line 334-335)
   c. Sets `isResettingContent = false` (line 337) -- removes the guard
   d. Calls `blockSyncService.startPolling()` (line 338)

The `fetchBlocksWithIds()` function (lines 11-34 of the same file) fetches blocks from DB, sorts them, and calls `BlockParser.assembleMarkdown()` which joins trimmed fragments with `"\n\n"`. This produces the 1747-char version (hypothetically).

---

## 5. setContentWithBlockIds() (BlockSyncService.swift, lines 134-174)

**CONFIRMED.** After the JS call completes, it posts a notification at lines 165-169:

```swift
NotificationCenter.default.post(
    name: .blockSyncDidPushContent,
    object: nil,
    userInfo: ["markdown": markdown]
)
```

Where `markdown` is the DB-assembled markdown (the 1747-char version).

---

## 6. .blockSyncDidPushContent Observer (MilkdownEditor.swift, lines 466-474)

**CONFIRMED.** The observer at lines 466-474:

```swift
blockSyncPushObserver = NotificationCenter.default.addObserver(
    forName: .blockSyncDidPushContent, object: nil, queue: .main
) { [weak self] notification in
    guard let markdown = notification.userInfo?["markdown"] as? String else { return }
    self?.lastPushedContent = markdown   // updates to 1747-char version
    self?.lastPushTime = Date()
}
```

This updates `lastPushedContent` to the DB-assembled markdown.

---

## 7. updateNSView (MilkdownEditor.swift, lines 146-180)

**CONFIRMED.** When `isResettingContent` is set to `false` (step 4c), SwiftUI triggers `updateNSView`. At this point:

- `isResettingContent = false` -> passes the guard at line 160
- `content` = `editorState.content` (stripped source, e.g., 1748 chars)
- Line 169: `context.coordinator.shouldPushContent(content)` is called
- If `content != lastPushedContent` (1748 != 1747), returns `true`
- Line 170: `context.coordinator.setContent(content)` pushes content WITHOUT block IDs

---

## 8. shouldPushContent() (MilkdownCoordinator+Content.swift, lines 346-350)

**CONFIRMED.** The logic:

```swift
func shouldPushContent(_ newContent: String) -> Bool {
    let timeSinceLastReceive = Date().timeIntervalSince(lastReceivedFromEditor)
    if timeSinceLastReceive < 0.6 && newContent == lastPushedContent { return false }
    return newContent != lastPushedContent
}
```

The critical comparison is `newContent != lastPushedContent`. If the stripped source content differs from the DB-assembled markdown by even one character, this returns `true`.

### Why They Differ (Trailing Newline)

- `BlockParser.parse()` trims each raw block: `rawBlock.trimmingCharacters(in: .whitespacesAndNewlines)` (BlockParser.swift, line 38)
- `BlockParser.assembleMarkdown()` joins with `"\n\n"` -- no trailing newline (BlockParser.swift, lines 364-366)
- The content from CodeMirror/Milkdown's `getContent()` does NOT trim the overall document. Milkdown's `getMarkdown()` serializer typically produces a trailing newline from ProseMirror's document model.
- CodeMirror's `doc.toString()` returns whatever is in the editor buffer, which typically includes a trailing newline.

The 1-char difference (trailing `\n`) is the trigger for the mismatch.

---

## 9. Proposed Fix Validation

The fix adds `editorState.content = result.markdown` after `setContentWithBlockIds()`:

```swift
Task {
    if let result = fetchBlocksWithIds() {
        await blockSyncService.setContentWithBlockIds(
            markdown: result.markdown, blockIds: result.blockIds)
        editorState.content = result.markdown   // <-- THE FIX
    }
    editorState.isResettingContent = false
    blockSyncService.startPolling()
}
```

### Safety Analysis

**Will `onChange(of: editorState.content)` fire and cause problems?**

No. The `onChange` handler at ViewNotificationModifiers.swift line 289-290 guards with:

```swift
guard editorState.contentState == .idle else { return }
```

At the time of the fix:
- `contentState = .editorTransition` (set at line 124, before any of this runs)
- It stays `.editorTransition` until the 1.5s `Task.sleep` at line 144 completes
- Therefore the `onChange` handler will early-return. **SAFE.**

**Will the assignment cause additional `updateNSView` calls?**

Yes, but now `editorState.content` will match `lastPushedContent` (both will be the DB-assembled markdown). So `shouldPushContent()` will return `false`. **SAFE.**

**Is there a race between the fix assignment and `isResettingContent = false`?**

Both happen sequentially in the same `Task` block on the `@MainActor`. The content assignment happens first, then `isResettingContent = false`. When SwiftUI processes the state change and calls `updateNSView`, both updates are visible. **SAFE.**

### Consistency with Other Call Sites

Every other call site that uses `setContentWithBlockIds()` ALREADY syncs `editorState.content`:

| File | Line | Already syncs? |
|------|------|----------------|
| ContentView.swift (bibliography rebuild) | 171 | Yes: `editorState.content = result.markdown` |
| ContentView.swift (notes section changed) | 200 | Yes: `editorState.content = result.markdown` |
| ContentView+ProjectLifecycle.swift (project switch) | 233 | Yes: `editorState.content = result.markdown` |
| **ContentView+ContentRebuilding.swift (onWebViewReady)** | **332-339** | **No -- THIS IS THE BUG** |

The `onWebViewReady` callback is the only call site missing this sync. The fix brings it into alignment with the established pattern.

---

## 10. Other Code Paths (Same Issue Potential)

I checked whether zoom in/out, bibliography rebuild, or project open could trigger the same issue:

- **Project open** (ContentView+ProjectLifecycle.swift, line 233): Already syncs. **No issue.**
- **Bibliography rebuild** (ContentView.swift, line 171): Already syncs. **No issue.**
- **Notes section rebuild** (ContentView.swift, line 200): Already syncs. **No issue.**
- **Zoom transitions**: These use `setContent()` via `updateNSView`, not `setContentWithBlockIds()`. They have their own coordination via `isZoomingContent` and `contentState`. Different mechanism, not affected.
- **MW->CM switch**: No `onWebViewReady` callback involved for CodeMirror. Different flow entirely.

The ONLY vulnerable path is the CM->MW switch via `onWebViewReady`, which is what the fix targets.

---

## Summary

| Claim in Diagnosis | Evidence | Status |
|---------------------|----------|--------|
| Triple content push | `batchInitialize` + `setContentWithBlockIds` + `updateNSView.setContent` | CONFIRMED |
| 1-char difference triggers `shouldPushContent` | BlockParser trims fragments; CodeMirror/Milkdown may have trailing newline | CONFIRMED (plausible) |
| `updateNSView` re-pushes stale content without block IDs | `shouldPushContent` returns true when `editorState.content != lastPushedContent` | CONFIRMED |
| Re-push causes temp IDs -> 8 deletes | Content push without block IDs replaces real UUIDs with temp-* IDs on next `detectChanges` | CONFIRMED (follows from JS block-sync-plugin behavior) |
| `onChange` guard prevents fix from causing side effects | `contentState == .editorTransition` at fix point; guard returns early | CONFIRMED |
| Fix aligns with existing patterns | All other `setContentWithBlockIds` call sites already sync `editorState.content` | CONFIRMED |

**The diagnosis is correct. The proposed fix is safe and well-targeted. The only modification needed is the single line `editorState.content = result.markdown` inside the `onWebViewReady` Task block in `ContentView+ContentRebuilding.swift`.**
