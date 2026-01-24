# Bug Fix: Milkdown Editor JavaScript Not Executing

**Reviewed by:** swift-engineering:swift-code-reviewer (confirmed diagnosis correct)

## Problem

The Milkdown editor shows a blank page. JavaScript files are served but code never executes.

**Error from logs:**
```
TypeError: undefined is not an object (evaluating 'window.FinalFinal.setContent')
```

**Critical observation:** The console.log `[Milkdown] Initializing editor...` on line 15 of main.ts NEVER appears, proving the JavaScript module isn't executing at all.

## Root Cause Analysis

**Root cause:** Vite adds `crossorigin` attribute to `<script type="module">` and `<link>` tags in the built HTML. Custom URL schemes (`editor://`) don't support CORS, causing WKWebView to block ES module execution entirely.

**Why this happens:**
- CORS is an HTTP/HTTPS protocol feature
- Custom URL schemes (`editor://`) have no CORS implementation
- WKWebView treats the `crossorigin` request as a failed CORS preflight
- The script loads (visible in logs) but never executes

**Evidence:**
1. Files ARE being served (confirmed in logs: `/milkdown.html`, `/milkdown.js`, `/milkdown.css`)
2. `[Milkdown] Initializing editor...` console.log NEVER appears → JS not executing
3. Built HTML contains: `<script type="module" crossorigin src="/milkdown.js">`

**Source:** [Vite GitHub Issue #6648](https://github.com/vitejs/vite/issues/6648)

---

## Fix

### Task 1: Add Vite plugin to Milkdown config

**File:** `web/milkdown/vite.config.ts`

Replace entire file with:

```typescript
import { defineConfig, Plugin } from 'vite';

// Custom plugin to remove crossorigin attribute from built HTML
// Required for WKWebView with custom URL schemes (editor://)
// See: https://github.com/vitejs/vite/issues/6648
function removeCrossOrigin(): Plugin {
  return {
    name: 'remove-crossorigin',
    transformIndexHtml(html) {
      return html.replace(/ crossorigin(?=[\s>])/g, '');
    },
  };
}

export default defineConfig({
  plugins: [removeCrossOrigin()],
  build: {
    outDir: '../../final final/Resources/editor/milkdown',
    emptyOutDir: true,
    rollupOptions: {
      input: 'milkdown.html',
      output: {
        entryFileNames: 'milkdown.js',
        assetFileNames: 'milkdown.[ext]',
      },
    },
  },
});
```

### Task 2: Add same plugin to CodeMirror config

**File:** `web/codemirror/vite.config.ts`

Replace entire file with:

```typescript
import { defineConfig, Plugin } from 'vite';

// Custom plugin to remove crossorigin attribute from built HTML
// Required for WKWebView with custom URL schemes (editor://)
// See: https://github.com/vitejs/vite/issues/6648
function removeCrossOrigin(): Plugin {
  return {
    name: 'remove-crossorigin',
    transformIndexHtml(html) {
      return html.replace(/ crossorigin(?=[\s>])/g, '');
    },
  };
}

export default defineConfig({
  plugins: [removeCrossOrigin()],
  build: {
    outDir: '../../final final/Resources/editor/codemirror',
    emptyOutDir: true,
    rollupOptions: {
      input: 'codemirror.html',
      output: {
        entryFileNames: 'codemirror.js',
        assetFileNames: 'codemirror.[ext]',
      },
    },
  },
});
```

### Task 3: Rebuild all web editors

```bash
cd "/Users/niyaro/Documents/Code/final final/web" && pnpm build
```

### Task 4: Verify crossorigin removed

```bash
grep crossorigin "/Users/niyaro/Documents/Code/final final/final final/Resources/editor/milkdown/milkdown.html"
grep crossorigin "/Users/niyaro/Documents/Code/final final/final final/Resources/editor/codemirror/codemirror.html"
```

Both should return NO matches.

### Task 5: Rebuild and run app

```bash
cd "/Users/niyaro/Documents/Code/final final" && xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

Launch app and check console for:
- `[Milkdown] Initializing editor...` ← This MUST appear now
- `[Milkdown] Editor initialized`
- No `setContent error`

### Task 6: Commit fix

```bash
git add web/milkdown/vite.config.ts web/codemirror/vite.config.ts "final final/Resources/editor/"
git commit -m "fix: Remove crossorigin attribute from Vite build for WKWebView compatibility

The crossorigin attribute on ES module script tags causes CORS validation
which fails for custom URL schemes like editor://. This prevented the
JavaScript from executing at all in WKWebView.

Applied to both Milkdown and CodeMirror editor configs."
```

---

## Verification Checklist

- [ ] Milkdown HTML has NO `crossorigin` attribute
- [ ] CodeMirror HTML has NO `crossorigin` attribute
- [ ] Console shows `[Milkdown] Initializing editor...`
- [ ] Console shows `[Milkdown] Editor initialized`
- [ ] Editor displays demo content
- [ ] No JavaScript errors in console
- [ ] Word count updates when typing

---

## Files Changed

| File | Change |
|------|--------|
| `web/milkdown/vite.config.ts` | Add `removeCrossOrigin()` plugin |
| `web/codemirror/vite.config.ts` | Add `removeCrossOrigin()` plugin |
| `final final/Resources/editor/milkdown/*` | Rebuilt without crossorigin attr |
| `final final/Resources/editor/codemirror/*` | Rebuilt without crossorigin attr |
