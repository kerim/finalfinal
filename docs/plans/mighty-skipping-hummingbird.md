# Plan: Safely Merge Zotero Branch

## Summary

Resolve merge conflict in `project.pbxproj` by keeping entries from **both** branches. The conflict is simple: main added `ProjectRepairService`, zotero added `ZoteroService` - both should be kept.

## Current State

- **Conflict file:** `final final.xcodeproj/project.pbxproj` (2 conflict markers)
- **Auto-merged files:** 25 files merged cleanly (all Zotero citation features + existing code)
- **No code logic conflicts** - only Xcode project structure

## Resolution Steps

### Step 1: Resolve project.pbxproj Conflicts

Edit the conflicted file to keep **both** entries at each conflict location:

**Conflict 1 (Build file references ~line 52-56):**
```
Keep BOTH:
- 95DA16BD31941C5CD424F43D /* ProjectRepairService.swift in Sources */
- 9E8D8F33D47F7001D135296C /* ZoteroService.swift in Sources */
```

**Conflict 2 (File references ~line 144-148):**
```
Keep BOTH:
- E2BEC2E8F18731A82D861A36 /* ProjectRepairServiceTests.swift */
- E16909CB53D2BCFD8CC1B0BF /* ZoteroService.swift */
```

Remove all `<<<<<<<`, `=======`, and `>>>>>>>` markers.

### Step 2: Stage the Resolution

```bash
git add "final final.xcodeproj/project.pbxproj"
```

### Step 3: Verify Build

```bash
# Regenerate project from yml (recommended since xcodegen is used)
xcodegen generate

# Build to verify
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

### Step 4: Complete the Merge

```bash
git commit -m "Merge branch 'zotero': add citation integration

Resolves project.pbxproj conflict by keeping entries for both
ProjectRepairService (from main) and ZoteroService (from zotero).

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

## Verification

1. App launches without crash
2. Citation features work (if Zotero + BBT is running):
   - `/cite` command opens search
   - Citations render inline
3. Project integrity check still works (ProjectRepairService)

## Alternative: Regenerate with xcodegen

Since this project uses `xcodegen`, if manual conflict resolution fails:

```bash
# Abort current merge
git merge --abort

# Create clean state
git checkout main
xcodegen generate
git stash  # save clean project.pbxproj

# Re-attempt merge
git merge zotero -m "zotero"

# Use xcodegen to regenerate (overwrites conflicts)
xcodegen generate

# Stage and commit
git add .
git commit -m "Merge zotero branch with regenerated project"
```

## Files Changed by This Merge

| Category | Files |
|----------|-------|
| **New Swift** | CSLItem.swift, ZoteroService.swift, BibliographySyncService.swift |
| **New Web** | citation-plugin.ts, citation-search.ts, citeproc-engine.ts, chicago-author-date.csl, locales-en-US.xml |
| **Modified** | MilkdownEditor.swift, ProjectDatabase.swift, Section.swift, EditorViewState.swift, ContentView.swift, OutlineSidebar.swift, and more |

## Recommended Approach

**Use the xcodegen regeneration approach** (the alternative) - it's cleaner and avoids manual editing of the complex pbxproj file. Since you use xcodegen, the project file can always be regenerated from `project.yml`.
