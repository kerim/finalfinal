# Code Review: Plan "Fix CM Blank Display + Mass Deletes After Image Addition"

**Plan file:** `/Users/niyaro/Documents/Code/ff-dev/images/docs/plans/idempotent-stirring-hopper.md`
**Reviewer:** Code Review Agent
**Date:** 2026-02-28

---

## Summary

The plan proposes two fixes: (1) fixing CodeMirror blank display when image markdown is present, and (2) preventing mass block deletes on CM-to-MW editor switch. I reviewed all 10 referenced files against the plan. Below are my findings organized by the six review criteria you specified.

---

## 1. Does the root cause analysis match the actual code flow?

### Fix 1 (CM Blank Display): PARTIALLY CONFIRMED, with a concern

The root cause claim is that `estimatedHeight: 200` in `ImagePreviewWidget` (line 67-69 of `image-preview-plugin.ts`) causes CM6's virtual viewport calculation to be wrong after async image loading, because CM6 is never notified of the actual height change.

**What matches:**
- The `estimatedHeight` getter does exist at lines 67-69 of `/Users/niyaro/Documents/Code/ff-dev/images/web/codemirror/src/image-preview-plugin.ts`
- There is no `img.onload` handler to trigger a re-measure after the image loads
- `EditorView` is already imported (line 13), so no new import is needed
- `EditorView.findFromDOM()` is a real CM6 API (confirmed via Context7 docs -- introduced in v6.0.0)

**Concern -- `EditorView.findFromDOM(wrapper)` may not work from a widget's DOM:**
The `findFromDOM` static method finds an `EditorView` from its own DOM structure (the element returned by `EditorView.dom`). A widget's DOM is injected as a child of a line element, so it should be traversable up to the view's root. However, the CM6 docs say it works on "its DOM structure" meaning the view's own `.dom` element -- not arbitrary child elements. The wrapper `<div>` created by `toDOM()` is a child inside the CM DOM tree, so `findFromDOM` should walk up the DOM to find the editor. But if the widget is detached or being removed, this could return `null`. The plan does guard against this with `if (view)`, which is correct.

**Alternative concern:** The blank display might not be solely caused by `estimatedHeight`. It could also stem from the `projectmedia://` scheme handler failing to serve the image (timing, scheme registration order, or the image not being available yet). The plan does not discuss this possibility. If the image never loads at all, removing `estimatedHeight` and adding `requestMeasure()` would not help -- the widget would just collapse to 0 height with no image and no error text.

### Fix 2 (Mass Deletes): CONFIRMED, with a nuance

The root cause analysis traces the sequence:
1. `batchInitialize()` sets `lastPushedContent = content` (from `contentBinding.wrappedValue`)
2. `onWebViewReady` Task calls `setContentWithBlockIds(result.markdown)` which may differ slightly
3. The existing fix (line 340-341) sets `editorState.content = result.markdown` but only when `contentState == .editorTransition`
4. `blockSyncDidPushContent` notification (line 165-168 of `BlockSyncService.swift`) also sets `lastPushedContent = markdown` on the coordinator

**The nuance:** The plan says `shouldPushContent(1842)` sees `lastPushedContent(1843)` and returns true, triggering a destructive re-push. But looking at the actual code flow:

- `setContentWithBlockIds` at line 165-168 of `BlockSyncService.swift` already posts `.blockSyncDidPushContent` with the correct markdown
- The MilkdownEditor coordinator subscribes to this at lines 466-474 of `MilkdownEditor.swift` and sets `lastPushedContent = markdown`

So `lastPushedContent` IS being updated via the notification path. The question is **timing**: does the notification handler run before or after `isResettingContent = false` (line 344) and the subsequent `updateNSView`? Since both the notification handler and the `onWebViewReady` Task body run on the main actor, and the notification is posted inside `setContentWithBlockIds` (which is `await`ed at line 334), the notification should fire and be processed BEFORE the line `editorState.isResettingContent = false` at line 344. This means `lastPushedContent` should already be updated by the time `updateNSView` runs.

