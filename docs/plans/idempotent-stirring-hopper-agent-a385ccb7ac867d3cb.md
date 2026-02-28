# TypeScript/Web Review of Image Insertion Plan

## Review of: `docs/plans/idempotent-stirring-hopper.md`

Reviewer examined the following source files against the plan:

- `web/milkdown/src/block-sync-plugin.ts`
- `web/milkdown/src/block-id-plugin.ts`
- `web/milkdown/src/section-break-plugin.ts`
- `web/milkdown/src/annotation-plugin.ts`
- `web/milkdown/src/source-mode-plugin.ts`
- `web/milkdown/src/main.ts`
- `web/milkdown/src/types.ts`
- `web/milkdown/src/api-content.ts`
- `web/milkdown/src/spellcheck-plugin.ts`
- `web/milkdown/package.json` and `web/pnpm-lock.yaml`
- `final final/Models/Block.swift`

---

## 1. SYNC_BLOCK_TYPES and BLOCK_TYPES: 'image' vs 'figure'

### Findings

**`block-sync-plugin.ts` (line 25)**: `SYNC_BLOCK_TYPES` currently contains `'image'`.

**`block-id-plugin.ts` (line 23)**: `BLOCK_TYPES` currently contains `'image'`.

**`spellcheck-plugin.ts` (line 116)**: `SKIP_NODE_TYPES` also contains `'image'`.

**Plan says (Section 6f, line 221-223)**:
> Add `'figure'` to `SYNC_BLOCK_TYPES` in `block-sync-plugin.ts:25`
> Add `'figure'` to `BLOCK_TYPES` in `block-id-plugin.ts:23`

### Issue (Important)

The plan says to **add** `'figure'` but does not say to **remove** `'image'`. This is a problem. The commonmark preset defines `image` as an **inline** node (group: `'inline'`), not a block node. In ProseMirror, inline images live inside paragraphs -- they will never appear as top-level children of `doc`. Since `snapshotBlocks()` at line 224 uses `doc.forEach()` (top-level only traversal), the inline `image` node will never be encountered at the top level, so `'image'` in `SYNC_BLOCK_TYPES` is currently dead code.

The plan introduces `$node('figure')` with `group: 'block'` -- this IS a top-level node and will appear in `doc.forEach()`.

**Recommendation**: The implementation should:
1. **Replace** `'image'` with `'figure'` in `SYNC_BLOCK_TYPES` (not add alongside)
2. **Replace** `'image'` with `'figure'` in `BLOCK_TYPES`
3. **Replace** `'image'` with `'figure'` in `SKIP_NODE_TYPES` in `spellcheck-plugin.ts`
4. Update the plan text to say "Replace" rather than "Add"

Additionally, the Swift `BlockType` enum (Block.swift line 26) has `case image` with raw value `"image"`. Since the plan's `nodeToMarkdownFragment()` will emit `blockType: 'figure'` for figure nodes, and the Swift `BlockType(rawValue:)` initializer would need to handle `"figure"` mapping to `.image`, this needs to be coordinated. Either:
- Add a `case figure` to the Swift enum, or
- Map `'figure'` to `'image'` in `nodeToMarkdownFragment()` / `snapshotBlocks()` / the `BlockInsert.blockType` field

The plan does not address this mapping. This is a **cross-boundary inconsistency** that will cause image blocks to fall through to the `?? .paragraph` default at `Database+Blocks.swift:450`.

---

## 2. nodeToMarkdownFragment() for figure nodes

### Findings

**`block-sync-plugin.ts` (lines 142-181)**: `nodeToMarkdownFragment()` has no case for `'figure'` (or `'image'`). Both fall into the `default` case at line 178, which calls `serializeInlineContent(node)`.

**Plan says (line 223)**: "Add figure case to `nodeToMarkdownFragment()` in `block-sync-plugin.ts:142-181`"

### Issue (Important)

The plan correctly identifies that a figure case is needed, but does not specify what it should produce. Since the figure node is `atom: true`, it has no inline content children -- `serializeInlineContent()` would return an empty string for an atom node (it iterates `node.forEach()` which yields nothing for atoms).

The figure case should reconstruct `![alt](media/file.png)` from the node's attributes:

