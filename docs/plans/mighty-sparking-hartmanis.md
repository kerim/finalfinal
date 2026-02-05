# Fix: Rebuild Web Editors After Word-Count Merge

## Problem
The word-count branch was merged, but features aren't visible in the build because the bundled JavaScript files are stale.

## Root Cause
The merge brought TypeScript source changes (`web/milkdown/src/main.ts`, `web/codemirror/src/main.ts`) but the compiled JavaScript in `final final/Resources/editor/` wasn't rebuilt.

## Solution
Run the web build to compile TypeScript changes:

```bash
cd web && pnpm build
```

Then rebuild the app.

## Verification
After rebuild, the bundled files should contain `strippedContent` variable (from the annotation-stripping word count fix).
