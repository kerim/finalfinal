# Stale Package on "Replace" in NSSavePanel

## Symptom

When creating a new project and choosing "Replace" at an existing `.ff` path, the old project's data persisted. The new project opened with stale content from the replaced package.

## Root Cause

`ProjectPackage.create(at:title:)` called `createDirectory(withIntermediateDirectories: true)`, which succeeds silently when the directory already exists. The old `content.sqlite` and other files inside the `.ff` package were left in place. The new project then opened the old database.

NSSavePanel does not delete directory-based packages when the user clicks "Replace" — it only deletes flat files. Since `.ff` packages are directories (declared as `com.apple.package` UTI), the panel left the existing directory intact.

## Fix

Added a guard in `ProjectPackage.create(at:title:)` that removes any existing package at the target URL before creating a fresh one:

```swift
if fm.fileExists(atPath: packageURL.path) {
    try fm.removeItem(at: packageURL)
}
```

**File:** `Models/ProjectPackage.swift`
**Commit:** `27d9047 fix: remove stale package when creating project at existing path`
