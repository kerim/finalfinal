# Fix Traveling Spell Check Underlines During Typing

## Context

While typing, spell check underlines "travel" across the document — appearing on wrong words — and only settle on the correct words a few seconds after the user stops typing. This is visually distracting and makes the spell check feel broken.

**Root cause:** Both editors store spell check results as a module-level array with absolute document positions (`{from: 50, to: 55, ...}`). When the user types a character at position 10, all positions after 10 shift by +1, but the stored results still say `{from: 50, to: 55}` — which now points to the wrong text. The `decorations()` function reads these stale positions on every state change, rendering underlines on wrong words. Fresh results only arrive after the 400ms debounce.

**Fix:** Use each editor's native position mapping to keep decoration positions synchronized with document changes as they happen. This is the standard pattern in both ProseMirror (`DecorationSet.map(tr.mapping, tr.doc)`) and CodeMirror (`decorationSet.map(update.changes)`).

## Files to Modify

| File | Change |
|------|--------|
| `web/milkdown/src/spellcheck-plugin.ts` | Convert to plugin state with `DecorationSet.map()` |
| `web/codemirror/src/spellcheck-plugin.ts` | Add `DecorationSet.map()` + version counter |

No Swift-side changes needed.

## Implementation

### Part 1: Milkdown (ProseMirror)

**1a. Add `buildDecorationSet()` helper** (extracted from current `props.decorations()`):

```ts
import type { Node } from '@milkdown/kit/prose/model';

function buildDecorationSet(results: SpellcheckResult[], doc: Node): DecorationSet {
  if (results.length === 0) return DecorationSet.empty;
  const decorations: Decoration[] = [];
  for (const result of results) {
    if (result.from < 0 || result.to > doc.content.size || result.from >= result.to) continue;
    const className = result.type === 'grammar' ? 'grammar-error'
      : result.type === 'style' ? 'style-error' : 'spell-error';
    const attrs: Record<string, string> = { class: className };
    if (result.message) attrs.title = result.message;
    try { decorations.push(Decoration.inline(result.from, result.to, attrs)); } catch { /* skip */ }
  }
  return DecorationSet.create(doc, decorations);
}
```

**1b. Add `mapResults()` helper** to keep module-level array in sync for click handlers:

```ts
function mapResults(
  results: SpellcheckResult[],
  mapping: { map(pos: number, assoc?: number): number }
): SpellcheckResult[] {
  return results
    .map(r => ({ ...r, from: mapping.map(r.from, 1), to: mapping.map(r.to, -1) }))
    .filter(r => r.from < r.to);
}
```

Bias values: `from` uses +1 (don't extend left), `to` uses -1 (don't extend right). Collapsed ranges (deleted text) are filtered out.

**1c. Convert plugin from stateless `props.decorations()` to plugin `state`:**

Replace the current `props.decorations(state)` body with plugin `state`:

```ts
state: {
  init() { return DecorationSet.empty; },
  apply(tr, decorationSet) {
    const newResults = tr.getMeta(spellcheckPluginKey);
    if (newResults !== undefined) {
      spellcheckResults = newResults;
      return buildDecorationSet(newResults, tr.doc);
    }
    if (tr.docChanged) {
      spellcheckResults = mapResults(spellcheckResults, tr.mapping);
      return decorationSet.map(tr.mapping, tr.doc);
    }
    return decorationSet;
  },
},
props: {
  decorations(state) {
    if (!enabled) return DecorationSet.empty;
    return spellcheckPluginKey.getState(state) ?? DecorationSet.empty;
  },
  handleDOMEvents: { /* unchanged */ },
},
```

**1d. Change `setSpellcheckResults()` to dispatch via transaction meta:**

```ts
export function setSpellcheckResults(requestId: number, results: SpellcheckResult[]): void {
  if (requestId !== currentRequestId) return;
  spellcheckResults = results;
  const editor = getEditorInstance();
  if (editor) {
    const view = editor.ctx.get(editorViewCtx);
    view.dispatch(view.state.tr.setMeta(spellcheckPluginKey, results));
  }
}
```

**1e. Update `disableSpellcheck()` and empty-result path in `triggerCheck()`** to dispatch with `setMeta(spellcheckPluginKey, [])`. This is critical — without meta, `state.apply()` won't clear the `DecorationSet`, leaving stale decorations in plugin state that reappear when spellcheck is re-enabled.