**However**, the plan's approach of also setting `coordinator.lastPushedContent` directly is a belt-and-suspenders approach that eliminates any reliance on notification timing. This is defensively sound.

---

## 2. Are there any files that need changes but are NOT listed in the plan?

**IMPORTANT finding -- the plan changes MilkdownEditor's `onWebViewReady` signature but does NOT update CodeMirrorEditor.**

Looking at all callsites of `onWebViewReady`:

| File | Line | Current Signature | Needs Change? |
|------|------|-------------------|---------------|
| `MilkdownEditor.swift` | 42 | `((WKWebView) -> Void)?` | YES (per plan) |
| `MilkdownEditor.swift` | 242 | Coordinator property | YES (follows from above) |
| `MilkdownEditor.swift` | 294 | Coordinator init parameter | YES (follows from above) |
| `CodeMirrorEditor.swift` | 38 | `((WKWebView) -> Void)?` | NO -- different type |
| `ContentView+ContentRebuilding.swift` | 323 | MW closure | YES (per plan) |
| `ContentView+ContentRebuilding.swift` | 378 | CM closure | NO -- different type |

The plan correctly identifies that only the Milkdown path needs the signature change. CodeMirror's `onWebViewReady` is a separate type on a separate struct and does not need to change. **No missing files.**

However, the plan should explicitly note that `MilkdownEditor.Coordinator.init()` at line 283-307 also needs the parameter type updated from `((WKWebView) -> Void)?` to `((WKWebView, Coordinator) -> Void)?`. The plan mentions "the `onWebViewReady` parameter already passes through, no change needed" -- but this is wrong. The `init` parameter type at line 294 is explicitly typed as `((WKWebView) -> Void)?` and must be changed to match.

Similarly, the coordinator's stored property at line 242:
```swift
var onWebViewReady: ((WKWebView) -> Void)?
```
must also be updated to:
```swift
var onWebViewReady: ((WKWebView, Coordinator) -> Void)?
```

The plan's statement "Update `makeCoordinator()` -- the `onWebViewReady` parameter already passes through, no change needed" is **incorrect** -- the init parameter signature and stored property both need updating.

---

## 3. Could there be alternative/simpler fixes?

### Fix 1 (CM Blank Display)

**Simpler alternative:** Instead of using `EditorView.findFromDOM(wrapper)` -- which depends on DOM hierarchy -- you could pass the `EditorView` reference directly to the widget. However, CM6 widgets do not receive the view in `toDOM()`, so `findFromDOM` is the standard approach. The plan's approach is the idiomatically correct CM6 pattern.

**Even simpler:** Just remove `estimatedHeight` and do nothing else. If the blank display is caused by the height mismatch, simply removing the estimated height would let CM6 measure naturally from the start (0 height before load, actual height after load). The `requestMeasure()` call is needed because CM6 may have already measured the widget at 0 height and won't re-measure unless told to. So the `requestMeasure()` is necessary -- the plan's approach is correct.

### Fix 2 (Mass Deletes)

**Simpler alternative that avoids the signature change entirely:**

The `.blockSyncDidPushContent` notification already exists and already syncs `lastPushedContent`. The actual bug (if it exists) might be that the notification handler on the coordinator fires but `updateNSView` is called before the handler processes. If that is the case, a simpler fix would be to just remove the `if editorState.contentState == .editorTransition` guard on line 340 and always set `editorState.content = result.markdown` after `setContentWithBlockIds`. This would ensure `editorState.content` always matches what was pushed, regardless of content state.

However, this may trigger an `onChange(of: editorState.content)` call. The plan's note that `contentState == .editorTransition` suppresses that `onChange` handler is important. So removing the guard would require verifying that the onChange handler at line ~289 of `ViewNotificationModifiers.swift` also guards correctly.

**The plan's approach (exposing coordinator) is more explicit and self-contained.** It does not rely on notification timing or onChange guards. It is the better approach.

---

## 4. Are there any unintended side effects of the proposed changes?

