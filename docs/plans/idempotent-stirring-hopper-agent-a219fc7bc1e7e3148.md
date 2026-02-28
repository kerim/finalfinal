# Code Review: Image Insertion Feature Plan

## Review Summary

The plan at `/Users/niyaro/Documents/Code/ff-dev/images/docs/plans/idempotent-stirring-hopper.md` is well-structured and demonstrates strong understanding of the existing codebase patterns. The database-first architecture is the right call. Below are findings organized by the six review areas requested.

---

## 1. Milkdown Plugin Feasibility

### The Approach Is Sound, But "Override" Needs Clarification

The plan says to "override the default commonmark image node" (line 180). In Milkdown's architecture, the commonmark preset registers an `image` node in ProseMirror's schema. When you define a new `$node('image', ...)` and load it **after** commonmark, Milkdown will use the last-registered definition for that node name.

**Evidence this works**: The codebase already does this implicitly. At `/Users/niyaro/Documents/Code/ff-dev/images/web/milkdown/src/block-id-plugin.ts` (line 23) and `/Users/niyaro/Documents/Code/ff-dev/images/web/milkdown/src/block-sync-plugin.ts` (line 25), `'image'` is already in the `BLOCK_TYPES` and `SYNC_BLOCK_TYPES` sets. The default commonmark image node is an **inline** node though, while these sets expect block-level nodes. This means the plan needs to register the image as a **block** node (like `section_break`), not keep it inline.

### Gotcha: Inline vs. Block Image

The commonmark image is inline (`group: 'inline'`). The plan's figure/caption rendering implies a **block-level** node. This is a significant schema change. Options:

- **Option A (Recommended)**: Define a new `$node('figure', ...)` with `group: 'block'` and keep the commonmark image node untouched. The remark plugin transforms `<!-- caption: ... -->` + `![](...)` pairs into `figure` mdast nodes. This avoids conflicts with the commonmark image entirely.

- **Option B**: Override `image` to be block-level. This breaks any existing inline image usage (e.g., images within paragraphs). It also conflicts with commonmark's serializer which expects `image` to be inline.

**Recommendation**: Option A is safer. The `section-break-plugin.ts` and `bibliography-plugin.ts` patterns at `/Users/niyaro/Documents/Code/ff-dev/images/web/milkdown/src/section-break-plugin.ts` show how to define independent block nodes with remark parsers that intercept content before commonmark processes it.

### Remark Plugin Parsing: `<!-- caption: -->` + `{width=N}`

The plan's remark plugin needs to combine an HTML comment and the following image into a single figure node. This is more complex than annotation-plugin.ts (which handles a single HTML comment). The remark plugin will need to:

1. Visit `html` nodes for `<!-- caption: ... -->`
2. Check if the next sibling is a `paragraph` containing an `image`
3. Merge them into a single `figure` node

**The `{width=Npx}` attribute syntax is NOT standard markdown.** Remark's default parser will not parse `{width=400px}` -- it will be treated as literal text after the image. You would need either:
- A remark plugin like `remark-directive` or `remark-attributes` (additional dependency)
- Custom regex parsing in the remark visitor to strip `{width=...}` from the raw text

This is a meaningful implementation detail the plan glosses over. I recommend handling width purely through the database columns and only emitting the `{width=}` syntax during **export**, not expecting to parse it on import from the editor.

### Plugin Load Order

Looking at `/Users/niyaro/Documents/Code/ff-dev/images/web/milkdown/src/main.ts` (lines 139-170), the comment at line 142-143 says: "sectionBreak/annotation must be before commonmark to intercept HTML comments before they get filtered out." The image plugin's remark component (parsing `<!-- caption: -->`) MUST similarly be registered before commonmark. The plan mentions this at line 282 ("Import and register image plugin") but does not specify the ordering constraint.

**Specific recommendation**: The image plugin should be loaded at approximately line 152 in main.ts, after `annotationPlugin` and before `commonmark`, in the same zone as other HTML-comment-intercepting plugins.

---

## 2. CodeMirror Decoration Feasibility

### Widget Decoration Pattern

The existing annotation decoration plugin at `/Users/niyaro/Documents/Code/ff-dev/images/web/codemirror/src/annotation-decoration-plugin.ts` uses **mark decorations** (Decoration.mark), not widget decorations. The image preview needs a **widget decoration** (`Decoration.widget`) placed below the image markdown line. This is a different pattern.

