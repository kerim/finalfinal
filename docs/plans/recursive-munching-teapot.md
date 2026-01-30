# Phase 0.2 — Stabilization & Production Readiness

**Version**: 0.2.0
**Goal**: Polish the alpha app for daily use, fix bugs, improve UX

---

## Version Update

Update version from 0.1.87 to 0.2.0 in:
- `project.yml` (CURRENT_PROJECT_VERSION)
- `web/package.json` (version)
- `README.md` (Version line)

---

## Phase 0.2.0 — UI Enhancements & New Features

### 0.2.0.1 Sidebar Header Level Filter
- Add dropdown/segmented control to filter sidebar by header level (show H1-H2, H1-H3, etc.)
- Helps see cleaner document structure for long documents
- Filter state persists per project

### 0.2.0.2 Editor Toolbar (Hideable)
- Formatting buttons: Bold, Italic, Link, Headers
- Toggle visibility via menu/keyboard shortcut
- Toolbar state persists in preferences

### 0.2.0.3 Appearance Settings Panel Expansion
Current panel exists but needs more options:
- Default font family
- Font size
- Line spacing
- CodeMirror line numbering toggle
- Settings persist globally

### 0.2.0.4 Find & Replace
- Cmd+F for Find
- Cmd+Shift+F or Cmd+Option+F for Find & Replace
- Works in both editor modes
- Highlight matches in document

### 0.2.0.5 Option-Click Header → Zoom
- Option-click on a header in the editor zooms to that section
- Matches existing double-click behavior in sidebar
- Complete the Phase 1 spec item

### 0.2.0.6 General UI Polish
- Review spacing, alignment, visual consistency

---

## Phase 0.2.1 — Editor & Theme Polish

### 0.2.1.1 Editor Load Time
- Profile and optimize initial editor load
- Consider lazy loading or preloading strategies

### 0.2.1.2 Main Editor Typography
- Improve default font, size, line-height, paragraph spacing
- Ensure readability for long-form writing

### 0.2.1.3 Theme Inconsistencies
- Fix version control window not respecting themes
- Audit all windows/panels for theme compliance

### 0.2.1.4 Bibliography Card Threading
- Bibliography card shows but isn't threaded with main document until zoom in/out
- Fix so bibliography is properly connected on initial load

---

## Phase 0.2.2 — Citation System Polish

### 0.2.2.1 /cite Bug with `?` Characters
- Investigate and fix /cite breaking before `?` characters

### 0.2.2.2 Citation Picker Positioning
- Fix picker appearing under right panel
- Ensure picker appears near cursor/centered properly

### 0.2.2.3 Multi-Citation Entry UI
- Allow selecting multiple citations in one action
- Common academic workflow: (Smith 2020; Jones 2021)

### 0.2.2.4 Research: Zotero Native Picker
- Investigate if Zotero's citation dialog can be invoked
- Document findings, implement if feasible
- Fall back to polished current system if not

### 0.2.2.5 PDF Export Citation Formatting
- In-text citations not formatted correctly in PDF export
- Ensure citations render properly with CSL styles

---

## Phase 0.2.3 — Foundation & Stability

### 0.2.3.1 Data Integrity Verification
- Test project corruption scenarios
- Add recovery/repair mechanisms if needed
- Validate database integrity on open

### 0.2.3.2 Error Handling Framework
- Structured error logging
- User-facing error messages (not crashes)
- Error recovery where possible

### 0.2.3.3 Performance Monitoring
- Establish baseline metrics
- Add instrumentation for key operations
- Identify bottlenecks

### 0.2.3.4 Structured Logging
- Debug logging for troubleshooting
- Log levels (error, warning, info, debug)
- Log rotation/cleanup

---

## Future Phases (Preserved from Design Doc)

### Phase 0.3 — Reference Pane (formerly Phase 5)
- Finder-style folders for PDFs, images, docs
- Reference files stored in `.ff` package
- Integration with editor (drag-drop references)

### Phase 0.4 — Sync (formerly Phase 6)
- CloudKit or Cloudflare DO
- Cross-device sync
- Conflict resolution

---

## Verification

### Phase 0.2.0
- [ ] Header level filter works, state persists
- [ ] Toolbar shows/hides, state persists
- [ ] Appearance settings (font, size, spacing, line numbers) all work
- [ ] Find works (Cmd+F)
- [ ] Replace works
- [ ] Option-click header zooms to section

### Phase 0.2.1
- [ ] Editor loads noticeably faster
- [ ] Typography looks good for long-form writing
- [ ] All windows respect current theme
- [ ] Bibliography card threaded on first load

### Phase 0.2.2
- [ ] /cite works before `?` characters
- [ ] Citation picker positioned correctly
- [ ] Can add multiple citations at once
- [ ] PDF export shows formatted citations

### Phase 0.2.3
- [ ] No data loss after extended use
- [ ] Errors show user-friendly messages
- [ ] Logs available for debugging

---

## Files to Modify

### Version Update
- `project.yml`
- `web/package.json`
- `README.md`

### Phase 0.2.0
- `Views/Sidebar/OutlineSidebar.swift` (header filter)
- `Views/EditorToolbar.swift` (new file)
- `Views/Preferences/AppearancePreferencesPane.swift`
- `Editors/MilkdownEditor.swift` (find/replace, option-click)
- `Editors/CodeMirrorEditor.swift` (find/replace)
- `web/milkdown/src/main.ts`
- `web/codemirror/src/main.ts`

### Phase 0.2.1
- `Theme/` files
- `web/*/src/styles.css`
- Editor initialization code

### Phase 0.2.2
- Citation plugin files
- `Services/ZoteroService.swift`
- `Services/ExportService.swift`
- `web/milkdown/src/citation-plugin.ts`

### Phase 0.2.3
- `Services/ProjectRepairService.swift`
- `Models/Database.swift`
- New logging infrastructure
