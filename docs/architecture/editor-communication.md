# Editor Communication

WebView bridge, source mode specifics, SectionSyncService, find bar, link handling, and bibliography section architecture.

---

## WebView Communication

Both editors use the same bridge pattern:

```javascript
// window.FinalFinal API (exposed by editor JavaScript)
// --- Content ---
setContent(markdown)                   // Load content into editor
getContent()                           // Get current markdown
setContentWithBlockIds(md, ids, opts)  // Atomic content + block ID push
setImageMeta([{src, width}])           // Push image widths for preview sizing (CM only)

// --- Block sync (2s polling) ---
hasBlockChanges()         // Check for pending changes (returns boolean)
getBlockChanges()         // Get {updates, inserts, deletes} changeset
syncBlockIds(ids)         // Align editor block order with DB IDs
confirmBlockIds(mapping)  // Confirm temp->permanent ID mapping

// --- Surgical updates ---
updateHeadingLevels(changes)  // Surgical heading level update (no doc replacement)

// --- Batched fallback poll (3s) ---
getPollData()             // Returns JSON: {stats, sectionTitle}

// --- UI ---
setFocusMode(enabled)    // Toggle paragraph dimming (WYSIWYG only)
getStats()               // Returns {words, characters}
scrollToOffset(n)        // Scroll to character offset
setTheme(css)            // Apply theme CSS variables

// --- Scroll sync (mode toggle) ---
getCursorPosition()      // Returns {line, column, scrollFraction, cursorIsVisible, topLine}
scrollToLine(float)      // Scroll to floating-point markdown line (e.g., 6.6)
```

**Content Sync (push + fallback poll)**:

Primary content sync is push-based: both editors push content to Swift via `window.webkit.messageHandlers.contentChanged.postMessage(markdown)` with a 50ms debounce after each doc change. This fires on every meaningful edit (keystroke, paste, delete) with ~50ms latency instead of the previous 500ms polling.

Fallback polling runs at 3s intervals for supplementary data only: `getPollData()` returns a batched JSON with `{stats, sectionTitle}` in a single JS call. Content is no longer polled — the push path handles it.

**Block Sync (2s polling)**: `BlockSyncService` polls `hasBlockChanges()` -> `getBlockChanges()` at 2s intervals for structural content sync. Block change detection is debounced (100ms) in the JS plugin to batch rapid keystrokes. All JS calls use `try? await webView.evaluateJavaScript()` (native async/await) instead of `withCheckedContinuation` wrappers. The poll cycle has a 5-second timeout (`withThrowingTaskGroup` racing the poll body against `Task.sleep`) to prevent permanent hangs if the WebView is unresponsive.

**Feedback Prevention**: `isSettingContent` flag prevents feedback loops when Swift pushes content to editor. `resetAndSnapshot(doc)` must be called after any `setContent()` to prevent false change waves. BlockSyncService checks `editorState.contentState == .idle` to gate polling during drag operations, zoom transitions, and other non-idle states. Push-based content uses grace period guards (150ms CodeMirror, 200ms Milkdown) to avoid overwriting recently pushed content.

---

## Scroll Position Sync (Mode Toggle)

When the user toggles between Milkdown (WYSIWYG) and CodeMirror (Source) via Cmd+/, the scroll position is preserved using a floating-point `topLine` coordinate.

**Coordinate System**: `topLine` is a 1-indexed float where the integer part is the markdown line number and the fractional part is the position within that line's rendered height. For example, `6.6` means "60% through line 6." This provides sub-line precision for blocks with varying rendered heights (images, code blocks, tables).

**Save/Restore Flow**:
1. Outgoing editor calls `getCursorPosition()` which returns `topLine` (float)
2. Swift stores `topLine` in `CursorPosition` (as `Double`)
3. If `cursorIsVisible == false && topLine > 1.0`, incoming editor calls `scrollToLine(topLine)` to restore scroll position
4. If cursor is visible, cursor position is restored instead (scroll follows cursor)

**Milkdown (WYSIWYG) — Anchor Map**:

