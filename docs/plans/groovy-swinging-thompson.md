# Merge Conflict Resolution Plan: project-mgt → main

## Overview
Resolve 5 files with merge conflicts from merging `project-mgt` branch into main (which already contains `outline-sidebar`).

## Conflicts and Resolutions

### 1. docs/LESSONS-LEARNED.md
**Conflict type:** Two different documentation entries
**Resolution:** Keep BOTH entries (combine)

- **HEAD section (keep):** CodeMirror keymap lesson - explains that `domEventHandlers.keydown` never fires because `historyKeymap` intercepts Mod-z first
- **project-mgt section (keep):** Milkdown empty content handling - explains early return checks bypassing edge case fixes

**Action:** Remove conflict markers, keep both sections in the file.

---

### 2. final final/Views/Sidebar/OutlineSidebar.swift
**Conflict type:** Print statement formatting (lines 607-613)
**Resolution:** Keep HEAD version

```swift
// HEAD version (KEEP - consistent with codebase swiftlint style):
// swiftlint:disable:next line_length
print("[DROP] onSectionReorder: id=\(request.sectionId), target=\(request.targetSectionId ?? "nil"), level=\(request.newLevel), parent=\(request.newParentId ?? "nil"), subtree=\(request.isSubtreeDrag)")
```

**Action:** Remove conflict markers, keep HEAD's swiftlint-commented single line.

---

### 3. project.yml
**Conflict type:** Three-way version conflict
**Resolution:** Use `0.1.78`

```yaml
CURRENT_PROJECT_VERSION: "0.1.78"
```

**Action:** Remove all conflict markers and version alternatives, set to 0.1.78.

---

### 4. web/package.json
**Conflict type:** Three-way version conflict
**Resolution:** Use `0.1.78`

```json
"version": "0.1.78"
```

**Action:** Remove all conflict markers and version alternatives, set to 0.1.78.

---

### 5. final final.xcodeproj/project.pbxproj
**Conflict type:** Version number in two build configurations (Debug and Release)
**Resolution:** Use `0.1.78`

Two locations (lines ~555 and ~581):
```
CURRENT_PROJECT_VERSION = 0.1.78;
```

**Action:** Remove conflict markers at both locations, set both to 0.1.78.

---

## Execution Order

1. **LESSONS-LEARNED.md** - Combine both sections
2. **OutlineSidebar.swift** - Keep HEAD version
3. **project.yml** - Set version to 0.1.78
4. **web/package.json** - Set version to 0.1.78
5. **project.pbxproj** - Set both version locations to 0.1.78

## Verification

After resolving:
```bash
# Check no conflict markers remain
git diff --check

# Stage resolved files
git add docs/LESSONS-LEARNED.md
git add "final final/Views/Sidebar/OutlineSidebar.swift"
git add project.yml
git add web/package.json
git add "final final.xcodeproj/project.pbxproj"

# Complete the merge
git commit -m "Merge branch 'project-mgt' - project management features (v0.1.78)"

# Verify build
xcodegen generate
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```
