# Footnote Architecture

Inline footnote references (`[^1]`, `[^2]`) with auto-managed `# Notes` section containing definitions (`[^1]: text`).

---

## Overview

Footnotes span three layers: a **Milkdown plugin** (JS) for inline rendering and interaction, a **Swift sync service** for managing the `# Notes` section in the database, and a **notification bridge** connecting them.

```
User types [^1] in editor
        |
        v
+---------------------------+
| footnote-plugin.ts        |  Remark: parse [^N] → footnote_ref atom nodes
| (Milkdown plugin)         |  NodeView: superscript display + hover tooltip + click navigation
+---------------------------+
        |
        | getContent() polls (500ms)
        v
+---------------------------+
| SectionSyncService        |  Extracts footnote refs from content
| (Swift)                   |  Passes to FootnoteSyncService
+---------------------------+
        |
        v
+---------------------------+
| FootnoteSyncService       |  Manages # Notes section in DB
| (Swift)                   |  Renumbers refs, preserves definition text
+---------------------------+
        |                           |
        | .notesSectionChanged      | .footnoteDefinitionsReady
        | .renumberFootnotes        |
        v                           v
+---------------------------+  +--------------------------+
| ContentView rebuilds      |  | Editor tooltip display   |
| editor from DB blocks     |  | (setFootnoteDefinitions) |
+---------------------------+  +--------------------------+
```

---

## JS Layer: footnote-plugin.ts

### Remark Plugin (MDAST Transform)

Three passes over the markdown AST:

1. **Pass 1**: GFM `footnoteDefinition` nodes → plain paragraphs with `[^N]: text` as text content (keeps definitions editable)
2. **Pass 2**: GFM `footnoteReference` nodes → custom `footnote_ref` MDAST type
3. **Pass 3**: Text-node fallback — regex scans for `[^N]` patterns missed by GFM

### ProseMirror Node: `footnote_ref`

- **Inline atom** (`atom: true`, `selectable: false`)
- Attributes: `{ label: string }` (the number)
- `toMarkdown`: Serializes as `html` MDAST node to emit `[^N]` without bracket escaping (ProseMirror's text serializer would produce `\[^N\]`)

### NodeView

- **WYSIWYG mode**: Superscript number with hover tooltip showing definition text
- **Source mode**: Raw `[^N]` syntax display
- **Click handler**: Searches ProseMirror doc for paragraph starting with `[^N]:`, places cursor after the prefix for immediate typing
- **Tooltip**: Reads from module-level `footnoteDefinitions` map, populated by Swift via `setFootnoteDefinitions()`

### Click Plugin (back-navigation)

`footnoteClickPlugin` handles clicks on definition prefixes (`[^N]:` text in # Notes). Clicking the `[^N]` portion navigates back to the corresponding superscript ref in the body. Clicks after the prefix (on definition text) are ignored to allow normal editing.

### Exported Functions

| Function | Purpose |
|----------|---------|
| `insertFootnote()` | Insert next-numbered `[^N]` atom at cursor, returns label |
| `renumberFootnotes(mapping)` | Batch-update atom labels via `setNodeMarkup`, update definitions map |
| `setFootnoteDefinitions(defs)` | Update tooltip map, dispatch `footnote-definitions-updated` event |

---

## Swift Layer: FootnoteSyncService

### Lifecycle

- Created as `@State` in `ContentView`
- Configured with `ProjectDatabase` on project open
- Reset on project switch

### Trigger Flow

1. `SectionSyncService` extracts `footnoteRefs` from editor content (via `extractFootnoteRefs`)
2. Calls `checkAndUpdateFootnotes(footnoteRefs:projectId:fullContent:)`
3. If refs changed from `lastKnownRefs`, debounces 3 seconds then calls `performFootnoteUpdate`

### performFootnoteUpdate

1. **Renumber check**: If refs aren't sequential `1..N`, computes an old→new mapping
2. **Feedback loop prevention**: Hashes effective refs; skips if hash matches `lastRenumberedHash`
3. **Posts `.renumberFootnotes`** notification with mapping (editor updates atom labels)
4. **Calls `updateNotesBlock`**: Rebuilds `# Notes` section in DB
5. **Posts `.notesSectionChanged`**: Triggers `ContentView` to rebuild editor from DB blocks
6. **Pushes definitions**: Extracts definition text and posts `.footnoteDefinitionsReady` for tooltip display

### updateNotesBlock (DB Write)

Within a single `database.write` transaction:

1. **Read existing definitions** from DB blocks (paragraph blocks with `isNotes=true` matching `[^N]: text` pattern) — avoids ProseMirror serializer escaping issues
2. **Delete all `isNotes` blocks**
3. **Clean up orphaned definitions** (legacy blocks without `isNotes` flag)
4. **Insert heading block**: `# Notes` with `isNotes=true`
5. **Insert definition blocks**: One paragraph per ref (`[^N]: text`) with `isNotes=true`
6. **Normalize sort order**: Ensures content → notes → bibliography ordering

### Definition Text Preservation

The critical design decision: **definitions are read from the database, not from editor content.**

ProseMirror's remark serializer escapes `[` to `\[` in text paragraphs. When `getContent()` returns the Notes section, definitions appear as `\[^1]: text`. The Swift `extractFootnoteDefinitions` regex expects `[^1]:` and would miss the escaped form, returning empty definitions.

Two-pronged fix:
- **Primary (Swift)**: `updateNotesBlock` reads definition text from DB blocks (`markdownFragment` is unescaped because `BlockSyncService.serializeInlineContent` uses `child.text` directly)
- **Defense-in-depth (JS)**: `getContent()` unescapes `\[^N]:` → `[^N]:` at line starts, fixing both the polling content and tooltip parsing

---

## Notification Flow

| Notification | Sender | Receiver | Purpose |
|-------------|--------|----------|---------|
| `.renumberFootnotes` | FootnoteSyncService | MilkdownCoordinator | Pass `mapping` dict to JS `renumberFootnotes()` |
| `.notesSectionChanged` | FootnoteSyncService | ContentView | Rebuild editor content from DB blocks |
| `.footnoteDefinitionsReady` | FootnoteSyncService | MilkdownCoordinator | Pass `definitions` dict to JS `setFootnoteDefinitions()` |

---

## Database Representation

Footnote-related blocks in the `block` table:

| Block | blockType | isNotes | markdownFragment |
|-------|-----------|---------|------------------|
| Notes heading | `.heading` | `true` | `# Notes` |
| Definition 1 | `.paragraph` | `true` | `[^1]: definition text` |
| Definition 2 | `.paragraph` | `true` | `[^2]: definition text` |

The `isNotes` flag:
- Prevents notes blocks from appearing in the outline sidebar
- Allows bulk deletion when rebuilding the notes section
- Ensures sort order: user content → notes → bibliography

---

## Known Constraints

- **Numeric labels only**: The regex `\[\^(\d+)\]` limits labels to digits. Named footnotes (`[^note]`) are not supported.
- **Single Notes section**: Only one `# Notes` heading is managed. Multiple would cause conflicts.
- **3-second debounce**: Definition updates lag behind typing. This prevents churn during rapid editing but means tooltips aren't instant on first creation.
- **GFM interaction**: The remark plugin must undo GFM's footnote parsing (Pass 1 and Pass 2) because we manage definitions as plain text paragraphs, not as GFM footnoteDefinition nodes.
