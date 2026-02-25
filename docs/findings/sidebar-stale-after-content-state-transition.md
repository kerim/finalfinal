# Sidebar Not Updating After Content State Transitions

**Date:** 2026-02-15
**Branch:** `bib-delete-all-bug`

## Symptoms

Three sidebar bugs, all manifesting as stale section data after database changes:

1. **CM to Milkdown switch before sidebar populates:** New content typed in CodeMirror never appeared in the sidebar if the user switched to Milkdown before the 1s block re-parse fired.

2. **Citation added in Milkdown:** Bibliography block was created in the database, but no bibliography card appeared in the sidebar.

3. **New citation with existing bibliography:** Citation was added correctly, but the reference count on the bibliography card didn't update.

## Root Cause

All three share the same root cause: **GRDB ValueObservation updates are dropped during non-idle `contentState`, with no recovery mechanism.**

The observation loop in `EditorViewState.swift` uses:

```swift
guard contentState == .idle else { continue }
```

When a database change fires the ValueObservation during a non-idle transition, the update is silently dropped. Because `.removeDuplicates()` is applied to the observation, no re-emission occurs when `contentState` returns to `.idle`.

### Timing trace (Bug 2 as example)

1. `BibliographySyncService.updateBibliographyBlock()` writes bibliography block to DB
2. GRDB ValueObservation detects change, schedules callback **async** on main queue (`scheduling: .async(onQueue: .main)`)
3. `.bibliographySectionChanged` notification posted **synchronously** (same call frame)
4. ContentView handler sets `contentState = .bibliographyUpdate` (still same call frame)
5. ValueObservation callback arrives on **next** main queue iteration — `contentState != .idle` — **dropped**
6. Handler completes, sets `contentState = .idle` — but no new DB change — observation won't re-fire

Same pattern for Bug 1 (`.editorTransition` during mode switch) and Bug 3 (same as Bug 2 but updating existing block).

## Solution

### Change 1: Add `refreshSections()` to EditorViewState

**File:** `final final/ViewState/EditorViewState.swift`

Added a one-shot fetch method that mirrors the ValueObservation handler logic. It fetches outline blocks, converts to `SectionViewModel`s, aggregates word counts, and updates the sections array:

```swift
func refreshSections() {
    guard let db = projectDatabase, let pid = currentProjectId else { return }
    do {
        let outlineBlocks = try db.fetchOutlineBlocks(projectId: pid)
        var viewModels = outlineBlocks.map { SectionViewModel(from: $0) }
        for i in viewModels.indices {
            if let wc = try? db.wordCountForHeading(blockId: viewModels[i].id) {
                viewModels[i].wordCount = wc
            }
        }
        self.sections = viewModels
        self.recalculateParentRelationships()
        self.onSectionsUpdated?()
    } catch {
        print("[EditorViewState] Section refresh error: \(error)")
    }
}
```

Uses the same `fetchOutlineBlocks()` query and conversion logic as the ValueObservation handler.

### Change 2: Call `refreshSections()` when contentState returns to `.idle`

**File:** `final final/Views/ViewNotificationModifiers.swift` (new `withContentStateRecovery` modifier)
**File:** `final final/Views/ContentView.swift` (chain the modifier)

Added as a separate modifier (not inline in `withContentObservers`) to avoid hitting the Swift compiler's type-check complexity limit on the existing long `.onChange` chain:

```swift
func withContentStateRecovery(editorState: EditorViewState) -> some View {
    self.onChange(of: editorState.contentState) { oldValue, newValue in
        if newValue == .idle && oldValue != .idle {
            editorState.refreshSections()
        }
    }
}
```

Chained after `.withContentObservers()` in `ContentView.mainContentView`.

## Files Modified

| File | Change |
|------|--------|
| `EditorViewState.swift` | Add `refreshSections()` method |
| `ViewNotificationModifiers.swift` | Add `withContentStateRecovery()` modifier |
| `ContentView.swift` | Chain `.withContentStateRecovery()` after `.withContentObservers()` |

## Why This Approach

- **Centralized:** One observer handles all three bugs plus any future `contentState` transitions
- **Minimal:** One method, one observer, no changes to the existing ValueObservation pipeline
- **Safe:** Runs only on transitions TO `.idle`, not on initial state; single synchronous DB read with negligible cost
- **No regression risk:** Doesn't modify the existing observation guard or the `contentState` machine

## Lessons Learned

### 1. Async observation + synchronous state changes = dropped updates

The core issue is a scheduling mismatch: notifications are posted synchronously, setting `contentState` to non-idle, while ValueObservation callbacks arrive asynchronously on the next main queue iteration. By the time the observation fires, the guard has already been set. This is inherent to GRDB's `.async` scheduling mode.

### 2. `.removeDuplicates()` prevents recovery

Without `.removeDuplicates()`, the observation would re-emit the same value on subsequent database writes, eventually catching an `.idle` window. With it, a dropped update is permanently lost unless a new distinct change occurs. The `refreshSections()` call on idle transition compensates for this.

### 3. Compiler type-check limits are real constraints

The existing `.onChange` chain in `withContentObservers` was already at the Swift compiler's type-check limit. Adding one more modifier caused `error: the compiler is unable to type-check this expression in reasonable time`. Breaking the new observer into a separate modifier method resolved this.

## Related

- [bibliography-block-migration.md](bibliography-block-migration.md) — Earlier findings on the same `contentState` guard pattern blocking bibliography and word count updates
- [delete-all-content-reappears.md](delete-all-content-reappears.md) — The delete-all fix that exposed these sidebar bugs
- [contentstate-guard-rework.md](../deferred/contentstate-guard-rework.md) — Deferred plan for alternative approaches to the `contentState` guard pattern