```typescript
case 'figure':
  return `![${node.attrs.alt || ''}](${node.attrs.src || ''})`;
```

**Also note**: `serializeInlineContent()` (line 90) checks `node.isTextblock` first. An atom block node is NOT a textblock (`isTextblock` requires `isBlock && inlineContent`), so it would fall to the container branch at line 131 which also iterates children -- again empty for atoms. The `default` fallback in `nodeToMarkdownFragment` would produce an empty string. This confirms the explicit `'figure'` case is essential.

---

## 3. Atom node with editable caption and resize handles

### Findings

The plan says (line 189): `atom: true` for the figure node.

The `section-break-plugin.ts` pattern (line 26) originally had `atom: true` but was changed to `atom: false` with the comment "Changed from true to allow single-press deletion". It uses a simple `toDOM` with `contenteditable: 'false'`.

The `annotation-plugin.ts` (line 115) uses `atom: true` with `inline: true`. Its NodeView (line 201-331) manually creates DOM elements -- the editable text is NOT a ProseMirror content hole but rather a click-to-popup interaction (`showAnnotationEditPopup` at line 265).

### Issue (Critical -- design tension)

An `atom: true` node cannot have editable content holes in ProseMirror. This means:

**The `<figcaption>` CANNOT be a native ProseMirror editable region.** The plan says (line 198): "Editable `<figcaption>` -- on blur/enter, sends `updateImageMeta` to Swift". This is achievable, but it must work like the annotation popup pattern -- a regular HTML `<input>` or `contenteditable` div managed entirely by the NodeView's DOM, NOT by ProseMirror's content model.

This is fine and consistent with how annotations work. However, the plan should be explicit that:
- The figcaption is a **NodeView-managed DOM element**, not a ProseMirror content hole
- Typing in the figcaption does NOT create ProseMirror transactions
- The figcaption value is committed to Swift via `updateImageMeta` message on blur/enter
- ProseMirror's undo/redo will NOT cover caption edits (they go directly to DB)

**Resize handles** are also fine with atom nodes -- they're just DOM event handlers that call `updateImageMeta`. The plan's approach here is sound.

**One concern with `atom: true`**: The section break plugin switched to `atom: false` to allow single-press deletion. With `atom: true`, deleting a figure requires the node to be selected first (click to select, then press Delete/Backspace). This is actually appropriate for images -- you don't want accidental single-keypress deletion of images. But the plan should document this behavior explicitly.

---

## 4. Paste/drop interception and Milkdown's clipboard plugin

### Findings

**`main.ts` (line 160)**: The clipboard plugin is registered: `.use(clipboard)`.

The Milkdown clipboard plugin (`@milkdown/kit/plugin/clipboard`) handles:
1. Copying content from editor to clipboard as Markdown
2. Pasting Markdown content into the editor
3. VSCode code block paste handling

It does NOT handle image file paste/drop -- that's what `@milkdown/plugin-upload` is for.

**Lock file**: `@milkdown/plugin-upload@7.18.0` exists as a transitive dependency but is NOT directly used by the project (not in `package.json`, not imported anywhere).

### Issue (Important -- the plan's approach needs refinement)

The plan says (Section 6e, line 214-218):
> Intercept paste/drop containing image data
> Insert loading placeholder immediately
> Send base64 to Swift via `pasteImage` message
> Prevent default Milkdown handling

**How to intercept**: The plan does not specify the interception mechanism. There are two viable approaches:

**Option A: ProseMirror `handlePaste` / `handleDrop` props** (recommended)
Register a `$prose` plugin with `props.handlePaste` and `props.handleDrop`. These fire BEFORE the clipboard plugin processes the event. If you return `true`, the event is consumed and the clipboard plugin never sees it.

```typescript
const imageInterceptPlugin = $prose(() => {
  return new Plugin({
    props: {
      handlePaste(view, event) {
        const items = event.clipboardData?.items;
        if (!items) return false;
        for (const item of items) {
          if (item.type.startsWith('image/')) {
            // Insert placeholder, send to Swift
            return true; // Consume the event
          }
        }
        return false; // Let clipboard plugin handle text paste
      },
      handleDrop(view, event) {
        const files = event.dataTransfer?.files;
        if (!files) return false;
        for (const file of files) {
          if (file.type.startsWith('image/')) {
            // Insert placeholder, send to Swift
            return true;
          }
        }
        return false;
      },
    },
  });
});
```

