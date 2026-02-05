# Merge `display` Branch to `main`

## Summary
Safely resolve merge conflicts from merging the `display` branch into `main`.

## Conflicts

### 1. `project.yml` (line 42-45)
- **Conflict**: Version number difference
- **Resolution**: Take `display` version (0.2.29 is higher than 0.2.26)

### 2. `web/milkdown/src/main.ts` (lines 195-217)
- **Conflict**: Different API additions to `window.FinalFinal`
- **main branch** added: Find/replace API (`find`, `findNext`, `findPrevious`, `replaceCurrent`, `replaceAll`, `clearSearch`, `getSearchState`)
- **display branch** added: Debug API (`getDebugState` for zoom transition diagnostics)
- **Resolution**: Keep BOTH APIs - they are independent additions

### 3. `final final.xcodeproj/project.pbxproj` (lines 769-773, 796-800)
- **Conflict**: Version number in two places (Debug and Release configs)
- **Resolution**: Regenerate via `xcodegen generate` after fixing `project.yml`

## Implementation Steps

1. **Fix `project.yml`**
   - Remove conflict markers
   - Keep version 0.2.29 from display branch

2. **Fix `web/milkdown/src/main.ts`**
   - Remove conflict markers
   - Keep BOTH the find/replace API (from main) AND the debug API (from display)
   - Ensure proper TypeScript formatting with both APIs in the interface

3. **Regenerate Xcode project**
   - Run `xcodegen generate` to rebuild `project.pbxproj` from the corrected `project.yml`

4. **Stage and commit**
   - Stage all resolved files
   - Commit the merge

## Verification

After merge completion:
1. `git status` shows clean working tree
2. `cd web && pnpm build` succeeds
3. `xcodebuild -scheme "final final" -destination 'platform=macOS' build` succeeds
