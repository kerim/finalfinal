# Footnote Architecture

Inline footnote references (`[^1]`, `[^2]`) with auto-managed `# Notes` section containing definitions (`[^1]: text`).

---

## Overview

Footnotes span four layers: a **Milkdown plugin** (WYSIWYG), a **CodeMirror plugin** (source mode), a **Swift sync service** for managing the `# Notes` section in the database, and a **notification bridge** connecting them. Both editors support insertion, renumbering, and click navigation; Milkdown uses ProseMirror atoms while CodeMirror uses regex-based decorations.

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

## JS Layer: CodeMirror (footnote-decoration-plugin.ts + api.ts)

CodeMirror handles footnotes as plain text with decoration overlays, unlike Milkdown's ProseMirror atom approach.

### Decoration Plugin

`footnote-decoration-plugin.ts` provides visual styling and click navigation:

- **References** (`[^N]`): Styled with `.cm-footnote-ref` class via `Decoration.mark()`
- **Definitions** (`[^N]:`): Styled with `.cm-footnote-def` class
- **Click handler**: Clicking a reference scrolls to its definition; clicking a definition prefix scrolls to the first reference

### Insertion (api.ts)

`insertFootnote()` and `insertFootnoteReplacingRange()` handle insertion with atomic renumbering:

1. Scan all existing `[^N]` references and `[^N]:` definitions in the document
2. Determine the new label based on cursor position among existing refs
3. Build a single CodeMirror `changes` array that simultaneously inserts the new ref and renumbers all subsequent refs/defs
4. Dispatch as one atomic transaction (single undo step)
5. Notify Swift via `webkit.messageHandlers.footnoteInserted.postMessage()`

### Zoom Mode

In zoom mode, `insertFootnote()` uses `getDocumentFootnoteCount()` (set by Swift via `.setZoomFootnoteState`) to assign the next document-wide label, avoiding conflicts with footnotes in non-zoomed sections.

### Hidden Markers

The `anchor-plugin.ts` hides three marker types in CodeMirror:
- `<!-- @sid:UUID -->` — section anchors
- `<!-- ::auto-bibliography:: -->` — bibliography marker
- `<!-- ::zoom-notes:: -->` — zoom-notes separator

All three use `Decoration.replace()` for visual hiding, `atomicRanges` for cursor skipping, and clipboard handlers for stripping on copy/cut.

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
| `.renumberFootnotes` | FootnoteSyncService | MilkdownCoordinator / CodeMirrorCoordinator | Pass `mapping` dict to JS `renumberFootnotes()` |
| `.notesSectionChanged` | FootnoteSyncService | ContentView | Rebuild editor content from DB blocks |
| `.footnoteDefinitionsReady` | FootnoteSyncService | MilkdownCoordinator | Pass `definitions` dict to JS `setFootnoteDefinitions()` |
| `.footnoteInsertedImmediate` | MilkdownCoordinator / CodeMirrorCoordinator | ContentView | Trigger immediate Notes section creation for a new label |
| `.insertFootnote` | EditorCommands | MilkdownEditor / CodeMirrorEditor | Keyboard shortcut (Cmd+Shift+F) triggers insertion |
| `.setZoomFootnoteState` | EditorViewState | MilkdownCoordinator / CodeMirrorCoordinator | Push zoom mode + max label to JS editors |
| `.scrollToFootnoteDefinition` | ContentView | MilkdownCoordinator / CodeMirrorCoordinator | Scroll to `[^N]:` after insertion |

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

## Zoom-Notes Behavior

When a user zooms into a section that contains footnote references, the full `# Notes` section (which lives at document level) is not part of the zoomed range. To keep footnotes functional during zoom, Swift injects a **mini Notes section** with only the relevant definitions.

### Zoom In (EditorViewState+Zoom.swift)

1. Fetch blocks in the zoomed range (excluding `isNotes` and `isBibliography` blocks)
2. Extract footnote refs from the zoomed content
3. Look up definitions from the full-document Notes blocks
4. Append a mini Notes section separated by `<!-- ::zoom-notes:: -->`
5. Push `setZoomFootnoteState(zoomed: true, maxLabel: N)` so editors assign document-wide labels

### Zoom Out

1. Sync mini-Notes definitions back to DB via `syncMiniNotesBackPublic()`
2. Clear zoom footnote state (`zoomed: false`)
3. Rebuild full document from DB

### The zoom-notes Marker

`<!-- ::zoom-notes:: -->` separates user content from the injected mini Notes section. It is:

- **Milkdown**: Parsed by `zoom-notes-marker-plugin.ts` into an invisible `zoom_notes_marker` ProseMirror node (round-trips through serialization)
- **CodeMirror**: Hidden by `anchor-plugin.ts` via `Decoration.replace()` (same mechanism as section anchors)
- **Swift**: Stripped by `SectionSyncService.stripZoomNotes()` before content is saved to the block database

### Zoomed Footnote Insertion

When a footnote is inserted while zoomed (`handleZoomedFootnoteInsertion` in `ContentView+ContentRebuilding.swift`):

1. Flush editor content to DB
2. Sync existing mini-Notes definitions back to DB
3. Call `handleImmediateInsertion()` to create the new definition in DB
4. Recalculate zoom range (count-based boundary)
5. Rebuild mini Notes section from DB definitions
6. Push updated content + block IDs to editor

---

## Known Constraints

- **Numeric labels only**: The regex `\[\^(\d+)\]` limits labels to digits. Named footnotes (`[^note]`) are not supported.
- **Single Notes section**: Only one `# Notes` heading is managed. Multiple would cause conflicts.
- **3-second debounce**: Definition updates lag behind typing. This prevents churn during rapid editing but means tooltips aren't instant on first creation.
- **GFM interaction**: The remark plugin must undo GFM's footnote parsing (Pass 1 and Pass 2) because we manage definitions as plain text paragraphs, not as GFM footnoteDefinition nodes.
