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
│  └────────┬────────┘  └──────────┬──────────────────┬────────────────┘ │
│           │                      │                  │                    │
└───────────┼──────────────────────┼──────────────────┼────────────────────┘
            │                      │                  │
            ▼                      ▼                  ▼
   ┌────────────────┐    ┌──────────────────┐  ┌─────────────────────┐
   │ EditorViewState│◄───│ BlockSyncService │  │ SectionSyncService  │
   │  (@Observable) │    │  (300ms poll)    │  │ (legacy/auxiliary)  │
   └────────┬───────┘    └────────┬─────────┘  └──────────┬──────────┘
            │                     │                       │
            │      ┌──────────────┘   ┌───────────────────┘
            ▼      ▼                  ▼
   ┌────────────────────────────────────┐
   │        ProjectDatabase             │
   │          (GRDB + SQLite)           │
   │                                    │
   │  - block table (primary content)   │
   │  - sections table (dual-write)     │
   │  - content table                   │
   │  - ValueObservation                │
   └────────────────────────────────────┘
```

**JS API surface** (block-related): `hasBlockChanges()`, `getBlockChanges()`, `syncBlockIds()`, `confirmBlockIds()`, `setContentWithBlockIds()`

### Data Flow

**Primary (block-based)**:
1. **Editor → BlockSyncService**: 300ms polling calls `hasBlockChanges()` then `getBlockChanges()`
2. **BlockSyncService → Database**: Applies insert/update/delete directly to block table
3. **Database → EditorViewState**: GRDB ValueObservation on **outline blocks** (heading + pseudo-section blocks) pushes updates
4. **EditorViewState → Sidebar**: Converts blocks to `SectionViewModel(from: Block)` with aggregated word counts
5. **Swift → Editor**: `setContentWithBlockIds()` pushes content + block IDs atomically; `confirmBlockIds()` sends temp→permanent ID mappings

**Auxiliary (legacy content binding)**:
6. **Editor → Swift**: 500ms polling reads `getContent()` for content binding + annotation sync via SectionSyncService

### Editor Modes

The app supports two editor modes that share the same content:

| Mode | Editor | Purpose |
|------|--------|---------|
| **WYSIWYG** | MilkdownEditor | Rich editing, hides markdown syntax |
| **Source** | CodeMirrorEditor | Raw markdown with syntax highlighting |

**Mode Toggle (Cmd+/)**:
- **WYSIWYG → Source**: Section anchors (`<!-- @sid:UUID -->`) are injected before each header to preserve section identity during editing
- **Source → WYSIWYG**: Anchors are extracted and stripped; a 1.5s delay allows Milkdown to initialize before content polling resumes

### Block Architecture

Blocks are the fundamental unit of document structure. Each block represents a single top-level ProseMirror node (paragraph, heading, list, etc.) with a stable UUID that annotations can reference.

```swift
struct Block {
    id: String              // UUID (stable across edits)
    projectId: String       // Parent project
    parentId: String?       // For nested blocks (list items)
    sortOrder: Double       // Fractional for easy insertion between blocks
    blockType: BlockType    // 12 types: paragraph, heading, bulletList, orderedList,
                            //   listItem, blockquote, codeBlock, horizontalRule,
                            //   sectionBreak, bibliography, table, image
    textContent: String     // Plain text (for search, word count)
    markdownFragment: String // Original markdown for this block
    headingLevel: Int?      // 1-6 for headings, nil for other types

    // Section metadata (heading and section break blocks only)
    status: SectionStatus?
    tags: [String]?
    wordGoal: Int?
    goalType: GoalType
    wordCount: Int