**Option B: Use `@milkdown/plugin-upload`** -- Milkdown's built-in upload plugin already handles paste/drop interception and placeholder insertion. It could be configured with a custom uploader that sends data to Swift. However, this would need careful evaluation since it creates `schema.nodes.image` (commonmark inline image) nodes, not the custom `figure` node.

**Recommendation**: Option A is better for this project because:
- It gives full control over placeholder and figure node creation
- It avoids fighting with the upload plugin's assumptions about inline images
- The interception plugin MUST be registered BEFORE the clipboard plugin in `main.ts` (plugin order matters for `handlePaste` priority -- first registered, first called)

**The plan should specify**: The image intercept `$prose` plugin must be `.use()`'d BEFORE `.use(clipboard)` at line 160 of `main.ts`. Currently the plan says "Register before commonmark" (line 208) which is about the remark plugin, but the paste intercept is a separate ProseMirror plugin that needs its own ordering relative to the clipboard plugin.

---

## 5. TypeScript type definitions

### Findings

**`types.ts` (lines 61-172)**: The `window.FinalFinal` interface is comprehensive. The plan says (line 178): "Add `insertImage` to `window.FinalFinal` interface".

### Issue (Suggestion)

The plan specifies `insertImage({src, alt, caption, width, blockId})` (line 171). The type definition should be:

```typescript
insertImage: (params: {
  src: string;
  alt?: string;
  caption?: string;
  width?: number;
  blockId: string;
}) => void;
```

Additionally, the `Block` interface in `types.ts` (lines 26-33) may need image-related fields if `applyBlocks()` needs to handle image blocks. Currently it has:

```typescript
export interface Block {
  id: string;
  blockType: string;
  textContent: string;
  markdownFragment: string;
  headingLevel?: number;
  sortOrder: number;
}
```

For image blocks arriving via `applyBlocks()`, the figure node needs `src`, `alt`, `caption`, and `width` attributes. These could be:
- Passed as additional optional fields on the `Block` interface, or
- Extracted from `markdownFragment` (which would contain `![alt](media/file.png)`) by the remark parser

The second approach (remark parser extracts from markdownFragment) is more consistent with how other block types work -- the parser reconstructs the ProseMirror node from the markdown text. But the caption and width live in DB columns, not in markdown. So either:
- `applyBlocks()` needs to pass caption/width separately, or
- The figure node's initial creation via `applyBlocks()` only sets src/alt (from markdownFragment), and caption/width are set via a subsequent `insertImage()` call

The plan does not address how `applyBlocks()` handles image blocks on initial load. This is a gap.

---

## 6. Remark and `{width=Npx}` parsing

### Findings

The project uses `@milkdown/kit` v7.18.0, which bundles `@milkdown/preset-commonmark`. The commonmark preset depends on standard remark (remark-parse -> micromark -> mdast). The lock file shows the preset also depends on `remark-inline-links`.

The remark/micromark ecosystem does NOT parse `{width=Npx}` attribute syntax by default. That syntax requires `remark-attributes` or `remark-directive` plugins, neither of which are dependencies of this project.

### Conclusion (Plan is correct)

The plan's claim (line 207) is accurate:
> Does NOT parse `{width=Npx}` -- width comes from database only

Standard remark will treat `{width=400px}` as literal text following the image. This confirms the plan's decision to keep width in the database and only emit `{width=Npx}` at export time via `markdownForExport()` is sound.

However, there is a subtle implication: if someone imports a Pandoc-formatted markdown file containing `![alt](src){width=400px}`, the remark parser will create a paragraph with the image followed by literal text `{width=400px}`. The plan mentions parsing `<!-- caption: text -->` for imported content (line 206) but does not mention handling `{width=Npx}` on import. This is acceptable for v1 but worth noting.

---

## 7. Additional observations

### 7a. Plugin registration order in main.ts

The plan says (line 208): "Must be registered before `commonmark` in `main.ts` (around line 152)".

Looking at `main.ts` lines 147-170, the current order is:
```
blockIdPlugin -> blockSyncPlugin -> sectionBreakPlugin -> ... -> annotationPlugin -> citationPlugin -> footnotePlugin -> commonmark -> gfm -> ... -> clipboard
```

