# Race Condition Fixes: Implementation Plan

**STATUS: ALL 5 FIXES IMPLEMENTED AND VERIFIED (2026-03-01)**

## Context

Features keep breaking due to race conditions between async operations (polling, JS callbacks, state transitions, DB observations). The root cause: 6 scattered suppression flags, a fragile continuation pattern, stale polling data, and a TOCTOU gap in flushContentToDatabase. These 5 surgical fixes address the systemic issues without a rewrite.

**Implementation order:** Fix 1 → 2 → 3 → 4 → 5 (safest first, largest refactor last). Each fix is independently committable.

**Code review status:** Plan validated by 3 independent code reviewers (swift-engineering, superpowers, feature-dev). Fixes 1-4 confirmed correct. Fix 5 had gaps identified and corrected below.

## Implementation Results

- All 5 fixes build and run successfully
- User-tested: load, zoom in/out, drag reorder, editor switch (Milkdown ↔ CodeMirror), project close/reopen, auto-backup
- Incidentally fixed: annotation display bug in right sidebar
- `contentState=dragReorder` confirmed in runtime logs (Fix 5 working)
- No crashes, no watchdog warnings, no stale poll messages
- Pre-existing issue noted (not part of this plan): Main Thread Checker violation in `fetchFromWebView` calling `evaluateJavaScript` off main thread (line 184 in logs)

---

## Fix 1: Harden CheckedContinuation Against Double-Resume

**Problem:** `waitForContentAcknowledgement()` has three code paths that can call `continuation.resume()` — a timeout task, the `acknowledgeContent()` callback, and the 5-second watchdog. The `isAcknowledged` boolean guard works today because all three paths are `@MainActor`-serialized (no suspension points between the guard check and resume call). However, this is fragile — the boolean flag set AFTER resume creates a confusing ordering, and any future refactoring that introduces an `await` between check and resume would create a fatal crash.

**File:** `final final/ViewState/EditorViewState+Zoom.swift`

**Changes:**

1. Add a helper method that nil-checks AND nils the reference before resuming — making it impossible to resume twice:
```swift
/// Resume the acknowledgement continuation exactly once.
/// Nils the reference before calling resume() to prevent double-resume.
func resumeAckContinuationOnce() {
    guard let continuation = contentAckContinuation else { return }
    contentAckContinuation = nil  // Nil BEFORE resume — atomic guard
    continuation.resume()
}
```

2. Rewrite `waitForContentAcknowledgement()` (lines 15-37):
```swift
func waitForContentAcknowledgement() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        contentAckContinuation = continuation
        // Timeout: if JS never acknowledges, resume after 1s to prevent deadlock
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.resumeAckContinuationOnce()
        }
    }
}
```

3. Rewrite `acknowledgeContent()` (lines 41-46):
```swift
func acknowledgeContent() {
    resumeAckContinuationOnce()
}
```

**File:** `final final/ViewState/EditorViewState.swift`

4. Remove `var isAcknowledged = false` (line 121) — no longer needed
5. In the watchdog (lines 80-81), replace:
```swift
// OLD:
self.contentAckContinuation?.resume()
self.contentAckContinuation = nil
// NEW:
self.resumeAckContinuationOnce()
```

**Why this works:** The nil-before-resume pattern is atomic on @MainActor because @MainActor code runs serially. The first caller gets the continuation and nils it; the second caller sees nil and returns.

---

## Fix 2: Make flushContentToDatabase Atomic (MEDIUM)

**Problem:** `flushContentToDatabase()` does a separate `db.fetchBlocks()` read to extract metadata, then passes it to `BlockParser.parse()`, then calls `db.replaceBlocks()`. Between the read and write, polling or observation could modify the blocks. This is a TOCTOU gap.

**Key insight:** Both `replaceBlocks()` and `replaceBlocksInRange()` already read existing blocks and preserve metadata **inside their write transactions** (`Database+BlocksReorder.swift:41-83, 88-170`). The pre-read in `flushContentToDatabase()` is redundant AND introduces a race.

**File:** `final final/ViewState/EditorViewState+Zoom.swift`

**Changes to `flushContentToDatabase()` (lines 348-428):**

1. Remove lines 357-365 (the redundant metadata pre-read):
```swift
// DELETE this entire block:
let existing = try db.fetchBlocks(projectId: pid)
var metadata: [String: SectionMetadata] = [:]
for block in existing where block.blockType == .heading {
    metadata[block.textContent] = SectionMetadata(
        status: block.status,
        tags: block.tags?.isEmpty == false ? block.tags : nil,
        wordGoal: block.wordGoal
    )
}
```

