# Code Review: "Save As..." Implementation vs Plan

## Summary

The plan (`docs/plans/toasty-cuddling-tiger.md`) proposes a single, focused fix: change the WAL checkpoint from `TRUNCATE` to `PASSIVE` and make checkpoint failure non-fatal. The implementation in `FileCommands.swift` currently contains the pre-fix code (still using `TRUNCATE` with hard error). The menu item, notification wiring, and overall Save As flow are already in place and working correctly.

---

## 1. Plan Alignment Analysis

**Status: Plan is accurate and aligned with the implementation.**

The plan correctly identifies:
- The existing `handleSaveProjectAs()` code at lines 365-434 of `FileCommands.swift`
- The `TRUNCATE` checkpoint at lines 384-392 that causes the runtime error
- The notification name `.saveProjectAs` in `DocumentManager.swift` (line 426)
- The observer wiring in `AppDelegate.swift` (lines 110-116)

The plan's proposed change is minimal and well-scoped -- it only modifies the checkpoint pragma and error handling within `handleSaveProjectAs()`.

---

## 2. WAL Fix Diagnosis

**Verdict: The diagnosis is correct.**

The root cause analysis is sound:

- `ProjectDatabase` creates a `DatabasePool` (line 20 of `ProjectDatabase.swift`), which enables WAL mode automatically.
- `EditorViewState` runs two persistent `ValueObservation` loops: `observeOutlineBlocks()` (line 217 of `EditorViewState.swift`) and `observeAnnotations()` (line 296). These hold read transactions via `DatabasePool`'s reader connections.
- `PRAGMA wal_checkpoint(TRUNCATE)` requires exclusive access to the database file -- it needs to truncate the WAL file to zero length, which requires that no readers are active.
- Since the ValueObservation readers are always running while a project is open, `TRUNCATE` will consistently fail with SQLite error 6 ("database table is locked").

This is a well-known SQLite behavior. The diagnosis is accurate.

---

## 3. PASSIVE + Non-Fatal Approach Assessment

**Verdict: Sound approach, with one important nuance to document.**

The proposed fix is correct for the following reasons:

**Why PASSIVE works:**
- `PASSIVE` checkpoints as many WAL frames as possible without acquiring an exclusive lock. It skips frames that active readers are still using, but checkpoints everything else.
- Since this app copies the entire `.ff` package directory (which is a folder containing `content.sqlite`, `content.sqlite-wal`, and `content.sqlite-shm`), all WAL data is preserved in the copy.

**Why non-fatal is safe:**
- Even if `PASSIVE` fails entirely, `FileManager.copyItem(at:to:)` copies the directory recursively, including the WAL and SHM files.
- When the copied project is opened via `openProject(at:)`, GRDB's `DatabasePool` initializer automatically replays any remaining WAL data during connection setup.

**Alternatives considered but inferior:**
- `RESTART` or `FULL` checkpoint modes: These also require waiting for readers to finish, so they would have the same problem as `TRUNCATE`.
- Temporarily cancelling `ValueObservation` tasks before checkpoint: This would work but adds complexity, risks observation state loss, and is unnecessary given that the directory copy includes WAL files.
- Using `sqlite3_backup` API: More robust for live databases, but overkill here since the package copy already preserves WAL integrity.

**One nuance:** The `PASSIVE` checkpoint is still worth doing (not removing entirely) because it reduces the size of the WAL file in the copy. A smaller WAL means faster replay on open, and smaller file size on disk.

---

## 4. Overall Save As Flow Review

**Flow:** flush -> checkpoint -> show panel -> copy -> open

| Step | Code Location | Assessment |
|------|--------------|------------|
| Guard checks | Lines 369-376 | Good -- checks for open project and rejects Getting Started |
| Flush to DB | Line 379 | Good -- calls `flushContentToDatabase()` via `AppDelegate.shared?.editorState` |
| WAL checkpoint | Lines 384-392 | Bug being fixed -- see plan |
| NSSavePanel | Lines 394-404 | Good -- uses correct UTType, pre-fills name |
| Panel dismiss | Line 407 | Good -- `orderOut(nil)` before async work |
| Remove existing | Lines 414-416 | Good -- handles overwrite case |
| Copy package | Line 419 | Good -- copies entire `.ff` directory |
| Open copy | Lines 422-423 | Good -- `openProject` closes current project internally |
| Post notification | Line 423 | Good -- UI will update |

**Important: The flush call on line 379 has a potential issue.**

```swift
AppDelegate.shared?.editorState?.flushContentToDatabase()
```