    // Special flags
    isBibliography: Bool
    isPseudoSection: Bool   // Section break markers
}
```

**Sort Order**: Fractional `Double` allows insertion between any two blocks without renumbering. `reorderAllBlocks()` reassigns sequential integers atomically when the sidebar is reordered.

**Block IDs**: The JS editor assigns `temp-XXXX` IDs to new blocks. Swift confirms with real UUIDs via `confirmBlockIds()`. The `syncBlockIds()` method aligns the editor's block order with the database.

**Legacy Dual-Write**: The `Section` model still exists in a separate table. `persistReorderedBlocks_legacySections()` writes to the section table as a fire-and-forget operation for backward compatibility. `SectionViewModel` is derived from heading blocks via `SectionViewModel(from: Block)`.

**Parent Relationships**: Computed at runtime from header levels. An H3's parent is the nearest preceding section with level < 3.

**Pseudo-sections**: Content breaks (`<!-- ::break:: -->`) create sections without headers. They inherit the header level of the preceding actual header.

### Word Count Architecture

Word counts flow through multiple layers, from per-section calculation to document totals with goal tracking.

#### Data Model

```swift
// Section model stores word count
struct Section {
    wordCount: Int           // Cached count for this section
    wordGoal: Int?           // User-set target (optional)
    goalType: GoalType       // .exact, .approx, .minimum
}

// Document-level goal settings (stored in settings table)
struct DocumentGoalSettings {
    goal: Int?               // Document word target
    goalType: GoalType       // How to interpret the goal
    excludeBibliography: Bool // Exclude bibliography from totals
}
```

#### Calculation Flow

1. **Section Word Count**: Calculated by `MarkdownUtils.wordCount()` during section sync
   - Strips markdown syntax before counting
   - Counts words separated by whitespace
   - Stored in `Section.wordCount` field

2. **Section Sync**: `SectionSyncService.syncContent()` recalculates word counts when sections are created/updated:
   ```swift
   let wordCount = MarkdownUtils.wordCount(for: sectionMarkdown)
   ```

3. **Document Total**: `EditorViewState.filteredTotalWordCount` computes totals:
   ```swift
   var filteredTotalWordCount: Int {
       sections
           .filter { !excludeBibliography || !$0.isBibliography }
           .reduce(0) { $0 + $1.wordCount }
   }
   ```

#### UI Display

| Location | What's Shown | Source |
|----------|--------------|--------|
| Status Bar | Document total | `filteredTotalWordCount` |
| Section Card | Section count | `SectionViewModel.wordCount` |
| Section Card | Goal progress | `wordCount` vs `wordGoal` |
| Filter Bar | Document goal progress | `filteredTotalWordCount` vs `documentGoal` |

#### Goal Colors

Word count colors indicate progress toward goals:

```swift
func goalColor(wordCount: Int, goal: Int, type: GoalType) -> Color {
    let ratio = Double(wordCount) / Double(goal)
    switch type {
    case .exact:
        // Green when within ±10%, yellow when close, red when far
    case .approx:
        // Green when ≥80%, yellow when 50-80%, gray below
    case .minimum:
        // Green when ≥100%, yellow when 80-100%, red below
    }
}
```

#### Section Status Persistence

Status changes from `StatusDot` are persisted immediately via a `.onChange(of: section.status)` modifier on `SectionCardView`. When the status value changes, `onSectionUpdated` fires, which calls `ContentView.updateSection()` to write the new status to the database. This ensures status survives zoom in/out and app restarts.

#### Zoom Mode Word Count Update

**Problem**: During zoom mode, ValueObservation is blocked by the `contentState` guard, preventing word count updates from reaching the UI.

**Solution**: Direct callback pattern bypasses ValueObservation:

```
Editor Content Changes
        ↓
SectionSyncService.syncZoomedSections()
        ↓
Database updated (word counts saved)
        ↓
onZoomedSectionsUpdated callback fired
        ↓
EditorViewState.refreshZoomedSections()
        ↓
Fetches from DB, updates sections array
        ↓
