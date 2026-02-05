# final final — Design Document

## Overview

A macOS-native markdown editor for long-form academic writing. SQLite-first architecture with header-based outlining.

**Core principles:**
- Database is the single source of truth (no file system sync)
- Headers (`#`, `##`, `###`, etc.) define document structure
- Clean, Bear/Ulysses-style interface
- Focus on writing experience, defer complexity

---

## Architecture

### Technology Stack

| Component | Technology | Rationale |
|-----------|------------|-----------|
| Platform | macOS (SwiftUI), iOS later | Native performance, shared codebase |
| Database | SQLite via GRDB | Performance, sync flexibility, reactive queries |
| WYSIWYG Editor | Milkdown (WKWebView) | ProseMirror-based, plugin support, proven |
| Source Editor | CodeMirror 6 (WKWebView) | Best markdown editing, mobile support |
| Web integration | WKWebView + JS bridge | Same pattern as Academic Writer, simplified by SQLite |

### Key Difference from Academic Writer

**Academic Writer**: Files in Finder → Manifest → Complex sync
**final final**: SQLite DB → Export when needed → No sync complexity

The database stores all content. No file watching, no manifest reconciliation, no undo coordination across files.

---

## Current Architecture (Phase 1 Implementation)

### Component Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           ContentView                                     │
│  ┌─────────────────┐  ┌───────────────────────────────────────────────┐ │
│  │  OutlineSidebar │  │              Editor (WKWebView)               │ │
│  │                 │  │  ┌────────────────────────────────────────┐  │ │
│  │  SectionCardView│  │  │  MilkdownEditor (WYSIWYG)              │  │ │
│  │  SectionCardView│  │  │         OR                             │  │ │
│  │  SectionCardView│  │  │  CodeMirrorEditor (Source)             │  │ │
│  │       ...       │  │  └────────────────────────────────────────┘  │ │
│  └────────┬────────┘  └──────────────────┬────────────────────────────┘ │
│           │                              │                               │
└───────────┼──────────────────────────────┼───────────────────────────────┘
            │                              │
            ▼                              ▼
   ┌────────────────┐           ┌──────────────────────┐
   │ EditorViewState│◄──────────│  SectionSyncService  │
   │  (@Observable) │           │    (debounced)       │
   └────────┬───────┘           └──────────┬───────────┘
            │                              │
            │      ┌───────────────────────┘
            ▼      ▼
   ┌────────────────────────┐
   │    ProjectDatabase     │
   │      (GRDB + SQLite)   │
   │                        │
   │  - sections table      │
   │  - content table       │
   │  - ValueObservation    │
   └────────────────────────┘
```

### Data Flow

1. **Editor → Swift**: 500ms polling reads `window.FinalFinal.getContent()` from WebView
2. **Swift → SectionSyncService**: Content changes trigger debounced sync (500ms)
3. **SectionSyncService → Database**: Parses headers, reconciles sections, saves
4. **Database → EditorViewState**: GRDB ValueObservation pushes section updates
5. **EditorViewState → Sidebar**: SwiftUI `@Observable` triggers UI update
6. **Swift → Editor**: `window.FinalFinal.setContent(markdown)` pushes content

### Editor Modes

The app supports two editor modes that share the same content:

| Mode | Editor | Purpose |
|------|--------|---------|
| **WYSIWYG** | MilkdownEditor | Rich editing, hides markdown syntax |
| **Source** | CodeMirrorEditor | Raw markdown with syntax highlighting |

**Mode Toggle (Cmd+/)**:
- **WYSIWYG → Source**: Section anchors (`<!-- @sid:UUID -->`) are injected before each header to preserve section identity during editing
- **Source → WYSIWYG**: Anchors are extracted and stripped; a 1.5s delay allows Milkdown to initialize before content polling resumes

### Section Architecture

Sections are the fundamental unit of document structure:

```swift
struct Section {
    id: String           // UUID
    projectId: String    // Parent project
    sortOrder: Int       // Position in document (0-based)
    headerLevel: Int     // 1-6 for H1-H6, inherited for pseudo-sections
    title: String        // Header text (without # prefix)
    markdownContent: String  // Full section content including header
    wordCount: Int       // Cached word count
    startOffset: Int     // Character offset in full document
    parentId: String?    // Computed from header levels (not stored)

