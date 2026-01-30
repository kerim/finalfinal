# Plan: Safely Merge Versioning Branch

## Context

Merging `versioning` branch into `main`. Three files have conflicts:
- `final final.xcodeproj/project.pbxproj`
- `final final/Models/ProjectDatabase.swift`
- `final final/Views/ContentView.swift`

**Key insight:** These are two independent features (citation integration on main, version history on versioning) that need to coexist. No logical conflicts—just structural overlap.

---

## Resolution Steps

### Step 1: Resolve `project.pbxproj` (Xcode project)

**Strategy:** Use `xcodegen generate` to regenerate the file from `project.yml`

Since this project uses xcodegen, the cleanest approach is:
1. Accept the versioning branch version (which has the new files listed in project.yml)
2. Regenerate the project file

```bash
git checkout --theirs "final final.xcodeproj/project.pbxproj"
xcodegen generate
```

This avoids manual pbxproj editing, which is error-prone.

---

### Step 2: Resolve `ProjectDatabase.swift`

**Conflict:** Both branches add a migration with `v6_` prefix.

**Resolution:**
- Keep main's `v6_bibliography` migration (adds `isBibliography` column to section table)
- Rename versioning's migration to `v7_snapshots` (creates snapshot and snapshotSection tables)

The final migrations should be ordered:
1. `v6_bibliography` (from main)
2. `v7_snapshots` (from versioning, renamed)

---

### Step 3: Resolve `ContentView.swift`

**Multiple conflicts—all require including both features:**

| Location | Main (HEAD) | Versioning | Resolution |
|----------|-------------|------------|------------|
| State vars (~line 27) | `BibliographySyncService` | `AutoBackupService` | Include both |
| Content onChange (~line 252) | Extract citekeys | Trigger auto-backup | Include both handlers |
| configureForCurrentProject (~line 1137) | Configure bibliography service | Configure auto-backup | Include both |
| handleProjectClosed (~line 1285) | Reset bibliography | Reset auto-backup | Include both |

---

## Verification

After resolving conflicts:

1. **Build check:**
   ```bash
   cd web && pnpm build && cd .. && xcodegen generate
   xcodebuild -scheme "final final" -destination 'platform=macOS' build
   ```

2. **Functional verification:**
   - Open a project with citations → bibliography should sync
   - Edit content → auto-backup timer should trigger
   - Check version history feature works (new menu item)

3. **Database migration test:**
   - Delete app data or use fresh database
   - Verify both migrations run in sequence without errors

---

## Files to Modify

| File | Action |
|------|--------|
| `final final.xcodeproj/project.pbxproj` | Regenerate with xcodegen |
| `final final/Models/ProjectDatabase.swift` | Manual merge, rename v6→v7 for snapshots |
| `final final/Views/ContentView.swift` | Manual merge, include both services |

---

## Risk Mitigation

- **Backup current state** before resolving (git stash or commit WIP)
- **Test database migration** on fresh database to ensure v6 and v7 sequence correctly
- **Verify both features** work independently after merge