ProseMirror positions don't map 1:1 to markdown line numbers, so Milkdown uses an anchor map (`scroll-map.ts`) with linear interpolation:

1. `buildAnchorMap(view, mdLines)` walks PM doc top-level nodes in parallel with markdown lines, building `{mdLine, pixelY}` anchor pairs
2. Each PM node type is matched to its markdown lines via a type-dispatch table in `findNodeInMdLines()` (not generic text matching, which drifts on duplicate text)
3. `saveScrollPosition()` finds the two anchors bracketing `window.scrollY` and interpolates a float mdLine
4. `restoreScrollPosition()` finds the two anchors bracketing the target mdLine and interpolates a pixel position

The anchor map is cached by PM doc identity (`===` reference check) and scroll position (within 50px), so it's not rebuilt on every 500ms poll cycle.

**CodeMirror (Source) — Native Line API**:

CodeMirror line numbers are 1:1 with markdown lines, so no anchor map is needed:

- **Save**: `lineBlockAtHeight(scrollTop)` gives the top line; fractional offset = `(scrollTop - block.top) / block.height`
- **Restore**: `doc.line(intLine)` + `lineBlockAt(from)` gives the block; `scrollTop = block.top + fraction * block.height`

**Key files**: `web/milkdown/src/scroll-map.ts`, `web/milkdown/src/api-modes.ts` (getCursorPosition, scrollToLine), `web/codemirror/src/api.ts` (getCursorPosition, scrollToLine)

---

## Source Mode Specifics

**Heading NodeView Plugin** (`heading-nodeview-plugin.ts`):
- WYSIWYG mode: Renders `<h2><span>content</span></h2>` with `heading-empty` class when empty
- Source mode: Renders headers with editable `## ` prefix in the text content

**Source Mode Plugin** (`source-mode-plugin.ts`):
- Adds `body.source-mode` class for CSS targeting
- Provides visual differentiation of markdown syntax

**Anchor Injection**: When switching to source mode, anchors are injected based on section startOffsets. When switching back, anchors are extracted and stripped.

---

## SectionSyncService

> **Note:** `BlockSyncService` is now the primary sync mechanism for content. SectionSyncService retains auxiliary roles described below.

Responsible for legacy section sync, anchor injection/extraction, and bibliography marker management.

**Remaining Roles**:
- `injectSectionAnchors(markdown:sections:)` -- Adds `<!-- @sid:UUID -->` for source mode
- `extractSectionAnchors(markdown:)` -- Removes anchors, returns mappings
- `injectBibliographyMarker` -- Adds `<!-- ::auto-bibliography:: -->` before bibliography header in source mode
- Legacy section table sync (dual-write for backward compatibility)

**Key Methods**:
- `contentChanged(_ markdown:)` -- Debounced entry point (500ms)
- `syncContent(_ markdown:)` -- Parses headers, reconciles with database (DB work dispatched off main thread via `Task.detached`)
- `syncNowSync(_ markdown:)` -- Synchronous section sync for app termination / project close. Mirrors `syncContent()` but runs inline on `@MainActor`. Skips when zoomed (content is a subset).
- `parseHeaders(from markdown:)` -- `nonisolated static` method, extracts section boundaries (callable from detached tasks)
- `cancelPendingSync()` -- Cancels debounce task AND increments `debounceGeneration` to invalidate any in-flight debounce that captured a stale generation

**Reconciliation**: Uses `SectionReconciler` (a `Sendable` struct) to compute minimal database changes (insert, update, delete) by comparing parsed headers against existing sections. All DB reads/writes run off the main thread; only `lastSyncedContent` tracking and UI notifications happen back on MainActor.

---

## Find Bar Architecture

The find bar provides native-style find and replace functionality using JavaScript APIs exposed by both editors.

**State Management** (`FindBarState.swift`):
- Observable state for visibility, search query, replace text, match counts
- Holds weak reference to active `WKWebView` for JavaScript calls
- Uses `focusRequestCount: Int` (not boolean) to trigger focus requests reliably

