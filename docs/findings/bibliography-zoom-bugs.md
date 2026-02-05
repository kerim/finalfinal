# Bibliography Rendering and Zoom Word Count Bug Findings

**Date:** 2026-02-05
**Related Commit:** Fix bibliography rendering and zoom word count bugs

## Overview

This document describes two related bugs discovered after fixing data loss issues, their root causes, and the solutions implemented. Both bugs share a common underlying cause: the `contentState` guard in ValueObservation blocking UI updates during editing.

## Bug 1: Bibliography Not Rendering After Paste

### Symptoms
- After pasting text with citekeys (e.g., `[@smith2020]`), bibliography section was created in the database but not rendered in the editor
- Workaround: Zooming in/out on any section would cause the bibliography to appear
- The zoom workaround worked because `didZoomOut` explicitly triggers a fresh content rebuild

### Root Cause
The data flow for bibliography updates was:
1. `BibliographySyncService.performBibliographyUpdate()` updates the database
2. `EditorViewState.startObserving()` should detect the change via ValueObservation
3. ValueObservation posts `.bibliographySectionChanged` notification
4. ContentView receives notification and rebuilds content

**The problem:** ValueObservation has a guard at line 254:
```swift
guard contentState == .idle else {
    print("[OBSERVE] SKIPPED due to contentState: \(contentState)")
    continue
}
```

During active editing, `contentState` is often not `.idle`, causing ValueObservation updates to be silently dropped. The bibliography was saved to the database but the UI never received the notification to update.

### Solution
Post `.bibliographySectionChanged` notification directly from `BibliographySyncService` after database updates, bypassing the ValueObservation path entirely:

```swift
// In performBibliographyUpdate() after successful update:
NotificationCenter.default.post(name: .bibliographySectionChanged, object: nil)

// In removeBibliographySection() after successful removal:
NotificationCenter.default.post(name: .bibliographySectionChanged, object: nil)
```

This may cause harmless duplicate notifications (the second from ValueObservation will be ignored), but ensures the UI always updates.

## Bug 2: Word Count Not Updating in Zoom Mode

### Symptoms
- Editing content while zoomed into a section did not update word counts in the sidebar
- Word count goal colors did not change when crossing thresholds
- Status bar total remained stale during zoomed editing
- Zooming out and back in would show the correct (updated) counts

### Root Cause
The data flow for zoomed editing was:
1. User edits content in zoomed view
2. `SectionSyncService.syncZoomedSections()` parses changes and updates DATABASE with new word counts
3. ValueObservation should detect database change and update `editorState.sections`
4. UI reads from `editorState.sections` to display word counts

**The problem:** Same `contentState` guard blocked ValueObservation during zoomed editing. The database had correct word counts, but `editorState.sections` (the in-memory array) was never updated.

### Solution
Implement a direct callback from `SectionSyncService` to `EditorViewState` that bypasses ValueObservation:

1. **New callback property in SectionSyncService:**
```swift
var onZoomedSectionsUpdated: ((Set<String>) -> Void)?
```

2. **Invoke callback after successful zoomed sync:**
```swift
try db.applySectionChanges(changes, for: pid)
onZoomedSectionsUpdated?(zoomedIds)
```

3. **New method in EditorViewState:**
```swift
func refreshZoomedSections(database: ProjectDatabase, projectId: String, zoomedIds: Set<String>) {
    let dbSections = try database.fetchSections(projectId: projectId)
    for dbSection in dbSections where zoomedIds.contains(dbSection.id) {
        if let index = sections.firstIndex(where: { $0.id == dbSection.id }) {
            sections[index].wordCount = dbSection.wordCount
        }
    }
}
```

4. **Wire up in ContentView.configureForCurrentProject():**
```swift
sectionSyncService.onZoomedSectionsUpdated = { zoomedIds in
    editorState.refreshZoomedSections(database: db, projectId: pid, zoomedIds: zoomedIds)
}
```

## Related: Data Loss Issue Context

These bugs were discovered after fixing a data loss issue where:
- Zooming out would overwrite edited content with stale fullDocumentBeforeZoom backup
- The fix was to rebuild the document from `sections` array (database source of truth) instead of fragile title-matching against the backup

The data loss fix exposed these display bugs because:
1. The database always had correct data (data loss was fixed)
2. But the UI wasn't reflecting database state due to blocked ValueObservation

## Lessons Learned

### 1. ValueObservation Guards Can Block Critical Updates
The `contentState` guard was added to prevent race conditions during zoom transitions. However, it has side effects:
- Blocks ALL database observation updates, not just content changes
- Creates divergence between database state and UI state
- Can make bugs appear "random" since they depend on timing/state

**Recommendation:** Consider narrower guards or alternative approaches for specific operations rather than blanket blocking.

### 2. Direct Notification for Critical UI Updates
When a database change MUST trigger a UI update (like bibliography appearing or word counts updating), post notifications directly from the service that made the change. Don't rely solely on ValueObservation, which can be blocked.

### 3. Database as Source of Truth
The sections array should always reflect database state. When ValueObservation is blocked:
- Use direct database reads to refresh specific data
- Implement targeted refresh methods that bypass observation
- Consider partial updates (just word counts) rather than full array replacement

### 4. Zoom Mode Complexity
Zoom mode creates several challenges:
- Content is a subset of the full document
- Edits must be synced without affecting non-zoomed sections
- Word counts for zoomed sections must update in real-time
- Bibliography is excluded from zoomed view but may be updated

Each of these needs explicit handling; relying on general observation patterns isn't sufficient.

## Files Modified

| File | Changes |
|------|---------|
| `BibliographySyncService.swift` | Direct notification post after DB updates (2 locations) |
| `EditorViewState.swift` | Added `refreshZoomedSections()` method |
| `SectionSyncService.swift` | Added `onZoomedSectionsUpdated` callback + invoke after sync |
| `ContentView.swift` | Wire up callback in configureForCurrentProject() |

## Testing Checklist

- [ ] Paste text with citekeys → bibliography renders immediately (no zoom needed)
- [ ] Edit content while zoomed → word count updates in sidebar
- [ ] Edit content while zoomed → word count color changes when crossing goal threshold
- [ ] Status bar total updates during zoomed editing
- [ ] Normal (non-zoomed) editing still works correctly
- [ ] Zoom in/out still works correctly
- [ ] No data loss during any editing scenario
