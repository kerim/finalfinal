# Review: Fix Typing Latency Plan

## Summary

The plan at `docs/plans/wise-inventing-trinket.md` proposes 7 steps to reduce typing latency in the FinalFinal app. I validated each claim against the actual source code. The plan is largely accurate in its diagnosis and the proposed fixes are reasonable, but there are several inaccuracies, risks, and missed latency sources that need to be addressed before implementation.

---

## 1. Validation of Root Cause Claims

### CLAIM: "500ms polling to detect content changes"
**Verified -- ACCURATE.**
- `MilkdownCoordinator+MessageHandlers.swift` line 639: `Timer.scheduledTimer(withTimeInterval: 0.5, ...)`
- `CodeMirrorCoordinator+Handlers.swift` line 637: same `0.5` interval.

### CLAIM: "Poll fires 3 sequential evaluateJavaScript() calls on MainActor"
**Verified -- ACCURATE.**
- Milkdown `pollContent()` (lines 656-736): calls `getContent()`, `getStats()`, `getCurrentSectionTitle()` -- three sequential evaluateJavaScript calls.
- CodeMirror `pollContent()` (lines 654-695): calls `getContentRaw()`, `getStats()`, `getCurrentSectionTitle()` -- also three calls.
- Note: CodeMirror calls `getContentRaw()` not `getContent()`. The plan does not account for this difference. The push-based messaging for CodeMirror would need to push raw content (with anchors) for the binding, not `doc.toString()` as the plan suggests.

### CLAIM: "Second polling loop (BlockSyncService at 300ms)"
**Verified -- ACCURATE.**
- `BlockSyncService.swift` line 18: `let pollInterval: TimeInterval = 0.3`
- This polling loop fires `hasBlockChanges()` + potentially `getBlockChanges()` every 300ms, competing for the JS bridge. However, this only runs for Milkdown (block-based architecture), not CodeMirror. The plan does not mention this distinction.

### CLAIM: "onContentChange() triggers SectionSyncService (500ms debounce)"
**Verified -- ACCURATE.**
- `SectionSyncService.swift` line 15: `let debounceInterval: Duration = .milliseconds(500)`
- `contentChanged()` at line 130 starts a debounced task.

### CLAIM: "DB writes on MainActor with exclusive locks (no WAL mode)"
**Verified -- ACCURATE.**
- `ProjectDatabase.swift` line 15: `self.dbWriter = try DatabaseQueue(path: package.databaseURL.path)` -- no Configuration passed, so default SQLite journal mode (DELETE, not WAL).
- `SectionSyncService` is `@MainActor` (line 12), so `syncContent()` runs on main. The DB calls (`fetchSections`, `applySectionChanges`, `saveContent`) inside it execute synchronous GRDB writes that block the main thread.

### CLAIM: "block-sync snapshots entire doc" on every tr.docChanged
**Verified -- ACCURATE.**
- `block-sync-plugin.ts` lines 331-350: the `apply()` method calls `snapshotBlocks(newState.doc)` then `detectChanges()` on every doc-changing transaction. `snapshotBlocks()` iterates all top-level nodes with `doc.forEach()` and runs `nodeToMarkdownFragment()` on each, which involves string operations.
- This is a real source of per-keystroke overhead in the ProseMirror synchronous pipeline.

### CLAIM: "focus-mode walks tree twice" on every transaction
**Verified -- ACCURATE.**
- `focus-mode-plugin.ts` lines 38-47: first `doc.descendants()` to find the cursor block.
- Lines 50-61: second `doc.descendants()` to build decorations for all other blocks.
- Note: The plan says "lines 38-63" which is correct. The two walks are confirmed.

### CLAIM: "ValueObservation fires on main queue"
**Verified -- ACCURATE.**
- `ProjectDatabase.swift` line 341: `scheduling: .async(onQueue: .main)`
- `Database+BlocksObservation.swift` line 29: `scheduling: .async(onQueue: .main)`
- Both section and block observation deliver on the main queue.

---

## 2. Inaccuracies in the Plan

