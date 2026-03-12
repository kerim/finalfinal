# Ghost Sidebar Sections from Image Drag-and-Drop

Branch: `image-section-fix`. Reported as spurious `#####`-level sections titled `!Screenshot 202...`.

---

## Problem

When images are dragged and dropped into the Milkdown editor, they appear as spurious sections in the outline sidebar with `#####` level and titles like `!Screenshot 202...`.

## Root Cause

A race condition between WebKit's native `performDragOperation` and ProseMirror's JS event handlers:

1. User drops an image file onto the editor
2. WebKit's native `performDragOperation` fires BEFORE JS events, inserting a native `<img src="blob:...">` into the DOM
3. ProseMirror's mutation observer picks this up and incorporates a CommonMark inline `image` node into its state — potentially inside a heading node at the cursor position
4. The JS `handleDrop` fires, sends image data to Swift for import
5. Swift calls `insertImage()` which removed blob/data `<img>` elements from the **DOM** (line 653 of `api-content.ts`) — but **not** from ProseMirror's internal state
6. A proper `figure` node is also inserted
7. The document now contains both: a ghost inline `image` node inside a heading + the correct `figure` node
8. When serialized to markdown, the heading becomes `##### ![Screenshot...](blob:...)` which the Swift parser reads as a level-5 heading

## Fix (two-pronged)

### 1. ProseMirror state cleanup (root cause)

`api-content.ts` `insertImage()` now uses a single ProseMirror transaction that:
- Scans `view.state.doc` for inline `image` nodes with `blob:` or `data:` src attributes
- Deletes them in reverse order (to preserve positions)
- Computes insert position against `tr.doc` (the modified document)
- Inserts the `figure` node
- Dispatches once (single undo step, single re-render)

DOM cleanup (`querySelectorAll`) is kept as belt-and-suspenders.

### 2. Swift parser defense-in-depth (safety net)

Three Swift parsers now reject headings whose title is purely image markdown with `blob:` or `data:` URLs:

- `SectionSyncService+Parsing.swift` `parseHeaderLine()`
- `OutlineParser.swift` `parseHeaderLine()`
- `Database+Blocks.swift` block type detection

The check is targeted: `title.hasPrefix("![") && (title.contains("](blob:") || title.contains("](data:"))`. This avoids suppressing legitimate headings like `## ![icon](media/logo.png) Introduction` — only `blob:` and `data:` URLs are filtered, which are never valid persisted image sources (legitimate images use the `projectmedia://` scheme).

## Files Modified

- `web/milkdown/src/api-content.ts` — ProseMirror transaction removes ghost images + inserts figure
- `final final/Services/SectionSyncService+Parsing.swift` — ghost image header guard
- `final final/Services/OutlineParser.swift` — ghost image header guard
- `final final/Models/Database+Blocks.swift` — ghost image block type guard

## Lesson

DOM-only cleanup is insufficient when ProseMirror has already incorporated a mutation into its state. Always modify ProseMirror state through transactions, not through direct DOM manipulation. The `image` node type from Milkdown's CommonMark plugin is distinct from the custom `figure` node — WebKit's native drop inserts the former, while the app's image handling inserts the latter.

## Related

- `image-block-duplication.md` — Different image bug (debounce race causing duplicate blocks on load)