    // Metadata (user-editable)
    status: SectionStatus  // draft, review, final, cut
    tags: [String]
    wordGoal: Int?
}
```

**Parent Relationships**: Computed at runtime from header levels. An H3's parent is the nearest preceding section with level < 3.

**Pseudo-sections**: Content breaks (`<!-- ::break:: -->`) create sections without headers. They inherit the header level of the preceding actual header.

### SectionSyncService

Responsible for bidirectional sync between editor content and database sections.

**Key Methods**:
- `contentChanged(_ markdown:)` - Debounced entry point (500ms)
- `syncContent(_ markdown:)` - Parses headers, reconciles with database
- `parseHeaders(from markdown:)` - Extracts section boundaries
- `injectSectionAnchors(markdown:sections:)` - Adds `<!-- @sid:UUID -->` for source mode
- `extractSectionAnchors(markdown:)` - Removes anchors, returns mappings

**Reconciliation**: Uses `SectionReconciler` to compute minimal database changes (insert, update, delete) by comparing parsed headers against existing sections.

### Content State Machine

`EditorContentState` prevents race conditions during complex transitions:

```swift
enum EditorContentState {
    case idle                 // Normal operation
    case zoomTransition       // Zooming in/out of a section
    case hierarchyEnforcement // Fixing header level violations
    case bibliographyUpdate   // Auto-bibliography being regenerated
    case editorTransition     // Switching between Milkdown ↔ CodeMirror
}
```

**Guards**: SectionSyncService and ValueObservation skip updates when `contentState != .idle`, preventing feedback loops.

### Zoom Functionality

Double-clicking a sidebar section "zooms" into it:

1. **Zoom In**:
   - Stores full document in `fullDocumentBeforeZoom`
   - Records `zoomedSectionIds` (section + all descendants)
   - Sets `content` to just the zoomed sections' markdown
   - Waits for editor acknowledgement before returning to `.idle`

2. **Zoom Out**:
   - Merges edited zoomed content back into the full document
   - Non-zoomed sections retain their original content
   - Clears zoom state

**Sync While Zoomed**: `syncZoomedSections()` updates only the zoomed sections in-place, preventing full document replacement.

**Zoom Modes**:
- **Full zoom** (double-click): Shows section + all descendants (by `parentId`) + following pseudo-sections (by document order)
- **Shallow zoom** (Option+double-click): Shows section + only direct pseudo-sections (no children)

**Pseudo-Section Handling**: Pseudo-sections have `parentId = nil` (they inherit H1 level), so `parentId`-based traversal misses them. The `getDescendantIds()` method uses **document order** to find pseudo-sections:

1. Start from the zoomed section's position in sorted sections
2. Scan forward, collecting pseudo-sections until hitting a regular section at same or shallower level
3. Then run the `parentId`-based loop to collect all transitive children (including children of pseudo-sections)

**Sidebar Zoom Filter**: The sidebar uses `zoomedSectionIds` from EditorViewState directly (passed as a read-only property), rather than recalculating descendants. This ensures editor and sidebar show exactly the same sections.

### Hierarchy Constraints

Headers must follow a valid hierarchy (can't jump from H1 to H4):

- First section must be H1
- Each section's level ≤ predecessor's level + 1
- Violations are auto-corrected by demoting headers

`enforceHierarchyConstraints()` runs after section updates from database observation.

### Database Reactivity (ValueObservation)

GRDB's `ValueObservation` provides reactive updates:

```swift
func startObserving(database: ProjectDatabase, projectId: String) {
    observationTask = Task {
        for try await dbSections in database.observeSections(for: projectId) {
            guard !isObservationSuppressed else { continue }
            guard contentState == .idle else { continue }

            sections = dbSections.map { SectionViewModel(from: $0) }
            recalculateParentRelationships()
            onSectionsUpdated?()  // Triggers hierarchy enforcement
        }
    }
}
```

**Suppression**: `isObservationSuppressed` is set during drag-drop operations to prevent database updates from overwriting in-progress reordering.

### Section Drag-Drop Reordering

The sidebar supports drag-drop reordering with hierarchy preservation:

1. **Single Section**: Section moves; orphaned children are promoted to parent's level
2. **Subtree Drag**: Section + all descendants move together; levels shift by delta

**Process**:
1. Cancel pending syncs
2. Suppress observation
3. Reorder sections array
4. Recalculate offsets and parent relationships
5. Enforce hierarchy constraints
6. Rebuild document content
7. Persist to database
8. Resume observation

### WebView Communication

Both editors use the same bridge pattern:

```javascript
// window.FinalFinal API (exposed by editor JavaScript)
setContent(markdown)     // Load content into editor
getContent()             // Get current markdown
setFocusMode(enabled)    // Toggle paragraph dimming (WYSIWYG only)
getStats()               // Returns {words, characters}
scrollToOffset(n)        // Scroll to character offset
setTheme(css)            // Apply theme CSS variables
```

**Polling**: Swift polls `getContent()` every 500ms. Content changes only trigger sync if the polled content differs from the binding.

**Feedback Prevention**: `lastSyncedContent` in SectionSyncService tracks what was just synced, preventing editor → sync → observation → editor loops.

### Source Mode Specifics

**Heading NodeView Plugin** (`heading-nodeview-plugin.ts`):
- WYSIWYG mode: Renders `<h2><span>content</span></h2>` with `heading-empty` class when empty
- Source mode: Renders headers with editable `## ` prefix in the text content