2. Change the `BlockParser.parse` call to pass `nil` for metadata:
```swift
let blocks = BlockParser.parse(
    markdown: contentToParse,
    projectId: pid,
    existingSectionMetadata: nil  // Metadata preserved atomically by replaceBlocks/replaceBlocksInRange
)
```

No other files change. `replaceBlocks` and `replaceBlocksInRange` handle metadata preservation internally within their single write transaction.

**Bonus:** The internal `HeadingMetadata` struct preserves 8 fields (`status`, `tags`, `wordGoal`, `goalType`, `aggregateGoal`, `aggregateGoalType`, `isBibliography`, `isNotes`) vs. the pre-read's `SectionMetadata` which only captures 3 (`status`, `tags`, `wordGoal`). Removing the pre-read actually preserves *more* metadata through flush operations.

---

## Fix 3: Guard Debounce with Generation Counter (MEDIUM)

**Problem:** In `SectionSyncService.contentChanged()`, rapid calls cancel and recreate debounce tasks. But `Task.isCancelled` checking is cooperative — there's a window where the old task passes the cancellation check and the new task also starts, leading to two `syncContent()` calls with different content.

**File:** `final final/Services/SectionSyncService.swift`

**Changes:**

1. Add a generation counter (after line 16):
```swift
private var debounceGeneration: Int = 0
```

2. Modify `contentChanged()` (lines 130-143):
```swift
func contentChanged(_ markdown: String, zoomedIds: Set<String>? = nil) {
    guard !isSyncSuppressed else { return }
    guard markdown != lastSyncedContent else { return }

    debounceTask?.cancel()
    debounceGeneration += 1
    let myGeneration = debounceGeneration
    debounceTask = Task {
        try? await Task.sleep(for: debounceInterval)
        guard !Task.isCancelled else { return }
        // Double-check: if another contentChanged fired during sleep, skip
        guard self.debounceGeneration == myGeneration else { return }
        await syncContent(markdown, zoomedIds: zoomedIds)
    }
}
```

**File:** `final final/Services/AnnotationSyncService.swift`

3. Same pattern — add `private var debounceGeneration: Int = 0` and guard the debounce task with a generation check in its `contentChanged()` method.

**Also apply to:** `blockReparseTask` in `ViewNotificationModifiers.swift` (lines 304-337) has the same cooperative cancellation race. Add a generation counter there too.

**Why this works:** Even if `Task.isCancelled` doesn't propagate in time, the generation check catches it. Only the most recent debounce task's generation will match.

---

## Fix 4: Content Generation Counter for Stale Poll Detection (HIGH)

**Problem:** Editor polling fires on a timer. The JS `evaluateJavaScript` callback is async. Between starting the poll and receiving the callback, `contentState` can change (e.g., zoom starts). The callback then delivers stale data from before the transition.

Existing guards check `contentState == .idle` before starting the poll, but the callback arrives later when the state may have changed.

**File:** `final final/ViewState/EditorViewState.swift`

1. Add a content generation counter (after line 106):
```swift
/// Incremented on every content state transition away from idle.
/// Polling captures this before JS calls and discards results if it changed.
var contentGeneration: Int = 0
```

2. In `contentState`'s `didSet` (line 65), add generation increment:
```swift
var contentState: EditorContentState = .idle {
    didSet {
        // Increment generation on every non-idle transition
        if oldValue == .idle && contentState != .idle {
            contentGeneration += 1
        }
        // ... existing watchdog code unchanged ...
    }
}
```

**Files:** `final final/Editors/MilkdownEditor.swift`, `final final/Editors/CodeMirrorEditor.swift`

3. Pass `contentGeneration` to editor views (add property + pass in `updateNSView`)

**Files:** `final final/Editors/MilkdownCoordinator+MessageHandlers.swift`, `final final/Editors/CodeMirrorCoordinator+Handlers.swift`

4. Add `var contentGeneration: Int = 0` property to each coordinator

5. In poll methods, capture generation before JS call, check after:
```swift
func pollContent() {
    guard !isCleanedUp, isEditorReady, let webView else { return }
    guard contentState == .idle else { return }

    let generationAtPoll = contentGeneration  // Capture BEFORE async call

    webView.evaluateJavaScript("window.FinalFinal.getPollData()") { [weak self] result, _ in
        guard let self, !self.isCleanedUp else { return }
        // Discard stale result if a state transition happened during the JS roundtrip
        guard self.contentGeneration == generationAtPoll else {
            #if DEBUG
            print("[Poll] Discarded stale result (gen \(generationAtPoll) != \(self.contentGeneration))")
            #endif
            return
        }
        // ... rest of existing processing unchanged ...
    }
}
```