### INACCURACY 1: Line number references are approximate, not exact
The plan references "MilkdownCoordinator+MessageHandlers.swift line 639" for the polling timer. The actual line is 639 -- this one is correct. But:
- "MilkdownEditor.swift lines 48-57" for preloaded path message handlers -- actual lines are 48-57 (correct).
- "MilkdownEditor.swift lines 112-120" for fallback path -- actual lines are 112-120 (correct).
- "CodeMirrorEditor.swift lines 43-50" for preloaded path -- actual lines are 43-50 (correct).
- "CodeMirrorEditor.swift lines ~107-115" for fallback -- actual lines are 103-109 (close enough).
- "ProjectDatabase.swift line 13-16" -- actual init is lines 13-16 (correct).
- "SectionSyncService.swift lines 202-236" -- the `syncContent()` method starts at line 191, not 202. The DB operations are at lines 204-235. This is close but not precise.
- "block-sync-plugin.ts lines 331-350" -- the `apply()` method runs from line 331 to 350 (correct).
- "focus-mode-plugin.ts lines 38-63" -- the `decorations()` function runs from line 25 to 63 (the two walks are at 38-47 and 50-61).

**Verdict: Line numbers are close enough to be useful. No critical errors.**

### INACCURACY 2: CodeMirror uses `getContentRaw()`, not `getContent()`
The plan's Step 1 says CodeMirror should push `doc.toString()` on docChanged. But CodeMirror's `pollContent()` calls `getContentRaw()` (line 656 of `CodeMirrorCoordinator+Handlers.swift`), which returns content with hidden section anchors (`<!-- @sid:UUID -->`). The push-based message for CodeMirror must push raw content, not clean content. Using `doc.toString()` would strip anchors and break section ID tracking.

### INACCURACY 3: Plan says "4 locations" for registering the handler
The plan lists 4 locations: 2 in MilkdownEditor.swift and 2 in CodeMirrorEditor.swift. This is correct -- each editor has a preloaded path and a fallback path that both register message handlers.

### INACCURACY 4: The plan references "Database+BlocksObservation.swift line 59"
The actual file is 72 lines long. The `scheduling: .async(onQueue: .main)` is at line 29 (for `observeBlocks`) and line 59 (for `observeOutlineBlocks`). The plan references line 59, which points to the outline observation. However, line 29 (block observation) also has the same issue. Both should be changed. The plan mentions "line 59" and "line 369" in ProjectDatabase.swift -- the latter is at line 369 (for `observeAnnotations`), but `observeSections` is at line 341. Both should be addressed.

---

## 3. Missed Latency Sources

### MISSED: Milkdown `getMarkdown()` runs on every keystroke
In `web/milkdown/src/main.ts` lines 195-201, the patched `view.dispatch` calls `editorInstance.action(getMarkdown())` on every `tr.docChanged`. This serializes the ENTIRE document to markdown on every keystroke. For large documents, this is likely the single biggest per-keystroke JS bottleneck. The plan mentions this indirectly ("getMarkdown() already runs here") but does not propose optimizing it. Consider:
- Deferring `setCurrentContent()` behind a microtask or short debounce (even 16ms / one frame).
- Or only serializing on push (when the message handler fires).

### MISSED: The `shouldPushContent()` guard in `updateNSView` runs string comparison
`MilkdownCoordinator+Content.swift` line 338-342 and `CodeMirrorCoordinator+Handlers.swift` line 530-534 both do `newContent != lastPushedContent`, which is an O(n) string comparison on every SwiftUI render cycle. For large documents this could contribute to main thread time. This is not a primary latency source but worth noting.

### MISSED: `BlockSyncService.applyChanges()` performs DB writes on MainActor
`BlockSyncService.swift` line 258 calls `database.applyBlockChangesFromEditor()` inside a `@MainActor` context. This has the same main-thread-blocking issue as SectionSyncService but is not addressed in the plan. Step 3 only targets SectionSyncService.

### MISSED: SpellCheckService integration
The spellcheck plugin sends text segments to Swift via `postMessage("spellcheck")`, and the coordinator processes them on MainActor, including calling `SpellCheckService.shared.check(segments:)` and then `evaluateJavaScript` to push results back. If spellcheck fires frequently, it competes for the JS bridge. Not a primary concern but worth noting.

---

## 4. Validation of Proposed Fixes