**1f. Update all learn/ignore/disableRule handlers** (6 locations in `handleContextMenu` and `handleClick`) to dispatch with meta:
```ts
spellcheckResults = spellcheckResults.filter(r => r.word !== word);
view.dispatch(view.state.tr.setMeta(spellcheckPluginKey, spellcheckResults));
```

**1g. Fix stale closure captures in onReplace/onLearn/onIgnore callbacks:**

The `result` object captured in menu callbacks holds positions from when the menu was opened. If the user types between opening the menu and selecting a suggestion, the captured `result.from`/`result.to` are stale. Fix all 3 `onReplace` callbacks (in `handleContextMenu` and both paths in `handleClick`) to re-lookup from the current mapped array:

```ts
onReplace: (replacement: string) => {
  const current = spellcheckResults.find(r => r.word === result.word && r.type === result.type);
  if (!current) return;
  const tr = view.state.tr.replaceWith(current.from, current.to, view.state.schema.text(replacement));
  view.dispatch(tr);
},
```

Apply the same re-lookup pattern to `onLearn` and `onIgnore` callbacks that use `result.from`/`result.to` (currently they only use `result.word` for filtering, so they are already safe — but verify during implementation).

### Part 2: CodeMirror

**2a. Add module-level version counter** (near existing module state):
```ts
let resultsVersion = 0;
```

**2b. Add `mapResultPositions()` helper:**
```ts
import { type ChangeDesc, RangeSetBuilder } from '@codemirror/state';

function mapResultPositions(results: SpellcheckResult[], changes: ChangeDesc): SpellcheckResult[] {
  if (changes.empty) return results;
  return results
    .map(r => ({ ...r, from: changes.mapPos(r.from, 1), to: changes.mapPos(r.to, -1) }))
    .filter(r => r.from < r.to);
}
```

**2c. Rewrite the ViewPlugin class** to map decorations instead of always rebuilding:

```ts
class SpellcheckViewPlugin {
  decorations: DecorationSet;
  lastResultsVersion: number;

  constructor(view: EditorView) {
    this.decorations = buildDecorations(view);
    this.lastResultsVersion = resultsVersion;
  }

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
}
```

Order matters: `docChanged` mapping runs first, then `resultsVersion` check. If both happen in the same update (theoretically impossible in single-threaded JS for this codebase), the fresh results win by overwriting the mapped set.

**2d. Increment `resultsVersion`** in all 9 mutation+dispatch sites:
- `setSpellcheckResults()` (line 48)
- `disableSpellcheck()` (line 76)
- `triggerCheck()` empty-segment path (line 262)
- 6 event handler callbacks: `onLearn` x2, `onIgnore` x3, `onDisableRule` x1

**2e. Fix stale closure captures** — same pattern as Part 1 step 1g: re-lookup `result` from `spellcheckResults` in all `onReplace` callbacks (3 locations in event handlers).

## Known Limitations

**Narrow timing window for fresh results:** When Swift delivers spell check results via `setSpellcheckResults()`, those positions were computed against the document state at the time `triggerCheck()` fired. If the user typed between the check request and the result delivery, the positions are slightly stale. However: (1) this window is typically <100ms for NSSpellChecker, (2) the `requestId` gating discards truly stale results, and (3) the next debounced recheck produces correct results 400ms later.

**`setContent()` clears decorations:** When Swift replaces the entire document (e.g., on zoom, editor toggle), `DecorationSet.map()` through a full-range replacement removes all decorations. This is correct — the existing `debouncedCheck()` on `docChanged` re-checks 400ms later, restoring underlines.

## Verification

1. **Type rapidly near underlined words** (both Milkdown and CodeMirror) — underlines should stay on the correct words, not travel
2. **Delete an underlined word** — underline should disappear immediately
3. **Type at the boundary of an underlined word** — underline should not grow to cover new characters
4. **Right-click/click an underlined word** — spell menu should appear and replacements should work correctly
5. **Learn/ignore a word** — underline should disappear for that word
6. **Open spell menu, type elsewhere, then select replacement** — replacement should target the correct text (stale closure fix)
7. **Toggle spellcheck off then on** — underlines should clear and then reappear after recheck
8. **Switch editors (Cmd+/)** — underlines should reappear after recheck in new editor
9. **Build**: `cd web && pnpm build` — no TypeScript errors
