# Plan: Fix Editor Loading - Restore IIFE Build Configuration

## Problem Analysis

The editor is not loading because `window.FinalFinal` is undefined. Investigation revealed:

1. **v0.1.14 has broken vite.config.ts files** - They use ES module format which generates:
   ```html
   <script type="module" crossorigin src="/milkdown.js"></script>
   ```

2. **ES modules don't work with custom URL schemes** - The `crossorigin` attribute fails with `editor://` scheme due to CORS restrictions.

3. **The stash contains the working IIFE configuration** - Builds as IIFE (Immediately Invoked Function Expression) which generates:
   ```html
   <script src="/milkdown.js"></script>
   ```

## Root Cause

The v0.1.14 commit never included the correct vite configurations. The working IIFE build setup was only in uncommitted changes that got stashed.

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
