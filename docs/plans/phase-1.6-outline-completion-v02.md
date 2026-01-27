# Phase 1.6a/b/c Plan: Outline Sidebar Completion (v02)

## Overview

Phase 1.6 is functionally complete but has gaps that need addressing. This plan covers three sub-phases:

- **Phase 1.6a**: Fix current bugs (scroll, slash command, word counts) **COMPLETE v0.1.53**
- **Phase 1.6b**: Editor → Sidebar sync (enables undo/redo)
- **Phase 1.6c**: Tagging and keyboard navigation

---

## Phase 1.6a Status: COMPLETE (v0.1.53)

| Issue | Status | Notes |
|-------|--------|-------|
| 1. Milkdown Scroll | **DONE** | Uses window.scrollTo with coordsAtPos |
| 2. Slash Commands | **DONE** | Using @milkdown/plugin-slash with custom UI |
| 3. Section Break Parsing | **DONE** | Fixed remark plugin order + unist-util-visit |
| 4. Word Count | **DONE** | Created `MarkdownUtils.swift` |
| 5. Demo Content | **DONE** | Expanded in `ContentView.swift` |

### Key Fix: Section Break Parsing (v0.1.53)

**Problem:** `<!-- ::break:: -->` rendered as § when inserted via `/break` but not when loaded from markdown.

**Root Cause:** Milkdown's `filterHTMLPlugin` removes HTML nodes before custom remark plugins run.

**Solution:**
1. Register `sectionBreakPlugin` BEFORE `commonmark` preset
2. Use `unist-util-visit` for proper tree traversal
3. Transform HTML nodes to custom type before filtering

**Files changed:**
- `web/milkdown/src/section-break-plugin.ts` - Refactored remark plugin
- `web/milkdown/src/main.ts` - Changed plugin order
- `web/milkdown/package.json` - Added `unist-util-visit` dependency

### Phase 1.6a Verification

- [x] Single-click scroll positions header ~100px from top in Milkdown
- [x] Single-click scroll works consistently in CodeMirror
- [x] `/break` command works in Milkdown (inserts `<!-- ::break:: -->`)
- [x] `/h1`, `/h2`, `/h3` commands work in Milkdown
- [x] Section breaks parse correctly when loading markdown
- [x] Word counts exclude markdown symbols
- [x] Word counts match between raw text and formatted view
- [x] Default document has sufficient content for scroll testing

---

## Phase 1.6b: Editor → Sidebar Sync (Bidirectional)

### Overview

Currently sync is one-way: Sidebar changes → Editor rebuild. For undo/redo to work, we need: Editor changes → Sidebar update.

### Architecture

```
┌─────────────┐         ┌──────────────────┐         ┌─────────────┐
│   Editor    │ ──────> │ SectionSyncService│ ──────> │   Sidebar   │
│ (WebView)   │ <────── │                  │ <────── │   (SwiftUI) │
└─────────────┘         └──────────────────┘         └─────────────┘
     │                         │                           │
     │  content change         │  parse & diff             │  drag-drop
     │  (polling/callback)     │  sections                 │  reorder
     └─────────────────────────┴───────────────────────────┘
```

### Implementation Steps

#### Step 1: Detect Editor Content Changes

**Files to modify:**
- `final final/Editors/MilkdownEditor.swift`
- `final final/Editors/CodeMirrorEditor.swift`
- `final final/ViewState/EditorViewState.swift`

**Current state:** Editors poll `getContent()` every 500ms to detect changes.

**Enhancement:** When content changes, trigger section re-parse.

#### Step 2: Section Diffing Algorithm

**Files to create:**
- `final final/Services/SectionDiffer.swift`

**Purpose:** Match new parsed sections to existing sections to preserve metadata.

#### Step 3: Handle Section Operations

**Scenarios to handle:**
1. User adds heading in editor → New section appears in sidebar
2. User deletes heading in editor → Section removed from sidebar
3. User changes heading text → Section title updates
4. User changes heading level → Section level updates
5. User uses undo → Sections revert to previous state

#### Step 4: Throttle Re-parsing

Debounce content changes to avoid expensive re-parsing on every keystroke.

#### Step 5: Persist Section Metadata

Save section metadata (goals, status, tags) to database when changed.

### Phase 1.6b Verification

- [ ] Adding `# New Section` in editor creates section in sidebar
- [ ] Deleting a header removes section from sidebar
- [ ] Changing header text updates section title
- [ ] Changing `##` to `###` updates section level and hierarchy
- [ ] Cmd+Z (undo) in editor reverts sidebar to previous state
- [ ] Section metadata (goals, status) preserved through edits
- [ ] No performance lag during typing (debounce works)
- [ ] Drag-drop in sidebar still works after bidirectional sync

---

## Phase 1.6c: Tagging and Keyboard Navigation

### Tag Features

- Tag filtering in sidebar
- Tag autocomplete when entering tags

### Keyboard Navigation

| Key | Action |
|-----|--------|
| ↑/↓ | Move selection between sections |
| Enter | Scroll to selected section |
| Space | Toggle expand/collapse (if has children) |
| Tab | Indent section (increase level) |
| Shift+Tab | Outdent section (decrease level) |
| Delete/Backspace | Delete section (with confirmation) |
| Cmd+↑/↓ | Move section up/down in list |

### Phase 1.6c Verification

- [ ] Tag chips appear in filter bar
- [ ] Clicking tag filters to sections with that tag
- [ ] Multiple tags can be selected (OR filter)
- [ ] Tag + status filter combines correctly (AND)
- [ ] Tag autocomplete shows existing tags
- [ ] New tags can be created
- [ ] Arrow keys navigate between sections
- [ ] Enter scrolls to selected section
- [ ] Tab/Shift+Tab changes section level
- [ ] Delete removes section (with confirmation)

---

## Implementation Order

1. **Phase 1.6a** (bug fixes) - **COMPLETE v0.1.53**
2. **Phase 1.6b** (bidirectional sync) - Core functionality for undo/redo
3. **Phase 1.6c** (polish) - Nice-to-have features

## Dependencies Added

| Package | Version | Purpose |
|---------|---------|---------|
| `unist-util-visit` | ^5.0.0 | Tree traversal for remark plugins |
