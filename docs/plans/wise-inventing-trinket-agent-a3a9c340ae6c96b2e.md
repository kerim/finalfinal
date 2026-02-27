# Review: Spell Check Underline Fix Plan

## Verdict

The plan's core approach (position mapping via `DecorationSet.map()`) is **correct and is the standard solution** for this class of problem in both ProseMirror and CodeMirror. However, there are several interactions and edge cases that the plan does not address, some of which could cause the fix to be incomplete or introduce new bugs.

---

## 1. Root Cause Diagnosis

**Assessment: Correct, but incomplete.**

The plan correctly identifies that stored absolute positions become stale when the document changes. This is indeed the primary cause of "traveling" underlines during typing.

However, there is a **second contributing factor** the plan does not mention: the current `props.decorations(state)` implementation rebuilds the `DecorationSet` from scratch on every state change (every keystroke), using the stale module-level `spellcheckResults` array. This means even non-doc-changing transactions (cursor moves, selection changes) cause a full rebuild from stale data. The plan's approach of moving to plugin `state` with `apply()` fixes this implicitly, since `apply()` only runs `map()` when `tr.docChanged` and otherwise returns the existing set unchanged. This is a significant but unstated benefit of the plan.

**No alternative cause identified.** The `setContent()` full-document-replacement path and other plugins do not appear to cause the traveling underline behavior during normal typing. The DOM is not rebuilt by other plugins during keystroke input.

---

## 2. Position Mapping vs. Clearing During Typing

**Assessment: Mapping is the better approach, but has one edge case the plan should acknowledge.**

The plan's `DecorationSet.map()` approach is strictly better than "clear and restore" because:

- It provides **continuous visual feedback** -- underlines stay on the correct words during typing, rather than disappearing and reappearing.
- It is the **standard, battle-tested pattern** used by ProseMirror and CodeMirror for exactly this purpose.
- It correctly handles insertions before, after, and between underlined ranges.

**Edge case: typing INSIDE a misspelled word.** When the user types inside "teh" (e.g., cursor between "t" and "e"), the mapping biases (`from: +1`, `to: -1`) will cause the decoration to **shrink** rather than grow to cover the new character. This is actually the correct behavior -- the word is changing, so the old underline should not expand to cover new text. The debounced recheck (400ms) will then produce fresh results for the modified word.

However, the plan's `mapResults()` helper filters out collapsed ranges (`r.from < r.to`), which means if the user deletes the entire misspelled word character-by-character, the decoration and the result entry will both be removed before the debounced recheck fires. This is correct and desirable.

**One concern with the mapping approach:** The `mapResults()` function maps the module-level `spellcheckResults` array to keep it in sync for click/context-menu handlers. But there is a subtle issue: if the user types rapidly and each keystroke maps the results, small floating-point-like drift could accumulate over many mappings. In practice, ProseMirror's integer position mapping is exact, so this is not actually a problem -- but it is worth noting that the 400ms debounced recheck acts as a periodic "ground truth" refresh that would correct any hypothetical drift.

---

## 3. Interaction with Other Plugins

### 3a. block-id-plugin.ts

**No interference.** The block ID plugin (`/Users/niyaro/Documents/Code/ff-dev/typing-delay/web/milkdown/src/block-id-plugin.ts`) uses `Decoration.node()` decorations (lines 285-289), not `Decoration.inline()`. These are a different decoration type and are managed in a separate plugin with its own `PluginKey`. They do not interact with the spellcheck plugin's inline decorations.

The block ID plugin's `apply()` handler (line 252) does run `assignBlockIds()` on every `docChanged` transaction, but this only modifies the block ID `Map` and does not affect the document or the spellcheck decoration set.

### 3b. focus-mode-plugin.ts

**No interference.** The focus mode plugin (`/Users/niyaro/Documents/Code/ff-dev/typing-delay/web/milkdown/src/focus-mode-plugin.ts`) also uses `Decoration.node()` decorations (line 41) and is stateless (`props.decorations()` rebuilds every time). It does not modify the document or interfere with inline decorations.

### 3c. main.ts -- dispatch override

**Potential timing concern.** In `main.ts` (lines 197-209), the original `view.dispatch` is wrapped with a content-push mechanism:

```typescript
view.dispatch = (tr) => {
  originalDispatch(tr);
  if (tr.docChanged && !getIsSettingContent()) {
    // 50ms debounce, then pushes content to Swift
  }
};
```

The spellcheck plugin's proposed `setSpellcheckResults()` dispatches a transaction with `setMeta(spellcheckPluginKey, results)`. This transaction does NOT change the document (`docChanged` is false), so it will not trigger the content push. This is correct behavior.

