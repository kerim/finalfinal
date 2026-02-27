# Code Review: Zotero Connection Failure Toast Notification Plan

## Summary

The plan is well-structured and follows existing patterns appropriately. It correctly identifies the two silent failure paths (citation search and lazy resolution) and proposes a proportionate solution. Below are findings organized by the four key questions, plus additional observations.

---

## 1. Completeness: Silent Failure Coverage

### Covered correctly

- **`MilkdownCoordinator+MessageHandlers.swift` -- `handleCitationSearch`** (line 379 catch block): Correctly identified. When `ZoteroService.shared.search()` throws a network error because Zotero is down, this catch block fires silently today. The plan adds a notification post here.

- **`MilkdownCoordinator+MessageHandlers.swift` -- `handleResolveCitekeys`** (lines 534-539 catch blocks): Correctly identified. Both the `ZoteroError.notRunning` and general error catch blocks are covered.

### Not covered -- CodeMirror editor (Important)

- **`CodeMirrorCoordinator+Handlers.swift` does NOT handle `searchCitations` or `resolveCitekeys` messages.** The CodeMirror source editor does not register these JS message handlers (confirmed: only `openCitationPicker` is registered for CodeMirror at `/Users/niyaro/Documents/Code/ff-dev/zotero-check/final final/Editors/CodeMirrorEditor.swift`, lines 44-50). This means when the user is in source mode, the only citation path is the CAYW picker, which already shows an NSAlert. So the plan's omission of CodeMirror is correct -- there is no silent failure path in CodeMirror to fix.

### Not covered -- BibliographySyncService (Should discuss)

- **`BibliographySyncService.swift` line 143**: `guard zoteroService.isConnected else { return }` -- This silently skips bibliography generation when Zotero is not connected. The plan does not address this.

  **Assessment**: This is an acceptable omission for now, and here is why. The `isConnected` guard means the bibliography sync simply does not attempt to contact Zotero when it was never established as connected. The user would already see the toast from the citation resolution path (which fires first when opening a document with citations), so a second toast from bibliography sync would be redundant. However, there is one edge case worth noting: if Zotero disconnects *after* initial connection and the user edits citations, the bibliography would silently fail to update while the toast only fires when citation resolution fails. This is a minor gap since the user would already see unresolved citations with `?` suffixes, but it may be worth a TODO comment in `BibliographySyncService` for future consideration.

### Not covered -- `refreshAllCitations()` (Suggestion)

- The `refreshAllCitations()` method at `/Users/niyaro/Documents/Code/ff-dev/zotero-check/final final/Editors/MilkdownCoordinator+MessageHandlers.swift` line 567 delegates to `handleResolveCitekeys()`, which IS covered by the plan. So this path is indirectly covered. No issue here.

### Not covered -- `editCitation()` in `ZoteroService+CAYW.swift`

- The `editCitation()` method at `/Users/niyaro/Documents/Code/ff-dev/zotero-check/final final/Services/ZoteroService+CAYW.swift` line 17 has `guard isConnected else { throw ZoteroError.notRunning }`. However, this is called from the CAYW picker flow, which already shows an NSAlert. Not a silent failure path.

### Not covered -- `connectToZotero()` at app launch (Discussed below in Edge Cases)

---

## 2. Pattern Consistency

### FocusModeToast pattern -- Good match

The plan correctly mirrors the existing `FocusModeToast` pattern:

| Aspect | FocusModeToast (existing) | ZoteroToast (proposed) |
|--------|--------------------------|----------------------|
| State property | `showFocusModeToast: Bool` on `EditorViewState` | `showZoteroToast: Bool` on `EditorViewState` |
| Binding pattern | `@Binding var isShowing: Bool` | `@Binding var isShowing: Bool` |
| Auto-dismiss | `Task.sleep(3s)` then `withAnimation { isShowing = false }` | `Task.sleep(8s)` then `withAnimation { isShowing = false }` |
| Overlay placement | `.overlay(alignment: .top)` on `mainContentView` | Same overlay, stacked with VStack |
| Material background | `.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))` | Same |

This is consistent and appropriate.

### NotificationCenter pattern -- Good match

