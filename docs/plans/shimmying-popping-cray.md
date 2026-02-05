# Plan: Generate getting-started.md from README.md

## Goal

Maintain a single source of truth (README.md) and generate `getting-started.md` automatically by stripping the Installation section.

## Transformation Rules

| README Section | Getting Started |
|----------------|-----------------|
| Welcome intro | Keep |
| **Installation** | **Remove** |
| Alpha Software | Keep |
| What's New | Keep |
| Set-up | Keep |
| Using FINAL FINAL | Keep |
| Giving Feedback | Keep (GitHub link works in-app too) |
| Closing note | Keep |

## Implementation

### 1. Create generation script

**File:** `scripts/generate-getting-started.js`

```javascript
// Read README.md
// Remove lines between "# Installation" and next "# " heading
// Write to final final/Resources/getting-started.md
```

Uses Node.js (already required for web build). Simple regex-based section removal.

### 2. Integrate with build process

**Option A:** Add npm script to `web/package.json`:
```json
"scripts": {
  "docs": "node ../scripts/generate-getting-started.js",
  "build": "... && npm run docs"
}
```

**Option B:** Standalone script, run manually before release.

### 3. Files to modify

| File | Change |
|------|--------|
| `scripts/generate-getting-started.js` | Create (new) |
| `web/package.json` | Add "docs" script |
| `CLAUDE.md` | Document the workflow |

## Verification

1. Run `node scripts/generate-getting-started.js`
2. Compare output to current getting-started.md
3. Build app, verify Help → Getting Started shows correct content

## Decision

**Automatic:** Script runs as part of `pnpm build` so getting-started.md always stays in sync.