### Step 1: Push-Based Content Messaging

**Assessment: Sound approach with important caveats.**

**Correctness of postMessage vs polling:** `window.webkit.messageHandlers.contentChanged.postMessage()` is indeed faster than polling. The message is dispatched to Swift immediately (next run loop iteration), avoiding the up-to-500ms wait. This is the correct approach.

**Risk: Message flooding during rapid typing.**
The plan proposes posting on every `tr.docChanged`. In Milkdown, `getMarkdown()` already runs on every docChanged (line 199 of main.ts), so the additional `postMessage` is minimal overhead -- it just sends the already-computed markdown. However, this means Swift will receive a message for EVERY keystroke. The Swift handler must be careful not to trigger expensive operations per message.

Recommendation: Add a small client-side debounce (50-100ms) using `requestAnimationFrame` or `setTimeout` to coalesce rapid keystrokes into a single message. This prevents flooding Swift with messages during fast typing while still being much faster than 500ms polling.

**Risk: Grace period logic with push-based messaging.**
The current 600ms grace period (`MilkdownCoordinator+MessageHandlers.swift` line 675) prevents poll results from overwriting content that Swift just pushed to the editor. With push-based messaging, this grace period is still needed but may need adjustment:
- When Swift pushes content via `setContent()`, the editor will echo it back via `postMessage`. The grace period must still suppress this echo.
- With push being near-instant instead of up to 500ms delayed, a shorter grace period (200-300ms) would be appropriate.
- The `lastPushedContent` check (line 686) already handles the echo case (content matches what was pushed), so the grace period is mainly for the window between push and echo.

**Risk: CodeMirror needs raw content, not clean content.**
As noted above, CodeMirror's push must send raw content (with anchors). The plan's suggestion of `doc.toString()` would lose section anchors. The implementation should use the equivalent of `getContentRaw()` which includes hidden anchor comments.

**Risk: Demoting polling to 3s may delay stats/section title updates.**
The plan proposes reducing poll frequency from 500ms to 3s. Stats and section title would update much less frequently. This is acceptable for stats (no user sees word count change per keystroke) but section title updates might feel sluggish in the status bar. Consider pushing stats alongside content in the postMessage payload, or keeping a separate 1s poll just for stats.

### Step 2: Enable WAL Mode

**Assessment: Correct and straightforward.**

GRDB's `DatabaseQueue` supports WAL mode via the `prepareDatabase` configuration callback. The proposed code is correct:

```swift
var config = Configuration()
config.prepareDatabase { db in
    try db.execute(sql: "PRAGMA journal_mode = WAL")
    try db.execute(sql: "PRAGMA synchronous = NORMAL")
}
self.dbWriter = try DatabaseQueue(path: package.databaseURL.path, configuration: config)
```

**Concern: `PRAGMA synchronous = NORMAL` and data safety.**
With WAL mode + `synchronous = NORMAL`, there is a small window where a power failure could lose the last committed transaction. For a writing app, this is a minor risk -- the user would lose at most the last few hundred milliseconds of work. The app already has auto-backup via `AutoBackupService`, so this is acceptable. However, it should be documented that this trade-off was made intentionally.

**Note on DatabaseQueue vs DatabasePool:**
With WAL mode enabled, `DatabaseQueue` still serializes reads and writes. GRDB's `DatabasePool` would allow concurrent reads during writes. The plan does not propose switching to `DatabasePool`, which would provide additional benefit. However, `DatabasePool` requires more careful handling of mutable state, so this is a reasonable scope limitation for now.

### Step 3: Move DB Writes Off Main Thread

**Assessment: Correct intent, but `Task.detached` is the wrong pattern for GRDB.**

**The problem with Task.detached for GRDB:**
GRDB's `DatabaseQueue.write()` is a synchronous blocking call. Wrapping it in `Task.detached(priority: .utility)` moves the blocking to a cooperative thread pool thread, which is better than blocking the main thread. However:

1. `Task.detached` creates an unstructured task that does not inherit the actor context. Since `SectionSyncService` is `@MainActor`, accessing its properties from a detached task requires explicit `await` back to MainActor, creating a lot of back-and-forth.

