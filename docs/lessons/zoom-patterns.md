# Zoom Feature Patterns

Patterns for zoom (section focus) functionality. Consult before modifying zoom-related code.

---

## Async Coordination

### CheckedContinuation Double-Resume Prevention

**Problem:** Fatal error when both timeout and acknowledgement callback fire for the same continuation.

**Root Cause:** `waitForContentAcknowledgement()` uses a continuation with timeout. If the timeout fires and then `acknowledgeContent()` is called (or vice versa), the continuation is resumed twice, causing a crash.

**Solution:** Add an `isAcknowledged` flag to prevent double-resume:

```swift
private var isAcknowledged = false

func waitForContentAcknowledgement() async {
    isAcknowledged = false
    // ... in timeout handler:
    guard !isAcknowledged else { return }
    isAcknowledged = true
    contentAckContinuation?.resume()
}

func acknowledgeContent() {
    guard !isAcknowledged else { return }
    isAcknowledged = true
    contentAckContinuation?.resume()
}
```

**General principle:** When using `CheckedContinuation` with timeout races, guard against double-resume with a flag.

---

### Set Transitional State Before Awaits

**Problem:** Race condition where `contentState` was set after `await zoomOut()`, allowing other operations to start during the transition.

**Root Cause:** The `contentState = .zoomTransition` assignment came after the first `await`, leaving a window where `contentState == .idle` while async work was in progress.

**Solution:** Set transitional state BEFORE any awaits:

```swift
func zoomToSection(_ sectionId: String) async {
    guard contentState == .idle else { return }

    // SET CONTENTSTATE FIRST - before any awaits
    contentState = .zoomTransition

    if zoomedSectionId != nil && zoomedSectionId != sectionId {
        await zoomOut()  // zoomOut detects we're already in transition
    }
    // ...
}
```

**General principle:** In async state machines, set transitional states BEFORE any `await` points to prevent race conditions.

---

### Caller-Managed State for Nested Async Calls

**Problem:** `zoomOut()` reset `contentState = .idle`, but when called from `zoomToSection()`, the caller still needed the transition state.

**Root Cause:** `zoomOut()` assumes it owns the state lifecycle, but it can be called both standalone (owns state) and nested (caller owns state).

**Solution:** Detect if caller is managing state:

```swift
func zoomOut() async {
    let callerManagedState = (contentState == .zoomTransition)
    if !callerManagedState {
        contentState = .zoomTransition
    }
    // ... do work ...

    // Only reset if we set it ourselves
    if !callerManagedState {
        contentState = .idle
    }
}
```

**General principle:** When async functions can be called standalone or nested, check if the caller is managing shared state before setting/clearing it.

---

## State Protection

### Protect Backup State During Consecutive Operations

**Problem:** When zooming from section A to section B (without fully unzooming), the backup was overwritten with partial content.

**Root Cause:** Each `zoomToSection()` call stored the current content as backup. When already zoomed, the "current content" was the zoomed section's content, not the full document.

**Solution:** Only store backup if none exists:

```swift
if fullDocumentBeforeZoom == nil {
    fullDocumentBeforeZoom = content
}
```

**General principle:** When storing "before" state for undo/restore operations, guard against overwriting during chained operations.

---

### Sync All Editable Fields, Not Just Content

**Problem:** When user edited a header title while zoomed, the database wasn't updated with the new title.

**Root Cause:** The sync function only checked if content changed, not if title or level changed:

```swift
// Before: only content comparison
if section.markdownContent != newContent {
    // update
}
```

**Solution:** Check for title and level changes, not just content:

```swift
if header.title != existing.title {
    updates.title = header.title
    hasChanges = true
}
if header.level != existing.headerLevel {
    updates.headerLevel = header.level
    hasChanges = true
}
```

**General principle:** When syncing structured data, ensure ALL editable fields are checked for changes.

---

### Use Database as Source of Truth, Not Backup Parsing

**Problem:** When zooming into a section in Milkdown, editing the title, then zooming out, the title reverted to the original. CodeMirror worked correctly.

**Root Cause:** The `zoomOut()` function stored a backup of the full document before zoom, then when zooming out, it parsed the backup to find sections by **title AND level**. When a title changed while zoomed, no match was found.

The `parseMarkdownToSectionOffsets()` function assigns IDs by matching title+level against the current sections array. When the title changed:
- Parser sees "one point two gb" (new title)
- Sections array has "one point two gb" (new title from sync)
- Backup has "one point two OH" (old title)
- Parser tries to match backup's "one point two OH" -> no match -> assigns "unknown-N" ID
- zoomedIds check fails -> uses backup content (old title)

**Why CodeMirror worked:** CodeMirror uses section anchors (`<!-- section:UUID -->`) embedded in the content. These anchors preserve the actual section ID regardless of title changes.

**Solution:** Eliminate backup parsing entirely. The `sections` array (synced via ValueObservation) already contains all needed content:
- Zoomed sections: have edited content (synced via `syncZoomedSections`)
- Non-zoomed sections: have original content (unchanged in database)

