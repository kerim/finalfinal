# Fix: Missing @codemirror/autocomplete symlink after git merge

## Problem

Post-merge build fails with:
```
Rollup failed to resolve import "@codemirror/autocomplete"
```

## Root Cause

The pnpm symlink for `@codemirror/autocomplete` is missing from `web/codemirror/node_modules/@codemirror/`.

**Evidence:**
- Package is declared in `web/codemirror/package.json` (line 11)
- Package is imported in `web/codemirror/src/main.ts` (line 7)
- Package exists in pnpm store: `web/node_modules/.pnpm/@codemirror+autocomplete@6.20.0`
- Symlink is **missing** from `web/codemirror/node_modules/@codemirror/` (only 6 of 7 @codemirror packages have symlinks)

This happens when git merge updates package.json but the symlinks weren't recreated.

## Fix

1. Run `pnpm install` in the `web/` directory to recreate all symlinks
2. Run `pnpm build` to verify the fix

## Verification

```bash
cd "/Users/niyaro/Documents/Code/final final/web"
pnpm install
pnpm build
```

Expected: Build completes successfully with no errors.