2. A cleaner pattern for GRDB is to use `dbWriter.asyncWrite` or wrap the synchronous calls in a plain `DispatchQueue`:
   ```swift
   DispatchQueue.global(qos: .utility).async {
       try db.applySectionChanges(changes, for: pid)
   }
   ```
   Or use GRDB's built-in async methods if available.

3. **Thread safety is fine** -- GRDB's `DatabaseQueue` is thread-safe. The DB operations themselves can safely run on any thread. The concern is about the service's own state (`lastSyncedContent`, etc.) which is `@MainActor`-isolated.

**Recommended approach:** Keep the debounce and state management on MainActor. Only move the actual DB calls off-thread. Something like:

```swift
let result = await Task.detached(priority: .utility) {
    try db.fetchSections(projectId: pid)
}.value
// Back on MainActor for state updates
```

**Missing: BlockSyncService should also be addressed** (see Missed Latency Sources above).

### Step 4: Batch Remaining JS Calls

**Assessment: Sound and low-risk.**

Combining `getStats()` and `getCurrentSectionTitle()` into a single `getAll()` call reduces the number of JS bridge round-trips from 3 to 1 (or from 2 to 1 if content is now pushed). This is straightforward to implement and has no regression risk.

### Step 5: Debounce Block Sync Plugin

**Assessment: Sound approach with one important caveat.**

Moving `snapshotBlocks()` + `detectChanges()` out of ProseMirror's synchronous `apply()` is the right idea. ProseMirror's state apply pipeline is synchronous and should be as fast as possible.

**Caveat: Block sync correctness.**
If the debounced callback fires after multiple transactions, the snapshot comparison needs to be against the last acknowledged snapshot, not an intermediate one. The current code already handles this by comparing against `value.lastSnapshot`, but with debouncing, the `apply()` method would need to either:
- Just set a dirty flag (and keep the old snapshot), letting the debounced callback do the full snapshot+diff.
- Or batch multiple transactions' document states and only compare first-to-last.

The plan proposes the dirty-flag approach, which is correct.

### Step 6: Optimize Focus Mode Plugin

**Assessment: Sound, simple optimization.**

Merging two `doc.descendants()` walks into one is straightforward. The first walk finds the cursor block; the second builds decorations. These can be combined. This is a clean optimization with no regression risk.

**Note:** The focus-mode `decorations()` function runs on every ProseMirror state update (not just docChanged), because cursor movement also triggers it. This means the double-walk overhead happens on cursor movement too, making this optimization slightly more impactful than described.

### Step 7: Move ValueObservation Off Main Queue

**Assessment: Correct but low priority.**

Changing `scheduling: .async(onQueue: .main)` to a background queue would move the DB read (that triggers the observation callback) off the main thread. The consumers still run on MainActor via the async stream. With WAL mode (Step 2), reads no longer block on writes, so this becomes less important. The plan correctly notes this.

---

## 5. Push-Based Messaging: Specific Concerns

### Is `postMessage` truly faster than polling?
Yes. `window.webkit.messageHandlers.*.postMessage()` dispatches immediately to the native side. The message arrives at `userContentController(_:didReceive:)` on the next run loop iteration (typically within 1-2ms). Compared to up to 500ms polling latency, this is a major improvement.

### Async overhead
The `userContentController(_:didReceive:)` method is `nonisolated` in both coordinators. The handler would need to dispatch to `@MainActor` via `Task { @MainActor in ... }` to update bindings. This adds ~1 run loop cycle of overhead, which is negligible.

### Grace period with push-based messaging
The 600ms grace period is currently tuned for 500ms polling. With push-based messaging:
- Content arrives much faster after a push (within milliseconds, not up to 500ms).
- The grace period mainly prevents the "echo" problem: Swift pushes content -> editor processes it -> editor pushes it back unchanged.
- The `content != lastPushedContent` check (existing code) already filters echoes.
- Recommendation: Reduce grace period to 200ms for push-based messages. Keep the 600ms for the demoted fallback polling.

### Message flooding
During fast typing (10+ chars/second), each keystroke would fire a postMessage. This is fine -- WKWebView's message passing is designed for high-frequency communication. The overhead per message is minimal (~0.1ms). However, each message triggers content binding updates and potentially `onContentChange()`, which feeds into SectionSyncService. Since SectionSyncService already has a 500ms debounce, the flooding is absorbed at that layer.