**Focus Request Pattern**: SwiftUI's `.onChange` requires actual value changes to fire. A boolean toggle (`true` -> `false` -> `true`) can be coalesced by SwiftUI. An incrementing counter always changes, guaranteeing the `.onChange` fires:

```swift
// In FindBarState
var focusRequestCount = 0

func show(withReplace: Bool = false) {
    isVisible = true
    focusRequestCount += 1  // Always triggers .onChange
}

// In FindBarView
.onChange(of: state.focusRequestCount) { _, _ in
    isSearchFieldFocused = true
}
```

**Zoom Integration**: Search state is cleared when zooming in/out to prevent stale highlights from appearing on different content scopes.

**JavaScript API** (`window.FinalFinal.find*`):
- `find(query, options)` -- Start search, returns `{matchCount, currentIndex}`
- `findNext()` / `findPrevious()` -- Navigate matches
- `replaceCurrent(text)` / `replaceAll(text)` -- Replace operations
- `clearSearch()` -- Remove highlights
- `getSearchState()` -- Get current match info

---

## Link Handling

Links are handled across three layers: auto-creation, navigation, and editing.

### Auto-linking (Milkdown only)

**Plugin:** `autolink-plugin.ts`

Converts bare URLs to clickable links when the user types a space after them. Uses ProseMirror `InputRule` for real-time auto-linking (GFM autolinks only work at parse time).

- Matches `https?://...` followed by a space
- Strips trailing punctuation (matches GitHub/Slack behavior: `.,;:!?)}\]>'"`)
- Registered AFTER `commonmark` so the `link` mark schema is available

### Cmd+click to open links

Both editors support Cmd+click (or Ctrl+click) to open URLs in the system browser via the `openURL` Swift message handler.

**Milkdown:** `link-click-handler.ts` — DOM-level click listener with capture phase. Walks up from click target to find `<a>` element, sends href to Swift.

**CodeMirror:** Inline `click` handler in `EditorView.domEventHandlers`. Uses `syntaxTree` to find `URL`, `Autolink`, or `Link` nodes at click position. Strips `<>` from autolink URLs.

**Swift side:** Both `MilkdownCoordinator+MessageHandlers.swift` and `CodeMirrorCoordinator+Handlers.swift` handle `openURL` messages. Only opens `http`, `https`, and `mailto` schemes via `NSWorkspace.shared.open()`.

### Link tooltip (Milkdown only)

**Plugin:** `link-tooltip.ts`

Custom link preview and edit popup, replacing `@milkdown/components/link-tooltip` (which bundles Vue 3, incompatible with WKWebView IIFE builds). Follows the `citation-edit-popup.ts` pattern: singleton DOM, `position: fixed`, `coordsAtPos()`, blur-with-delay.

**Preview popup** (click on link): Shows URL with Edit, Copy, and Remove buttons. Positioned below the link using `coordsAtPos()`.

**Edit popup** (Edit button or Cmd+K): Input field for URL editing. Enter to save, Escape to cancel. Blur commits after 150ms delay.

**Keyboard shortcut:** Cmd+K opens link creation/editing:
- Cursor on existing link → opens edit with pre-filled URL
- Text selected → opens edit to wrap selection in link
- No selection → opens edit to insert new link at cursor
- Skipped in source mode

### Message handler registration

Both editors register the `openURL` handler:

```swift
// MilkdownEditor.swift / CodeMirrorEditor.swift
controller.add(context.coordinator, name: "openURL")
```

### Key files

| File | Purpose |
|------|---------|
| `web/milkdown/src/autolink-plugin.ts` | Auto-link bare URLs on space |
| `web/milkdown/src/link-click-handler.ts` | Cmd+click opens links (Milkdown) |
| `web/milkdown/src/link-tooltip.ts` | Preview/edit tooltip + Cmd+K handler |
| `web/codemirror/src/main.ts` | Cmd+click opens links (CodeMirror, inline handler) |
| `final final/Editors/MilkdownEditor.swift` | `openURL` message handler registration |
| `final final/Editors/CodeMirrorEditor.swift` | `openURL` message handler registration |
| `final final/Editors/MilkdownCoordinator+MessageHandlers.swift` | `openURL` handler impl |
| `final final/Editors/CodeMirrorCoordinator+Handlers.swift` | `openURL` handler impl |

