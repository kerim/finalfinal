# Version History Window Bugs

Multiple issues with the standalone version history window, discovered after initial implementation.

---

## Bug 1: Window Restoration on Launch

**Symptom:** macOS restored the version-history window on app launch, appearing before any project was open — showing stale/empty state.

**Root cause:** macOS state restoration saves and restores all windows by default. SwiftUI `Window(id:)` scenes participate in this system automatically.

**Fix (two-part):**

1. `FinalFinalApp.swift`: Added `.defaultLaunchBehavior(.suppressed)` to the Window scene declaration. This tells SwiftUI not to open the window on launch.
2. `AppDelegate.swift`: Added cleanup in `applicationDidFinishLaunching` that closes any restored version-history windows and sets `isRestorable = false` before closing. SwiftUI assigns identifiers like `"version-history-1"` based on the Window id, so we match with `hasPrefix("version-history")`.

**Lesson:** Any secondary Window scene that should only open on demand needs `.defaultLaunchBehavior(.suppressed)` and AppDelegate cleanup as a belt-and-suspenders approach.

---

## Bug 2: `dismiss()` vs `dismissWindow(id:)`

**Symptom:** Clicking "Close" or completing a restore did not close the version history window.

**Root cause:** `@Environment(\.dismiss)` is designed for sheets and NavigationStack destinations. For standalone `Window` scenes opened via `openWindow(id:)`, the correct API is `@Environment(\.dismissWindow)` called with the window's id: `dismissWindow(id: "version-history")`.

**Fix:** Replaced all `dismiss()` calls with `dismissWindow(id: "version-history")` throughout `VersionHistoryWindow.swift` and `VersionHistoryWindow+Restore.swift`.

---

## Bug 3: Loading State Priority

**Symptom:** "No project open" message flashed briefly before snapshots loaded.

**Root cause:** The `isLoading` state check was ordered after `projectClosed` and `hasValidState` checks in the view body. When the coordinator hadn't populated yet, `hasValidState` was false and showed the wrong view.

**Fix:** Moved `isLoading` check to be the first condition in the view body's `if/else` chain. Also added `isLoading = false` when `coordinator.projectId` is nil to avoid infinite loading state.

---

## Bug 4: Sections Not Fresh from Database

**Symptom:** Version history showed stale section data from `editorState.sections` which could be empty or outdated.

**Root cause:** `ContentView` passed `editorState.sections` to the coordinator, but these might not reflect the latest database state (e.g., after background sync).

**Fix:** In `ContentView.swift`, fetch sections directly from the database via `db.fetchSections(projectId:)` and map to `SectionViewModel` before passing to the coordinator. Falls back to `editorState.sections` if the fetch fails.

---

## Bug 5: Auto Snapshot Deduplication

**Symptom:** Auto-backup created identical snapshots even when content hadn't changed, bloating the snapshot list.

**Fix:** Added `contentHash` (SHA256) column to the `snapshot` table. `SnapshotService.createAutoSnapshot()` now computes the hash and compares against the latest snapshot's hash, returning `nil` if unchanged. Manual snapshots always create regardless of hash match. Return type changed from `Snapshot` to `Snapshot?`.
