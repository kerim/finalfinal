# Plan: Refactor docs/ Folder (Hub-and-Spoke Model)

## Context

The `docs/` folder has grown organically. Two files are too large for effective AI context (LESSONS-LEARNED.md at 1,059 lines, design.md at 908 lines). Folder naming is inconsistent ("claude setup", "Development Guide"). Some files overlap. The goal is a **hub-and-spoke model** optimized for Claude Code: a central INDEX.md pointing to focused sub-documents, each under ~300 lines.

**Scope:** docs/ folder only. No changes to CLAUDE.md, README.md, KARMA.md, or any files outside docs/.

---

## Target Structure

```
docs/
├── INDEX.md                              (NEW - hub, ~80 lines)
├── roadmap.md                            (NEW - phases + future plans, ~150 lines)
├── architecture/
│   ├── overview.md                       (NEW - from design.md §Overview–§Current Architecture)
│   ├── block-system.md                   (MOVE block-architecture.md, absorb design.md §Block overlap)
│   ├── data-model.md                     (NEW - from design.md §Project Model + §Data Model)
│   ├── editor-communication.md           (NEW - from design.md §WebView + §Bibliography + §Find Bar)
│   ├── state-machine.md                  (NEW - from design.md §Content State + §Zoom + §Hierarchy)
│   └── word-count.md                     (NEW - from design.md §Word Count Architecture)
├── guides/
│   ├── running-tests.md                  (MOVE from "Development Guide/")
│   ├── testing-architecture.md           (MOVE from design/testing-implementation.md)
│   └── hooks.md                          (MOVE from "claude setup/")
├── lessons/
│   ├── prosemirror-milkdown.md           (SPLIT from LESSONS-LEARNED §ProseMirror + §Remark + §Slash + §Empty)
│   ├── codemirror.md                     (SPLIT from LESSONS-LEARNED §CodeMirror)
│   ├── swiftui-webkit.md                 (SPLIT from LESSONS-LEARNED §SwiftUI/WebKit + §Event + §Perf + §Compositor + §DataFlow)
│   ├── grdb-database.md                  (SPLIT from LESSONS-LEARNED §ValueObservation + §Configuration)
│   ├── zoom-patterns.md                  (SPLIT from LESSONS-LEARNED §Zoom Feature + §Dual Editor)
│   ├── block-sync-patterns.md            (SPLIT from LESSONS-LEARNED §Pseudo-Sections + §Sidebar Zoom IDs)
│   └── misc-patterns.md                  (SPLIT from LESSONS-LEARNED §JavaScript + §Cursor + §Build + §XeTeX)
├── findings/
│   ├── bibliography-block-migration.md   (RENAME bibliography-zoom-bugs.md)
│   ├── project-switch-css-layout.md      (RENAME, drop "-bug")
│   ├── project-switch-source-mode.md     (RENAME, drop "-bugs")
│   ├── sidebar-cm-zoom.md               (RENAME, shorter)
│   └── cursor-mapping-postmortem.md      (MERGE deferred-cursor-issues + precise-table-cursor-mapping)
├── deferred/
│   ├── block-sync-robustness.md          (KEEP as-is)
│   ├── contentstate-guard-rework.md      (RENAME, lowercase)
│   ├── per-citation-author-suppression.md (KEEP as-is)
│   └── tagging-keyboard-nav.md           (RENAME, drop phase prefix)
└── plans/                                (KEEP empty)
```