---

## Popup Positioning

**File:** `web/shared/position-popup.ts`

Five popup types (annotation edit, citation edit, link preview, link edit, image caption) use a shared `positionPopup(popup, anchor, options?)` utility for viewport-aware positioning. The utility accepts any anchor with `{left, right, top, bottom}` — both `coordsAtPos()` (ProseMirror) and `getBoundingClientRect()` (DOM elements) return compatible objects.

**Algorithm:** Default below-left of anchor. Flips above if bottom overflows (when space permits). Shifts left if right edge overflows. Clamps to viewport margins (8px default). Runs synchronously (no `requestAnimationFrame`) to avoid race conditions with blur-commit handlers.

**Usage pattern:** Set `display: block/flex` *before* calling `positionPopup()` so `getBoundingClientRect()` returns accurate popup dimensions. The browser paints synchronously, so no visual flash occurs.

**Not using this utility:** Selection toolbar (`selection-toolbar.ts`) has its own centering + arrow logic. Slash menus use `position: absolute` coordinates. Spellcheck popover uses native macOS menu positioning.

---

## Image Preview Architecture

Both editors render inline image previews for `![alt](media/filename.ext)` markdown syntax. Images are stored in a `media/` subdirectory inside the `.ff` project package and served via a custom URL scheme.

### URL Scheme

Images use `projectmedia://` scheme (handled by `MediaSchemeHandler`), which maps to the project's `media/` directory. The markdown path `media/photo.jpg` becomes `projectmedia://photo.jpg` in the rendered preview.

### CodeMirror Implementation

**Plugin:** `image-preview-plugin.ts`

Uses `StateField.define<DecorationSet>()` (not `ViewPlugin`) because image previews are block-level widgets (`Decoration.widget({ block: true, side: 1 })`). CM6 requires block decorations to come from `StateField`.

**Data flow:**
1. `buildDecorations(state: EditorState)` scans document text for `IMAGE_REGEX` matches
2. For each match, looks up explicit width from `imageMetaField` (a `StateField<Map<string, number>>` keyed by `media/` src path)
3. Creates an `ImagePreviewWidget` positioned at line end (`line.to`), passing the width
4. Widget's `toDOM()` creates a `<div class="cm-image-preview">` with `<img>` inside
5. If explicit width exists, applies `img.style.width` and `maxHeight: 'none'`; otherwise CSS `max-width: 100%` + `height: auto` renders at full container width (matching Milkdown)
6. `img.src` rewrites `media/...` to `projectmedia://...` for the custom scheme handler
7. `img.onload` triggers `EditorView.requestMeasure()` via DOM traversal (`wrapper.closest('.cm-editor')` + `EditorView.findFromDOM()`)

**Image metadata bridge:** Swift pushes image widths to CodeMirror via `window.FinalFinal.setImageMeta([{src, width}])`. This dispatches a `StateEffect` that updates `imageMetaField`, triggering decoration rebuild. Metadata is pushed on project load, zoom in/out, and content rebuilds via `CodeMirrorEditor.updateNSView()` (reads `pendingImageMeta` binding from `EditorViewState`).

**Initialization ordering:** In `CodeMirrorCoordinator+Handlers.swift`, `onWebViewReady` (which pushes `setImageMeta`) must be called BEFORE `batchInitialize` (which pushes `setContent`). WKWebView guarantees FIFO ordering for `evaluateJavaScript` calls from the same thread, so this ensures `imageMetaField` is populated when `buildDecorations()` first runs during content load. If `batchInitialize` runs first, images render without width data and the `onload` handler fires before metadata arrives.

**Key constraint:** `StateField` only has access to `EditorState` (not `EditorView`), so the widget cannot hold a `view` reference. Instead it finds the view from the DOM when needed.

