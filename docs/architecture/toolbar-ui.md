# Toolbar & Formatting UI Architecture

Five interconnected UI areas provide formatting and insertion commands. Each area targets a different interaction context (menu bar, title bar, in-editor selection, in-editor typing, bottom status).

## 1. Format Menu (macOS Menu Bar)

**File:** `final final/Commands/EditorCommands.swift`

The `EditorCommands` struct registers native macOS menu items under a **Format** menu and additional items in the standard Edit menu group. Each menu item posts a `Notification.Name` when activated.

**Communication flow:**

```
Menu item click → NotificationCenter.post(.toggleBold)
  → MilkdownCoordinator / CodeMirrorCoordinator observe notification
  → evaluateJavaScript("window.FinalFinal.toggleBold()")
  → Web editor applies formatting
```

**Commands registered:**
- Inline: Bold (⌘B), Italic (⌘I), Strikethrough, Link (⌘K)
- Block: Heading 1–6, Paragraph, Bullet List, Numbered List, Blockquote, Code Block
- Inserts: Highlight (⌘⇧H), Footnote (⌘⇧N), Section Break (⌘⇧↩), Annotations (⌘⇧T/C/R)
- Find: Find (⌘F), Find & Replace (⌘H), Find Next/Previous (⌘G/⌘⇧G), Use Selection for Find (⌘E)

**Notification names** are defined in `EditorViewState+Types.swift` (formatting) and `EditorCommands.swift` (find, focus mode, spelling).

## 2. Editor Toolbar (Title Bar)

**File:** `final final/Views/Components/EditorToolbar.swift`

A SwiftUI `ToolbarContent` struct placed in the window title bar (`.primaryAction` placement). Contains four groups of toolbar buttons:

| Group | Contents | Visual treatment |
|-------|----------|-----------------|
| Annotations | Task, Comment, Reference | System SF Symbol icons, separate capsule |
| Inserts | Cite (❝), Footnote (‡) | Custom text icons, merged via `ControlGroup` |
| Deferred | Image, Table, Math | Disabled placeholder items |
| Sidebar | Annotation panel toggle | `sidebar.right` icon |

**Communication:** Same NotificationCenter pattern as the Format menu — buttons post notifications that coordinators observe and forward to JavaScript.

**Design note:** Cite and Footnote use `ControlGroup` to force macOS to render them as one visual capsule, since plain `Text()` icons in separate `Button`s would render as separate capsules.

## 3. Selection Toolbar (Floating Format Bar)

**Files:**
- Shared: `web/shared/selection-toolbar.ts` (logic), `web/shared/selection-toolbar.css` (styles)
- Milkdown plugin: `web/milkdown/src/selection-toolbar-plugin.ts`
- CodeMirror plugin: `web/codemirror/src/selection-toolbar-plugin.ts`

A floating toolbar that appears above (or below, if near viewport top) the text selection. Both editors share the same toolbar DOM element and CSS.

### Architecture (3-layer)

```
┌────────────────────────────────────────────────┐
│  Shared Layer (selection-toolbar.ts)            │
│  - Creates/destroys toolbar DOM                 │
│  - Positions toolbar relative to selection rect │
│  - Updates active button states                 │
│  - Dispatches commands via window.FinalFinal    │
│  - Heading dropdown submenu                     │
│  - CSS animation (fade in/out, arrow pointer)   │
└────────────┬──────────────────┬────────────────┘
             │                  │
┌────────────▼──────┐  ┌───────▼───────────────┐
│ Milkdown Plugin   │  │ CodeMirror Plugin      │
│ (ProseMirror)     │  │ (ViewPlugin)           │
│                   │  │                        │
│ getActiveFormats: │  │ getActiveFormats:       │
│ - storedMarks     │  │ - syntaxTree nodes     │
│ - nodesBetween    │  │ - line text regex      │
│ - highlight mark  │  │ - fence counting       │
│                   │  │ - == highlight heuristic│
│ Hides in source   │  │                        │
│ mode              │  │ Debounced 50ms         │
└───────────────────┘  └───────────────────────┘
```

### Toolbar buttons

| Section | Buttons |
|---------|---------|
| Inline | **B** (bold), *I* (italic), ~~S~~ (strikethrough), ≡ (highlight) |
| Link | Chain-link SVG icon |
| Heading | H▾ dropdown → H1–H6 + Paragraph (with checkmark on active level) |
| Block | • (bullet), 1. (number), ❝ (blockquote), </> (code block) |

### Format detection differences

- **Milkdown:** Uses ProseMirror's `storedMarks` and `nodesBetween()` with schema mark type names (`strong`, `emphasis`, `strike_through`). Note: GFM registers strikethrough as `strike_through` (with underscore).
- **CodeMirror:** Uses Lezer syntax tree node names (`StrongEmphasis`, `Emphasis`, `Strikethrough`) and line-text regex for block formats.

### Positioning logic

1. Toolbar centers horizontally over the selection
2. Default: above selection with 8px margin
3. Falls back to below selection if too close to viewport top
4. Arrow (CSS `::after` pseudo-element) points toward selection center
5. Clamped to viewport edges

## 4. Slash Commands (/ Menu)

**Files:**
- Milkdown: `web/milkdown/src/slash-commands.ts`
- CodeMirror: `web/codemirror/src/slash-completions.ts`
- Shared styles: `web/shared/slash-menu.css`

An autocomplete-style dropdown that appears when the user types `/` followed by optional filter text.

### Architecture

