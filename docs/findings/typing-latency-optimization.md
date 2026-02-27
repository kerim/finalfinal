# Typing Latency Optimization

Branch: `typing-delay`. Addresses multiple sources of main-thread contention during keystroke processing.

---

## Problem

Typing felt sluggish, especially in longer documents. Profiling revealed multiple contributors competing for main-thread time during every keystroke:

1. **500ms content polling** — 3 sequential `evaluateJavaScript()` calls per poll cycle on MainActor
2. **300ms block sync polling** — additional JS bridge calls for structural sync
3. **Synchronous DB writes on MainActor** — `SectionSyncService` and `BlockSyncService` held exclusive SQLite locks on the main thread (DatabaseQueue without WAL)
4. **Per-keystroke overhead in JS plugins** — block-sync snapshot + detectChanges on every transaction; focus-mode double tree walk
5. **Traveling spell check underlines** — stale absolute positions caused decorations to appear on wrong words during typing

## Changes

### 1. Push-Based Content Messaging

**Before:** Swift polled `getContent()` every 500ms (3 JS calls per cycle: content, stats, section title).

**After:** Both editors push content to Swift via `contentChanged` WKWebView message handler with 50ms debounce. Polling reduced to 3s fallback for supplementary data only (`getPollData()` — one batched JSON call returning stats + section title).

**Files:**
- `web/milkdown/src/main.ts` — 50ms debounced `contentChanged` postMessage in dispatch wrapper
- `web/codemirror/src/main.ts` — 50ms debounced `contentChanged` postMessage via EditorView.updateListener
- `MilkdownCoordinator+MessageHandlers.swift` — `handleContentPush()` + polling interval 0.5s→3s
- `CodeMirrorCoordinator+Handlers.swift` — `handleContentPush()` + polling interval 0.5s→3s
- `MilkdownEditor.swift` / `CodeMirrorEditor.swift` — register `contentChanged` message handler

**Design decisions:**
- 50ms debounce balances responsiveness (much faster than 500ms poll) with avoiding per-keystroke bridge calls during rapid typing
- Grace period guards (150ms CM, 200ms Milkdown) prevent push handler from overwriting content that Swift just pushed to the editor
- Milkdown retains corruption check (heading→`<br>` mutation) in push path

### 2. DatabasePool + WAL Mode

**Before:** `DatabaseQueue` with default journal mode (DELETE). Every write took an exclusive lock, blocking concurrent reads (including ValueObservation).

**After:** `DatabasePool` enables WAL automatically — concurrent readers + single writer. Added `PRAGMA synchronous = NORMAL` for reduced fsync overhead.

**Files:** `ProjectDatabase.swift`

### 3. Off-Main-Thread DB Writes

**Before:** `SectionSyncService.syncContent()` ran DB reads, header parsing, reconciliation, and DB writes all on MainActor.

**After:** DB-heavy work dispatched via `Task.detached(priority: .utility)`. MainActor captures needed values before detaching; only `lastSyncedContent` tracking and UI notifications run back on MainActor.

**Files:**
- `SectionSyncService.swift` — `syncContent()` and `syncZoomedSections()` use `Task.detached`
- `SectionSyncService+Parsing.swift` — `parseHeaders()`, `parseHeaderLine()`, `extractPseudoSectionTitle()`, `extractExcerpt()` made `nonisolated static`
- `SectionReconciler.swift` — changed from `class` to `struct SectionReconciler: Sendable`
- `Database+Sections.swift` — `SectionChange` and `SectionUpdates` made `Sendable`
- `BlockSyncService.swift` — `applyChanges()` dispatches DB write via `Task.detached`
- `FootnoteSyncService.swift` — `nonisolated` annotations for detached task compatibility

### 4. Block Sync Debouncing

**Before:** `detectChanges()` ran synchronously on every ProseMirror transaction, including a redundant `nodeToMarkdownFragment()` call per updated block. Block polling at 300ms.

**After:** `detectChanges()` debounced with 100ms timer. Preserves the oldest un-processed snapshot across debounce resets so rapid keystrokes A→B→C diff A→C (not B→C, which would lose inserts from A). Uses pre-computed `markdownFragment` from snapshot instead of re-serializing. Block polling interval increased to 2s.

**Files:**
- `web/milkdown/src/block-sync-plugin.ts` — debounce timer + `pendingOldSnapshot` preservation
- `BlockSyncService.swift` — polling interval 0.3s→2s

### 5. Focus Mode Single-Pass

**Before:** Two `doc.descendants()` walks per transaction — one to find the cursor block, another to build decorations.

**After:** Single pass combines cursor detection and dimming. If cursor is in the current block, skip; otherwise, add dimmed decoration.

**Files:** `web/milkdown/src/focus-mode-plugin.ts`

### 6. Spellcheck Decoration Position Mapping

**Before:** Both editors stored spell check results with absolute positions and rebuilt the entire `DecorationSet` on every state change from those stale positions. During typing, underlines appeared on wrong words until the 400ms debounced recheck.

**After:** Both editors use native position mapping (`DecorationSet.map()`) to keep decorations synchronized with document changes. Fresh results delivered via transaction metadata (Milkdown) or version counter (CodeMirror).

**Files:**
- `web/milkdown/src/spellcheck-plugin.ts` — plugin state with `apply()`, `buildDecorationSet()`, `mapResults()`
- `web/codemirror/src/spellcheck-plugin.ts` — `DecorationSet.map()` in ViewPlugin, `mapResultPositions()`, `resultsVersion` counter

See [spellcheck.md](../architecture/spellcheck.md) "Decoration Position Mapping" section for full architectural details.

### 7. ValueObservation Deduplication

Added `.removeDuplicates()` to block observation stream to suppress redundant UI updates when DB writes don't change the actual block data.

**Files:** `Database+BlocksObservation.swift`

### 8. Drop Zone Level Calculation

Refactored `calculateZoneLevel()` to offer 2-3 valid level options relative to the predecessor (predecessor-1, same, predecessor+1) instead of dividing the sidebar width across all levels H1-HN. This is a correctness fix bundled with the branch, not a latency change.

**Files:** `OutlineSidebar+Models.swift`
