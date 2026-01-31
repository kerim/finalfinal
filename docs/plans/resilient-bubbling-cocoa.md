# Plan: Merge Design Branch to Main

## Summary

Safely merge the `design` branch into `main` by resolving the single conflict in the Xcode project file.

## Current State

- **Current branch:** `main` (mid-merge from `design`)
- **Conflicted file:** `final final.xcodeproj/project.pbxproj`
- **Conflict cause:** Version number mismatch (`0.2.2` on main vs `0.2.0` on design)
- **Successfully merged:** 12 files already staged and ready

## Files Being Merged

**New files from design branch:**
- `final final/Theme/Typography.swift`
- `web/shared/typography.css`

**Modified files (auto-merged successfully):**
- `final final/Theme/ColorScheme.swift`
- `final final/Views/AnnotationPanel/AnnotationCardView.swift`
- `final final/Views/AnnotationPanel/AnnotationFilterBar.swift`
- `final final/Views/AnnotationPanel/AnnotationPanel.swift`
- `final final/Views/Sidebar/HashBar.swift`
- `final final/Views/Sidebar/OutlineFilterBar.swift`
- `final final/Views/Sidebar/SectionCardView.swift`
- `final final/Views/Sidebar/TagPillView.swift`
- `web/codemirror/src/styles.css`
- `web/milkdown/src/styles.css`

## Resolution Steps

### Step 1: Resolve the pbxproj conflict

The conflict is in `CURRENT_PROJECT_VERSION` (appears twice - Debug and Release configs).

**Resolution:** Keep main's version `0.2.2` (or bump to `0.2.3` since we're adding new changes).

Edit the file to:
1. Remove conflict markers (`<<<<<<<`, `=======`, `>>>>>>>`)
2. Keep `CURRENT_PROJECT_VERSION = 0.2.3;` (bumped version for the merge)

### Step 2: Stage the resolved file

```bash
git add "final final.xcodeproj/project.pbxproj"
```

### Step 3: Rebuild web editors

The design branch modified web CSS files and added `web/shared/typography.css`. Rebuild the web editors to bundle these changes:

```bash
cd web && pnpm build && cd ..
```

### Step 4: Build the macOS app

```bash
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

This ensures the merged code (Swift + bundled web assets) compiles correctly before committing.

### Step 5: Complete the merge

```bash
git commit -m "Merge design branch: typography and theme updates" \
  -m "Merged design improvements including:" \
  -m "- Typography.swift with centralized font definitions" \
  -m "- ColorScheme updates for consistent theming" \
  -m "- Sidebar and annotation panel styling fixes" \
  -m "- Shared typography.css for web editors"
```

### Step 6: Update version in web package (optional)

If bumping to 0.2.3, also update `web/package.json` version to match.

## Verification

1. **Build succeeds** - xcodebuild completes without errors
2. **App launches** - Run the app and verify it opens
3. **Typography visible** - Check that the new typography styling is applied
4. **No regressions** - Quick smoke test of sidebar and editor

## Rollback Plan

If issues are discovered after merging:
```bash
git reset --hard HEAD~1
```

This will undo the merge commit and return to the pre-merge state.

## Critical Files

- `final final.xcodeproj/project.pbxproj:632` - Debug config version
- `final final.xcodeproj/project.pbxproj:642` - Release config version