**One real concern:** If the push handler updates `contentBinding.wrappedValue` on every keystroke, this triggers SwiftUI view updates (since the binding is observed). The `updateNSView` method would fire, hit `shouldPushContent()`, and return false (content matches). But the view diff still takes time. Consider rate-limiting the binding update to something like 100-200ms.

---

## 6. WAL Mode Proposal: Detailed Assessment

### Does GRDB's DatabaseQueue support WAL correctly?
Yes. GRDB's `Configuration.prepareDatabase` callback runs immediately after each database connection is opened. Setting WAL mode there is the documented approach.

### Will WAL survive across app restarts?
Yes. SQLite persists the journal mode in the database file. Once set to WAL, it remains WAL until explicitly changed.

### Are there concerns with DatabaseQueue + WAL?
`DatabaseQueue` serializes all database access (reads and writes). WAL mode's main benefit (concurrent reads during writes) is only fully realized with `DatabasePool`. With `DatabaseQueue`, WAL still provides benefits:
- Writes don't require exclusive locks on the entire database file.
- Write-ahead logging is generally faster than rollback journal for small transactions.
- No need for fsync on every commit with `synchronous = NORMAL`.

The plan's claim that "reads no longer block on writes" is only fully true with `DatabasePool`. With `DatabaseQueue`, reads still wait for writes to complete because the queue serializes access. This is an overstatement in the plan.

---

## 7. Task.detached for DB Writes: Detailed Assessment

### Is Task.detached the right pattern?
Not ideal. Better alternatives:

1. **GRDB's async write methods:** If available in the version being used, `dbWriter.write { }` can be called from a background context.

2. **Nonisolated helper method:** Create a nonisolated method on SectionSyncService that wraps just the DB calls, so Swift can schedule them on a cooperative thread without `Task.detached`:

```swift
private nonisolated func performDBSync(
    db: ProjectDatabase,
    pid: String,
    markdown: String
) throws {
    let sections = try db.fetchSections(projectId: pid)
    // ... reconcile and apply
    try db.saveContent(markdown: markdown, for: pid)
}
```

Then call from the MainActor context:
```swift
Task.detached(priority: .utility) { [db, pid, markdown] in
    try self.performDBSync(db: db, pid: pid, markdown: markdown)
}
```

3. **Thread safety:** `ProjectDatabase` is `Sendable` (line 9 of `ProjectDatabase.swift`), so passing it across isolation boundaries is safe. `SectionReconciler` would also need to be sendable or its work done within the detached task.

### Are there race conditions?
Yes, one potential issue: if `syncContent()` fires twice in quick succession (debounce timer races), two detached tasks could write to the database concurrently. GRDB's `DatabaseQueue` serializes them, so no data corruption occurs, but the second write might use stale data. The existing debounce (500ms) makes this unlikely but not impossible.

---

## 8. Overall Assessment

The plan correctly identifies the major latency contributors and proposes reasonable fixes. The priorities are well-ordered (push-based messaging and WAL mode are indeed highest impact).

**Critical issues to fix before implementation:**
- CodeMirror must push raw content (with anchors), not `doc.toString()`.
- Add client-side debounce (50-100ms) on the push messages to prevent message flooding.
- Use a better pattern than bare `Task.detached` for moving DB writes off-thread.
- WAL mode benefit with `DatabaseQueue` is overstated -- consider `DatabasePool` if concurrent reads are important.
- Address `BlockSyncService` DB writes too (same main-thread blocking issue as SectionSyncService).

**Important issues:**
- Reduce grace period from 600ms to ~200ms for push-based path.
- The per-keystroke `getMarkdown()` call in Milkdown's dispatch override is a major JS-side bottleneck not addressed in the plan.
- Consider rate-limiting SwiftUI binding updates from push messages.

**Suggestions:**
- Consider `DatabasePool` instead of `DatabaseQueue` to get full WAL concurrency benefits.
- Push stats alongside content to avoid needing a separate poll.
- Document the `synchronous = NORMAL` durability trade-off.
