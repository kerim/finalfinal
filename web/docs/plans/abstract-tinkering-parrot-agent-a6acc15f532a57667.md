# Image Fixes Round 2 -- Code Review

## Summary

Review of changes implementing 3 image-related fixes plus diagnosing the
regression that broke project window opening.

---

## 1. Circular Import Analysis -- The Hypothesis Is Wrong

**The build succeeds.** Running `vite build` on the milkdown source compiles
all 924 modules without any import cycle error. The import graph is:

```
main.ts  -->  api-content.ts  -->  image-plugin.ts  -->  block-id-plugin.ts
   |                                     |                      |
   +--> image-plugin.ts                  +--> source-mode-plugin.ts
```

`image-plugin.ts` imports from `block-id-plugin.ts` and `source-mode-plugin.ts`.
`api-content.ts` imports `consumePendingDropPos` from `image-plugin.ts`.
Neither `image-plugin.ts` nor `block-id-plugin.ts` imports from `api-content.ts`.

**There is no circular import.** The `api-content -> image-plugin` edge is a
one-way dependency. `image-plugin` never imports from `api-content`, `main`,
or any module that imports from `api-content`. Vite/Rollup would detect and
warn about true cycles during bundling, and none appeared.

**The built JS file confirms the changes are included.** The output at
`final final/Resources/editor/milkdown/milkdown.js` (built at 21:13:30,
sources modified at 21:13:22) contains `imageMeta`, `blob:` cleanup code,
and `posAtCoords` drop position logic. The build succeeded completely.

**Creating `image-drop-state.ts` is unnecessary.** The proposed fix to extract
the `pendingDropPos` state into a separate module would work, but it is solving
a problem that does not exist. The current import structure is acyclic.

---

## 2. What Actually Broke the App?

Since the JS builds cleanly, the break must be on the **Swift side**. The most
likely candidate is the new `scrollToBlockId` binding plumbing:

### The `MilkdownEditor` Initializer Change

`MilkdownEditor` gained a new required `@Binding var scrollToBlockId: String?`.
The `ContentView+ContentRebuilding.swift` diff shows it being added to the
editor construction site (line ~319), but I only see it in ONE place in
that file.

**Critical question:** Is `scrollToBlockId` passed everywhere `MilkdownEditor`
is instantiated? If any call site is missing the new binding, Swift will fail
to compile. The Xcode build would catch this as a compile error, not a runtime
crash.

If the app does build but windows do not open, the issue is more likely a
**runtime crash in the content loading path**. The changes to
`fetchBlocksWithIds()` changed its return type from
`(markdown: String, blockIds: [String])?` to
`(markdown: String, blockIds: [String], imageMeta: [ImageBlockMeta])?`.

Every call site that destructures this return value needs updating. The diffs
show 4 call sites updated in:
- `ContentView.swift` (3 places)
- `ContentView+ProjectLifecycle.swift` (1 place)

If there is a 5th call site that was missed, it would crash at runtime when
trying to destructure the tuple. This would manifest as the window failing
to open because content loading crashes during `onAppear`.

**Recommended diagnostic steps:**
1. Check the Xcode build log -- does the Swift code compile at all?
2. If it compiles, check the Xcode console for crash logs when opening a project
3. Search for ALL uses of `fetchBlocksWithIds` to verify none were missed

---

## 3. Fix-by-Fix Review

### Fix 1: AVIF Paste Error Dialog (Swift NSAlert)

**Files:** `MilkdownCoordinator+MessageHandlers.swift`,
`CodeMirrorCoordinator+Handlers.swift`

**Verdict: Correct, with one concern.**

The implementation is straightforward and correct. Adding `NSAlert.runModal()`
in the catch block of `handlePasteImage` will show a modal dialog when image
import fails. This is the right UX for a user-initiated paste action.

**Concern: `runModal()` is blocking.** It runs a modal event loop on the main
thread. This is fine for a user-triggered error dialog, but verify that
`handlePasteImage` is always called from a WKScriptMessageHandler on the main
thread (which it should be, since WKWebView message handlers dispatch to main).
If it were ever called from a background context, `runModal()` would crash or
behave unexpectedly.

**Minor issue in CodeMirror version:** The existing `print()` was not wrapped
in `#if DEBUG` before this change. The diff adds `#if DEBUG` around it, which
is good -- that is a bonus cleanup.

**This fix cannot cause the app to break on startup** because it only runs
inside a catch block of an image paste operation that requires user action.

### Fix 2: Drop Position Capture

**Files:** `image-plugin.ts` (handleDrop + pendingDropPos state),
`api-content.ts` (consumePendingDropPos in insertImage)

**Verdict: Correct design, well-implemented.**

The approach is sound:
1. `handleDrop` captures the drop position using `view.posAtCoords()` before
   the async round-trip to Swift
2. The position is stored as module-level state (`pendingDropPos`)
3. `insertImage()` consumes it via `consumePendingDropPos()` (consume = read
   and clear atomically)
4. A 10-second timeout clears stale positions if the import fails

**Good defensive coding:**
- The `$pos.depth >= 1` check prevents a crash when dropping at doc boundary
- The `try/catch` around `doc.resolve()` handles edge cases
- The `dropPos >= 0 && dropPos <= view.state.doc.content.size` range check in
  `insertImage` prevents out-of-bounds insertion
