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

---

## Bug 6: All Sections Marked "New" — Random UUIDs in Current Sections

**Symptom:** Opening version history marked every section as "New" regardless of actual changes. This was a regression from the block-based architecture migration.

**Root cause (three independent bugs):**

### 6a: `parseAndGetSections()` creates random UUIDs (PRIMARY)

`ContentView`'s `onShowHistory` handler called `sectionSyncService.parseAndGetSections(from:)` which creates **new `Section` objects with random UUIDs every time** (SectionSyncService.swift). These random IDs became `originalSectionId` in the comparison, so they never matched any snapshot section's `originalSectionId`. The `computeSectionChanges` function then marked everything as "New".

**Fix:** Replaced `parseAndGetSections()` with `syncNow()` + `loadSections()` which fetches real sections from the database with stable IDs. Wrapped in `Task {}` since both methods are async. Added guard against project change during await. For zoomed mode, assembles full content from blocks before syncing.

### 6b: Section table empty during editing

`ViewNotificationModifiers`'s `.onChange(of: editorState.content)` handler never called `sectionSyncService.contentChanged()` — the call had been removed during the block migration. Without this, the section table was never populated during editing, so `loadSections()` would return empty results.

**Fix:** Re-added `sectionSyncService.contentChanged(newValue, zoomedIds: editorState.zoomedSectionIds)` in the content change handler.

### 6c: Silent error swallowing + nil originalSectionId fallback

`fetchOrParseSnapshotSections` had a `catch { return [] }` that silently swallowed ALL errors. If `fetchSnapshotSections` threw (e.g., GRDB decode failure), the error was hidden. Additionally, old snapshots (pre-fix) genuinely have no `snapshotSection` rows, so the fallback parsed sections from `previewMarkdown` with `originalSectionId: nil`. The `computeSectionChanges` function marked any section with nil `originalSectionId` as "New".

**Fix (two-part):**
1. Added `#if DEBUG` error logging in the catch block to surface decode failures.
2. Added title+headerLevel fallback matching in `computeSectionChanges`: when `originalSectionId` is nil or not found, falls back to matching by compound key `"title|headerLevel"` to reduce false "New" badges on old snapshots.

### 6d: Snapshots used stale content and parsed (not DB) sections

`SnapshotService.createManualSnapshot()` and `createAutoSnapshot()` read from the `content` table which could be stale (block sync writes to blocks, not content). They also didn't ensure sections were synced before creating snapshots.

**Fix:**
- Both snapshot methods now assemble fresh markdown from blocks via `BlockParser.assembleMarkdown(from:)` and save it to the content table before creating the snapshot.
- Both methods use `database.fetchSections()` to get real sections with stable IDs.
- `ContentView+ProjectLifecycle.handleSaveVersion()` calls `syncNow()` before snapshot creation.
- `configureForCurrentProject()` calls `syncNow()` after loading content to populate the section table.

### 6e: Coordinator state leak between projects

`VersionHistoryCoordinator.close()` didn't clear `projectId`, so stale state from a previous project could leak into the next session.

**Fix:** Added `self.projectId = nil` in `close()`.

**Key architectural lesson:** `parseAndGetSections()` (SectionSyncService) creates ephemeral sections with random UUIDs — suitable for sidebar display but **never** for identity-dependent operations like version history comparison. Always use `loadSections()` for stable IDs.
