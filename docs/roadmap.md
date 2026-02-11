# Roadmap

Phase planning and design decisions.

---

## Phase 1: MVP (Editor + Outline) -- Complete

### Goals
- Working editor with both modes (Milkdown WYSIWYG + CodeMirror 6 source)
- Header-based outline sidebar with preview text and word counts
- Focus mode (paragraph dimming)
- Color scheme theming
- SQLite persistence
- Basic document management

### Verification Checklist

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

### 0.2.0 -- UI Enhancements & New Features
- Sidebar header level filter (dropdown to show H1-H2, H1-H3, etc.)
- Hideable editor toolbar (Bold, Italic, Link, Headers)
- Expanded appearance settings (font family, size, line spacing, line numbers)
- Find & Replace (Cmd+F, Cmd+Shift+F)
- Option-click header in editor -> zoom to section

### 0.2.1 -- Editor & Theme Polish
- Editor load time optimization
- Typography improvements (font, line-height, paragraph spacing)
- Theme consistency audit (all windows/panels)
- Bibliography card threading fix

### 0.2.2 -- Citation System Polish
- Fix /cite bug with `?` characters
- Citation picker positioning
- Multi-citation entry UI
- Research Zotero native picker
- PDF export citation formatting

### 0.2.3 -- Foundation & Stability
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
