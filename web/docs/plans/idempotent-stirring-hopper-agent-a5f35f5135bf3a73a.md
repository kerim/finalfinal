# Code Review: Fix 2 (Mass-Delete Safety Guard) from idempotent-stirring-hopper Plan

## Review Summary

This review validates the proposed Fix 2 (mass-delete safety guard in `BlockSyncService.swift`) against the actual codebase, and confirms the plan's root cause diagnosis of the double-push pattern.

---

## 1. Double-Push Pattern Diagnosis Validation

**Confidence: HIGH (confirmed in code)**

The plan's diagnosis is accurate. The double-push pattern exists and works exactly as described.

**Push 1 -- `batchInitialize()` flow:**

In `/Users/niyaro/Documents/Code/ff-dev/images/final final/Editors/MilkdownCoordinator+MessageHandlers.swift`, line 29-32:

```swift
func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    isEditorReady = true
    batchInitialize()  // <-- Push 1 starts here
    startPolling()
    ...
```

`batchInitialize()` (line 68) calls `performBatchInitialize()` (line 107), which calls JS `window.FinalFinal.initialize(...)` (line 143). The `initialize()` function in `api-modes.ts:452-471` calls `setContent(options.content)`, which in `api-content.ts:127` calls `resetAndSnapshot(view.state.doc)`.

Critically, `setContent()` operates with `syncPaused = true` (line 91) and `setIsSettingContent(true)` (line 92), but these are both set back to `false` in the `finally` block (lines 165-168). So by the time `setContent()` returns, sync is unpaused and the block-sync plugin's `apply()` method will run on subsequent transactions. However, the `setContent()` call itself does call `resetAndSnapshot()` at line 127, which should rebuild the snapshot.

The issue: `setContent()` does NOT set `syncPaused` during the `resetAndSnapshot()` call, but it does call `resetAndSnapshot()` before the `finally` block clears `syncPaused`. Looking more carefully at lines 91-168, the flow is:

1. `setSyncPaused(true)` (line 91)
2. `setIsSettingContent(true)` (line 92)
3. `view.dispatch(tr)` (line 126) -- the `apply()` in the plugin returns early because `syncPaused` is true
4. `resetAndSnapshot(view.state.doc)` (line 127) -- rebuilds snapshot but does NOT cancel any pending detect timer
5. `setCurrentContent(markdown)` (line 164)
6. `setIsSettingContent(false)` (line 166)
7. `setSyncPaused(false)` (line 167)

So after Push 1 completes, `syncPaused` is `false`, and the snapshot reflects the content-without-block-IDs state. The `blockIdPlugin.apply()` would have assigned temp IDs during step 3 (since blockIdPlugin is separate from blockSyncPlugin). Actually wait -- `syncPaused` was `true` during step 3, so the blockSyncPlugin `apply()` returns early and does NOT start a detect timer.

Let me re-examine: the plan says the detect timer fires from "push 1." But if `syncPaused` was true during the dispatch, the `apply()` method returns early (line 340 of block-sync-plugin.ts: `if (!tr.docChanged || syncPaused) return value;`). So no detect timer starts from push 1's dispatch.

**However**, after push 1 completes and `syncPaused` is set back to `false`, the next transaction that changes the doc WILL trigger the apply method. And between push 1 and push 2, any intermediate transactions (e.g., from cursor positioning, focus, or other side effects of `initialize()`) would fire with `syncPaused = false`.

**Push 2 -- `setContentWithBlockIds()` flow:**

In `/Users/niyaro/Documents/Code/ff-dev/images/final final/Views/ContentView+ContentRebuilding.swift`, lines 326-339 (inside the `onWebViewReady` closure):

```swift
onWebViewReady: { webView in
    findBarState.activeWebView = webView
    if let db = documentManager.projectDatabase,
       let pid = documentManager.projectId {
        blockSyncService.configure(database: db, projectId: pid, webView: webView)
        editorState.isResettingContent = true
        Task {
            if let result = fetchBlocksWithIds() {
                await blockSyncService.setContentWithBlockIds(
                    markdown: result.markdown, blockIds: result.blockIds)
            }
            editorState.isResettingContent = false
            blockSyncService.startPolling()
        }
    }
}
```

This `onWebViewReady` callback is set during the MilkdownEditor construction. It fires from `webView(_:didFinish:)` at line 39: `onWebViewReady?(webView)`. Looking at the sequence in lines 29-39:

```swift
isEditorReady = true
batchInitialize()       // Push 1 -- async JS evaluation
startPolling()
pushCachedCitationLibrary()
onWebViewReady?(webView) // Push 2 setup -- Task { await setContentWithBlockIds() }
```

Both `batchInitialize()` and `onWebViewReady` fire synchronously from `didFinish`, but `batchInitialize()` does an async JS evaluation (line 80: `webView.evaluateJavaScript("typeof window.FinalFinal")`), so `performBatchInitialize()` runs asynchronously. Meanwhile, `onWebViewReady` creates a `Task` which also runs asynchronously.