**Deleted after content is migrated:**
- `docs/design/design.md` (split into architecture/* + roadmap.md)
- `docs/findings/LESSONS-LEARNED.md` (split into lessons/*)
- `docs/deferred/deferred-cursor-issues.md` (merged into findings/cursor-mapping-postmortem.md)
- `docs/deferred/precise-table-cursor-mapping.md` (merged into findings/cursor-mapping-postmortem.md)

**Empty dirs removed:** `docs/claude setup/`, `docs/Development Guide/`, `docs/design/`

---

## Content Mapping

### Splitting design.md (908 lines) → 6 architecture files + roadmap

| New File | Source Sections (by line) | Est. Lines |
|----------|--------------------------|------------|
| architecture/overview.md | §Overview (3–13), §Architecture (15–34), §Current Architecture (36–493) minus data model/word count | ~160 |
| architecture/data-model.md | §Project Model (495–515), §Data Model (516–585) | ~130 |
| architecture/editor-communication.md | WebView communication, source mode, bibliography architecture, find bar, SectionSyncService sections from within §Current Architecture | ~180 |
| architecture/state-machine.md | Content state machine, zoom, hierarchy constraints, ValueObservation reactivity, drag-drop reordering sections | ~200 |
| architecture/word-count.md | Word count architecture section (calculation, goals, UI, zoom mode) | ~120 |
| architecture/block-system.md | Current block-architecture.md (197 lines) + brief overlap from design.md | ~200 |
| roadmap.md | §Phase 1 goals (623–842, trimmed), §Phase 0.2 (844–875), §Future Phases (876–884), §Lessons from AW (885–900), §Design Decisions (901–908) | ~150 |

### Splitting LESSONS-LEARNED.md (1,059 lines) → 7 lessons files

| New File | Source Sections (by ## header) | Est. Lines |
|----------|-------------------------------|------------|
| lessons/prosemirror-milkdown.md | §ProseMirror/Milkdown (7–56), §Milkdown Remark Plugins (213–258), §Milkdown SlashProvider (269–306), §Milkdown Empty Content (476–522) | ~230 |
| lessons/codemirror.md | §CodeMirror (348–472) | ~120 |
| lessons/swiftui-webkit.md | §SwiftUI/WebKit (59–78), §macOS Event Handling (138–163), §Performance (166–210), §SwiftUI Data Flow (309–345), §WKWebView Compositor (1113–1153) | ~150 |
| lessons/grdb-database.md | §GRDB ValueObservation (525–627), §GRDB Configuration (630–680) | ~150 |
| lessons/zoom-patterns.md | §Zoom Feature (736–965), §Dual Editor Mode Content Update (969–1003) | ~200 |
| lessons/block-sync-patterns.md | §Pseudo-Sections (1007–1068), §Sidebar Zoom IDs (1072–1110) | ~120 |
| lessons/misc-patterns.md | §JavaScript (81–89), §Cursor Position Mapping (93–135), §Build (261–266), §XeTeX (683–733) | ~100 |

### Merging cursor mapping files → findings/cursor-mapping-postmortem.md

- Base: `deferred/precise-table-cursor-mapping.md` (102 lines) — full post-mortem on abandoned approach
- Add: `deferred/deferred-cursor-issues.md` §Escaped Asterisks section (separate issue, still deferred)
- Update status: mark table cursor as "Abandoned" (was "In Progress v0.1.25")

---

## Implementation Steps

### Step 1: Create new directories
- `docs/architecture/`, `docs/guides/`, `docs/lessons/`

### Step 2: Move/rename files with no content changes
- `Development Guide/running-tests.md` → `guides/running-tests.md`
- `design/testing-implementation.md` → `guides/testing-architecture.md`
- `claude setup/hooks.md` → `guides/hooks.md`
- `design/block-architecture.md` → `architecture/block-system.md`
- Rename 4 findings files (shorter names, drop "-bug"/"-bugs")
- Rename 2 deferred files (lowercase, drop phase prefix)

### Step 3: Split LESSONS-LEARNED.md → 7 lessons/ files
- Extract each topic group with its header and content
- Add a 1-line header to each file: "Patterns for [topic]. Consult before writing related code."
- Add cross-references to findings/ where a lesson originated from a bug investigation
- Verify no content is lost
- Delete LESSONS-LEARNED.md

### Step 4: Split design.md → architecture/ files + roadmap.md
- Extract each section group per the mapping above
- In overview.md, replace detailed sections with 1-sentence summary + link to spoke
- Drop the "Files to Create" list from Phase 1 (already implemented, no future value)
- Keep Phase 1 verification checklist in roadmap.md
- Verify no content is lost
- Delete design.md

### Step 5: Merge cursor mapping files → findings/cursor-mapping-postmortem.md
- Combine content, update status markers
- Delete the two source files from deferred/

### Step 6: Create INDEX.md
- Written last so all links can be verified
- 1-2 sentence description per spoke, grouped by category
- Brief intro explaining hub-and-spoke structure

### Step 7: Clean up empty directories
- Remove `docs/claude setup/`, `docs/Development Guide/`, `docs/design/`

### Step 8: Verify
- Every original file's content exists in the new structure
- No file exceeds ~300 lines
- All INDEX.md links resolve to real files

---

## Verification

1. **Content completeness:** Diff total line count before/after (should be roughly equal, minus the deleted "Files to Create" list from design.md)
2. **No broken references:** Grep INDEX.md links against actual file paths
3. **Size check:** No spoke file exceeds 300 lines
4. **Git diff review:** Confirm no content was silently dropped during splits