**Source Mode Plugin** (`source-mode-plugin.ts`):
- Adds `body.source-mode` class for CSS targeting
- Provides visual differentiation of markdown syntax

**Anchor Injection**: When switching to source mode, anchors are injected based on section startOffsets. When switching back, anchors are extracted and stripped.

### Bibliography Section Architecture

The bibliography section is auto-generated by `BibliographySyncService` when citations exist in the document. It follows the **section anchor pattern** for visibility control:

**Data Storage**: Bibliography `markdownContent` is stored **without** the marker:
```markdown
# Bibliography

Author, A. (2024). Title. *Journal*.
```

**Data Flow**:
1. **Milkdown (WYSIWYG)**: `editorState.content` contains clean content - bibliography renders as normal `# Bibliography` heading
2. **CodeMirror (Source)**: `editorState.sourceContent` includes injected marker (`<!-- ::auto-bibliography:: -->`) before the bibliography header
3. **CodeMirror hides the marker** using the same decoration system that hides section anchors

**Marker Injection** (`SectionSyncService.injectBibliographyMarker`):
- Called when switching to source mode, after `injectSectionAnchors()`
- Finds bibliography section by `isBibliography` flag
- Inserts `<!-- ::auto-bibliography:: -->` before the bibliography header

**Bibliography Detection** (in parsers):
- **With marker**: Legacy support - parsers detect `<!-- ::auto-bibliography:: -->` prefix
- **Without marker**: Parsers receive `existingBibTitle` parameter to identify bibliography by title match against existing sections
- Bibliography sections are excluded from normal section parsing (managed separately by `BibliographySyncService`)

**Migration**: Old content with embedded markers is cleaned when:
- Loading content from database (`stripBibliographyMarker`)
- Initializing `SectionViewModel` from database sections
- Rebuilding document content from sections

---

## Project Model

### Package Structure

Each project is a macOS package (folder appearing as file):

```
MyBook.ff/
├── content.sqlite        # SQLite database (GRDB)
└── references/           # Reference files (Phase 6+)
    └── (user-organized folders)
```

