# Delete-All Content Reappears Bug

**Date:** 2026-02-14
**Branch:** `bib-delete-all-bug`
**Related Commit:** `8bbfa60`

## Symptoms

After Cmd+A + Delete in Milkdown (WYSIWYG mode), deleted content reappeared within one poll cycle (~500ms). The user could not permanently delete all content.

## Root Causes (2 issues)

### 1. Empty-content guard in polling (CRITICAL)

`MilkdownCoordinator+MessageHandlers.swift` had a defensive guard that blocked empty content from overwriting non-empty content:

```swift
if content.isEmpty && !existingContent.isEmpty {
    print("[MilkdownEditor] pollContent: BLOCKED empty content overwriting non-empty")
    return  // Don't erase good content with empty from broken editor
}
```

This guard was originally added to protect against Milkdown initialization failures where `getContent()` would return empty before the editor was fully loaded. However, it also blocked legitimate delete-all operations. When the user selected all and deleted, the poll detected empty content, compared it to the existing non-empty binding value, and rejected the update. The stale binding value then got pushed back to the editor on the next `setContent()` cycle.

### 2. Same guard in content save path

`MilkdownCoordinator+Content.swift` had the same pattern in `saveContentBeforeSwitch()`:

```swift
if content.isEmpty && !existingContent.isEmpty {
    // Skip - don't overwrite good content with empty
}
```

This prevented mode switches from preserving the empty state — switching to CodeMirror after a delete-all would show the old content.

### 3. Mass delete safety net (CONTRIBUTING)

`Database+Blocks.swift` had a safety net in `applyBlockChangesFromEditor()` that rejected deletions affecting >50% of blocks (minimum 6):

```swift
if deleteRatio > 0.5 && changes.deletes.count > 5 {
    print("[Database+Blocks] SAFETY NET: Rejecting mass delete...")
    changes.deletes = []
}
```

This was added during early block sync development to catch runaway delete bugs. With the polling guard fixed, this safety net was no longer needed and would interfere with legitimate bulk operations.

## Solution

### Change 1: Remove empty-content blocking in poll handler

**File:** `MilkdownCoordinator+MessageHandlers.swift`

Removed the `return` statement so empty content flows through normally. Kept the debug log for visibility:

```swift
if content.isEmpty && !self.contentBinding.wrappedValue.isEmpty {
    #if DEBUG
    print("[MilkdownEditor] pollContent: Accepting empty content (user deleted all)")
    #endif
}
```

### Change 2: Remove empty-content blocking in content save

**File:** `MilkdownCoordinator+Content.swift`

Removed the guard entirely — `saveContentBeforeSwitch()` now unconditionally passes content through:

```swift
self.lastPushedContent = content
self.contentBinding.wrappedValue = content
```

### Change 3: Remove mass delete safety net

**File:** `Database+Blocks.swift`

Removed the delete ratio check from `applyBlockChangesFromEditor()`. The `contentState` guard and debounced polling provide sufficient protection against spurious deletes without blocking legitimate operations.

## Files Modified

| File | Change |
|------|--------|
| `MilkdownCoordinator+MessageHandlers.swift` | Remove `return` from empty-content guard in poll handler |
| `MilkdownCoordinator+Content.swift` | Remove empty-content guard in `saveContentBeforeSwitch()` |
| `Database+Blocks.swift` | Remove mass delete safety net from `applyBlockChangesFromEditor()` |

## Lessons Learned

### 1. Defensive guards can become bugs

The empty-content guard was a reasonable defense during early development when Milkdown initialization was unreliable. But it prevented a core user operation (delete all). Defensive code should be re-evaluated as the system matures — the `contentState` machine now handles initialization races properly, making the guard redundant and harmful.

### 2. Safety nets need expiration dates

The mass delete safety net was useful for catching early sync bugs but overstayed its welcome. Safety nets added during active development should be documented with the specific bug they prevent and removed once the underlying system is stable.

## Related

- [section-break-cleanup-after-delete-all.md](../deferred/section-break-cleanup-after-delete-all.md) — Deferred fix for `§` placeholder appearing after delete-all (ProseMirror default block type issue)
