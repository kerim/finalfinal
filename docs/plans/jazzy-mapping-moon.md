# Update finalfinalapp.cc Homepage

## Context

The product homepage at finalfinalapp.cc (repo: `/Users/niyaro/Documents/GitHub/finalfinal-homepage/`) is outdated. It still says "Coming Soon" with no download link, lists old version numbers (02.17–02.31), is missing features that have been implemented (footnotes, toolbars, grammar check, export), and has stale FAQ text. Now that the app is publicly available on GitHub Releases, the homepage needs to reflect the current state.

The homepage is an Eleventy + Tailwind site deployed via Cloudflare Pages. Content lives in config files under `src/config/`.

## Changes

### 1. Hero section: Replace "Coming Soon" with download button
**File:** `src/11ty/_includes/hero.njk`
- Replace the grey "Coming Soon" span with a link to `https://github.com/kerim/finalfinal/releases/latest`
- Style as a primary button (blue/accent, matching existing Tailwind theme)
- Label: "Download for macOS"

Also fix the typo in `src/config/appInfo.js`: "loosing" → "losing"

### 2. Add missing features
**File:** `src/config/features.js`
- Add **Footnotes** — "Insert footnotes that are automatically numbered and collected at the end of the document."
- Add **Grammar & Spell Check** — "Built-in spell check plus optional LanguageTool integration for enhanced grammar and style checking."
- Add **Toolbars** — "Selection toolbar for quick formatting, Format menu, and a status bar showing word count and document statistics."
- Add **Export** — "Export to Markdown, Word, or PDF. Word export preserves Zotero citation markers for further editing."

### 3. Replace updates/changelog with current versions
**File:** `src/config/updates.js`
- Replace old entries (02.17–02.31) with current CHANGELOG entries (0.2.42–0.2.52)
- Point `changelogUrl` to `https://github.com/kerim/finalfinal/blob/main/CHANGELOG.md`

### 4. Update FAQ
**File:** `src/config/faq.js`
- "How do I install it?" → Update to link to GitHub Releases for download
- "Is it stable enough for real work?" → Remove mention of missing toolbars/spell checking/keyboard shortcuts (all implemented now). Keep the alpha warning.

### 5. Update nav link label
**File:** `src/11ty/_includes/header.njk`
- Change "Updates" nav link text to "Changelog" (or keep as-is — minor)

## Files to modify

| File | Change |
|------|--------|
| `src/11ty/_includes/hero.njk` | Replace "Coming Soon" with download link |
| `src/config/appInfo.js` | Fix "loosing" typo |
| `src/config/features.js` | Add 4 new features (Footnotes, Grammar, Toolbars, Export) |
| `src/config/updates.js` | Replace old versions with 0.2.42–0.2.52 entries |
| `src/config/faq.js` | Update install answer + alpha status answer |

## Verification

1. Run `cd /Users/niyaro/Documents/GitHub/finalfinal-homepage && npm run build` — verify no build errors
2. Run `npx @11ty/eleventy --serve` — preview locally and check:
   - Hero shows "Download for macOS" button linking to GitHub Releases
   - Features grid shows all 12 features
   - Changelog shows current versions (0.2.42–0.2.52)
   - FAQ answers are up to date
3. Commit and push to deploy via Cloudflare Pages