**Benefits:**
- Portable: backup/share as single "file"
- Sync-friendly: package or just SQLite
- Finder shows as file, "Show Package Contents" reveals internals
- Standard macOS pattern (like Scrivener, Final Draft)

---

## Data Model (GRDB)

### Core Tables

```sql
-- Project metadata
CREATE TABLE project (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

-- Main content (one row per project)
CREATE TABLE content (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES project(id),
    markdown TEXT NOT NULL,  -- Full markdown content
    updated_at TEXT NOT NULL
);

-- Outline cache (derived from headers, rebuilt on content change)
CREATE TABLE outline_nodes (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES project(id),
    header_level INTEGER NOT NULL,  -- 1-6
    title TEXT NOT NULL,
    start_offset INTEGER NOT NULL,  -- Character position in content
    end_offset INTEGER NOT NULL,
    parent_id TEXT REFERENCES outline_nodes(id),
    sort_order INTEGER NOT NULL,
    is_pseudo_section BOOLEAN DEFAULT FALSE  -- For "## Title-part 1" style
);

-- User preferences per project
CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Future tables
-- annotations, citations (Phase 2-3)
-- reference_folders, reference_files (Phase 6)
```

### Content Model

One project = one markdown string. Headers within that string define the outline structure.

```markdown
# Book Title

## Chapter 1

### Section 1.1

Content here...

### Section 1.2

More content...

## Chapter 2

...
```

The `outline_nodes` table is a cache rebuilt whenever content changes. It enables fast sidebar rendering without parsing markdown on every frame.

---

## UI Layout

```
┌─────────────────────────────────────────────────────────────┐
│  Toolbar: [Toggle Editor Mode] [Zoom Out] [Settings]        │
├──────────────┬──────────────────────────────────────────────┤
│              │                                              │
│   Outline    │                                              │
│   Sidebar    │              Editor                          │
│              │              (Milkdown or CodeMirror 6)      │
│   - H1 Card  │                                              │
│     - H2     │                                              │
│       - H3   │                                              │
│     - H2     │                                              │
│   - H1 Card  │                                              │
│              │                                              │
├──────────────┴──────────────────────────────────────────────┤
│  Status: Word count | Section name | Editor mode            │
└─────────────────────────────────────────────────────────────┘
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

---

## Phase 1: MVP (Editor + Outline)

### Goals
- Working editor with both modes (Milkdown WYSIWYG + CodeMirror 6 source)
- Header-based outline sidebar with preview text and word counts
- Focus mode (paragraph dimming)
- Color scheme theming
- SQLite persistence
- Basic document management

### Feature Details

**Editors:**
- Milkdown for WYSIWYG mode
- CodeMirror 6 for source mode
- Cmd+/ toggles between modes (cursor position preserved)
- Cmd+B/I/K formatting shortcuts (insert markdown syntax in source mode)
- Both editors use same `editor://` URL scheme pattern from Academic Writer

**Outline Sidebar (Bear/Ulysses style):**
- Flat card list with banners for top-level headers
- Each card shows: header title, preview text (1-4 lines), word count
- Single click = scroll to section
- Double click = zoom into section (sidebar shows only subtree)
- Option-click header in editor = zoom
- Pseudo-sections (`## Title-part 1`) show with special marker
- NO drag-and-drop add bar in MVP (design TBD for later)

**Focus Mode:**
- Paragraph dimming (dims non-current paragraph)
- Use ProseMirror Decoration system (not DOM manipulation)
- Works in WYSIWYG mode only

**Theming:**
- Multiple color schemes (light/dark variants)
- Sidebar colors from theme system
- Editor colors from theme system

### Implementation Steps

#### 1.1 Project Setup
- Create Xcode project (SwiftUI, macOS 13+)
- Add GRDB via SPM
- Set up basic app structure
- Configure `editor://` URL scheme