UI reflects new word counts
```

**Implementation**:
- `SectionSyncService.onZoomedSectionsUpdated`: Callback invoked after zoomed sections are saved
- `EditorViewState.refreshZoomedSections()`: Reads from database and updates in-memory sections
- Wired up in `ContentView.configureForCurrentProject()`

This ensures word counts update in real-time while editing zoomed sections, even though ValueObservation is blocked.

### SectionSyncService

> **Note:** `BlockSyncService` is now the primary sync mechanism for content. SectionSyncService retains auxiliary roles described below.

Responsible for legacy section sync, anchor injection/extraction, and bibliography marker management.

**Remaining Roles**:
- `injectSectionAnchors(markdown:sections:)` - Adds `<!-- @sid:UUID -->` for source mode
- `extractSectionAnchors(markdown:)` - Removes anchors, returns mappings
- `injectBibliographyMarker` - Adds `<!-- ::auto-bibliography:: -->` before bibliography header in source mode
- Legacy section table sync (dual-write for backward compatibility)

**Key Methods**:
- `contentChanged(_ markdown:)` - Debounced entry point (500ms)
- `syncContent(_ markdown:)` - Parses headers, reconciles with database
- `parseHeaders(from markdown:)` - Extracts section boundaries

**Reconciliation**: Uses `SectionReconciler` to compute minimal database changes (insert, update, delete) by comparing parsed headers against existing sections.

### Find Bar Architecture

The find bar provides native-style find and replace functionality using JavaScript APIs exposed by both editors.

**State Management** (`FindBarState.swift`):
- Observable state for visibility, search query, replace text, match counts
- Holds weak reference to active `WKWebView` for JavaScript calls
- Uses `focusRequestCount: Int` (not boolean) to trigger focus requests reliably

**Focus Request Pattern**: SwiftUI's `.onChange` requires actual value changes to fire. A boolean toggle (`true` → `false` → `true`) can be coalesced by SwiftUI. An incrementing counter always changes, guaranteeing the `.onChange` fires:

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
- `find(query, options)` - Start search, returns `{matchCount, currentIndex}`
- `findNext()` / `findPrevious()` - Navigate matches
- `replaceCurrent(text)` / `replaceAll(text)` - Replace operations
- `clearSearch()` - Remove highlights
- `getSearchState()` - Get current match info

### Content State Machine

`EditorContentState` prevents race conditions during complex transitions:

```swift
enum EditorContentState {
    case idle                 // Normal operation
    case zoomTransition       // Zooming in/out of a section
    case hierarchyEnforcement // Fixing header level violations
    case bibliographyUpdate   // Auto-bibliography being regenerated
    case editorTransition     // Switching between Milkdown ↔ CodeMirror
    case dragReorder          // During sidebar drag-drop reorder
}
```

**Guards**: SectionSyncService, BlockSyncService, and ValueObservation skip updates when `contentState != .idle`, preventing feedback loops.

**Cancellation Pattern**: `EditorViewState.currentPersistTask` stores the current persist task during drag-drop reorder. Rapid successive reorders cancel the previous persist task before starting a new one, preventing stale writes.

**Watchdog**: A `didSet` observer on `contentState` starts a 5-second watchdog Task whenever the state enters a non-idle value. If the state hasn't returned to `.idle` within 5 seconds, the watchdog force-resets it and cleans up associated state (e.g., `isZoomingContent`, pending continuations). This prevents permanently blocked ValueObservation if a transition is interrupted.

### Zoom Functionality

Double-clicking a sidebar section "zooms" into it:

1. **Zoom In** (block-based):
   - Finds the heading block, determines its sort-order range (from heading's sortOrder to next same/higher-level heading's sortOrder)
   - Filters blocks within that range from the database
   - Assembles markdown from the filtered blocks
   - Records `zoomedSectionIds` and `zoomedBlockRange`
   - Pushes content + block IDs to editor via `setContentWithBlockIds()`
   - No `fullDocumentBeforeZoom` needed — DB always has the complete document

2. **Zoom Out** (block-based):
   - Fetches ALL blocks from DB and assembles full document via `BlockParser.assembleMarkdown()`
   - No merge needed — BlockSyncService writes changes to DB during zoom
   - Clears zoom state (`zoomedSectionIds`, `zoomedBlockRange`)
   - Pushes full content + block IDs to editor

**Sync While Zoomed**: BlockSyncService continues its 300ms polling during zoom. Changes are written directly to the block table. The `zoomedBlockRange` on EditorViewState tells `pushBlockIds()` which blocks to filter for the editor.

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

GRDB's `ValueObservation` provides reactive updates. The observation now watches the **block table** (outline blocks only) instead of the sections table:

```swift
func startObserving(database: ProjectDatabase, projectId: String) {
    self.projectDatabase = database
    self.currentProjectId = projectId

    observationTask = Task {
        for try await outlineBlocks in database.observeOutlineBlocks(for: projectId) {
            guard !isObservationSuppressed else { continue }
            guard contentState == .idle else { continue }

            var viewModels = outlineBlocks.map { SectionViewModel(from: $0) }

            // Aggregate word counts for each heading block
            for i in viewModels.indices {
                if let wc = try? database.wordCountForHeading(blockId: viewModels[i].id) {
                    viewModels[i].wordCount = wc
                }
            }

            sections = viewModels
            recalculateParentRelationships()
            onSectionsUpdated?()
        }
    }
}
```

**Key details**:
- `observeOutlineBlocks(for:)` filters to heading + pseudo-section blocks only
- `SectionViewModel(from: Block)` converts block data to sidebar view models
- `wordCountForHeading(blockId:)` aggregates word counts from body blocks under each heading
- `projectDatabase` and `currentProjectId` are stored on EditorViewState for use during zoom and reorder operations

**Suppression**: `isObservationSuppressed` is set during drag-drop operations to prevent database updates from overwriting in-progress reordering.

### Section Drag-Drop Reordering

The sidebar supports drag-drop reordering with hierarchy preservation:

1. **Single Section**: Section moves; orphaned children are promoted to parent's level
2. **Subtree Drag**: Section + all descendants move together; levels shift by delta

**Process** (block-based):
1. Set `contentState = .dragReorder`
2. Cancel `currentPersistTask` (from any rapid preceding reorder)
3. Reorder sections array in memory for immediate visual feedback
4. Recalculate parent relationships and enforce hierarchy constraints
5. Rebuild document content via `rebuildDocumentContentStatic()` (static method, no state mutation)
6. Push content to editor
7. Persist atomically via `reorderAllBlocks()` — moves body blocks with their headings, applies heading updates (markdownFragment + headingLevel) in a single write transaction
8. Fire-and-forget `persistReorderedBlocks_legacySections()` for section table dual-write
9. Push block IDs to editor via `blockSyncService.pushBlockIds()`
10. Return to `contentState = .idle`

**Cancellation**: `currentPersistTask` on `EditorViewState` stores the async persist task. Rapid successive reorders cancel the previous task before starting a new one, preventing stale sort orders from being written.

### WebView Communication

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
confirmBlockIds(mapping)  // Confirm temp→permanent ID mapping

// --- UI ---
setFocusMode(enabled)    // Toggle paragraph dimming (WYSIWYG only)
getStats()               // Returns {words, characters}
scrollToOffset(n)        // Scroll to character offset
setTheme(css)            // Apply theme CSS variables
```

