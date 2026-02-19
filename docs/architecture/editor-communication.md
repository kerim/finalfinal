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

// --- Block sync (300ms polling) ---
hasBlockChanges()         // Check for pending changes (returns boolean)
getBlockChanges()         // Get {updates, inserts, deletes} changeset
syncBlockIds(ids)         // Align editor block order with DB IDs
confirmBlockIds(mapping)  // Confirm temp->permanent ID mapping

// --- UI ---
setFocusMode(enabled)    // Toggle paragraph dimming (WYSIWYG only)
getStats()               // Returns {words, characters}
scrollToOffset(n)        // Scroll to character offset
setTheme(css)            // Apply theme CSS variables
```

**Polling**: Two polling loops run concurrently:
- **Block polling** (300ms): `BlockSyncService` polls `hasBlockChanges()` -> `getBlockChanges()` for structural content sync
- **Content polling** (500ms): Reads `getContent()` for content binding + annotation sync via `SectionSyncService`

**Feedback Prevention**: `isSettingContent` flag prevents feedback loops when Swift pushes content to editor. `resetAndSnapshot(doc)` must be called after any `setContent()` to prevent false change waves. `isSyncSuppressed` on BlockSyncService gates polling during drag operations and block ID pushes.

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
- `syncContent(_ markdown:)` -- Parses headers, reconciles with database
- `parseHeaders(from markdown:)` -- Extracts section boundaries

**Reconciliation**: Uses `SectionReconciler` to compute minimal database changes (insert, update, delete) by comparing parsed headers against existing sections.

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
