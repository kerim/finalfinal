# Deferred: § Placeholder After Delete-All

## Problem

After Cmd+A + Delete, Milkdown shows a § symbol instead of a blank screen. Toggling to CodeMirror and back clears it because `setContent("")` in `api-content.ts` has explicit cleanup that replaces the document with a proper empty paragraph.

**Root cause:** The `section_break` node (registered via `sectionBreakPlugin` before `commonmark`) is chosen as ProseMirror's default block type when all content is deleted. ProseMirror picks the first matching node in the `block` group — since `sectionBreakPlugin` is `.use()`d before `.use(commonmark)`, `section_break` gets registered before `paragraph`. After Cmd+A + Delete, ProseMirror fills the empty document with a `section_break` instead of a `paragraph`, and the section break renders as § via its `toDOM`.

**Why toggle fixes it:** `setContent("")` (lines 46-77 of `api-content.ts`) has explicit code that checks if the document is a valid empty paragraph, and if not, replaces it with `paragraph.create()`.

## Proposed Approach: `appendTransaction` in section-break plugin

Add a ProseMirror `appendTransaction` handler that prevents `section_break` from being the sole content of the document. When the document has only a single `section_break` child, replace it with an empty paragraph. This runs synchronously after the delete transaction — no delay, no Swift round-trip.

**Alternative considered (not recommended):** Calling `setContent("")` from Swift's `pollContent()` when empty content is detected. This works but has ~500ms delay (poll interval) during which § is visible.

## Changes Required

### 1. Add cleanup `appendTransaction` to section-break plugin

**File:** `web/milkdown/src/section-break-plugin.ts`

Add new imports and a `$prose` plugin:

```typescript
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';
import { $prose } from '@milkdown/kit/utils'; // add to existing import

const sectionBreakCleanupPlugin = $prose(() => {
  return new Plugin({
    key: new PluginKey('section-break-cleanup'),
    appendTransaction: (_transactions, _oldState, newState) => {
      const doc = newState.doc;
      if (doc.childCount === 1 && doc.firstChild?.type.name === 'section_break') {
        const paragraph = newState.schema.nodes.paragraph.create();
        return newState.tr.replaceWith(0, doc.content.size, paragraph);
      }
      return null;
    },
  });
});
```

Update the export array:
```typescript
export const sectionBreakPlugin: MilkdownPlugin[] = [
  remarkPlugin,
  sectionBreakNode,
  sectionBreakCleanupPlugin,
].flat();
```

### 2. Rebuild web assets

Run `cd web && pnpm build` to bundle the updated plugin.

## Key files

- `web/milkdown/src/section-break-plugin.ts` — section break node definition + new cleanup plugin
- `web/milkdown/src/api-content.ts` — existing `setContent("")` cleanup (reference, no changes)

## Verification

1. Build: `cd web && pnpm build && cd .. && xcodebuild -scheme "final final" -destination 'platform=macOS' build`
2. Open a document with content (including section breaks if present)
3. Cmd+A + Delete → should show blank screen immediately (no §)
4. Type new content → works normally
5. Cmd+A + Delete → Cmd+/ to CodeMirror → empty
6. Cmd+/ back to Milkdown → blank screen (no §)
7. Close and reopen project → blank content persisted
