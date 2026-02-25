# Footnote Development Issues and Solutions

**Date**: 2026-02-22
**Branch**: `footnotes`
**Commits**: `dbb5b67` through `dbf35c4`

---

## Issue 1: ProseMirror Bracket Escaping

**Symptom**: Footnote definitions in the `# Notes` section lost their text on each rebuild cycle. Definitions appeared as `\[^1]: text` instead of `[^1]: text` when read back from the editor.

**Root cause**: ProseMirror's remark serializer escapes `[` to `\[` in text paragraphs. Since definitions are stored as plain paragraphs (not GFM footnoteDefinition nodes), the `[^N]:` prefix gets escaped on round-trip through `getContent()`.

**Solution (two-pronged)**:
- **Primary**: `updateNotesBlock()` reads definition text from DB blocks (whose `markdownFragment` is unescaped) rather than from editor content
- **Defense-in-depth**: `getContent()` in `api-content.ts` unescapes `\[^N]:` at line starts before returning

**Files**: `FootnoteSyncService.swift`, `web/milkdown/src/api-content.ts`

---

## Issue 2: GFM Footnote Parser Conflict

**Symptom**: Milkdown's GFM plugin parsed `[^1]` references and `[^1]: text` definitions into its own footnote AST nodes, which conflicted with our custom rendering and management.

**Root cause**: remark-gfm includes footnote support. It converts references to `footnoteReference` and definitions to `footnoteDefinition` MDAST nodes. Our design manages definitions as plain editable paragraphs, not GFM nodes.

**Solution**: The remark plugin in `footnote-plugin.ts` runs three passes to undo GFM's parsing:
1. Convert `footnoteDefinition` nodes back to plain paragraphs
2. Convert `footnoteReference` nodes to custom `footnote_ref` atoms
3. Text-node fallback regex for any refs GFM missed

**Files**: `web/milkdown/src/footnote-plugin.ts`

---

## Issue 3: Zoom Breaks Footnotes

**Symptom**: Zooming into a section that contained footnote references showed broken references because the `# Notes` section (at document level) was excluded from the zoomed content.

**Root cause**: Zoom filters blocks by sort-order range. Notes blocks have `isNotes=true` and are excluded from zoom ranges. Without definitions, references are orphaned.

**Solution**: Swift injects a mini `# Notes` section with only the relevant definitions, separated by a `<!-- ::zoom-notes:: -->` marker. On zoom-out, definitions are synced back to DB before rebuilding the full document.

**Files**: `EditorViewState+Zoom.swift`, `ContentView+ContentRebuilding.swift`, `zoom-notes-marker-plugin.ts`, `anchor-plugin.ts`

---

## Issue 4: Content Duplication on Zoom-Out

**Symptom**: Zooming out produced duplicated content — the zoomed section appeared twice in the restored document.

**Root cause**: The zoom-out path was not stripping the mini `# Notes` section before flushing content to the database. The `flushContentToDatabase()` method parsed the full editor content (including the mini Notes) as body blocks, creating duplicate Notes blocks alongside the real ones.

**Solution**: `flushContentToDatabase()` now calls `SectionSyncService.stripZoomNotes()` to remove the mini Notes marker and content before parsing blocks for DB storage. The `zoomOut()` method also syncs mini-Notes definitions back to DB before fetching fresh blocks.

**Files**: `EditorViewState+Zoom.swift`

---

## Issue 5: Notes Block ID Desync (Deferred)

**Symptom**: User-typed definition text was lost when inserting subsequent footnotes.

**Root cause**: The immediate insertion path uses `setContent()` (not `setContentWithBlockIds()`), so the JS editor assigns temporary IDs to Notes blocks. Subsequent polls cannot match temp IDs to DB blocks, creating duplicates with empty definitions.

**Status**: Deferred with interim fix. The interim fix reads existing definitions from fresh editor content instead of from DB blocks during immediate insertion. See `docs/deferred/notes-block-id-desync.md` for full analysis.

**Files**: `FootnoteSyncService.swift`, `ContentView.swift`, `ContentView+ContentRebuilding.swift`

---

## Issue 6: CodeMirror Zoom-Notes Marker Visible

**Symptom**: The `<!-- ::zoom-notes:: -->` HTML comment appeared as raw text in CodeMirror when zooming into a section with footnotes.

**Root cause**: Milkdown hid the marker via a custom ProseMirror node plugin, but CodeMirror had no corresponding handling.

**Solution**: Added the zoom-notes marker pattern to CodeMirror's `anchor-plugin.ts`, which already hides section anchors and bibliography markers using `Decoration.replace()`.

**Files**: `web/codemirror/src/anchor-plugin.ts`

---

## Issue 7: Zoom Footnote Insertion Label Conflicts

**Symptom**: Inserting a footnote while zoomed into a section assigned label `[^1]` even when the full document already had footnotes with that label.

**Root cause**: The insertion logic counted only refs visible in the zoomed content, not the full document.

**Solution**: Swift pushes `setZoomFootnoteState(zoomed: true, maxLabel: N)` before setting zoomed content. The JS `insertFootnote()` functions check `getIsZoomMode()` and use `getDocumentFootnoteCount()` to assign the next document-wide label.

**Files**: `EditorViewState+Zoom.swift`, `web/codemirror/src/api.ts`, `web/milkdown/src/footnote-plugin.ts`, `web/codemirror/src/editor-state.ts`
