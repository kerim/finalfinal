# Fix Milkdown Build Failure

## Problem

The `vite build` command fails in the milkdown workspace:

```
[vite]: Rollup failed to resolve import "@milkdown/plugin-slash"
```

**Root cause:** `@milkdown/plugin-slash` and `unist-util-visit` are declared in `web/milkdown/package.json` but not installed in the workspace. There's also a version mismatch:
- Declared: `@milkdown/plugin-slash@^7.8.0`
- Available via `@milkdown/kit`: `@milkdown/plugin-slash@7.18.0`

## Solution

Run `pnpm install` from the `web/` directory to properly install workspace dependencies.

```bash
cd /Users/niyaro/Documents/Code/final\ final/web && pnpm install
```

## Verification

After installation, rebuild the web editors:

```bash
cd /Users/niyaro/Documents/Code/final\ final/web && pnpm build
```

Expected: Build completes without errors.

## Files Involved

- `web/milkdown/package.json` - dependency declarations
- `web/milkdown/src/main.ts` - imports `SlashProvider` from `@milkdown/plugin-slash`