However, the `debouncedCheck()` call (triggered by the plugin's `view.update()` on doc changes) will fire 400ms after typing stops and send segments to Swift. Swift will then call `setSpellcheckResults()` which dispatches a meta transaction. This meta transaction triggers another pass through `apply()`, which sees `newResults` and rebuilds the decoration set. This is all correct.

---

## 4. Swift-Side Timing

### 4a. Spellcheck message handler

**Assessment: No timing issue in normal flow, but one race condition exists.**

Looking at `/Users/niyaro/Documents/Code/ff-dev/typing-delay/final final/Editors/MilkdownCoordinator+MessageHandlers.swift` (lines 284-329):

The spellcheck flow is:
1. JS sends `spellcheck` message with `action: "check"`, segments, and `requestId`
2. Swift cancels any previous `spellcheckTask` and starts a new one
3. Swift calls `SpellCheckService.shared.check(segments:)` asynchronously
4. On completion, Swift calls `window.FinalFinal.setSpellcheckResults(requestId, results)`
5. JS discards results if `requestId !== currentRequestId`

**Race condition:** Between step 1 and step 4, the user may have typed more characters. The `requestId` guard in step 5 correctly discards stale results in most cases. However, there is a subtle window: if the user types, triggering `debouncedCheck()` which increments `currentRequestId`, but then the previous check result arrives *before* the new debounce fires, the stale result is correctly discarded. The new debounce then fires, sends a fresh check, and results eventually arrive. During the gap, the mapped decorations from the plan's approach will be displayed, which is the correct behavior (old underlines at approximately correct positions rather than no underlines at all).

**The plan correctly states no Swift changes are needed.** The Swift side is already well-structured with request ID gating and task cancellation.

### 4b. contentChanged message handler

**No interference.** The `contentChanged` handler (line 198) only reads content from the editor and updates the Swift-side `contentBinding`. It does not push content back to the editor or trigger spellcheck. The spellcheck trigger comes from the plugin's own `view.update()` handler on `docChanged`.

---

## 5. setContent() Interaction -- CRITICAL ISSUE

**Assessment: The plan has a significant gap here.**

When Swift calls `setContent()` (via `window.FinalFinal.setContent(markdown)`), the entire document is replaced via `tr.replace(0, docSize, new Slice(doc.content, 0, 0))` (line 113 in `api-content.ts`).

With the plan's proposed plugin `state.apply()`:

```typescript
if (tr.docChanged) {
  spellcheckResults = mapResults(spellcheckResults, tr.mapping);
  return decorationSet.map(tr.mapping, tr.doc);
}
```

When `setContent()` replaces the entire document, `tr.mapping` maps the old full range to the new full range. The behavior of `DecorationSet.map()` through a full-document replacement depends on how ProseMirror handles the mapping:

- If the replacement is a single `replace(0, oldSize, newContent)` step, **all decorations whose ranges fall within the replaced region will be removed** (they collapse to zero-width and get filtered out). This means after `setContent()`, all spellcheck underlines will disappear.
- The `mapResults()` helper will similarly collapse all results (the entire `from..to` range is being replaced), so `spellcheckResults` will be emptied.

**Is this the correct behavior?** Partially. The underlines should indeed be cleared after a full document replacement, since positions are meaningless in the new document. But the plan does not address **what happens next**: no recheck is triggered after `setContent()`.

Looking at the current code, `setContent()` sets `isSettingContent = true` during the replacement (line 92 in `api-content.ts`). The dispatch wrapper in `main.ts` checks `!getIsSettingContent()` before pushing content (line 200). But the spellcheck plugin's `view.update()` handler does NOT check `isSettingContent` -- it fires `debouncedCheck()` whenever `view.state.doc !== prevState.doc` (line 381 in spellcheck-plugin.ts).

So actually, `debouncedCheck()` WILL be called after `setContent()` because the doc changes. After the 400ms debounce, a fresh spellcheck will run on the new document. **This means the gap is self-healing** -- underlines will reappear 400ms + spellcheck processing time after `setContent()`.

**Recommendation:** This is acceptable behavior. Add a comment in the plan noting that `setContent()` clears all decorations (via mapping through full replacement) and a fresh check is automatically triggered by the existing `debouncedCheck()` in the `view.update()` handler.

---

## 6. Additional Issues Found

### 6a. Milkdown: enabled flag check location

In the plan's proposed `state.apply()`, there is no check for the `enabled` flag. The `enabled` check only appears in `props.decorations()`:

```typescript
props: {
  decorations(state) {
    if (!enabled) return DecorationSet.empty;
    return spellcheckPluginKey.getState(state) ?? DecorationSet.empty;
  },
}
```

This is correct -- decorations are hidden when disabled, but the underlying state is preserved. However, there is an inefficiency: when `enabled` is false, the `apply()` handler still maps decorations through every doc change. This is minor but could be optimized by checking `enabled` in `apply()` as well:

```typescript
apply(tr, decorationSet) {
  const newResults = tr.getMeta(spellcheckPluginKey);
  if (newResults !== undefined) {
    spellcheckResults = newResults;
    return buildDecorationSet(newResults, tr.doc);
  }
  if (tr.docChanged && enabled) {
    spellcheckResults = mapResults(spellcheckResults, tr.mapping);
    return decorationSet.map(tr.mapping, tr.doc);
  }
  return decorationSet;
},
```

**Severity: Suggestion (nice to have).** The cost of mapping an empty set is negligible.

### 6b. CodeMirror: order of operations in update()

The plan's proposed CodeMirror `update()` method has a subtle ordering issue:

```typescript
update(update: ViewUpdate) {
  if (update.docChanged) {
    debouncedCheck();
    this.decorations = this.decorations.map(update.changes);
    spellcheckResults = mapResultPositions(spellcheckResults, update.changes);
  }
  if (resultsVersion !== this.lastResultsVersion) {
    this.decorations = buildDecorations(update.view);
    this.lastResultsVersion = resultsVersion;
  }
}
```

If `update.docChanged` is true AND `resultsVersion` has changed in the same update cycle (which can happen if `setSpellcheckResults` is called synchronously before the update runs -- unlikely but possible with microtask ordering), the decorations would be mapped and then immediately rebuilt. The rebuild would use the already-mapped `spellcheckResults`, which is correct, but the map step is wasted work. This is a minor efficiency concern.

**More importantly:** The `debouncedCheck()` call comes before the mapping. This is fine because `debouncedCheck()` only sets a timer -- it does not read `spellcheckResults`. The actual `triggerCheck()` runs 400ms later and extracts fresh segments from the document at that point.

**Severity: Suggestion (minor).**

### 6c. Click handlers use captured `result` object

Both the Milkdown and CodeMirror spellcheck plugins capture the `result` object in closure callbacks for `onReplace`, `onLearn`, `onIgnore`, etc. For example (line 241 in milkdown spellcheck):

```typescript
onReplace: (replacement: string) => {
  const tr = view.state.tr.replaceWith(result.from, result.to, view.state.schema.text(replacement));
  view.dispatch(tr);
},
```

After the plan's changes, `spellcheckResults` will be continuously mapped, but the `result` object captured in the closure is a **reference to the original object in the array** (before spreading in `mapResults()`). With the plan's `mapResults()`:

```typescript
function mapResults(results, mapping) {
  return results
    .map(r => ({ ...r, from: mapping.map(r.from, 1), to: mapping.map(r.to, -1) }))
    .filter(r => r.from < r.to);
}
```

Each call to `mapResults()` creates **new objects** via `{ ...r }`. This means the `result` captured in the click handler closure will have **stale** `from`/`to` values if the user types between clicking an underline and selecting a suggestion from the menu.

**Severity: Important (should fix).** If the user:
1. Clicks a misspelled word (captures `result` with `from: 50, to: 55`)
2. Types a character at position 10 before choosing a suggestion
3. Selects "Replace" from the menu
4. The replacement uses `result.from = 50, result.to = 55`, but the actual word is now at `51-56`

This would replace the wrong text. The fix is to re-lookup the result at the time of replacement, or to use the mapped positions. One approach: store the `word` and look it up from the current `spellcheckResults` at replacement time:

```typescript
onReplace: (replacement: string) => {
  // Re-find the result with current positions
  const current = spellcheckResults.find(r => r.word === result.word);
  if (!current) return;
  const tr = view.state.tr.replaceWith(current.from, current.to, ...);
  view.dispatch(tr);
},
```

**However**, this bug exists in the current code too (before the plan's changes), since `spellcheckResults` positions are already stale during typing. The plan does not make this worse -- in fact, the mapped positions in `spellcheckResults` would be more accurate than the current unmapped ones. But since the plan is touching this code, it would be a good opportunity to fix it.

### 6d. Plan does not mention the `resetForProjectSwitch()` path

When switching projects, `resetForProjectSwitch()` in `api-content.ts` (line 208) replaces the document with an empty paragraph via `view.dispatch(tr)`. With the plan's changes, this transaction would pass through `apply()` and map the decorations. The mapping would likely clear all decorations (since the entire doc is replaced). The `spellcheckResults` array would be emptied via `mapResults()`.

This is correct behavior -- spellcheck state should be cleared on project switch. But `disableSpellcheck()` or explicit state clearing is not called. With the current code, `spellcheckResults = []` is never explicitly cleared on project switch either, so the plan does not make this worse.

**Severity: Suggestion.** Consider adding `spellcheckResults = []` to `resetForProjectSwitch()` for explicitness, or dispatching `setMeta(spellcheckPluginKey, [])`.

---

## 7. Summary

| Category | Issue | Severity |
|----------|-------|----------|
| Root cause | Diagnosis is correct | No issue |
| Approach | `DecorationSet.map()` is the right pattern | No issue |
| `setContent()` | Decorations cleared by full-doc replace; recheck self-heals via `debouncedCheck()` | Add comment in plan |
| Click handlers | Captured `result.from`/`to` become stale after mapping creates new objects | Important |
| Enabled flag | `apply()` maps even when disabled | Suggestion |
| CodeMirror update order | Potential wasted map when version also changes | Suggestion |
| Project switch | `spellcheckResults` not explicitly cleared | Suggestion |
| Plugin interactions | block-id, focus-mode, dispatch wrapper -- no interference found | No issue |
| Swift timing | Request ID gating is sufficient; no Swift changes needed | No issue |

The plan is architecturally sound and uses the correct standard patterns. The most significant issue is the stale closure captures in click handlers (issue 6c), which is a pre-existing bug that the plan should address while it is modifying these code paths.