If `AppDelegate.shared` is nil (theoretically shouldn't happen but defensive code should account for it) or `editorState` is nil, the flush silently does nothing. The `editorState` reference is `weak`, so it could be nil if the view has been deallocated. This is low-risk in practice because Save As requires an open project with an active editor, but worth noting.

---

## 5. Data Loss Risk: WAL Changes Between Checkpoint and Copy

**Verdict: No data loss risk, but for a subtle reason.**

The concern: Could the database change between the checkpoint call (line 384-392) and the `copyItem` call (line 419)?

Analysis:
- Between checkpoint and copy, the user interacts with an `NSSavePanel`. During this time, `ValueObservation` callbacks and debounced writes could modify the database.
- However, this is safe because `copyItem` copies the entire directory including WAL files. Any writes that happen between checkpoint and copy will be in the WAL file, and `copyItem` will include that updated WAL.
- The only theoretical risk would be if `copyItem` copies `content.sqlite` and `content.sqlite-wal` at different instants and a write happens between them. Since `copyItem` on a directory is not atomic, this is theoretically possible.

**This is the most significant concern in the implementation.** In practice, the risk is extremely low because:
1. The files are small (typical project databases are < 1MB)
2. The copy happens very quickly
3. `flushContentToDatabase()` was already called, so there's limited new data being written

However, if you wanted to be fully paranoid, you could:
- Move the `NSSavePanel` display BEFORE the flush+checkpoint, so the copy happens immediately after the flush with no user-facing delay in between.
- Or use SQLite's backup API.

For a desktop writing app, the current approach is acceptable. This is not a database serving concurrent network requests.

---

## 6. Error Handling Assessment

| Location | Current Handling | Assessment |
|----------|-----------------|------------|
| Checkpoint failure | Hard error + return (pre-fix) | Bug -- plan fixes this correctly |
| copyItem failure | Catch + alert | Good |
| openProject failure | Catch + alert | Good |
| Flush failure | Silent (inside flushContentToDatabase) | Acceptable -- errors logged internally |
| No project open | Guard + return | Good |
| Getting Started guard | Guard + return | Good |

**After the plan's fix is applied**, the error handling will be adequate. The non-fatal checkpoint warning is the right approach.

One minor suggestion: the post-fix `catch` block could use `#if DEBUG` around the print statement for consistency with other debug logging in the codebase:

```swift
} catch {
    #if DEBUG
    print("[FileOperations] Save As: WAL checkpoint warning: \(error)")
    #endif
}
```

However, looking at other print statements in `FileOperations` (e.g., lines 263, 389, 429), they are NOT gated by `#if DEBUG`. So the plan's approach is consistent with the existing pattern in this file. No change needed.

---

## 7. Coding Standards Issues

**No significant issues found.** The implementation follows the established patterns in the codebase:

- Uses the notification-based command dispatch pattern (consistent with other File menu items)
- Uses `@MainActor` correctly on `FileOperations`
- Uses `Task { @MainActor in }` for async work after panel callbacks
- Follows the `savePanel.orderOut(nil)` pattern before async work
- Error alerts use the shared `showErrorAlert` helper

**One minor observation:** The `Save As...` menu item (line 47-49) does not have a keyboard shortcut. This is standard macOS behavior -- Save As typically uses Cmd+Shift+Option+S or no shortcut at all. The current implementation (no shortcut) is fine.

**Title issue in copied project:** After `copyItem` + `openProject`, the copied project will retain the original project's title in the database (since `fetchProject()` reads the title from the `project` table). If the user saves as "My Essay - Copy.ff", the displayed title will still be whatever the original was (e.g., "My Essay"). The filename-based `defaultName` on line 394 is only used for the save panel suggestion, not for updating the database after copy. This might confuse users who expect the title to match the filename.

This is outside the scope of the WAL fix plan, but worth tracking as a follow-up.

---

## Final Assessment

**The plan is correct and should be applied as written.** The WAL fix is well-diagnosed, the proposed PASSIVE + non-fatal approach is the right solution, and the overall Save As flow is sound.

### Issues Summary

| Category | Issue | Recommendation |
|----------|-------|----------------|
| Critical | WAL `TRUNCATE` fails at runtime | Apply the plan's fix (PASSIVE + non-fatal) |
| Suggestion | Title not updated in copied database | Track as follow-up -- after Save As, update the project title in the new database to match the new filename |
| Suggestion | Theoretical non-atomic directory copy risk | Acceptable for a desktop writing app. No action needed now. |
