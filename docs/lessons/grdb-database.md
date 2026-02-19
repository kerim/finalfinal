# GRDB Database Patterns

Patterns for GRDB ValueObservation and configuration. Consult before writing database-related code.

---

## ValueObservation Race Conditions

### In-Memory Corrections vs Async Observation Delivery

**Problem:** Hierarchy enforcement corrected section header levels in memory, but the sidebar kept showing the old (uncorrected) levels.

**Root Cause:** ValueObservation delivers database updates asynchronously. When enforcement modified sections in memory:

```
T+0ms:    User types /h1 (H2 -> H1)
T+500ms:  Database updated with new header
T+501ms:  ValueObservation delivers update
T+502ms:  Enforcement corrects sibling H3 -> H2 in MEMORY
T+503ms:  ValueObservation delivers AGAIN (same DB change, async)
T+504ms:  sections = viewModels  // OVERWRITES in-memory corrections!
```

The second observation delivery reverted the in-memory corrections before they could be persisted.

**Solution:** Use a state machine to block observation updates during enforcement:

```swift
// In startObserving() - check state before applying updates
guard contentState == .idle else {
    print("[OBSERVE] SKIPPED due to contentState: \(contentState)")
    continue
}

// In enforcement function - use async with state blocking
@MainActor
private static func enforceHierarchyAsync(editorState: EditorViewState, ...) async {
    editorState.contentState = .hierarchyEnforcement
    defer { editorState.contentState = .idle }

    enforceConstraints(...)
    rebuildContent(...)
    await persistToDatabase(...)  // Wait for completion before clearing state
}
```

**Key elements:**
1. **State machine enum** (`EditorContentState: idle | zoomTransition | hierarchyEnforcement`)
2. **Check state in observation loop** -- skip updates when not `.idle`
3. **Use `defer` for cleanup** -- guarantees state reset even on errors
4. **Persist before clearing state** -- wait for database write to complete
5. **async/await instead of DispatchQueue** -- modern, structured concurrency

**General principle:** When in-memory state corrections compete with async observation delivery, block observation updates during the correction window using a state machine, and await persistence completion before re-enabling observation.

---

### Dual Content Properties: Update Both When Mode-Specific

**Problem:** Drag-drop section reorder in the sidebar updated the document correctly in WYSIWYG mode, but the editor didn't update when in Source mode (CodeMirror).

**Root Cause:** The app has two separate content properties for different editor modes:
- `editorState.content` -- used by WYSIWYG mode (MilkdownEditor binding)
- `editorState.sourceContent` -- used by Source mode (CodeMirrorEditor binding), contains anchor markup

The `rebuildDocumentContent()` function only updated `editorState.content`:

```swift
// rebuildDocumentContent() - ONLY updates content
editorState.content = newContent  // MilkdownEditor sees this

// But CodeMirrorEditor binds to sourceContent:
CodeMirrorEditor(content: $editorState.sourceContent, ...)  // Never updated!
```

When in source mode, the binding to `sourceContent` never changed, so `updateNSView()` was never triggered, and the editor continued showing the old content.

**Solution:** After rebuilding `content`, also update `sourceContent` when in source mode:

```swift
private func finalizeSectionReorder(sections: [SectionViewModel]) {
    editorState.contentState = .dragReorder
    defer { editorState.contentState = .idle }

    // ... recalculate offsets, rebuild content ...
    rebuildDocumentContent()

    // If in source mode, also update sourceContent with anchors
    if editorState.editorMode == .source {
        var adjustedSections: [SectionViewModel] = []
        var adjustedOffset = 0
        for section in editorState.sections.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            adjustedSections.append(section.withUpdates(startOffset: adjustedOffset))
            adjustedOffset += section.markdownContent.count
        }

        let injected = sectionSyncService.injectSectionAnchors(
            markdown: editorState.content,
            sections: adjustedSections
        )
        editorState.sourceContent = injected
    }
}
```

**Why `contentState` is also needed:** Even with `sourceContent` updated, editor polling could race with the update. Setting `contentState = .dragReorder` during the operation suppresses polling, ensuring the editor receives the complete reordered content.

**General principle:** When a view model has multiple properties that serve the same purpose for different contexts (e.g., mode-specific content), ensure all relevant properties are updated when the shared state changes. Track which property each consumer binds to.

---

### removeDuplicates() Suppresses Derived-Data Updates

**Problem:** Word counts in the sidebar didn't update while zoomed into a section. They only refreshed on zoom-out.

**Root Cause:** `observeOutlineBlocks` queried heading blocks with `.removeDuplicates()`. When the user typed body text:

1. BlockSyncService polled and updated body blocks in DB
2. The DB write triggered re-evaluation of the heading-only query
3. The query returned identical heading rows (body text changed, not headings)
4. `.removeDuplicates()` suppressed the emission
5. Word count recalculation never ran

**Why it was less noticeable outside zoom:** Non-zoomed mode has frequent `contentState` transitions (bibliography sync, hierarchy enforcement), each triggering `refreshSections()` on completion. During zoom, these are skipped (hierarchy enforcement is guarded by `zoomedSectionIds == nil`), so `refreshSections()` is rarely called.

**Solution:** Remove `.removeDuplicates()` from `observeOutlineBlocks`. The heading-only query returns <100 rows — well within GRDB's "small dataset" category where plain `.tracking` is recommended. The safety guards (`isObservationSuppressed`, `contentState == .idle`) already limit emission processing.

**General principle:** Don't use `.removeDuplicates()` when the observation's downstream processing derives values from related rows not included in the query. The query result may be identical, but the derived values (aggregates, counts) may differ.

---

## GRDB Configuration

### Never Use eraseDatabaseOnSchemaChange in Production

**Problem:** User data was being completely wiped when opening projects. All tables existed with correct schema, but all data rows were empty.

**Root Cause:** GRDB's `DatabaseMigrator` has an `eraseDatabaseOnSchemaChange` option that's useful during development but catastrophic in production:

```swift
// DANGEROUS - destroys all data on ANY schema change
var migrator = DatabaseMigrator()
#if DEBUG
migrator.eraseDatabaseOnSchemaChange = true  // DO NOT USE
#endif
```

When enabled, if GRDB detects any difference between the current schema and migrations, it:
1. Drops ALL tables
2. Recreates tables from migrations
3. **All user data is permanently lost**

This triggers on seemingly innocuous changes like:
- Modifying column defaults
- Adding indexes
- Changing column constraints
- Even recompiling with different Swift optimization levels

**Solution:** Never use `eraseDatabaseOnSchemaChange`. Instead:

1. **Write proper incremental migrations** that preserve data:
```swift
migrator.registerMigration("v2_add_column") { db in
    try db.alter(table: "section") { t in
        t.add(column: "newField", .text).defaults(to: "")
    }
}
```

2. **Use GRDB's migration versioning** -- migrations run once and are tracked in `grdb_migrations` table

3. **Test migrations on copies of real databases** before deploying

**Detection:** If you see:
- All tables exist with correct schema
- `grdb_migrations` table shows all migrations completed
- All data tables are empty (0 rows)

This is the signature of `eraseDatabaseOnSchemaChange` having wiped the database.

**Recovery:** Data cannot be recovered once wiped. The repair service can recreate structural records (project, content) but original content is lost forever.