### Fix 1

- **Removing `estimatedHeight`:** No side effects. CM6 will measure the widget at 0 height initially, then re-measure after `requestMeasure()`. This may cause a brief layout shift when the image loads, but that is expected and preferable to a blank editor.

- **`requestMeasure()` in `onload`/`onerror`:** Safe. `requestMeasure()` is designed to be called from event handlers. It batches with other pending measurements. No performance concern.

- **`EditorView.findFromDOM(wrapper)` returning null:** The plan guards against this with `if (view)`. If null, the re-measure simply does not happen. The image will still display; CM6 just might not re-layout perfectly. This is a graceful degradation.

### Fix 2

- **Changing `onWebViewReady` signature:** This is a breaking change to the `MilkdownEditor` API. Any code that constructs a `MilkdownEditor` and passes `onWebViewReady` must update its closure signature. I verified there is only one callsite at line 323 of `ContentView+ContentRebuilding.swift`, which the plan does update. **No unintended breakage.**

- **Setting `coordinator.lastPushedContent` and `coordinator.lastPushTime` inside the `onWebViewReady` Task:** This runs after `setContentWithBlockIds` completes (because of `await`). At that point, `isResettingContent` is still `true` (set at line 330, cleared at line 344). So `updateNSView` will early-return at the `guard !isResettingContent` check (line 160 of `MilkdownEditor.swift`). After `isResettingContent = false` is set at line 344, `updateNSView` will run and `shouldPushContent` will see the correct `lastPushedContent`. **Safe -- no race condition.**

- **`lastPushTime = Date()` setting:** This is also set by the notification handler. Setting it twice is harmless -- it just extends the grace period slightly.

---

## 5. Is the CM blank display fix sufficient, or could the root cause be something else?

This is the area of lowest confidence in the plan.

### Potential alternative root causes NOT addressed:

**A. CM `initialize()` error:**
The CodeMirror `batchInitialize()` in `CodeMirrorCoordinator+Handlers.swift` (line 220-267) uses template literal escaping for content:
```swift
let escapedContent = content.escapedForJSTemplateLiteral
let script = """
window.FinalFinal.initialize({
    content: `\(escapedContent)`,
    ...
})
"""
```
If `escapedForJSTemplateLiteral` does not properly escape all characters in image markdown (especially `![alt](media/...)` patterns), the JS could fail silently or produce corrupted content. The plan does not investigate this path.

**B. projectmedia:// scheme not registered on the CM WebView:**
Looking at `CodeMirrorEditor.swift` lines 76-77:
```swift
configuration.setURLSchemeHandler(EditorSchemeHandler(), forURLScheme: "editor")
configuration.setURLSchemeHandler(MediaSchemeHandler.shared, forURLScheme: "projectmedia")
```
The scheme IS registered. But for preloaded views (line 42-66), the preloader must also register `projectmedia://`. This is worth verifying but falls outside the current plan scope.

**C. The blank display happens even without images:**
If the blank display only occurs with images, the plan's analysis is likely correct. If it also occurs without images, the root cause is elsewhere. The plan states "Only happens when image markdown `![alt](media/...)` is in the content" which, if verified by testing, supports the plan's root cause.

**D. Image loading never completes:**
If `projectmedia://` returns an error or never responds, `img.onerror` fires (which the plan updates to call `requestMeasure()`). But if neither `onload` nor `onerror` fires (e.g., the request hangs), the widget stays at 0 height with no re-measure. The plan does not handle this case. A timeout-based fallback could be added, but this is a minor edge case.

### Verdict on sufficiency:

The fix is **likely sufficient** if the blank display is indeed caused by viewport miscalculation from `estimatedHeight`. The fix correctly removes the static estimate and adds re-measure triggers. However, if the blank display persists after this fix, the investigation should turn to the JS initialization path and the `projectmedia://` scheme handler timing.

---

## 6. Does the plan handle ALL callsites that reference `onWebViewReady`?

**YES**, with one correction needed.

