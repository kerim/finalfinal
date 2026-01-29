# Plan: Update Documentation for Annotations 1.7 Completion

## Overview

Mark Phase 1.7 (Annotations) as complete in the project design document and README.

## Changes Required

### 1. `README.md`

**Move annotations from "Planned Features" to "Implemented Features" table:**

Add row to Implemented Features:
```
| Annotations | Task, Comment, Reference markers with inline/collapsed modes and panel view |
```

Update Planned Features table to remove annotations from Phase 2, renumber remaining phases.

### 2. `docs/design.md`

**Add Phase 1.7 section after 1.6 (Outline Sidebar):**

```markdown
#### 1.7 Annotations
- Annotation types: Task, Comment, Reference
- Slash commands: `/task`, `/comment`, `/reference`
- Display modes: inline (full text) and collapsed (marker symbols)
- Annotation panel for sidebar viewing
- Task completion tracking
- Highlight span support (associate annotations with text)
- Storage as HTML comments: `<!-- ::type:: text -->`
```

**Update Future Phases table:** Remove "Annotations" from Phase 2, renumber phases.

**Add to Verification checklist:**
```markdown
**Annotations:**
- [x] Can create annotations via /task, /comment, /reference
- [x] Annotations display inline and collapsed modes
- [x] Annotation panel shows all annotations
- [x] Tasks can be marked complete
```

### 3. `CLAUDE.md`

**Add to Completed Phases list:**
```markdown
- [x] **Phase 1.7** - Annotations (task, comment, reference) (2026-01-29)
```

## Files to Modify

1. `/Users/niyaro/Documents/Code/final final/README.md`
2. `/Users/niyaro/Documents/Code/final final/docs/design.md`
3. `/Users/niyaro/Documents/Code/final final/CLAUDE.md`

## Verification

1. Read each file after editing to confirm changes are correct
2. Ensure phase numbering is consistent across all documents