#### 1.2 Database Layer
- Define GRDB models (Document, OutlineNode)
- Implement document CRUD operations
- Implement outline parsing (markdown → nodes)

#### 1.3 Theme System
- Define color scheme structure
- Implement theme switching
- CSS variables for web editors

#### 1.4 Editor Integration (Milkdown)
- Set up WKWebView wrapper
- Bundle Milkdown with vite build
- Implement Swift ↔ JS bridge:
  - `setContent(markdown)`
  - `getContent() → markdown`
  - `onContentChange` callback
  - `setFocusMode(enabled)`
- Focus mode plugin with Decoration system
- Connect to database

#### 1.5 Editor Integration (CodeMirror 6)
- Bundle CodeMirror 6 with markdown support
- Same bridge pattern as Milkdown
- Mode toggle (Cmd+/) with cursor preservation
- Formatting shortcuts (Cmd+B/I/K)

#### 1.6 Outline Sidebar
- `FlatListBuilder` to flatten header hierarchy
- `SectionBannerView` for top-level headers
- `SidebarCardView` with preview text, word count
- Click/double-click handlers
- Zoom state management
- Scroll sync (editor position ↔ sidebar highlight)

#### 1.7 Annotations
- Annotation types: Task, Comment, Reference
- Slash commands: `/task`, `/comment`, `/reference`
- Display modes: inline (full text) and collapsed (marker symbols)
- Annotation panel for sidebar viewing
- Task completion tracking
- Highlight span support (associate annotations with text)
- Storage as HTML comments: `<!-- ::type:: text -->`

#### 1.8 Project Management
- New project (creates .ff package)
- Open project (file picker for .ff packages)
- Recent projects list
- Save (automatic, debounced 500ms)
- Import markdown file (creates new project from .md)
- Export to markdown file

### Files to Create

```
final final/
├── final final.xcodeproj
├── final final/
│   ├── App/
│   │   ├── FinalFinalApp.swift
│   │   └── AppDelegate.swift      # Static shared reference pattern
│   ├── Models/
│   │   ├── Document.swift         # GRDB model
│   │   ├── OutlineNode.swift      # GRDB model
│   │   └── Database.swift         # GRDB setup, migrations
│   ├── ViewState/
│   │   └── EditorViewState.swift  # Published state (zoom, mode, focus)
│   ├── Views/
│   │   ├── ContentView.swift      # Main layout
│   │   ├── StatusBar.swift        # Bottom status
│   │   └── Sidebar/
│   │       ├── OutlineSidebar.swift
│   │       ├── SectionBannerView.swift
│   │       ├── SidebarCardView.swift
│   │       └── FlatListBuilder.swift
│   ├── Editors/
│   │   ├── MilkdownEditor.swift   # WKWebView wrapper
│   │   ├── CodeMirrorEditor.swift # WKWebView wrapper
│   │   ├── EditorBridge.swift     # Shared JS bridge protocol
│   │   └── EditorSchemeHandler.swift  # Custom editor:// URL scheme
│   ├── Theme/
│   │   ├── ColorScheme.swift      # Theme definitions
│   │   └── ThemeManager.swift     # Theme switching, persistence
│   ├── Services/
│   │   ├── OutlineParser.swift    # Markdown → outline nodes
│   │   └── DocumentManager.swift  # Document lifecycle
│   ├── Commands/
│   │   └── ViewCommands.swift     # Menu items, keyboard shortcuts
│   └── Resources/
│       └── editor/                # Bundled web editors (build output)
├── web/
│   ├── milkdown/                  # Milkdown source + plugins
│   │   ├── src/
│   │   │   ├── main.ts
│   │   │   ├── focus-mode-plugin.ts
│   │   │   └── styles.css
│   │   ├── package.json
│   │   └── vite.config.ts
│   └── codemirror/                # CodeMirror 6 source
│       ├── src/
│       │   ├── main.ts
│       │   └── styles.css
│       ├── package.json
│       └── vite.config.ts
└── docs/
    └── plans/
```