All `onWebViewReady` references in the codebase:

| Location | Type | Plan addresses? |
|----------|------|----------------|
| `MilkdownEditor.swift:42` | Struct property declaration | YES -- change signature |
| `MilkdownEditor.swift:194` | Passed to `makeCoordinator()` | Implicit (type flows through) |
| `MilkdownEditor.swift:242` | Coordinator stored property | **NEEDS explicit mention** |
| `MilkdownEditor.swift:294` | Coordinator init parameter | **NEEDS explicit mention** |
| `MilkdownEditor.swift:306` | Assignment in init body | Implicit (type flows through) |
| `MilkdownCoordinator+MessageHandlers.swift:39` | Invocation in `didFinish` | YES -- pass `self` |
| `MilkdownCoordinator+MessageHandlers.swift:63` | Invocation in `handlePreloadedView` | YES -- pass `self` |
| `ContentView+ContentRebuilding.swift:323` | MW closure definition | YES -- update signature |
| `ContentView+ContentRebuilding.swift:378` | CM closure definition | NO change needed (different type) |
| `CodeMirrorEditor.swift:38` | CM struct property | NO change needed (different type) |
| `CodeMirrorEditor.swift:255` | CM coordinator property | NO change needed |
| `CodeMirrorEditor.swift:266` | CM coordinator init param | NO change needed |
| `CodeMirrorEditor.swift:276` | CM coordinator init body | NO change needed |
| `CodeMirrorCoordinator+Handlers.swift:208` | CM invocation in `didFinish` | NO change needed |
| `CodeMirrorCoordinator+Handlers.swift:216` | CM invocation in `handlePreloadedView` | NO change needed |

The plan correctly limits changes to Milkdown-only callsites. CodeMirror has its own independent `onWebViewReady` type that is unrelated.

---

## Issues Summary

### Critical (must fix before implementation)

1. **Plan incorrectly states "no change needed" for `makeCoordinator()` / Coordinator init.**
   The Coordinator's stored property at line 242 and the init parameter at line 294 of `/Users/niyaro/Documents/Code/ff-dev/images/final final/Editors/MilkdownEditor.swift` are both explicitly typed as `((WKWebView) -> Void)?`. These MUST be changed to `((WKWebView, Coordinator) -> Void)?` for the code to compile. The plan should list these as explicit changes.

### Important (should fix)

2. **Fix 2 may be solving an already-solved problem.** The `.blockSyncDidPushContent` notification (posted by `BlockSyncService.setContentWithBlockIds` at line 165-168 of `BlockSyncService.swift`) already updates `lastPushedContent` on the coordinator (MilkdownEditor.swift lines 466-474). This runs on `.main` queue and is `await`ed inside the `onWebViewReady` Task before `isResettingContent = false`. If the notification path is working correctly, the `shouldPushContent` check would already return `false`. The plan should verify whether the mass deletes are still occurring with the current code (after the existing Fix 5 was applied). If they are, the timing analysis needs refinement. If they are not, Fix 2 may be unnecessary.

### Suggestions (nice to have)

3. **Add a diagnostic guard in Fix 1.** Before deploying, add a console.log to the `onload`/`onerror` handlers to verify they actually fire. This would help diagnose whether the blank display is truly caused by the image loading issue:
   ```typescript
   img.onload = () => {
     console.log('[CM-ImagePreview] Image loaded:', this.src);
     const view = EditorView.findFromDOM(wrapper);
     if (view) view.requestMeasure();
   };
   ```

4. **Consider removing the `if editorState.contentState == .editorTransition` guard on line 340.** The existing code only syncs `editorState.content` during editor transitions. On initial project load (when `contentState == .idle`), the same desync can theoretically occur. The plan's approach (exposing coordinator) makes this guard less critical, but it is worth noting that the existing Fix 5 guard has a scope limitation.

5. **The plan should mention that `image-preview-plugin.ts` is already imported and registered in `main.ts` (line 71, line 243).** This confirms no additional wiring is needed for Fix 1.
