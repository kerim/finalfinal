# Plan: Fix "Save As..." Runtime Errors

## Context

The "Save As..." feature was implemented (notification, menu item, handler, AppDelegate wiring all done) but fails at runtime with:

```
SQLite error 6: database table is locked - while executing `PRAGMA wal_checkpoint(TRUNCATE)`
```

**Root cause**: `TRUNCATE` checkpoint requires exclusive database access, but GRDB's `ValueObservation` readers (`observeOutlineBlocks()`, `observeAnnotations()` in `EditorViewState`) are always active while a project is open.

## Changes

All changes in **`final final/Commands/FileCommands.swift`** — `handleSaveProjectAs()`.

### 1. Change WAL checkpoint to PASSIVE and make non-fatal (line ~384-392)

`PASSIVE` checkpoints as much WAL as possible without requiring exclusive access. Even if it only partially succeeds, `FileManager.copyItem` copies the entire `.ff` package (including `-wal` and `-shm` files), and SQLite replays remaining WAL data when the copy is opened.

Replace the current hard-error checkpoint block with:
```swift
do {
    try dm.projectDatabase?.dbWriter.write { db in
        try db.execute(sql: "PRAGMA wal_checkpoint(PASSIVE)")
    }
} catch {
    // Non-fatal: copyItem includes WAL files, SQLite recovers on open
    print("[FileOperations] Save As: WAL checkpoint warning: \(error)")
}
```

### 2. Move flush + checkpoint inside save panel callback

Currently `flushContentToDatabase()` runs *before* the save panel opens. The user could spend minutes choosing a location, during which the sync service continues writing to the database. Move both the flush and checkpoint to just before `copyItem`, inside the `Task { @MainActor in` block.

### 3. Update project title in copied database

After the copy is opened, the database still has the old project title. Update it to match the new filename:
```swift
try dm.openProject(at: destURL)
// Update title in copied database to match new filename
let newTitle = destURL.deletingPathExtension().lastPathComponent
if let db = dm.projectDatabase, var project = try db.fetchProject() {
    project.title = newTitle
    try db.updateProject(project)
    dm.projectTitle = newTitle
}
```

Uses existing `Database+CRUD.swift:20` `updateProject()` and the mutable `Project.title` field (`Document.swift:19`).

## Verification

1. Build and run
2. Open a project with content and images
3. File > Save As... > choose new name/location > should succeed without error
4. Verify: window title reflects the **new** name, not the old one
5. Verify: content and media images load correctly
6. Verify: original project is unchanged when reopened
7. Verify: new project appears in Open Recent with correct name