6. Same pattern for BlockSyncService's `checkForChanges()` and `getBlockChanges()` callbacks.

**Why this works:** The generation counter is incremented atomically on @MainActor when contentState transitions. Any poll that started before the transition will see a stale generation and discard its result.

---

## Fix 5: Consolidate Suppression Flags (HIGH — Largest Change)

**Problem:** 6 separate boolean flags across 4 services control whether operations should be suppressed:
- `EditorViewState.isObservationSuppressed` — during drag
- `EditorViewState.isZoomingContent` — during zoom content push (KEEP: rendering directive)
- `EditorViewState.isResettingContent` — during project switch (KEEP: rendering directive)
- `SectionSyncService.isSyncSuppressed` — during drag/zoom/bibliography
- `BlockSyncService.isSyncSuppressed` — during drag/zoom/bibliography/push
- `AnnotationSyncService.isSyncSuppressed` — during bibliography rebuild

When adding a new feature, you must remember to set the right combination of flags. Missing one causes a race condition.

**Goal:** Replace flag-checking with a single query: `contentState != .idle`. Services check `contentState` directly instead of maintaining their own flags.

### Review-Identified Gaps (Must Address)

Code reviewers found 3 places where flags are set but `contentState` is NOT already non-idle. These must be fixed or the consolidation will silently remove real guards:

**Gap 1: `onDragStarted` never sets `contentState = .dragReorder`** (`ContentView.swift:487-495`)
The callback sets `isObservationSuppressed`, `sectionSyncService.isSyncSuppressed`, and `blockSyncService.isSyncSuppressed` — but `contentState` stays `.idle`. The `.dragReorder` case already exists in the enum but is only set later in `finalizeSectionReorder()`.
**Fix:** Set `contentState = .dragReorder` in `onDragStarted`, clear to `.idle` in `onDragEnded`.

**Gap 2: `handleAnnotationTextUpdate` suppression has no backing `contentState`** (`ContentView+ContentRebuilding.swift:241-279`)
Sets `annotationSyncService.isSyncSuppressed = true` with a fragile 100ms sleep-based reset. `contentState` is `.idle` throughout.
**Fix:** Add `case annotationEdit` to `EditorContentState`. Set it before the annotation update, clear after the 100ms delay (replacing the sleep-based flag toggle).

**Gap 3: Zoom sidebar callbacks set flags before Task** (`ContentView.swift:441-447, 470-474, 479-483`)
`blockSyncService.isSyncSuppressed = true` is set synchronously, then a `Task { }` calls `zoomToSection()`/`zoomOut()` which sets `contentState = .zoomTransition` inside. Brief window between flag set and contentState transition.
**Fix:** Move `contentState = .zoomTransition` to before the Task (synchronous), so it covers the gap. `zoomToSection()`/`zoomOut()` already guard `contentState == .idle` at entry — change their guards to accept `.zoomTransition` as well (since the caller pre-set it).

### Changes

**File:** `final final/ViewState/EditorViewState+Types.swift`
- Add `case projectSwitch` to `EditorContentState` enum
- Add `case annotationEdit` to `EditorContentState` enum

**File:** `final final/ViewState/EditorViewState.swift`
- Add `var isBusy: Bool { contentState != .idle }` computed property
- Remove `var isObservationSuppressed = false` (line 202)
- In `startObserving()` line 221: remove the `isObservationSuppressed` guard (line 224 already checks `contentState == .idle`)
- In `resetForProjectSwitch()`: remove `isObservationSuppressed = false` (line 458)

**File:** `final final/Services/SectionSyncService.swift`
- Add `weak var editorState: EditorViewState?` property
- Update `configure()` to accept and store `editorState`
- Replace `guard !isSyncSuppressed` (line 132) with `guard !(editorState?.isBusy ?? false)`
- Remove `var isSyncSuppressed: Bool = false`

**File:** `final final/Services/BlockSyncService.swift`
- Add `weak var editorState: EditorViewState?` property
- Update `configure()` to accept and store `editorState`
- In `pollBlockChanges()`: replace `!isSyncSuppressed` with `editorState?.contentState == .idle`
- In `pushBlockIds()` and `setContentWithBlockIds()`: remove `isSyncSuppressed = true / defer { false }` pairs — these are always called when contentState is already non-idle
- Remove `var isSyncSuppressed: Bool = false`

**File:** `final final/Services/AnnotationSyncService.swift`
- Same pattern: add `weak var editorState`, replace `isSyncSuppressed` check, remove the property