**Polling**: Two polling loops run concurrently:
- **Block polling** (300ms): `BlockSyncService` polls `hasBlockChanges()` → `getBlockChanges()` for structural content sync
- **Content polling** (500ms): Reads `getContent()` for content binding + annotation sync via `SectionSyncService`

**Feedback Prevention**: `isSettingContent` flag prevents feedback loops when Swift pushes content to editor. `resetAndSnapshot(doc)` must be called after any `setContent()` to prevent false change waves. `isSyncSuppressed` on BlockSyncService gates polling during drag operations and block ID pushes.

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

-- Block-based content (one row per structural element)
CREATE TABLE block (
    id TEXT PRIMARY KEY,
    projectId TEXT NOT NULL REFERENCES project(id),
    parentId TEXT,                -- For nested blocks (list items in lists)
    sortOrder DOUBLE NOT NULL,   -- Fractional for easy insertion
    blockType TEXT NOT NULL,     -- paragraph, heading, bulletList, orderedList,
                                 -- listItem, blockquote, codeBlock, horizontalRule,
                                 -- sectionBreak, bibliography, table, image
    textContent TEXT NOT NULL,   -- Plain text (search, word count)
    markdownFragment TEXT NOT NULL, -- Original markdown for this block
    headingLevel INTEGER,        -- 1-6 for headings, NULL otherwise
    status TEXT,                 -- draft, review, final, cut (headings only)
    tags TEXT,                   -- JSON array string
    wordGoal INTEGER,
    goalType TEXT DEFAULT 'approx',
    wordCount INTEGER DEFAULT 0,
    isBibliography BOOLEAN DEFAULT FALSE,
    isPseudoSection BOOLEAN DEFAULT FALSE,
    createdAt TEXT NOT NULL,
    updatedAt TEXT NOT NULL
);

