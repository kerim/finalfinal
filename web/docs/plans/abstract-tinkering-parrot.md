# Fix: Image Fixes Round 2 — Rollback, Isolate, Re-apply

## Context

Round 2 image fixes (AVIF error dialog, drop position, width persistence) broke the app — no project window appears after opening a project. Three independent code reviewers confirmed there is NO circular import. The root cause is unknown. The app was working with Round 1 changes before Round 2 was applied.

## Strategy

Roll back all Round 2 changes, verify the app works, then re-apply each fix one at a time with a web rebuild + app test between each to isolate which change breaks things.

---

## Step 1: Roll Back All Round 2 Changes

### Swift files (my changes are the ONLY changes in these files)
- `git checkout HEAD -- "final final/Editors/MilkdownCoordinator+MessageHandlers.swift"`
- `git checkout HEAD -- "final final/Editors/CodeMirrorCoordinator+Handlers.swift"`

### TypeScript files (have BOTH Round 1 and Round 2 changes — selective revert)

**`web/milkdown/src/image-plugin.ts`** — Remove these Round 2 additions:
1. Remove the `pendingDropPos` variable and `consumePendingDropPos()` export (~line 478-487)
2. Revert `handleDrop(view:` back to `handleDrop(_view:` and remove the coords capture + setTimeout block
3. In `onResizeEnd`: remove the `!blockId.startsWith('temp-')` check and the else/retry block — restore to simple `if (blockId) { postMessage... }`
4. In `onCaptionBlur`: same — remove temp-ID retry, restore simple `if (blockId) { postMessage... }`
5. In `showAltTextPopup`: same — remove temp-ID retry, restore simple `if (blockId) { postMessage... }`

**`web/milkdown/src/api-content.ts`** — Remove these Round 2 additions:
1. Remove `import { consumePendingDropPos } from './image-plugin'` (line ~38)
2. In `insertImage()`: remove the `consumePendingDropPos()` call and `dropPos` logic — restore original cursor-based insertion

### Rebuild web
```bash
cd web && pnpm build
```

## Step 2: Verify Baseline

Build and run app in Xcode. Open a project. **Verify the project window appears.**

## Step 3: Re-apply Fix 1 (AVIF Error Dialog) — TEST

Add NSAlert in `handlePasteImage()` catch blocks:
- `final final/Editors/MilkdownCoordinator+MessageHandlers.swift`
- `final final/Editors/CodeMirrorCoordinator+Handlers.swift`

No web rebuild needed (Swift-only change). Build in Xcode, open project, verify window appears.

## Step 4: Re-apply Fix 2 (Drop Position) — TEST

- `web/milkdown/src/image-plugin.ts`: Add `pendingDropPos`, `consumePendingDropPos`, capture in `handleDrop`
- `web/milkdown/src/api-content.ts`: Import `consumePendingDropPos`, use in `insertImage()`

Rebuild web (`cd web && pnpm build`). Build in Xcode, open project, verify window appears.

## Step 5: Re-apply Fix 3 (Width Persistence / Temp-ID Retry) — TEST

- `web/milkdown/src/image-plugin.ts`: Add temp-ID retry in `onResizeEnd`, `onCaptionBlur`, `showAltTextPopup`

Rebuild web (`cd web && pnpm build`). Build in Xcode, open project, verify window appears.

## Files

| File | Rollback | Re-apply step |
|------|----------|---------------|
| `final final/Editors/MilkdownCoordinator+MessageHandlers.swift` | `git checkout HEAD` | Step 3 |
| `final final/Editors/CodeMirrorCoordinator+Handlers.swift` | `git checkout HEAD` | Step 3 |
| `web/milkdown/src/image-plugin.ts` | Manual selective revert | Steps 4, 5 |
| `web/milkdown/src/api-content.ts` | Manual selective revert | Step 4 |