**File:** `final final/Views/ContentView.swift`
- Update service `configure()` calls to pass `editorState`
- Remove all `blockSyncService.isSyncSuppressed = true/false` assignments — contentState transitions handle this
- Remove all `sectionSyncService.isSyncSuppressed = true/false`
- Remove all `annotationSyncService.isSyncSuppressed = true/false`
- In `onDragStarted`: replace flag sets with `editorState.contentState = .dragReorder`
- In `onDragEnded`: replace flag clears with `editorState.contentState = .idle`
- In zoom sidebar callbacks (lines 441, 470, 479): set `editorState.contentState = .zoomTransition` synchronously before the Task, remove flag assignments
- Replace `editorState.isResettingContent = true/false` in project switch paths with `editorState.contentState = .projectSwitch / .idle`

**File:** `final final/Views/ContentView+ContentRebuilding.swift`
- In `handleAnnotationTextUpdate()`: replace `annotationSyncService.isSyncSuppressed = true` with `editorState.contentState = .annotationEdit`; replace the 100ms sleep + flag clear with `editorState.contentState = .idle`
- Remove `blockSyncService.isSyncSuppressed` assignments (lines 388, 428)

**File:** `final final/ViewState/EditorViewState+Zoom.swift`
- In `zoomToSection()`: change `guard contentState == .idle` to `guard contentState == .idle || contentState == .zoomTransition` (to accept pre-set state from sidebar callbacks)
- In `zoomOut()`: same guard adjustment

**Keep unchanged:**
- `isZoomingContent` — rendering directive, not a suppression flag. Passed through SwiftUI view hierarchy for `updateNSView` to decide how to handle content pushes.
- `isResettingContent` — also a rendering directive used in bibliography/footnote paths where `contentState` is already `.bibliographyUpdate`. Tells `updateNSView` to skip content pushes during atomic operations. Keep as a derived property: set in `contentState`'s `didSet` when state is `.projectSwitch` or `.bibliographyUpdate`.

---

## Verification Plan

After each fix, verify manually:

1. **Fix 1 (continuation):** Rapidly zoom in/out of sections 10+ times. Should never crash. Also test: zoom in, wait >1s (timeout fires), then zoom out — continuation should not double-resume.
2. **Fix 2 (atomic flush):** Edit content in zoomed mode, zoom out. Verify: section status, tags, word goals, goal types, aggregate goals, bibliography/notes flags all preserved. The replace methods preserve 8 fields vs. the old pre-read's 3.
3. **Fix 3 (debounce guard):** Type rapidly in editor. Watch Xcode console — should see exactly one `[SectionSyncService]` sync per debounce period, never two.
4. **Fix 4 (stale poll):** Start a zoom while typing. Watch for `[Poll] Discarded stale result` debug messages. Content should not flash or revert.
5. **Fix 5 (flag consolidation) — FULL REGRESSION:**
   - **Drag-drop:** Drag a section in the sidebar. Observation and sync should be suppressed during the drag gesture (not just during finalize). Sections should not flicker or re-sort during drag.
   - **Zoom from sidebar:** Click to zoom. `contentState` should transition to `.zoomTransition` synchronously before the async zoom Task starts. No stale poll during the gap.
   - **Annotation sidebar edit:** Double-click an annotation to edit text. Annotation sync should be suppressed during the edit. No feedback loop or duplicate annotations.
   - **Editor toggle (Cmd+/):** Content should transfer cleanly between Milkdown and CodeMirror.
   - **Bibliography update:** Insert a citation. Bibliography should rebuild without sync interference.
   - **Project switch:** Open a different project. Old content should not bleed into the new project.
   - **Footnote insertion while zoomed:** Insert a footnote. Mini-notes section should update correctly.

## Key Files Summary

| File | Fixes |
|------|-------|
| `ViewState/EditorViewState+Zoom.swift` | 1, 2, 5 |
| `ViewState/EditorViewState.swift` | 1, 4, 5 |
| `ViewState/EditorViewState+Types.swift` | 5 |
| `Services/SectionSyncService.swift` | 3, 5 |
| `Services/BlockSyncService.swift` | 4, 5 |
| `Services/AnnotationSyncService.swift` | 3, 5 |
| `Views/ContentView.swift` | 5 |
| `Views/ContentView+ContentRebuilding.swift` | 5 |
| `Views/ViewNotificationModifiers.swift` | 3 |
| `Editors/MilkdownEditor.swift` | 4 |
| `Editors/CodeMirrorEditor.swift` | 4 |
| `Editors/MilkdownCoordinator+MessageHandlers.swift` | 4 |
| `Editors/CodeMirrorCoordinator+Handlers.swift` | 4 |
