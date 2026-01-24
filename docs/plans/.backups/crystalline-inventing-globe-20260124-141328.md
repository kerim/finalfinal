# Plan: Fix Editor Loading - Restore IIFE Build Configuration

## Critical Discovery: No "Working Version" in Git

**The `Resources/editor/` directory is gitignored** (line 23 of `.gitignore`). The compiled editor files were NEVER committed to git.

### Git History Shows All Commits Have Broken Config

| Commit | Description | vite.config.ts Status |
|--------|-------------|----------------------|
| `60adadb` | main/current - v0.1.14 | ❌ ES modules (broken) |
| `c50180d` | backup branch | ❌ ES modules (broken) |
| `aee8688` | Phase 1.5 - CodeMirror | ❌ ES modules (broken) |
| `6b9337a` | Phase 1.4 - Milkdown | ❌ ES modules (broken) |
| `e29b3fb` | Phase 1.3 - First vite config | ❌ ES modules (broken from start) |

**The ONLY working configuration is in your stash** - it was never committed.

## Problem Analysis

The editor is not loading because `window.FinalFinal` is undefined. Investigation revealed:

1. **All git commits have broken vite.config.ts** - They use ES module format which generates:
   ```html
   <script type="module" crossorigin src="/milkdown.js"></script>
   ```

2. **ES modules don't work with custom URL schemes** - The `crossorigin` attribute fails with `editor://` scheme due to CORS restrictions.

3. **The stash contains the working IIFE configuration** - Builds as IIFE (Immediately Invoked Function Expression) which generates:
   ```html
   <script src="/milkdown.js"></script>
   ```

## Root Cause

The vite configurations in git have ALWAYS been broken since Phase 1.3.

**What went wrong during commits:**
1. The vite.config.ts was modified to IIFE format in the working directory
2. But `git add` was never run on that file during subsequent commits
3. So commits captured other changes but left vite.config.ts as an unstaged modification
4. The `git stash` swept up all these uncommitted changes

**Why Resources/editor/ wasn't committed:**
- `.gitignore` line 23 excludes `final\ final/Resources/editor/`
- This was a design decision from Phase 1.1 to treat compiled JS as build artifacts
- The assumption was: rebuild from source after checkout
- But since the SOURCE (vite.config.ts) was also broken, rebuilds produce broken output

## Solution

### Step 1: Extract vite.config.ts from stash

Apply only the vite.config.ts files from the stash (not the scroll tracking code):

```bash
git checkout stash@{0} -- web/milkdown/vite.config.ts web/codemirror/vite.config.ts
```

### Step 2: Rebuild web editors

```bash
cd web && pnpm build
```

### Step 3: Rebuild Xcode project

```bash
xcodegen generate && xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

### Step 4: Commit the fix

The vite.config.ts files should have been part of the original v0.1.14 commit. Commit them as a fix.

## Files to Modify

| File | Action |
|------|--------|
| `web/milkdown/vite.config.ts` | Restore IIFE build config from stash |
| `web/codemirror/vite.config.ts` | Restore IIFE build config from stash |
| `final final/Resources/editor/milkdown/` | Rebuilt with IIFE format |
| `final final/Resources/editor/codemirror/` | Rebuilt with IIFE format |

## Key Differences in vite.config.ts

**Broken (current v0.1.14):**
```typescript
export default defineConfig({
  build: {
    rollupOptions: {
      input: 'milkdown.html',
      output: { entryFileNames: 'milkdown.js' },
    },
  },
});
```

**Working (in stash):**
```typescript
export default defineConfig({
  build: {
    lib: {
      entry: resolve(__dirname, 'src/main.ts'),
      name: 'MilkdownEditor',
      fileName: () => 'milkdown.js',
      formats: ['iife'],  // <-- Critical: IIFE not ES modules
    },
  },
  plugins: [generateHtml()],  // <-- Custom HTML without type="module"
});
```

## Verification

1. Launch the app
2. Check console logs show `[Milkdown] window.FinalFinal API registered`
3. Editor content should load and be editable
4. Test Cmd+/ mode switching
5. Test cursor position preservation
