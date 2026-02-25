# TEMP ID Warnings on Zoom Transitions

Spurious TEMP ID warnings fired during zoom in/out, project switch, and initial load. Fixed by checking the `isSettingContent` flag.

**Date:** 2026-02-14
**Files changed:** `web/milkdown/src/block-id-plugin.ts`

---

## Root Cause

During zoom transitions, content changes follow a two-step sequence:

1. `setContent(markdown)` fires via SwiftUI binding — ProseMirror's `apply()` calls `assignBlockIds()` with stale `currentBlockIds` from the previous zoom state
2. `pushBlockIds()` runs after and correctly sets all real IDs

For example, zooming out from a section with 6 blocks to a full document with 35 blocks: step 1 only has 6 IDs to match against 35 nodes, so 29 blocks get temp IDs and fire warnings. Step 2 immediately overwrites them with real IDs.

The same pattern occurs on zoom-in, project switch, and initial load — any time Swift sets content programmatically.

## Key Insight

The `isSettingContent` flag in `editor-state.ts` is already `true` during every programmatic `setContent()` call. It wraps `view.dispatch(tr)` synchronously, and ProseMirror's `apply()` → `assignBlockIds()` runs synchronously inside `dispatch()`. This flag perfectly distinguishes programmatic changes from user editing.

## Fix

Added `getIsSettingContent()` check to the warning condition in `block-id-plugin.ts`:

```typescript
if (!suppressTempIdWarnings && !getIsSettingContent()) {
```

Coverage of all code paths:

| Scenario | `suppressTempIdWarnings` | `getIsSettingContent()` | Warnings? |
|----------|------------------------|------------------------|-----------|
| Initial load (binding) | false | **true** | Suppressed |
| `setContentWithBlockIds()` | **true** | true | Suppressed |
| Zoom in/out (binding) | false | **true** | Suppressed |
| Project switch (binding) | false | **true** | Suppressed |
| Bibliography rebuild | **true** | true | Suppressed |
| User typing (new paragraph) | false | **false** | **Fires** |

The last row preserves diagnostic value: when a user creates a new block by pressing Enter, `isSettingContent` is `false`, so genuine temp ID warnings still fire.

## Prior Attempt

The `suppressTempIdWarnings` flag and `setContentWithBlockIds()` atomic function were added earlier to handle initial load and project switch. They remain correct and useful but didn't cover zoom transitions because zoom uses the SwiftUI binding path (`setContent`) rather than the atomic path.
