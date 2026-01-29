# Plan: Migrate Themes from Academic Writer

## Overview

Replace the current 5 placeholder themes with 4 carefully designed themes from Academic Writer. Extend them for the more complex UI (sidebar, annotations, status colors). Improve typography (18px font, 1.75 line height).

## User Requirements

1. Use Academic Writer's 4 theme palettes
2. Avoid dark blue URLs on dark backgrounds (use per-theme accent colors)
3. Follow usability guidelines (WCAG contrast)
4. Increase default font to 18px
5. Increase line height to 1.75

## The 4 New Themes

| Shortcut | Theme | Background | Text | Accent |
|----------|-------|------------|------|--------|
| Cmd+Opt+1 | High Contrast Day | #ffffff | #1a1a1a | #0066cc (blue) |
| Cmd+Opt+2 | Low Contrast Day | #faf8f5 (parchment) | #3d3a36 | #8b7355 (golden brown) |
| Cmd+Opt+3 | High Contrast Night | #0a0a0a (OLED) | #f5deb3 (amber) | #ffb74d (orange) |
| Cmd+Opt+4 | Low Contrast Night | #2e3440 (Nord) | #d8dee9 | #88c0d0 (cyan) |

## Files to Modify

### 1. `final final/Theme/ColorScheme.swift`

**Changes:**
- Add `AnnotationColors` struct with task, taskCompleted, comment, reference
- Add to `AppColorScheme`: `annotationColors`, `highlightBackground`, `tooltipBackground`, `tooltipText`
- Extend `cssVariables` to include new variables
- Replace 5 themes with 4 new ones:
  - `.highContrastDay` (id: "high-contrast-day")
  - `.lowContrastDay` (id: "low-contrast-day")
  - `.highContrastNight` (id: "high-contrast-night")
  - `.lowContrastNight` (id: "low-contrast-night")
- Per-theme status colors (brighter for dark themes)
- Per-theme annotation colors (light blue/purple on dark, deeper on light)

### 2. `final final/Theme/ThemeManager.swift`

**Changes:**
- Add migration logic in `loadThemeFromDatabase()` for old theme IDs:
  - "light" -> "high-contrast-day"
  - "sepia" -> "low-contrast-day"
  - "dark" -> "high-contrast-night"
  - "solarized-dark" -> "low-contrast-night"
  - "solarized-light" -> "low-contrast-day"

### 3. `web/milkdown/src/styles.css`

**Changes:**
- Add `font-size: 18px` to body
- Change `.milkdown p` line-height from 1.6 to 1.75
- CSS variables already support annotation colors (fallbacks exist)

### 4. `web/codemirror/src/styles.css`

**Changes:**
- Change `.cm-editor` font-size from 16px to 18px
- Change line-height from 1.6 to 1.75

### 5. Rebuild web assets

```bash
cd web && pnpm build
```

## Color Specifications

### High Contrast Day (Light)
```
Sidebar: #f5f5f5 bg, #1a1a1a text, divider #e0e0e0
Selection: rgba(0, 102, 204, 0.25)
Status: writing #2563eb, next #ea580c, waiting #ca8a04, review #9333ea, final #16a34a
Annotations: task #d97706, completed #059669, comment #2563eb, reference #7c3aed
Highlight: rgba(255, 235, 59, 0.4)
Tooltip: bg #1f2937, text #f3f4f6
```

### Low Contrast Day (Parchment)
```
Sidebar: #f0ebe4 bg, #3d3a36 text, divider #d8d0c4
Selection: rgba(139, 115, 85, 0.25)
Status: same as High Contrast Day
Annotations: same as High Contrast Day
Highlight: rgba(255, 193, 7, 0.35)
Tooltip: bg #3d3a36, text #faf8f5
```

### High Contrast Night (OLED Amber)
```
Sidebar: #1a1a1a bg, #f5deb3 text, divider #333333
Selection: rgba(255, 183, 77, 0.3)
Status: writing #60a5fa, next #fb923c, waiting #fcd34d, review #c084fc, final #4ade80
Annotations: task #fbbf24, completed #34d399, comment #60a5fa, reference #a78bfa
Highlight: rgba(255, 183, 77, 0.25)
Tooltip: bg #f5deb3, text #0a0a0a (inverted)
```

### Low Contrast Night (Nord)
```
Sidebar: #3b4252 bg, #d8dee9 text, divider #4c566a
Selection: rgba(136, 192, 208, 0.25)
Status: writing #81a1c1, next #d08770, waiting #ebcb8b, review #b48ead, final #a3be8c
Annotations: task #ebcb8b, completed #a3be8c, comment #88c0d0, reference #b48ead
Highlight: rgba(235, 203, 139, 0.25)
Tooltip: bg #eceff4, text #2e3440
```

## Implementation Order

1. Update ColorScheme.swift with new theme definitions
2. Update ThemeManager.swift with migration logic
3. Update milkdown/styles.css (font size, line height)
4. Update codemirror/styles.css (font size, line height)
5. Rebuild web: `cd web && pnpm build`
6. Build and test: `xcodebuild -scheme "final final" -destination 'platform=macOS' build`

## Verification

- [ ] All 4 themes accessible via Cmd+Opt+1-4
- [ ] Editor text readable on all themes
- [ ] Sidebar text readable on all themes
- [ ] Links visible (no dark blue on dark backgrounds)
- [ ] Status dots visible in sidebar
- [ ] Annotations visible in editor
- [ ] Font size is 18px
- [ ] Line height is 1.75
- [ ] Theme persists after restart
- [ ] Old theme IDs migrate correctly
