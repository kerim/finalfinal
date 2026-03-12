# Debug Logging (DebugLog Category System)

Category-based logging that replaces raw `print()` calls. Noisy categories are off by default; enable only what you need.

---

## Quick Reference

```swift
// Category-gated (debug builds only, must be in `enabled` set)
DebugLog.log(.sync, "[SYNC-DIAG:Detect] found \(count) changes")

// Always prints (ALL builds) — mass-delete safety guards ONLY
DebugLog.always("[BlockSync] REJECTED mass delete of \(count) blocks")
```

## Available Categories

| Category | Covers | Default |
|----------|--------|---------|
| `.sync` | `[SYNC-DIAG:*]` block sync diagnostics | off |
| `.contentPush` | `[ContentPush]` per-keystroke content changes | off |
| `.blockPoll` | `[BlockPoll]` polling cycle details (~500ms) | off |
| `.editor` | `[MilkdownEditor]` `[CodeMirrorEditor]` lifecycle, JS errors | off |
| `.scheme` | `[EditorSchemeHandler]` `[MediaSchemeHandler]` asset serving | off |
| `.outline` | Outline cache, `[onSectionsUpdated]` | off |
| `.lifecycle` | `[AppDelegate]` `[DocumentManager]` `[FinalFinalApp]` app lifecycle | **on** |
| `.zotero` | `[ZoteroService]` citation operations | **on** |
| `.theme` | `[ThemeManager]` `[AppearanceSettings]` `[GoalColorSettings]` | off |
| `.bib` | `[CV:bib*]` bibliography rebuild cycle | off |
| `.zoom` | Zoom/section editing | off |
| `.fileOps` | `[FileOperations]` file commands | off |
| `.backup` | `[SnapshotService]` `[AutoBackupService]` | off |
| `.data` | `[Database+Blocks]` `[ProjectRepairService]` data layer | off |

## Enabling Categories

Edit `final final/Utilities/DebugLog.swift`:

```swift
/// Default: only lifecycle + zotero. Add categories here when debugging.
static let enabled: Set<Category> = [.lifecycle, .zotero]
```

To debug block sync issues, temporarily change to:

```swift
static let enabled: Set<Category> = [.lifecycle, .zotero, .sync, .blockPoll, .contentPush]
```

Rebuild after changing. The set is a compile-time constant — no runtime overhead for disabled categories.

## When to Use `always()` vs `log()`

- **`log(.category, ...)`** — all normal logging. Compiles to nothing in release builds; only prints when the category is in the `enabled` set.
- **`always(...)`** — reserved **exclusively** for mass-delete safety guards where silence risks data loss. Currently used in only 2 places (BlockSyncService mass-delete rejection). Do not add new `always()` calls without strong justification.

## JS → Swift Bridge Routing

The `errorHandler` WKWebView message handler routes JS messages by type:

| JS `type` field | Swift category | Prefix example |
|----------------|----------------|----------------|
| `sync-diag` | `.sync` | `[MilkdownEditor] JS SYNC-DIAG: ...` |
| `debug`, `slash-diag` | `.editor` | `[CodeMirrorEditor] JS DEBUG: ...` |
| `plugin-error`, `unhandledrejection`, `error` | `.editor` | `[MilkdownEditor] JS ERROR: ...` |

To see JS sync diagnostics, enable `.sync`. To see JS errors, enable `.editor`.

See [webkit-debug-logging.md](webkit-debug-logging.md) for the JS-side `postMessage` API.

## Adding New Log Calls

```swift
// Good — single-line, category-gated
DebugLog.log(.editor, "[MilkdownEditor] loaded theme: \(theme.name)")

// Bad — don't wrap in #if DEBUG (DebugLog handles that internally)
#if DEBUG
DebugLog.log(.editor, "[MilkdownEditor] loaded theme: \(theme.name)")
#endif

// Bad — don't use always() for routine errors
DebugLog.always("[Editor] failed to load: \(error)")  // Use log() instead
```

## @autoclosure and String Interpolation Cost

The message parameter is `@autoclosure`, so string interpolation is only evaluated when the category is enabled:

```swift
// This expensive interpolation only runs if .data is enabled
DebugLog.log(.data, "[DB] row count: \(try db.fetchCount(Block.self))")
```

For previously multi-line `#if DEBUG` blocks, inline the computation:

```swift
// Before (3 lines):
#if DEBUG
let count = try db.fetchCount(Block.self)
print("[DB] row count: \(count)")
#endif

// After (1 line):
DebugLog.log(.data, "[DB] row count: \((try? db.fetchCount(Block.self)) ?? -1)")
```

## Migration from print()

All `~336 print()` calls across `~40 Swift files` have been migrated. The only remaining `print()` calls are:
- Inside `#Preview` blocks (placeholder callbacks)
- Inside `DebugLog.swift` itself

If you add new logging, use `DebugLog.log()` — never bare `print()`.