CodeMirror 6 widget decorations work well for this purpose. The key consideration:

- **Widget decorations insert DOM elements at a specific position** but do not replace text. Placing one "below" a line means inserting it at the end of the line with a `block: true` option or after the line break.
- The correct approach: `Decoration.widget({ widget: new ImagePreviewWidget(src), block: true, side: 1 })` placed at the end of the image line.

### Performance Concerns

The annotation-decoration-plugin at line 39-91 runs `buildDecorations()` on every `docChanged || viewportChanged`, doing a full-document regex scan with `view.state.doc.toString()`. For a few annotations this is fine, but for images:

- **Creating `<img>` elements on every viewport change** could cause visible flicker as images reload.
- **The full-document toString() approach** is acceptable for regex matching, but the widget should cache image elements and reuse them when the src hasn't changed.

**Recommendation**: The widget's `eq()` method should compare src URLs so CodeMirror reuses existing DOM rather than recreating it. Also consider using `WidgetType` with `toDOM()` that creates the `<img>` once and only updates `src` if changed.

### Atomic Blocks in CodeMirror

The plan says image blocks should be "atomic" in CodeMirror -- metadata editable only via popup, not direct text editing (line 217). CodeMirror does not have ProseMirror's `atom` concept. Making a text range read-only in CM6 requires either:

- A **state field + transaction filter** that rejects edits within image block ranges
- Or using `EditorView.editable` facet scoped to ranges (not directly supported)

This is non-trivial and the plan does not address the implementation details. The simplest approach: do NOT make image blocks read-only in source view. Instead, treat them as normal editable markdown text (like everything else in CodeMirror) and just add the visual preview below. If the user edits the markdown directly, the block sync system will pick up the change. This is consistent with how annotations work -- they are fully editable as raw HTML comments in source view.

---

## 3. Block Sync Flow

### How Swift-Created Blocks Reach the Editor

The plan says image blocks are "created from Swift (not the editor's block change stream)" (line 155-156). Looking at the block sync flow:

1. **Swift creates image block in DB** with `blockType: .image` and image columns
2. **Swift calls `applyBlocks()`** on the editor -- see `/Users/niyaro/Documents/Code/ff-dev/images/web/milkdown/src/api-content.ts` lines 249-297
3. `applyBlocks()` assembles markdown from `block.markdownFragment`, parses it, replaces the document, and sets block IDs

This is the correct flow. The `markdownFragment` for an image block would be the generated markdown (`<!-- caption: ... -->\n\n![alt](media/file.png){width=400px}`), and the remark plugin would parse it into a figure node.

### The `SYNC_BLOCK_TYPES` Set Already Includes `'image'`

At `/Users/niyaro/Documents/Code/ff-dev/images/web/milkdown/src/block-sync-plugin.ts` line 25, `'image'` is already in the set. This means the block sync plugin will track image nodes. **However**, this refers to the ProseMirror node type name. If the plan uses `'figure'` instead of `'image'` (per my recommendation in section 1), this set needs updating to `'figure'`. The same applies to `/Users/niyaro/Documents/Code/ff-dev/images/web/milkdown/src/block-id-plugin.ts` line 23.

### nodeToMarkdownFragment Needs a Case for Image/Figure

At `/Users/niyaro/Documents/Code/ff-dev/images/web/milkdown/src/block-sync-plugin.ts` lines 142-181, the `nodeToMarkdownFragment()` function has cases for paragraph, heading, blockquote, etc. but no case for `image` or `figure`. Without this, image blocks would fall through to the `default` case (line 179) which just returns `serializeInlineContent(node)` -- incorrect for a figure block. A new case is needed.

### Paste/Drop Flow Creates a Race Condition Risk

The plan's paste flow (line 155): JS intercepts paste -> sends base64 to Swift -> Swift saves image -> Swift creates block -> block sync pushes back to editor. This round-trip means there's a delay between the user pasting and seeing the image. During that delay:

- The cursor position may have moved
- The user may have typed more text
- The editor's block structure may have changed

The plan should specify a **placeholder** mechanism: immediately insert a "loading" placeholder node in the editor when paste is intercepted, then replace it with the real image when Swift responds. The annotation system doesn't have this problem because annotations are created entirely client-side.

---

## 4. URL Rewriting

### No Existing URL Rewriting Patterns