### Verification (Phase 1)

**Editor basics:**
- [ ] Can create new document
- [ ] Can type in WYSIWYG mode (Milkdown)
- [ ] Can toggle to source mode (CodeMirror 6) with Cmd+/
- [ ] Cursor position approximately preserved on toggle
- [ ] Cmd+B/I/K insert markdown syntax in source mode
- [ ] Content persists after app restart

**Outline sidebar:**
- [ ] Headers appear as cards with preview text
- [ ] Word counts display on cards/banners
- [ ] Single click scrolls to section
- [ ] Double click zooms into section
- [ ] Zoomed view shows only subtree in sidebar
- [ ] Option-click header in editor zooms
- [ ] Pseudo-sections show with special marker

**Focus mode:**
- [ ] Cmd+Shift+F toggles focus mode
- [ ] Non-current paragraphs dimmed in WYSIWYG mode
- [ ] Focus mode hidden when in source mode

**Theming:**
- [ ] Can switch between color schemes
- [ ] Sidebar and editor respect theme
- [ ] Theme persists after restart

**Annotations:**
- [x] Can create annotations via /task, /comment, /reference
- [x] Annotations display inline and collapsed modes
- [x] Annotation panel shows all annotations
- [x] Tasks can be marked complete

**Status bar:**
- [ ] Word count updates in both modes
- [ ] Current section name displayed
- [ ] Editor mode indicator shown

**Onboarding:**
- [x] Project picker shown on launch when no project is open
- [x] Getting Started guide accessible from Help menu
- [x] Getting Started accessible from project picker

**Sidebar toggles:**
- [x] Cmd+[ toggles outline sidebar
- [x] Cmd+] toggles annotations sidebar

---

## Phase 0.2: Stabilization & Production Readiness

**Goal**: Polish the alpha app for daily use, fix bugs, improve UX

### 0.2.0 — UI Enhancements & New Features
- Sidebar header level filter (dropdown to show H1-H2, H1-H3, etc.)
- Hideable editor toolbar (Bold, Italic, Link, Headers)
- Expanded appearance settings (font family, size, line spacing, line numbers)
- Find & Replace (Cmd+F, Cmd+Shift+F)
- Option-click header in editor → zoom to section

### 0.2.1 — Editor & Theme Polish
- Editor load time optimization
- Typography improvements (font, line-height, paragraph spacing)
- Theme consistency audit (all windows/panels)
- Bibliography card threading fix

### 0.2.2 — Citation System Polish
- Fix /cite bug with `?` characters
- Citation picker positioning
- Multi-citation entry UI
- Research Zotero native picker
- PDF export citation formatting

### 0.2.3 — Foundation & Stability
- Data integrity verification and recovery
- Error handling framework
- Performance monitoring
- Structured logging

---

## Future Phases (Reference)

| Phase | Features |
|-------|----------|
| 0.3 | Reference pane (Finder-style folders for PDFs, images, docs) |
| 0.4 | Sync (Cloudflare DO or CloudKit) |

---

## Lessons from Academic Writer

**Apply:**
- ProseMirror Decoration system for focus mode (not DOM manipulation)
- Custom URL scheme (`editor://`) for loading bundled assets
- 500ms polling for content changes (simple, works)
- Web Inspector debugging (`isInspectable = true`)

**Avoid:**
- File system sync complexity (eliminated by SQLite)
- Section/text node distinction (use headers instead)
- Numeric file prefixes (not needed)
- ID-based manifest ordering (outline derived from content)

---

## Design Decisions (Resolved)

1. **Pseudo-sections**: `## Chapter 1-part 1` style breaks show with a special marker in the sidebar (indicating they're continuations, not full sections)

2. **Zoom state**: When zoomed into a section, sidebar shows only that subtree (parent and children), not the full document outline

3. **Large documents**: Defer until we hit performance issues. GRDB handles data efficiently; CodeMirror 6 has viewport-based rendering built in