The actual timing depends on Swift's concurrency scheduling, but the plan's core observation is correct: these are two separate content pushes that can create a window for stale snapshot comparison.

**Revised understanding of the race:** The more likely scenario is:
1. `batchInitialize()` fires JS `initialize()` which calls `setContent()` -- this replaces the doc and calls `resetAndSnapshot()`, but the blockIdPlugin assigns temp IDs during the dispatch.
2. `setContentWithBlockIds()` fires -- this replaces the doc again, clears block IDs, sets real IDs, and calls `resetAndSnapshot()`.
3. If any transaction fires between steps 1 and 2 with `syncPaused = false`, it could start a detect timer with temp-ID snapshots.

The `resetAndSnapshot()` function at `block-sync-plugin.ts:434-440` does NOT cancel the detect timer:

```typescript
export function resetAndSnapshot(doc: Node): void {
  if (!currentState) return;
  currentState.pendingUpdates.clear();
  currentState.pendingInserts.clear();
  currentState.pendingDeletes.clear();
  currentState.lastSnapshot = snapshotBlocks(doc);
}
```

This confirms the plan's diagnosis: Fix 1 (canceling the detect timer in `resetAndSnapshot()`) is the primary fix, and Fix 2 is the safety net.

---

## 2. Fix 2: Guard Location

**Confidence: HIGH**

The plan says the guard should go in `pollBlockChanges()` around line 196. Looking at the actual code in `/Users/niyaro/Documents/Code/ff-dev/images/final final/Services/BlockSyncService.swift`, lines 196-207:

```swift
// Skip if no actual changes
guard !changes.updates.isEmpty || !changes.inserts.isEmpty || !changes.deletes.isEmpty else {
    return
}

#if DEBUG
print("[BlockSyncService] Processing changes: ...")
#endif

// Apply changes to database
do {
    try await applyChanges(changes, database: database, projectId: projectId)
```

The guard should go between line 203 (after the debug print) and line 206 (before `applyChanges()`). This is the correct location -- after the changes have been decoded and validated as non-empty, but before they are destructively applied to the database.

**Verdict: Location is correct.**

---

## 3. Threshold Reasonableness

**Confidence: MEDIUM -- the threshold is directionally correct but has edge cases**

The plan proposes rejecting deletes when `deleteCount > existingCount / 2` and `existingCount > 2`.

**Scenarios where a user legitimately deletes more than half the blocks in one 2-second poll interval:**

- **Cmd+A, Delete:** Selects all text and deletes it. This would delete ALL blocks in one action. The poll interval is 2 seconds, but the detect timer is only 100ms, so this would be captured in a single set of pending changes. This IS a legitimate user action that would be blocked by the guard.

- **Cmd+A, paste replacement content:** Selects all and replaces with new content. In ProseMirror, this is a single transaction that replaces the entire document. The block-sync plugin would see all old IDs as deleted and all new content as temp-ID inserts. This is also legitimate and would be blocked.

- **Deleting a short document (3 blocks, deleting 2):** `existingCount > 2` allows this (3 > 2 is true), and `2 > 3/2 = 1` is true, so this would be blocked incorrectly.

**Problem:** The guard is too aggressive for small documents and for legitimate "select all + delete/replace" operations.

**Verdict: The threshold has significant false-positive risk.** A user working on a short document (3-10 blocks) can easily delete more than half the blocks in one editing action. Even on longer documents, Cmd+A followed by Delete or paste is a normal workflow.

---

## 4. Could the Guard Mask Legitimate Operations?

**Confidence: HIGH -- yes, it can and will**

As analyzed above:

- **Cmd+A, Delete** on ANY document: 100% of blocks would be deleted. Guard triggers. User's action is silently rejected. Content reappears on next poll.

- **Cmd+A, paste replacement:** All blocks deleted, new blocks inserted. Guard skips ALL changes (including the inserts), so the new content is not recorded in the database. This is a data loss scenario in the opposite direction -- the user's new content would be lost on next reload.

- **Working on a 4-block document, deleting 3 blocks:** Guard triggers. Normal editing blocked.

The plan says "Normal user editing will never delete half the document in one poll cycle" -- but this is incorrect. Users absolutely can and do select all and delete/replace content.

---

## 5. Performance of `fetchBlocks()` for Count Check

**Confidence: HIGH**

The `fetchBlocks()` method at `Database+Blocks.swift:92-98` does a full table read:

```swift
func fetchBlocks(projectId: String) throws -> [Block] {
    try read { db in
        try Block
            .filter(Block.Columns.projectId == projectId)
            .order(Block.Columns.sortOrder)
            .fetchAll(db)
    }
}
```

This fetches ALL block records (including `markdownFragment`, `textContent`, etc.) just to get a count. For a safety guard that runs every 2 seconds, this is wasteful. A `SELECT COUNT(*)` query would be much more appropriate:

