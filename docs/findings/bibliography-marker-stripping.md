# Bibliography Marker Stripping Bug

**Date:** 2026-02-19
**Related Changes:** BlockParser.swift revert, bibliography-plugin.ts addition, CM polling callback fix

## Overview

The `<!-- ::auto-bibliography:: -->` marker was being stripped from `BlockParser.assembleMarkdown()` as "defense-in-depth," which caused the bibliography section to vanish on every editor round-trip. Three changes were made to fix bibliography marker handling across the stack.

## Root Cause

The marker `<!-- ::auto-bibliography:: -->` is stored as a legitimate `Block` record in the database (blockType `.bibliography`, markdownFragment `"<!-- ::auto-bibliography:: -->""`). A previous fix added `SectionSyncService.stripBibliographyMarker(from:)` inside `BlockParser.assembleMarkdown()` to strip any leaked markers from assembled content.

This was wrong. The round-trip cycle is:

```
DB blocks → assembleMarkdown() → editor → poll → re-parse → save to DB
```

Stripping the marker in `assembleMarkdown()` meant the marker block's content was destroyed before it even reached the editor. On the next re-parse, there was no marker to save back, so the bibliography block was deleted from the database.

## Fix (3 parts)

### 1. Revert BlockParser.assembleMarkdown (Swift)

**File:** `final final/Services/BlockParser.swift`

Removed the `stripBibliographyMarker` call. The method now returns the joined fragments without post-processing:

```swift
// Before (broken):
static func assembleMarkdown(from blocks: [Block]) -> String {
    let sorted = blocks.sorted { ... }
    let raw = sorted.map { $0.markdownFragment }.joined(separator: "\n\n")
    return SectionSyncService.stripBibliographyMarker(from: raw)
}

// After (fixed):
static func assembleMarkdown(from blocks: [Block]) -> String {
    let sorted = blocks.sorted { ... }
    return sorted.map { $0.markdownFragment }.joined(separator: "\n\n")
}
```

### 2. Strip marker in CM polling callback (Swift)

**File:** `final final/Views/ContentView+ContentRebuilding.swift`

The CodeMirror polling callback (`onContentChange`) now strips the bibliography marker from content before setting `editorState.content`. This prevents the marker from leaking into blocks during re-parse (the correct place to strip, since it's the entry point from the editor, not from the database):

```swift
let cleanContent = sectionSyncService.stripSectionAnchors(from: newContent)
editorState.content = SectionSyncService.stripBibliographyMarker(from: cleanContent)
```

### 3. Bibliography plugin for Milkdown (TypeScript)

**File:** `web/milkdown/src/bibliography-plugin.ts`

New remark plugin that intercepts `<!-- ::auto-bibliography:: -->` HTML comments before commonmark's `filterHTMLPlugin` removes them. Follows the same pattern as `section-break-plugin.ts`:

- Converts the HTML comment to an `autoBibliography` mdast node type
- Defines an `auto_bibliography` ProseMirror node that is invisible in the editor (hidden via CSS `.auto-bib-marker { display: none }`)
- Serializes back to `<!-- ::auto-bibliography:: -->` on markdown export
- Handles marker concatenated with following content (e.g., marker + "# Bibliography") by preserving the remainder

**Registration order matters** — must be registered BEFORE `commonmark`:

```typescript
.use(bibliographyPlugin)  // Intercept before commonmark filters HTML
.use(commonmark)
```

### Supporting change: stripBibliographyMarker made static

**File:** `final final/Services/SectionSyncService+Anchors.swift`

Changed from instance method to `nonisolated static func`. Pure string operation, safe to call from any context. Still used by the CM callback and content loading paths.

## Why the defense-in-depth was wrong

The marker IS a legitimate block fragment stored in the database. The correct fix is to prevent the marker from leaking into blocks at the *entry point* (CM polling callback), not to strip it from the *exit point* (assembleMarkdown). The bibliography plugin in Milkdown also ensures the marker survives the Milkdown round-trip without being filtered out by commonmark.

## Testing Checklist

- [x] Bibliography heading and section appear in sidebar
- [x] Switch to CodeMirror and back — bibliography persists
- [x] Quit and relaunch — bibliography still there
- [x] Add new citations — bibliography regenerates
- [x] Build succeeds

## Lesson Learned

**Don't strip data at the assembly layer.** `assembleMarkdown()` should faithfully reconstruct what's in the database. Data cleaning belongs at boundary points (where content enters or leaves the system), not in the middle of the pipeline.
