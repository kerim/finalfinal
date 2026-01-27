# Deferred: Phase 1.6c - Tagging & Keyboard Navigation

**Deferred from:** Phase 1.6d planning (2026-01-27)
**Reason:** Focus on zoom sync and header enforcement first

---

## Feature 1: Tag Input Enhancement

### Problem

Currently tags are stored and displayed but there's no convenient way to add/edit them.

### Proposed Approach

Add an inline tag editor that appears when clicking the tag area:
- Comma-separated input field
- Autocomplete from existing tags in project
- Pressing Enter saves and dismisses

### Files to Modify

- `SectionCardView.swift` - Add tag editing popover/inline editor
- `SectionSyncService.swift` - Add tag persistence

---

## Feature 2: Keyboard Navigation

### Problem

No keyboard navigation in the sidebar currently.

### Proposed Approach

- Arrow keys to navigate sections
- Enter to zoom into selected section
- Escape to zoom out
- Space to toggle expand/collapse (if hierarchical view)

### State Changes

Add `selectedSectionId` to track keyboard focus separate from zoom.

### Files to Modify

- `OutlineSidebar.swift` - Add keyboard handling
- `EditorViewState.swift` - Add selectedSectionId

---

## Notes

These features are lower priority than editor-sidebar sync. Can be revisited after Phase 1.6d is complete.