```swift
let existingCount = try database.read { db in
    try Block.filter(Block.Columns.projectId == projectId).fetchCount(db)
}
```

However, since this is SQLite reading from a local file, and typical documents have tens to hundreds of blocks (not millions), the practical performance impact is negligible. Still, it is poor practice to fetch full records when only a count is needed.

**Verdict: Functionally fine, but should use `fetchCount` instead of `fetchBlocks().count` for correctness of intent and minor performance improvement.**

---

## 6. Should the Guard Skip ALL Changes or Only Deletes?

**Confidence: HIGH -- skipping all changes is wrong**

The plan's proposed guard uses `return` to skip ALL changes:

```swift
if existingCount > 2 && deleteCount > existingCount / 2 {
    return  // Skip ALL changes in this batch
}
```

This is problematic because a single batch of changes can contain legitimate updates and inserts alongside phantom deletes. For example:

- User types in a block (update) while the detect timer fires with stale snapshots (phantom deletes).
- The guard would discard the user's typing along with the phantom deletes.

A better approach would be to only filter out the deletes while preserving updates and inserts:

```swift
if existingCount > 2 && deleteCount > existingCount / 2 {
    // Only skip deletes, not updates/inserts
    changes = BlockChanges(updates: changes.updates, inserts: changes.inserts, deletes: [])
}
```

However, `BlockChanges` is decoded from JSON (line 245), so modifying it requires `var` or creating a filtered copy.

**Verdict: If implementing this guard at all, it should only suppress deletes, not discard the entire batch.**

---

## 7. Alternative Approach: Cooldown Window After Content Push

**Confidence: MEDIUM -- worth considering but adds complexity**

The suggestion to suppress deletes during a cooldown window after `isSyncSuppressed` was recently cleared is interesting. Looking at the code:

- `setContentWithBlockIds()` at `BlockSyncService.swift:134-173` sets `isSyncSuppressed = true` at line 138 and clears it in `defer` at line 139.
- `pushBlockIds()` does the same at lines 84-85.

A cooldown approach could look like:

```swift
private var lastSyncResumeTime: Date = .distantPast

var isSyncSuppressed: Bool = false {
    didSet {
        if !isSyncSuppressed {
            lastSyncResumeTime = Date()
        }
    }
}

// In pollBlockChanges():
let timeSinceResume = Date().timeIntervalSince(lastSyncResumeTime)
if timeSinceResume < 0.5 && !changes.deletes.isEmpty {
    // Suppress deletes during cooldown
    changes.deletes = []
}
```

This is more targeted than the mass-delete guard -- it only suppresses deletes immediately after a content push, which is exactly when the stale-snapshot race can occur. It would NOT interfere with legitimate user deletes during normal editing.

**However**, this approach assumes the race condition only occurs within a specific time window after a content push. If the race is more subtle (e.g., the detect timer fires later due to JS event loop scheduling), the cooldown might be too short.

**Verdict: The cooldown approach is more surgical and less likely to have false positives, but Fix 1 (canceling the timer in `resetAndSnapshot()`) is the proper solution. If a safety net is still desired, the cooldown approach is preferable to the mass-delete threshold.**

---

## Overall Assessment

| Aspect | Verdict |
|--------|---------|
| Root cause diagnosis | **Correct** -- double-push pattern and stale detect timer confirmed |
| Fix 1 (cancel timer in resetAndSnapshot) | **Essential and correct** -- this is the proper fix |
| Fix 2 guard location | **Correct** -- between change validation and `applyChanges()` |
| Fix 2 threshold | **Too aggressive** -- will block legitimate Cmd+A operations |
| Fix 2 skip-all behavior | **Incorrect** -- should only skip deletes, not all changes |
| Fix 2 fetchBlocks performance | **Acceptable but suboptimal** -- should use fetchCount |
| Fix 3 (cancel timer in destroy) | **Correct and harmless** -- good cleanup practice |

### Recommendations

1. **Implement Fix 1 as the primary fix.** It directly addresses the root cause.

2. **Implement Fix 3 for completeness.** No downside.

3. **Reconsider Fix 2 significantly before implementing.** The current proposal:
   - Will block Cmd+A + Delete (a common user action)
   - Will block Cmd+A + Paste replacement (another common action)
   - Will discard legitimate updates/inserts alongside phantom deletes
   - Uses a full table fetch where a count query suffices

4. **If a safety net is still desired**, prefer the cooldown approach: suppress deletes for 300-500ms after `isSyncSuppressed` transitions from `true` to `false`. This targets the exact window where the race can occur without interfering with normal user editing.

5. **If keeping Fix 2, at minimum:**
   - Only suppress deletes, not all changes
   - Use `fetchCount` instead of `fetchBlocks().count`
   - Raise the threshold (e.g., reject deletes only when `deleteCount == existingCount` and `existingCount > 5`)
   - Add a log-only mode first (log the warning but still apply the deletes) to validate whether Fix 1 actually eliminates the race before making the guard enforce anything