I found no existing URL rewriting in the codebase. The `EditorSchemeHandler` at `/Users/niyaro/Documents/Code/ff-dev/images/final final/Editors/EditorSchemeHandler.swift` serves bundled assets from `editor://` but doesn't do any path transformation.

### ProseMirror Schema and URL Rewriting

The plan says `media/file.png` in markdown gets rewritten to `projectmedia://file.png` in DOM rendering (line 188). This should happen in the **NodeView**, not in the schema's `toDOM`. Here's why:

- `toDOM` is used for ProseMirror's internal representation and clipboard serialization. If `toDOM` produces `projectmedia://` URLs, copying an image from the editor and pasting it elsewhere would produce broken URLs.
- The **NodeView** (like in annotation-plugin.ts at line 201) has full control over DOM rendering and can rewrite URLs for display without affecting the schema's canonical representation.

This is the correct place, and the plan's description at line 188-189 ("in NodeView") is right. Just ensure `toDOM` in the `$node` definition keeps `media/file.png` as-is.

### MediaSchemeHandler Registration Timing

The plan correctly identifies all the files where `projectmedia://` needs to be registered (lines 119-123). One detail: `WKWebViewConfiguration.setURLSchemeHandler` must be called **before** the web view loads its content. Looking at `EditorPreloader.swift` (line 51 and line 93), the scheme handlers are set during configuration, before `webView.load()`. The `projectmedia://` handler needs to go in the same place.

**Important**: The `MediaSchemeHandler` needs a mutable `mediaDirectoryURL` (as the plan states at line 115). But `WKURLSchemeHandler` methods are called on WKWebView's internal threads. The implementation needs to be thread-safe. The plan should specify using `@MainActor` or an `NSLock` to protect `mediaDirectoryURL`.

---

## 5. Architecture Quality

### Database-First Approach Aligns Well

The plan's core decision -- image metadata in DB columns, markdown generated for export -- is consistent with how the codebase handles blocks. Looking at `/Users/niyaro/Documents/Code/ff-dev/images/final final/Models/Block.swift`, blocks already have `textContent` and `markdownFragment` as separate concerns (lines 64-65). Adding `imageSrc`, `imageAlt`, `imageCaption`, `imageWidth` as additional columns follows this pattern naturally.

### Migration Numbering Is Correct

The latest migration is `v12_notes_section` at `/Users/niyaro/Documents/Code/ff-dev/images/final final/Models/ProjectDatabase.swift` line 309. The plan proposes `v13_image_blocks` (line 85), which is the correct next version.

### Block.swift Changes Are Well-Scoped

The `Block` struct at `/Users/niyaro/Documents/Code/ff-dev/images/final final/Models/Block.swift` already has `BlockType.image` (line 26). Adding optional properties for `imageSrc`, `imageAlt`, `imageCaption`, `imageWidth` requires updates to:
- The `init()` (line 87)
- `CodingKeys` (line 158)
- `Columns` enum (line 133)
- `init(from decoder:)` (line 181)
- `encode(to:)` (line 237)

This is straightforward but tedious. The plan could mention that these are all required updates.

### ProjectPackage.swift Is Minimal

At `/Users/niyaro/Documents/Code/ff-dev/images/final final/Models/ProjectPackage.swift`, the `create()` method (line 17) already creates a `references` subdirectory (line 32). Adding `media/` follows the same pattern. One note: the plan should handle **existing projects** that don't have a `media/` directory -- `ImageImportService` should create it lazily rather than expecting it to exist.

---

## 6. Missing Considerations

### Critical: Image Deletion

The plan has no mention of how images are **deleted**. When a user deletes an image block:
- The block is removed from the DB
- But the file in `media/` remains as an orphan
- Over time, `media/` accumulates unused files

**Recommendation**: Add a garbage collection mechanism. Either:
- Clean up on block delete (query DB for any blocks referencing the file, delete if none)
- Periodic cleanup on project save/close
- Never auto-delete (simplest, but wastes disk space)

### Critical: Undo/Redo

The plan does not address undo/redo for image insertion. When a user pastes an image:
1. JS sends base64 to Swift
2. Swift writes file to `media/`
3. Swift creates DB block
4. Block sync pushes to editor

If the user hits Cmd+Z:
- ProseMirror will undo the document change (removing the figure node)
- But the file in `media/` and the DB block still exist
- The block sync system will detect a delete and remove the DB block
- But the file in `media/` is now orphaned

