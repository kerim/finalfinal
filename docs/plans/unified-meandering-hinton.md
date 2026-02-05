# Safe Merge Plan: zoom → main

## Summary

The `zoom` branch contains a significant architectural rewrite moving to a **block-based schema**. This plan ensures a safe merge with proper conflict resolution and verification.

### Branch Status
- **Common ancestor**: `52b87ea` (linted code and removed debugging)
- **Main branch**: 2 commits ahead (plan files + documentation updates)
- **Zoom branch**: 9 commits ahead (block-based architecture + bug fixes)
- **Scope**: 47 files changed, +7,269/-610 lines

### Key Architectural Changes in Zoom
1. **New Block model** - granular paragraph-level tracking vs section-level
2. **Block ID plugins** - stable UUIDs for each block in editor
3. **Block sync service** - structured change detection vs full document reparse
4. **Source mode plugin** - dual-appearance editing (WYSIWYG syntax decorations)
5. **Double sortOrder** - fractional ordering to prevent cascading reorders

---

## Pre-Merge Preparation

### Step 1: Create Safety Backup
```bash
cd "/Users/niyaro/Documents/Code/final final"
git stash --include-untracked  # Save any uncommitted work
git tag backup-before-zoom-merge  # Safety tag
```

### Step 2: Verify Both Branches Build
Test main branch:
```bash
cd "/Users/niyaro/Documents/Code/final final"
cd web && pnpm build && cd ..
xcodegen generate
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

Test zoom branch:
```bash
cd "/Users/niyaro/Documents/Code/final final development/zoom"
cd web && pnpm build && cd ..
xcodegen generate
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

---

## Merge Strategy

**Recommended: Merge zoom INTO main** (not the reverse)

The zoom branch is the feature branch with significant new work. Main has minor additions (plan files, docs) that are easy to preserve.

### Step 3: Create Test Merge Branch
```bash
cd "/Users/niyaro/Documents/Code/final final"
git checkout -b test/zoom-merge main
git merge zoom
```

---

## Expected Conflicts & Resolution

### HIGH PRIORITY (Core Architecture)

| File | Resolution Strategy |
|------|---------------------|
| `Models/Database+CRUD.swift` | Keep zoom's version; main's changes were minor |
| `Services/SectionSyncService.swift` | Keep zoom's version; contains block-aware refactoring |
| `Services/OutlineParser.swift` | Keep zoom's version; has parsing improvements |
| `ViewState/EditorViewState.swift` | Keep zoom's version; has state machine improvements |
| `Editors/MilkdownEditor.swift` | Keep zoom's version; has block API calls |
| `Editors/CodeMirrorEditor.swift` | Keep zoom's version; has anchor handling |
| `Views/ContentView.swift` | Keep zoom's version; has layout changes |

### MEDIUM PRIORITY (Configuration)

| File | Resolution Strategy |
|------|---------------------|
| `project.yml` | Merge: take higher version number |
| `web/package.json` | Merge: take higher version number |
| `web/pnpm-lock.yaml` | Regenerate after merge with `pnpm install` |
| `project.pbxproj` | Regenerate with `xcodegen generate` |

### LOW PRIORITY (Documentation)

| File | Resolution Strategy |
|------|---------------------|
| `docs/design.md` | Keep zoom's version (more comprehensive) |
| `docs/LESSONS-LEARNED.md` | Keep zoom's version |
| `README.md` | Merge both: zoom has content updates, main has table restructuring |
| `getting-started.md` | Keep zoom's version |

### MAIN-ONLY FILES (Preserve)

These files only exist in main and should be preserved:
- `docs/plans/foamy-launching-hopper.md`
- `docs/plans/jazzy-hopping-koala.md`
- `docs/plans/sleepy-waddling-lobster.md`
- `docs/plans/swift-puzzling-manatee.md` → renamed to `block-based-architecture.md` in zoom

### ZOOM-ONLY FILES (Accept)

New files from zoom to accept:
- `Models/Block.swift` - new block model
- `Models/Database+Blocks.swift` - block database operations
- `Models/ExportSettings.swift` - export configuration
- `Services/BlockParser.swift` - markdown → blocks parser
- `Services/BlockSyncService.swift` - block synchronization
- `web/milkdown/src/block-id-plugin.ts` - block ID tracking
- `web/milkdown/src/block-sync-plugin.ts` - block change detection
- `web/milkdown/src/source-mode-plugin.ts` - source mode decorations
- `web/milkdown/src/heading-nodeview-plugin.ts` - heading rendering
- `web/codemirror/src/anchor-plugin.ts` - section anchor handling

---

## Step-by-Step Merge Process

### Step 4: Perform the Merge
```bash
cd "/Users/niyaro/Documents/Code/final final"
git checkout test/zoom-merge  # Should already be here
git merge zoom --no-commit  # Pause before committing to review
```

### Step 5: Resolve Conflicts
For each conflicted file:

1. **Swift files** - Use zoom's version as base, carefully check if main added anything:
   ```bash
   git checkout --theirs <file>  # Take zoom's version
   ```

2. **Version numbers** - Manually set to next version (0.2.14 or higher)

3. **Documentation** - Manual merge to preserve both branches' content

### Step 6: Regenerate Generated Files
```bash
cd web && pnpm install && pnpm build && cd ..
xcodegen generate
```

### Step 7: Verify Build
```bash
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

### Step 8: Test Core Functionality
- [ ] App launches without crash
- [ ] Existing project opens correctly
- [ ] WYSIWYG editing works
- [ ] Source mode toggle (Cmd+/) works
- [ ] Sidebar shows sections
- [ ] Zoom into section works (double-click)
- [ ] Zoom out works
- [ ] Content persists after restart

### Step 9: Commit the Merge
```bash
git add -A
git commit -m "Merge zoom branch: block-based architecture" -m "Major refactoring to block-based content model:" -m "- Add Block model with granular paragraph tracking" -m "- Add block ID and sync plugins for Milkdown" -m "- Add source mode plugin for dual-appearance editing" -m "- Improve zoom functionality with state machine" -m "- Fix various editor bugs"
```

### Step 10: Merge to Main
```bash
git checkout main
git merge test/zoom-merge
git branch -d test/zoom-merge
```

---

## Rollback Plan

If the merge fails or causes issues:

```bash
# Return to pre-merge state
git checkout main
git reset --hard backup-before-zoom-merge
git branch -D test/zoom-merge

# Or if already merged to main
git reset --hard backup-before-zoom-merge
```

---

## Post-Merge Cleanup

1. **Delete zoom worktree** (after confirming merge is stable):
   ```bash
   git worktree remove "/Users/niyaro/Documents/Code/final final development/zoom"
   git branch -d zoom
   ```

2. **Update version number** in `project.yml` and `web/package.json`

3. **Update CLAUDE.md** if any architectural descriptions changed

---

## Verification Checklist

After merge is complete, verify:

- [ ] `git log --oneline -10` shows clean merge history
- [ ] `git status` shows clean working tree
- [ ] Web build succeeds: `cd web && pnpm build`
- [ ] Xcode project generates: `xcodegen generate`
- [ ] Full build succeeds: `xcodebuild -scheme "final final" build`
- [ ] App launches and opens existing project
- [ ] Create new section, verify it appears in sidebar
- [ ] Toggle editor mode (Cmd+/), verify content preserved
- [ ] Zoom into section, verify content isolated
- [ ] Zoom out, verify full document restored