**Milkdown:** Uses `@milkdown/plugin-slash` (`SlashProvider` + `slashFactory`). The provider detects `/` patterns in paragraph/heading nodes and manages show/hide. Menu rendering and keyboard navigation are custom.

**CodeMirror:** Custom `ViewPlugin` class (`SlashMenuPlugin`). Detects `/` at line start or after whitespace via regex on each doc/selection change. Fully self-contained: positioning, rendering, keyboard handling.

### Shared command set (18 commands)

| Command | Milkdown behavior | CodeMirror behavior |
|---------|------------------|-------------------|
| `/break` | Inserts `section_break` node | Inserts `<!-- ::break:: -->` HTML comment |
| `/h1`–`/h6` | Transforms parent to heading node | Replaces line with `#` prefix |
| `/bullet` | `callCommand(wrapInBulletListCommand)` | Replaces line prefix with `- ` |
| `/number` | `callCommand(wrapInOrderedListCommand)` | Replaces line prefix with `1. ` |
| `/quote` | `callCommand(wrapInBlockquoteCommand)` | Prefixes line with `> ` |
| `/code` | `callCommand(createCodeBlockCommand)` | Wraps in ``` fences |
| `/link` | Opens link tooltip editor | Inserts `[link text](url)` template |
| `/highlight` | Calls `window.FinalFinal.toggleHighlight()` | Same |
| `/task`, `/comment`, `/reference` | Inserts annotation node | Inserts HTML comment syntax |
| `/cite` | Opens Zotero CAYW picker via Swift bridge | Posts to `webkit.messageHandlers` |
| `/footnote` | Calls `insertFootnoteWithDelete()` | Calls `insertFootnoteReplacingRange()` |

### Smart undo/redo (Milkdown)

After a slash command executes, `pendingSlashUndo` is set. Pressing ⌘Z performs a double-undo (removes both the command result and the `/` trigger). ⌘⇧Z performs a double-redo to restore both.

### Keyboard navigation

Both editors intercept `ArrowUp`, `ArrowDown`, `Enter`/`Tab`, and `Escape` via a document-level keydown listener (Milkdown) or class method (CodeMirror) to navigate and confirm slash menu items.

## 5. Status Bar

**File:** `final final/Views/StatusBar.swift`

A SwiftUI `View` at the bottom of the editor window. Displays state and provides quick toggles.

### Contents (left to right)

| Element | Description |
|---------|------------|
| Word count | Shows `X words` or `X/Y words` if document goal is set. Uses `filteredTotalWordCount` (respects bibliography exclusion). |
| Section name | Current section from `editorState.currentSectionName` |
| Outline popover | Button with `list.bullet.indent` icon. Opens a popover listing all sections with status colors, indented by heading level. Clicking scrolls to that section. |
| Proofing indicator | Green/yellow/red dot showing LanguageTool connection status. Only visible when LanguageTool mode is active. Popover shows details + link to preferences. |
| Spelling toggle | Click to toggle spell-checking. Strikethrough text when disabled. Posts `.spellcheckTypeToggled`. |
| Grammar toggle | Same pattern as spelling toggle. |
| Editor mode badge | Shows "WYSIWYG" or "Source". Click to toggle (posts `.willToggleEditorMode`). Styled with accent-colored background. |
| Focus badge | Shows "Focus" when focus mode is active. Display-only. |

## Formatting API (Bridge Layer)

**Files:**
- Milkdown: `web/milkdown/src/api-formatting.ts`
- CodeMirror: `web/codemirror/src/api-formatting.ts`

Both files export the same function signatures (`toggleBold()`, `toggleItalic()`, `toggleStrikethrough()`, `setHeading(level)`, `toggleBulletList()`, `toggleNumberList()`, `toggleBlockquote()`, `toggleCodeBlock()`, `insertLinkAtCursor()`). These are exposed on `window.FinalFinal` and called by:

1. The Format menu (via Swift → JavaScript bridge)
2. The selection toolbar (via `executeCommand()` in shared `selection-toolbar.ts`)

### Implementation differences

| Operation | Milkdown | CodeMirror |
|-----------|---------|------------|
| Inline marks | ProseMirror `callCommand` (bold, italic) or `toggleStrikethroughCommand` from GFM | Raw markdown wrapper toggle (`**`, `*`, `~~`) with surrounding-context detection |
| Headings | `callCommand(wrapInHeadingCommand)` or ProseMirror node replacement for level 0 | Regex replace on line text (`#` prefix) |
| Lists | `callCommand` + `liftListItem` for unwrap | Line prefix toggle (`- ` / `1. `) |
| Blockquote | `callCommand` + `lift` for unwrap | Line prefix toggle (`> `) |
| Code block | `callCommand` + ProseMirror node replacement for unwrap | Fence detection + wrap/unwrap |
| Link | Opens Milkdown link tooltip (`openLinkEdit`) | Calls `insertLink()` from CodeMirror API |

## Communication Summary

```
┌─────────────────────────────────────────────────────────────────┐
│ Swift (Native)                                                  │
│                                                                 │
│  EditorCommands ──┐                                             │
│  EditorToolbar ───┼── NotificationCenter ──→ Coordinator ──→ JS│
│  StatusBar ───────┘         .post()          .observe()    eval │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│ JavaScript (WebView)                                            │
│                                                                 │
│  Selection Toolbar ──→ window.FinalFinal.toggleBold() etc.      │
│  Slash Commands ─────→ Direct ProseMirror/CM transactions       │
│                        OR window.FinalFinal API calls            │
│  api-formatting.ts ──→ Editor-specific implementation           │
└─────────────────────────────────────────────────────────────────┘
```