This ties back to the deletion issue above, but undo makes it happen in normal workflow, not just edge cases.

### Important: Editor Mode Switch (Milkdown <-> CodeMirror)

When switching from WYSIWYG to source view, the content is serialized to markdown and re-parsed. The plan's figure node serializer (`toMarkdown`) needs to produce markdown that the CodeMirror side can parse and display. This should work if the markdown format is consistent (`<!-- caption: ... -->` + `![alt](media/file.png)`), but it needs testing.

More critically: the current editor toggle destroys and recreates WebViews (via EditorPreloader claims). The `projectmedia://` scheme handler needs its `mediaDirectoryURL` set on EVERY new WebView, not just the first one. The plan mentions this at line 123 ("Wire mediaDirectoryURL updates on project open/switch") but doesn't mention editor mode switches.

### Important: Large Image Handling in Base64 Paste Flow

The paste flow sends base64-encoded image data from JS to Swift via `postMessage` (line 155). For a 10MB image, the base64 string is ~13.3MB. `WKWebView.postMessage` serializes through WebKit's IPC, which has practical limits. Images over ~50MB as base64 could cause:
- Memory pressure in the web process
- IPC message size limits
- UI freeze during encoding

**Recommendation**: For paste, instead of base64, consider:
- Using the `clipboard` plugin to intercept at the Swift level (NSPasteboard) rather than JS
- Or chunked transfer if staying in JS

For drag-drop, the file URL approach (line 156) is better since it avoids base64 entirely.

### Important: Image Loading States

The plan does not address what happens when an image fails to load (file missing, corrupt, wrong format). The NodeView should handle:
- Loading state (spinner or placeholder)
- Error state (broken image icon with filename)
- Missing file state (file deleted outside the app)

### Suggestion: Source Mode in Milkdown

The codebase has a "source mode" within Milkdown (not CodeMirror) -- see `/Users/niyaro/Documents/Code/ff-dev/images/web/milkdown/src/source-mode-plugin.ts` referenced in `annotation-plugin.ts` line 13 and used at line 206. The annotation NodeView checks `isSourceModeEnabled()` and renders raw HTML comment text when in source mode (lines 271-276). The image NodeView needs the same treatment -- showing raw markdown instead of the rendered figure when Milkdown's source mode is active.

### Suggestion: `window.FinalFinal.insertImage` API Type Definition

The plan specifies adding `insertImage` to the `window.FinalFinal` API (line 168). The TypeScript type definitions at `/Users/niyaro/Documents/Code/ff-dev/images/web/milkdown/src/types.ts` (lines 61-172) need updating with this new method signature. The CodeMirror types at the equivalent file also need the same addition.

### Suggestion: Concurrent Project Image Isolation

The `MediaSchemeHandler` uses a single mutable `mediaDirectoryURL` (line 115). If the app ever supports multiple windows or documents simultaneously, this singleton pattern breaks -- one project's images would be served for another. Currently the app appears to be single-document, but this is worth noting as a future limitation.

---

## Summary of Recommended Plan Changes

| Priority | Issue | Recommendation |
|----------|-------|----------------|
| Critical | Inline vs block image node | Use `figure` node name, not override `image` |
| Critical | Image deletion / orphan files | Add cleanup mechanism |
| Critical | Paste placeholder | Show loading state during Swift round-trip |
| Important | `{width=Npx}` parsing | Handle width in DB only; emit on export, don't parse |
| Important | Plugin load order | Specify position before commonmark in main.ts |
| Important | `SYNC_BLOCK_TYPES` / `BLOCK_TYPES` | Update if using `figure` instead of `image` |
| Important | `nodeToMarkdownFragment` | Add figure/image case to block-sync-plugin.ts |
| Important | Editor mode switch | Wire mediaDirectoryURL on mode switch too |
| Important | CodeMirror "atomic" blocks | Drop read-only requirement; let markdown be editable |
| Important | Thread safety | MediaSchemeHandler.mediaDirectoryURL needs synchronization |
| Important | Undo/redo | Document behavior and handle orphaned files |
| Suggestion | Source mode rendering | Handle isSourceModeEnabled() in NodeView |
| Suggestion | TypeScript types | Update types.ts with insertImage signature |
| Suggestion | Image loading/error states | Specify fallback UI in NodeView |
| Suggestion | Base64 size limits | Consider native paste interception for large images |