-- Full markdown content (one row per project, kept in sync)
CREATE TABLE content (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES project(id),
    markdown TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

-- Legacy section table (dual-write for backward compatibility)
CREATE TABLE section (
    -- ... (same as before, populated by persistReorderedBlocks_legacySections)
);

-- User preferences per project
CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
```

### Content Model

One project = many blocks, ordered by `sortOrder`. Headers within the block sequence define the outline structure. The `content` table stores the assembled markdown string and is kept in sync.

```markdown
# Book Title          → block(type=heading, level=1, sortOrder=1.0)
                      → block(type=paragraph, sortOrder=2.0)
## Chapter 1          → block(type=heading, level=2, sortOrder=3.0)
Content here...       → block(type=paragraph, sortOrder=4.0)
```

The `block` table is the primary content store. `observeOutlineBlocks()` filters to heading + pseudo-section blocks for fast sidebar rendering. Body block word counts are aggregated per heading via `wordCountForHeading(blockId:)`.

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
- Comprehensive distraction-free writing experience
- Paragraph dimming (dims non-current paragraph) via ProseMirror Decorations
- Works in WYSIWYG mode only (CodeMirror ignores focus mode)

**Focus Mode Behavior:**
- **Enter** (Cmd+Shift+F): Captures pre-focus state → enters full screen → hides sidebars with animation → collapses all annotations → enables paragraph highlighting → shows toast notification (auto-dismiss 3s)
- **During**: User can manually toggle sidebars/annotations; changes are temporary
- **Exit** (Esc or Cmd+Shift+F): Exits full screen only if focus mode entered it → restores sidebar visibility from snapshot → restores annotation display modes → disables paragraph highlighting
- **Persistence**: Focus mode state persists via UserDefaults; restored on next launch after 500ms window stabilization
- **Implementation**: `FullScreenManager` controls NSWindow full screen; `FocusModeSnapshot` captures pre-state; NSEvent monitor handles Esc key when WKWebView has focus

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
- [x] Cmd+Shift+F enters focus mode
- [x] Esc or Cmd+Shift+F exits focus mode
- [x] Full screen activates on enter (if not already)
- [x] Full screen exits only if focus mode entered it
- [x] Both sidebars hidden with animation on enter
- [x] Sidebars restored to pre-focus state on exit
- [x] Annotations collapsed on enter, restored on exit
- [x] Toolbar and status bar hidden in focus mode
- [x] Toast notification appears on enter (auto-dismiss 3s)
- [x] Non-current paragraphs dimmed in WYSIWYG mode
- [x] Focus mode persists across app restarts
- [x] Manual sidebar toggles work during focus mode (temporary)

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