The plan uses `NotificationCenter.default.post(name:)` from the coordinator and `.onReceive()` in ContentView, which matches the existing `proofingConnectionStatusChanged` pattern used in StatusBar. The difference is that StatusBar uses `.onReceive` while ContentView uses the same pattern for bibliography/notes/footnote notifications. Both are valid SwiftUI patterns.

### Minor concern: Notification vs direct property access

The existing `proofingConnectionStatusChanged` notification pattern works because `SpellCheckService` runs on a background actor and cannot directly update `@MainActor`-isolated state. In this case, `MilkdownEditor.Coordinator` is already `@MainActor` (its methods are annotated `@MainActor`), so it *could* directly access `EditorViewState` through a reference. However, the coordinator does not hold a reference to `EditorViewState`, and adding one would increase coupling. Using `NotificationCenter` is the simpler, more decoupled approach and is the right choice here.

---

## 3. Edge Cases

### App launch with Zotero closed and document containing citations

When a project opens, `connectToZotero()` at `/Users/niyaro/Documents/Code/ff-dev/zotero-check/final final/Views/ContentView+ProjectLifecycle.swift` line 159-161 pings Zotero and sets `isConnected = false` silently if Zotero is not running. Then:

1. The Milkdown editor loads and calls `pushCachedCitationLibrary()` -- since there are no cached items (fresh launch), it pushes nothing.
2. The web editor's citeproc engine finds unresolved `[@citekey]` nodes and sends a `resolveCitekeys` message.
3. `handleResolveCitekeys()` calls `fetchItemsForCitekeys()`, which has `guard isConnected else { throw ZoteroError.notRunning }`. This throws immediately.
4. The catch block fires, and with the plan, the toast would appear.

**This is correct behavior.** The user opened a document with citations, the editor tried to resolve them, and it failed. The toast would rightly inform the user. It would NOT fire spuriously just because Zotero is not installed -- it only fires when citation resolution is actually attempted by the web editor (meaning the document contains citations).

### Document with zero citations

If a document has no `[@citekey]` patterns, the web editor never sends a `resolveCitekeys` message, and `handleCitationSearch` is only called when the user explicitly types `/cite`. So no toast fires spuriously. This is correct.

### `fetchItemsForCitekeys` throws immediately without trying

The `guard isConnected else { throw ZoteroError.notRunning }` at `/Users/niyaro/Documents/Code/ff-dev/zotero-check/final final/Services/ZoteroService.swift` line 339 throws without making any network request. **This is the right behavior for toast triggering.** The toast should fire when the *result* is that citations cannot be resolved, regardless of whether we attempted a network call. The `isConnected` flag is set to `false` after a failed `ping()` or `search()`, so it accurately reflects Zotero's unreachability.

However, there is a subtle issue: **after the initial failed `connect()` on project open, `isConnected` stays `false` forever -- even if the user starts Zotero later.** The `isConnected` flag is only updated to `true` when `search()`, `ping()`, or `openCAYWPicker()` succeeds. This means:

- If the user opens Zotero after launching the app, the lazy resolution path will keep hitting the `guard isConnected` and showing the toast every 60 seconds (due to the cooldown) until the user triggers a successful `search()` or CAYW picker.
- The CAYW picker pre-check (`ping()`) would update `isConnected = true` if Zotero is now running, which would unblock `fetchItemsForCitekeys`. But the already-failed lazy resolution attempts would have already shown the toast.

**This is actually acceptable behavior** -- the toast tells the user "Zotero is not responding" which was true at the time. Once they use the CAYW picker, `isConnected` gets updated and subsequent resolution attempts succeed. But it is worth noting this in the plan as a known limitation.

### Rapid toast from multiple citekeys

When a document has N unresolved citekeys, the web editor sends a single `resolveCitekeys` message with all of them (not N separate messages). This means one failure = one notification post = one toast. The 60-second cooldown is a safety net for subsequent failures (e.g., polling triggers re-resolution), not for batching. This is well-designed.

### CAYW picker failure + toast double notification

The plan's verification step 7 mentions: "Type `/cite` with Zotero closed -- verify the CAYW picker still shows its own NSAlert, and the toast also appears if the cooldown has elapsed."