**Caption handling:**
- Captions are stored as HTML comments: `<!-- caption: text -->`
- Database-loaded images have a blank line between caption and image; popup-inserted captions have no blank line
- `buildDecorations()` scans backward (up to 3 lines, skipping blanks) to find caption comments
- Found captions are hidden via `Decoration.replace()` spanning from caption line start to image line start
- `atomicRanges` makes the cursor skip over the hidden caption+blank region
- Click-to-edit popup (`image-caption-popup.ts`) allows adding/editing captions inline

### Milkdown Implementation

**Plugin:** `image-plugin.ts`

Uses Milkdown's remark/ProseMirror pipeline to handle image nodes. The `imageSchema` node renders images with the `projectmedia://` URL rewrite.

### Key Files

| File | Purpose |
|------|---------|
| `web/codemirror/src/image-preview-plugin.ts` | CM6 StateField-based block widget for image previews + caption hiding |
| `web/codemirror/src/image-caption-popup.ts` | Click-to-edit caption popup (add/edit captions) |
| `web/milkdown/src/image-plugin.ts` | Milkdown image node with URL rewriting |
| `final final/Editors/MediaSchemeHandler.swift` | `projectmedia://` URL scheme handler |
| `final final/Services/ImageImportService.swift` | Image import (copy to media/, insert markdown) |

---

## Bibliography Section Architecture

The bibliography section is auto-generated by `BibliographySyncService` when citations exist in the document.

**Data Storage**: The bibliography marker `<!-- ::auto-bibliography:: -->` is stored as a standalone `Block` record in the database (blockType `.bibliography`). The bibliography content (heading + entries) is a separate block with `isBibliography: true`.

**Data Flow**:
1. **Database → Editor**: `BlockParser.assembleMarkdown()` faithfully includes the marker block. The marker must NOT be stripped here (see `findings/bibliography-marker-stripping.md`).
2. **Milkdown (WYSIWYG)**: `bibliography-plugin.ts` converts the marker to an invisible ProseMirror node. The `# Bibliography` heading renders normally. On export, the node serializes back to `<!-- ::auto-bibliography:: -->`.
3. **CodeMirror (Source)**: `editorState.sourceContent` includes the marker. CodeMirror hides it using the decoration system that hides section anchors.
4. **Editor → Database**: The CM polling callback strips the marker via `SectionSyncService.stripBibliographyMarker()` before setting `editorState.content`, preventing it from leaking into parsed blocks.

**Bibliography Plugin** (`bibliography-plugin.ts`):
- Remark plugin intercepts `<!-- ::auto-bibliography:: -->` HTML comments BEFORE commonmark's `filterHTMLPlugin` removes them
- Converts to `autoBibliography` mdast node type → `auto_bibliography` ProseMirror node
- Node is invisible in editor (CSS: `.auto-bib-marker { display: none }`)
- Handles marker concatenated with following content by preserving the remainder
- Must be registered BEFORE `commonmark` in the plugin chain

**Marker Injection** (`SectionSyncService.injectBibliographyMarker`):
- Called when switching to source mode, after `injectSectionAnchors()`
- Finds bibliography section by `isBibliography` flag
- Inserts `<!-- ::auto-bibliography:: -->` before the bibliography header

**Marker Stripping** (`SectionSyncService.stripBibliographyMarker`):
- `nonisolated static` method — pure string operation, callable from any context
- Used in CM polling callback and content loading paths
- NOT used in `BlockParser.assembleMarkdown()` (stripping there destroys data)

**Bibliography Detection** (in parsers):
- **With marker**: `BlockParser` detects `<!-- ::auto-bibliography:: -->` and sets blockType to `.bibliography`
- **By heading**: Detects `# Bibliography`, `## Bibliography`, `# References`, `## References` and propagates `isBibliography` flag to all subsequent blocks until a non-bibliography heading resets it
- Bibliography sections are excluded from normal section parsing (managed separately by `BibliographySyncService`)