The figure remark plugin needs to be before `commonmark` to intercept `![alt](src)` markdown before commonmark's default image handler creates an inline `image` node. This is the same pattern used by citation and annotation plugins.

**But there is a conflict**: commonmark's `image` node is inline. If the remark plugin converts `![alt](src)` to a `figure` block node BEFORE commonmark processes it, commonmark's image handler won't see it -- good. But commonmark still registers the `image` node type in the schema. Having both `image` (inline, from commonmark) and `figure` (block, custom) in the schema is fine -- they coexist. The figure remark plugin just needs to match and transform image MDAST nodes before commonmark's `parseMarkdown` runner gets them.

### 7b. Source mode rendering

The plan says (line 201): "Check `isSourceModeEnabled()` and render raw markdown text (like annotation NodeView at `annotation-plugin.ts:206`)".

Looking at `annotation-plugin.ts` lines 271-276, source mode rendering replaces the NodeView DOM content with the raw markdown text. The same pattern applies to figure nodes -- in source mode, the NodeView should display `![alt](media/file.png)` as plain text.

This is consistent with `source-mode-plugin.ts` which handles block-level syntax decorations but does NOT handle atom node rendering (that's each NodeView's responsibility via `isSourceModeEnabled()` check).

### 7c. Missing: cursor-mapping.ts

`cursor-mapping.ts` (lines 136-139, 312-323) already handles inline `![alt](src)` image syntax for cursor position mapping between markdown and ProseMirror. If figures become block-level atoms instead of inline images, the cursor mapping logic may need updates -- an atom block node has nodeSize of 1 in ProseMirror but its markdown representation is longer. The plan does not mention `cursor-mapping.ts`.

### 7d. Missing: utils.ts

`utils.ts` (line 21) strips images from text: `.replace(/!\[([^\]]*)\]\([^)]+\)/g, '$1')`. This may need updating if figure nodes have different serialization behavior, though since `markdownFragment` still uses `![alt](src)` this is likely fine.

### 7e. Milkdown's built-in image-block component

The Context7 documentation reveals Milkdown v7 ships with `@milkdown/components/image-block` and `@milkdown/components/image-inline` components. These provide ready-made block image handling with caption, upload, and resize functionality. The plan creates a custom `$node('figure')` from scratch instead.

This is a valid choice given the project's specific requirements (DB-first metadata, `projectmedia://` scheme, Swift bridge), but it's worth being aware that the built-in component exists as a reference implementation or potential starting point.

---

## Summary of issues

| # | Severity | Issue | Location |
|---|----------|-------|----------|
| 1 | Important | Plan says "add" `'figure'` but should say "replace" `'image'` with `'figure'` in SYNC_BLOCK_TYPES, BLOCK_TYPES, and SKIP_NODE_TYPES | Plan line 221-223; block-sync-plugin.ts:25; block-id-plugin.ts:23; spellcheck-plugin.ts:116 |
| 2 | Important | BlockType enum raw value mismatch: Swift has `"image"`, JS will emit `"figure"` as blockType string. Needs mapping or new enum case | Block.swift:26 vs plan's figure node |
| 3 | Important | nodeToMarkdownFragment() needs explicit figure case producing `![alt](src)` from attrs -- atom nodes produce empty string via default path | block-sync-plugin.ts:142-181 |
| 4 | Important | Paste interception mechanism unspecified -- should use `$prose` plugin with `handlePaste`/`handleDrop` props, registered BEFORE clipboard plugin | main.ts:160 |
| 5 | Important | Plan does not address how `applyBlocks()` handles image blocks on initial document load -- caption/width from DB not present in markdownFragment | api-content.ts:249-297; types.ts:26-33 |
| 6 | Suggestion | Figcaption editability should be explicitly documented as NodeView-managed DOM (not ProseMirror content hole), with note that undo/redo won't cover caption edits | Plan section 6b |
| 7 | Suggestion | cursor-mapping.ts may need updates for block-level figure atoms (nodeSize 1 vs multi-char markdown) | cursor-mapping.ts:136-139, 312-323 |
| 8 | Suggestion | Consider Milkdown's built-in `@milkdown/components/image-block` as reference implementation | Not in current deps |