**Concern**: The CAYW picker path calls `showZoteroAlert()` which runs `alert.runModal()` -- a blocking modal dialog. The toast is non-modal. If both fire, the user sees an NSAlert *and* a toast behind it. This is not harmful but is slightly redundant. The CAYW path does NOT go through `handleCitationSearch` (it uses `handleOpenCitationPicker`), so the plan's notification posts in `handleCitationSearch` would NOT fire from the CAYW path. The only way both fire simultaneously is if:

1. Background lazy resolution fails (shows toast), AND
2. User immediately clicks `/cite` which shows NSAlert

This is a natural sequence and not a bug -- the toast is about background resolution, the NSAlert is about the explicit user action. Acceptable.

---

## 4. Verification Plan Adequacy

The verification section covers the core scenarios well. Here are additional test cases that should be included:

### Missing test cases (Important)

1. **Switch editors while toast is visible**: Toggle from WYSIWYG to Source mode while the toast is showing. Verify the toast is not duplicated or lost (it lives on ContentView, not the editor, so it should survive).

2. **Project switch with Zotero down**: Open project A (citations, toast fires), then open project B (citations). Verify the 60-second cooldown persists across projects (the plan explicitly states `lastZoteroToastTime` is NOT reset -- test this).

3. **Zotero recovery scenario**: Start with Zotero down, see toast. Start Zotero. Use `/cite` command (CAYW picker succeeds, sets `isConnected = true`). Verify toast no longer appears for subsequent documents.

4. **Empty document**: Open a document with no citations and Zotero closed. Verify no toast appears.

5. **Zoomed section with citations**: Zoom into a section containing citations with Zotero closed. Verify toast fires (since `handleResolveCitekeys` is called regardless of zoom state).

---

## 5. Additional Observations

### Plan references incorrect line numbers

The plan references specific line numbers (e.g., "line 379 catch block", "lines 534-539"). These line numbers are approximately correct for the current codebase but will drift as the code changes. This is a minor documentation concern, not a code concern.

### `showZoteroToastIfNeeded()` thread safety

The proposed `showZoteroToastIfNeeded()` method on `EditorViewState` uses `Date()` for cooldown comparison. Since `EditorViewState` is `@MainActor`, all calls to this method run on the main actor, so there is no race condition. The `NotificationCenter` `.onReceive` in SwiftUI also dispatches on the main thread. This is thread-safe.

### Toast dismissal interaction with cooldown

If the user sees the toast (8 seconds), then 52 seconds later another resolution fails, the cooldown (60 seconds from last show) would prevent the toast from appearing again. This is correct -- the cooldown counts from when it was *shown*, not when it was *dismissed*. If it counted from dismissal, the effective cooldown would be 68 seconds (8s display + 60s cooldown), which might be too long. The current design is better.

### The `.task` modifier for auto-dismiss

The plan uses `.task { try? await Task.sleep(nanoseconds: 8_000_000_000) ... }` inside the `ZoteroToast` view, matching the existing `FocusModeToast` pattern exactly. One thing to note: if `isShowing` is set to `true` while the view is already showing (e.g., the toast was re-triggered before it dismissed), the `.task` modifier in SwiftUI re-fires because the `if isShowing` condition causes a fresh view insertion. However, with the 60-second cooldown, this cannot happen (the toast dismisses after 8 seconds, and the cooldown prevents re-showing for 60 seconds). So this is a non-issue.

---

## Verdict

The plan is solid and ready for implementation with the following recommendations:

**No critical issues found.**

**Important suggestions:**
1. Add a comment in `BibliographySyncService.swift` near the `guard zoteroService.isConnected` line noting that toast notification for this path is intentionally omitted (covered by citation resolution toast).
2. Expand the verification section with the additional test cases listed above (especially the empty document case and the Zotero recovery case).

**Nice-to-have suggestions:**
1. Consider adding a brief note in the plan about why `isConnected` behavior (no automatic re-check) is acceptable for now, to document the design decision.
2. The overlay stacking approach (`VStack` with both toasts) is clean, but if more toasts are added in the future, consider extracting a generic `ToastStack` component. Not needed now.
