# Plan: Fix Milkdown Plugin Initialization Error

## Problem

Editor fails to initialize with error:
```
Editor.make().create() failed: r is not a function. (In 'r(i)', 'r' is an instance of Re)
```

## Root Cause

The `focusModePlugin` in `web/milkdown/src/focus-mode-plugin.ts` is a raw ProseMirror plugin. Milkdown requires all ProseMirror plugins to be wrapped with `$prose()` from `@milkdown/kit/utils`.

**Current (broken):**
```typescript
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';

export const focusModePlugin = new Plugin({...});
```

**Required (working):**
```typescript
import { $prose } from '@milkdown/kit/utils';
import { Plugin, PluginKey } from '@milkdown/kit/prose/state';

export const focusModePlugin = $prose(() => new Plugin({...}));
```

## Solution

Extract the fix from stash and rebuild:

```bash
git checkout stash@{0} -- web/milkdown/src/focus-mode-plugin.ts
cd web && pnpm build
xcodegen generate && xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

## Files to Modify

| File | Action |
|------|--------|
| `web/milkdown/src/focus-mode-plugin.ts` | Add `$prose()` wrapper from stash |

## Verification

1. Launch the app
2. Console shows `[Milkdown] window.FinalFinal API registered`
3. Editor loads and displays content
4. Focus mode toggle (Cmd+Shift+F) works
5. Mode switching (Cmd+/) works