```swift
// In zoomOut() - ROBUST
let sortedSections = sections
    .filter { !$0.isBibliography }
    .sorted { $0.sortOrder < $1.sortOrder }

var mergedContent = sortedSections
    .map { section in
        var md = section.markdownContent
        if !md.hasSuffix("\n") { md += "\n" }
        return md
    }
    .joined()

// Append bibliography at end
if let bibSection = sections.first(where: { $0.isBibliography }) {
    mergedContent += bibSection.markdownContent
}
```

**Why this works:**
1. **Database is truth** -- `syncZoomedSections` persists edits during zoom
2. **`sections` array is current** -- ValueObservation keeps it in sync
3. **No title matching** -- We use section IDs and sortOrder directly
4. **Handles all cases** -- Title changes, content changes, reordering all work

**General principle:** When restoring state after an editing operation, prefer using the live database-backed model rather than parsing a text backup. Text parsing is fragile when identifiers (like titles) can change during the operation.

---

### Bibliography Sync During Zoom

**Problem:** Citations added while zoomed into a section didn't trigger bibliography updates until app restart.

**Root Cause:** The bibliography sync service extracts citekeys from `editorState.content`, but during zoom this only contains the zoomed section's content, not the full document. Citations in the zoomed section were invisible to the sync check.

**Solution:** Post a `.didZoomOut` notification when zoom-out completes, triggering bibliography sync with the full document:

```swift
// In zoomOut()
if !callerManagedState {
    contentState = .idle
    NotificationCenter.default.post(name: .didZoomOut, object: nil)
}

// In ContentView
.onReceive(NotificationCenter.default.publisher(for: .didZoomOut)) { _ in
    let citekeys = BibliographySyncService.extractCitekeys(from: editorState.content)
    bibliographySyncService.checkAndUpdateBibliography(
        currentCitekeys: citekeys,
        projectId: projectId
    )
}
```

**General principle:** When operations occur in a partial-view context (zoom, filter), defer side effects that require the full view until the context is restored.

---

## Mode-Aware Block Range Calculation

### Shallow Zoom Must Narrow Editor Content, Not Just Sidebar

**Problem:** Option+double-click (shallow zoom) correctly filtered the sidebar to show only the root section (no child sections), but both editors still displayed all child headings and content — identical to a regular double-click.

**Root Cause:** The `endSortOrder` calculation in `zoomToSection()` always stopped at the next same-or-higher-level heading, regardless of zoom mode. The `mode` parameter only affected sidebar filtering (via `getShallowDescendantIds()` vs `getDescendantIds()`), never the block range sent to editors.

**Solution:** Make the `endSortOrder` loop mode-aware:

```swift
for block in sorted where block.sortOrder > headingBlock.sortOrder {
    if block.blockType == .heading {
        if mode == .shallow {
            // Shallow: stop at the very next heading (any level)
            endSortOrder = block.sortOrder
            break
        } else if let level = block.headingLevel, level <= headingLevel {
            // Full: stop at next same-or-higher-level heading
            endSortOrder = block.sortOrder
            break
        }
    }
}
```

**General principle:** When a mode parameter affects what the user sees, ensure it affects ALL output paths (sidebar, WYSIWYG editor, source editor), not just the first one implemented. Verify by tracing the mode parameter through every code path that computes visible content.

---

## Dual Editor Mode Content Update

**Problem:** After operations like drag-drop reorder, the CodeMirror editor (source mode) didn't update even though Milkdown (WYSIWYG) showed the correct content.

**Root Cause:** The app maintains two content properties:
- `editorState.content` -- used by MilkdownEditor
- `editorState.sourceContent` -- used by CodeMirrorEditor (includes section anchors)

Functions like `rebuildDocumentContent()` only updated `content`. When in source mode, `sourceContent` remained stale, so CodeMirror didn't re-render.

**Solution:** Create a helper that updates `sourceContent` whenever `content` changes while in source mode:

```swift
private func updateSourceContentIfNeeded() {
    guard editorState.editorMode == .source else { return }

    // Recalculate section offsets for anchor injection
    var adjustedSections: [SectionViewModel] = []
    var adjustedOffset = 0
    for section in sectionsForAnchors {
        adjustedSections.append(section.withUpdates(startOffset: adjustedOffset))
        adjustedOffset += section.markdownContent.count
        if !section.markdownContent.hasSuffix("\n") { adjustedOffset += 1 }
    }

    let withAnchors = sectionSyncService.injectSectionAnchors(
        markdown: editorState.content, sections: adjustedSections)
    editorState.sourceContent = sectionSyncService.injectBibliographyMarker(
        markdown: withAnchors, sections: editorState.sections)
}
```

Call this at the end of `rebuildDocumentContent()`.

**General principle:** When a view model has mode-specific content properties, ensure ALL are updated when shared state changes. Track which property each editor binds to.
