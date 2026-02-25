# Architecture Overview

A macOS-native markdown editor for long-form academic writing. SQLite-first architecture with header-based outlining.

**Core principles:**
- Database is the single source of truth (no file system sync)
- Headers (`#`, `##`, `###`, etc.) define document structure
- Clean, Bear/Ulysses-style interface
- Focus on writing experience, defer complexity

---

## Technology Stack

| Component | Technology | Rationale |
|-----------|------------|-----------|
| Platform | macOS (SwiftUI), iOS later | Native performance, shared codebase |
| Database | SQLite via GRDB | Performance, sync flexibility, reactive queries |
| WYSIWYG Editor | Milkdown (WKWebView) | ProseMirror-based, plugin support, proven |
| Source Editor | CodeMirror 6 (WKWebView) | Best markdown editing, mobile support |
| Web integration | WKWebView + JS bridge | Same pattern as Academic Writer, simplified by SQLite |

### Key Difference from Academic Writer

**Academic Writer**: Files in Finder -> Manifest -> Complex sync
**final final**: SQLite DB -> Export when needed -> No sync complexity

The database stores all content. No file watching, no manifest reconciliation, no undo coordination across files.

---

## Component Overview

```
+-----------------------------------------------------------------------+
|                           ContentView                                 |
|  +-----------------+  +---------------------------------------------+ |
|  |  OutlineSidebar |  |              Editor (WKWebView)             | |
|  |                 |  |  +----------------------------------------+ | |
|  |  SectionCardView|  |  |  MilkdownEditor (WYSIWYG)              | | |
|  |  SectionCardView|  |  |         OR                             | | |
|  |  SectionCardView|  |  |  CodeMirrorEditor (Source)             | | |
|  |       ...       |  |  +----------------------------------------+ | |
|  +--------+--------+  +----------+------------------+--------------+ |
|           |                      |                  |                |
+-----------+----------------------+------------------+----------------+
            |                      |                  |
            v                      v                  v
   +----------------+    +------------------+  +---------------------+
   | EditorViewState|<---| BlockSyncService |  | SectionSyncService  |
   |  (@Observable) |    |  (300ms poll)    |  | (legacy/auxiliary)  |
   +--------+-------+    +--------+---------+  +----------+----------+
            |                     |                       |
            |      +--------------+   +-------------------+
            v      v                  v
   +------------------------------------+
   |        ProjectDatabase             |
   |          (GRDB + SQLite)           |
   |                                    |
   |  - block table (primary content)   |
   |  - sections table (dual-write)     |
   |  - content table                   |
   |  - ValueObservation                |
   +------------------------------------+
```

**JS API surface** (block-related): `hasBlockChanges()`, `getBlockChanges()`, `syncBlockIds()`, `confirmBlockIds()`, `setContentWithBlockIds()`

---

## Data Flow

**Primary (block-based)**:
1. **Editor -> BlockSyncService**: 300ms polling calls `hasBlockChanges()` then `getBlockChanges()`
2. **BlockSyncService -> Database**: Applies insert/update/delete directly to block table
3. **Database -> EditorViewState**: GRDB ValueObservation on **outline blocks** (heading + pseudo-section blocks) pushes updates
4. **EditorViewState -> Sidebar**: Converts blocks to `SectionViewModel(from: Block)` with aggregated word counts
5. **Swift -> Editor**: `setContentWithBlockIds()` pushes content + block IDs atomically; `confirmBlockIds()` sends temp->permanent ID mappings

**Auxiliary (legacy content binding)**:
6. **Editor -> Swift**: 500ms polling reads `getContent()` for content binding + annotation sync via SectionSyncService

---

## Editor Modes

The app supports two editor modes that share the same content:

| Mode | Editor | Purpose |
|------|--------|---------|
| **WYSIWYG** | MilkdownEditor | Rich editing, hides markdown syntax |
| **Source** | CodeMirrorEditor | Raw markdown with syntax highlighting |

**Mode Toggle (Cmd+/)**:
- **WYSIWYG -> Source**: Section anchors (`<!-- @sid:UUID -->`) are injected before each header to preserve section identity during editing
- **Source -> WYSIWYG**: Anchors are extracted and stripped; a 1.5s delay allows Milkdown to initialize before content polling resumes

See [editor-communication.md](editor-communication.md) for WebView bridge details.
See [block-system.md](block-system.md) for block architecture.
See [data-model.md](data-model.md) for database schema.
See [state-machine.md](state-machine.md) for content state machine and zoom.
See [word-count.md](word-count.md) for word count architecture.

---

## UI Layout

```
+-------------------------------------------------------------+
|  Toolbar: [Toggle Editor Mode] [Zoom Out] [Settings]        |
+--------------+----------------------------------------------+
|              |                                              |
|   Outline    |                                              |
|   Sidebar    |              Editor                          |
|              |              (Milkdown or CodeMirror 6)      |
|   - H1 Card |                                              |
|     - H2    |                                              |
|       - H3  |                                              |
|     - H2    |                                              |
|   - H1 Card |                                              |
|              |                                              |
+--------------+----------------------------------------------+
|  Status: Word count | Section name | Editor mode            |
+-------------------------------------------------------------+
```

### Sidebar Behavior

- **Cards**: Each header (H1-H6) becomes a card, nested by level
- **Single click**: Scroll editor to that section
- **Double click**: Zoom into section (show only that section + children)
- **Option-click header in editor**: Also zooms

### Editor Modes

- **WYSIWYG (Milkdown)**: Default, hides markdown syntax
- **Source (CodeMirror 6)**: Shows raw markdown with syntax highlighting
- **Toggle**: Preserve cursor position when switching