- The `event.stopPropagation()` addition prevents WebKit from also handling the
  drop (which was causing duplicate blob: img insertions)

**The blob: cleanup in insertImage is a nice touch:**
```typescript
document.querySelectorAll('img[src^="blob:"], img[src^="data:"]').forEach((el) => el.remove());
```
This handles the race where WebKit's native drag handler inserts a blob image
before the ProseMirror plugin's `handleDrop` fires.

**Potential concern:** If two images are dropped in quick succession (within
10 seconds), the second drop overwrites `pendingDropPos` before the first
`insertImage` call arrives. This is unlikely in practice but worth noting.

### Fix 3: Image Width Persistence Across Editor Switch

**Files:** `types.ts` (new `ImageBlockMeta` interface),
`api-content.ts` (imageMeta injection in `setContentWithBlockIds`),
`BlockSyncService.swift` (passing imageMeta to JS),
`ContentView+ContentRebuilding.swift` (collecting imageMeta from DB)

**Verdict: Correct approach, matching existing pattern.**

The implementation mirrors the existing `applyBlocks` pattern for injecting
image metadata into figure nodes. The `setContentWithBlockIds` function now
accepts optional `imageMeta` and does a positional match of figure nodes to
metadata entries -- the same approach `applyBlocks` already uses.

The Swift side builds the JSON correctly via `JSONSerialization` and passes
it through the JS template literal with proper escaping.

**One concern with positional matching:** Both `applyBlocks` and
`setContentWithBlockIds` match figure nodes to metadata by position (index 0
= first figure, index 1 = second figure, etc.). If the markdown has figure
nodes that do NOT correspond to image blocks in the DB (e.g., inline images
not managed as blocks), the positional matching would apply wrong metadata.
This is a pre-existing design limitation, not introduced by this change.

### Bonus Fix: Block-ID-based Scrolling for Milkdown

**Files:** `MilkdownEditor.swift`, `EditorViewState.swift`,
`MilkdownCoordinator+Content.swift`, `ContentView+SectionManagement.swift`,
`api-content.ts` (scrollToBlock improvement)

**Verdict: Good improvement, correctly scoped.**

The change to use `scrollToBlockId` instead of character offset for Milkdown
is a legitimate fix. Atom nodes (like figures) have `nodeSize=1` in ProseMirror
but variable character length in markdown, causing character-offset-based
scrolling to land at the wrong position.

The `scrollToBlock` JS implementation was also improved to use
`view.coordsAtPos()` + `window.scrollTo()` instead of
`setSelection().scrollIntoView()`, which provides better visual positioning
(~100px from top).

CodeMirror still uses character offsets, which is correct since CodeMirror
works with plain text where character positions map directly.

---

## 4. Identified Issues

### Critical (must fix before committing)

1. **Find the actual cause of the app breaking.** It is NOT a circular import.
   Verify whether the Swift code compiles at all, and if so, check for runtime
   crashes in the content loading path. Specifically, verify all call sites of
   `fetchBlocksWithIds()` were updated for the new 3-tuple return type.

### Important (should fix)

2. **The `image-drop-state.ts` extraction is unnecessary.** Do not create it.
   The current import structure is acyclic and the build succeeds. Adding an
   extra module adds complexity for no benefit.

3. **Double-escape bug in BlockSyncService.swift:** The `escapedMeta` string
   does `replacingOccurrences(of: "\\", with: "\\\\")` on JSON produced by
   `JSONSerialization`. But the JSON is then embedded via `JSON.parse(...)` in
   a JS template literal. The `JSON.parse` call re-parses the string, so the
   double-escaping of backslashes is correct for the template literal embedding.
   However, if any metadata values contain backticks or `${`, the existing
   escaping handles that. This is fine.

### Suggestions (nice to have)

4. **Extract the temp-ID retry pattern into a helper.** The same retry logic
   (check for temp ID, setTimeout 3000ms, retry with getBlockIdAtPos) is
   repeated in `onResizeEnd`, `onCaptionBlur`, and `showAltTextPopup`. A
   single helper function like `sendMetaToSwiftWithRetry(blockId, pos, payload)`
   would reduce the ~15 lines of duplication to ~3 lines per call site.

5. **The 10-second stale timeout for pendingDropPos could be shorter.** The
   Swift image import typically completes in under 2 seconds. A 5-second
   timeout would still be safe and reduce the window for stale position bugs.

6. **scrollToBlock in api-content.ts no longer sets selection.** The old code
   set the ProseMirror selection and used `scrollIntoView()`. The new code only
   scrolls the window. This means clicking a section in the sidebar no longer
   places the cursor at that section. This may be intentional (avoiding cursor
   jump disruption) but is a behavior change worth confirming with the user.

---

## 5. Recommended Next Steps

1. **Check Xcode build output** -- does the project compile?
2. If yes, **check Xcode console** for runtime crash on project open
3. **Search for ALL uses of `fetchBlocksWithIds`** to ensure none were missed
4. If the build fails, the error message will point to the exact missing
   binding or tuple mismatch
5. Do NOT create `image-drop-state.ts` -- the circular import hypothesis is
   disproven
