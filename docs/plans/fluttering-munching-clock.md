# Plan: Fix Annotation Display Mode Defaults Not Applied in Editor

## Problem

Annotation display modes show "Inline" in the settings panel but comments/references still render collapsed in the editor.

**Root Cause:** The JavaScript plugin has its own hardcoded defaults that differ from Swift. Swift's `onChange` only fires when values **change**, not on initialization. So the editor keeps using its stale JavaScript defaults.

## Changes Required

### 1. Sync JavaScript defaults to match Swift
**File:** `web/milkdown/src/annotation-display-plugin.ts` (lines 17-21)

**Current:**
```typescript
const displayModes: Record<AnnotationType, AnnotationDisplayMode> = {
  task: 'inline',
  comment: 'collapsed',
  reference: 'collapsed',
};
```

**New:**
```typescript
const displayModes: Record<AnnotationType, AnnotationDisplayMode> = {
  task: 'inline',
  comment: 'inline',
  reference: 'inline',
};
```

### 2. Rebuild web editors
```bash
cd web && pnpm build
```

## Verification

1. Build and run the app
2. Open an existing document with annotations or create new ones
3. Comments and references should display inline (text visible) by default
4. Changing the setting to "Collapsed" should hide the text, leaving only the marker
5. Changing back to "Inline" should restore the text
