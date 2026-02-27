# Plan: Update Night Theme Default Colors

## Context

The user has customized the "High Contrast Night" and "Low Contrast Night" themes via saved presets in the Appearance panel. They want these override values baked into the built-in theme defaults so new users and "Reset to Defaults" will use these colors.

Currently, `AppColorScheme` has no separate header color property -- headers fall back to `editorText`. The user's presets use distinct header colors, so we need to add this capability to the theme struct itself.

The CSS infrastructure is already fully in place: both Milkdown and CodeMirror editors use `var(--editor-heading-text, var(--editor-text))` with proper fallbacks (14+ declarations across both editors). No web-side changes needed.

### Target Colors (extracted from database presets)

**High Contrast Night:**
| Property | Current | New |
|----------|---------|-----|
| Text Color | `#F76B15` (orangeDark.step9) | `#BD6B15` (custom darker orange) |
| Header Color | (same as text) | `#FFFFFF` (white) |
| Accent Color | `#FF801F` (orangeDark.step10) | `#FFB700` (golden amber) |

**Low Contrast Night:**
| Property | Current | New |
|----------|---------|-----|
| Text Color | `#B0B4BA` (slateDark.step11) | `#A5D6E7` (light cyan) |
| Header Color | (same as text) | `#4C98CA` (medium blue) |
| Accent Color | `#00A2C7` (cyanDark.step9) | `#00C8FF` (bright cyan) |

## Implementation Steps

### Step 1: Add `editorHeaderText` to `AppColorScheme`

**File:** `final final/Theme/ColorScheme.swift`

- Add `let editorHeaderText: Color` property between `editorText` (line 110) and `editorTextSecondary` (line 111)
- Add `--editor-heading-text: \(editorHeaderText.cssHex);` to `cssVariables` after the `--editor-text` line (line 138)

### Step 2: Update all four theme definitions with new property + night theme colors

**File:** `final final/Theme/ColorScheme.swift`

Day themes (add property only, no visual change):
- **highContrastDay**: Add `editorHeaderText: RadixScales.gray.step12` (same as existing `editorText`)
- **lowContrastDay**: Add `editorHeaderText: RadixScales.parchment.step12` (same as existing `editorText`)

Night themes (add property + change colors):
- **highContrastNight**:
  - `editorText`: `Color(red: 0.740, green: 0.420, blue: 0.082)` — #BD6B15
  - `editorHeaderText`: `Color.white` — #FFFFFF
  - `accentColor`: `Color(red: 1.0, green: 0.719, blue: 0.0)` — #FFB700
  - `editorSelection`: `Color(red: 1.0, green: 0.719, blue: 0.0).opacity(0.30)` — match new accent
  - `sidebarSelectedBackground`: `Color(red: 1.0, green: 0.719, blue: 0.0).opacity(0.30)` — match new accent
  - `highlightBackground`: `Color(red: 1.0, green: 0.719, blue: 0.0).opacity(0.25)` — match new accent
- **lowContrastNight**:
  - `editorText`: `Color(red: 0.648, green: 0.840, blue: 0.904)` — #A5D6E7
  - `editorHeaderText`: `Color(red: 0.298, green: 0.596, blue: 0.794)` — #4C98CA
  - `accentColor`: `Color(red: 0.0, green: 0.785, blue: 1.0)` — #00C8FF
  - `editorSelection`: `Color(red: 0.0, green: 0.785, blue: 1.0).opacity(0.25)` — match new accent
  - `sidebarSelectedBackground`: `Color(red: 0.0, green: 0.785, blue: 1.0).opacity(0.25)` — match new accent

**Left unchanged** (user has been using presets with these values and hasn't changed them):
- `sidebarText`, `sidebarTextSecondary` — sidebar uses theme colors, not overridden by presets
- `editorTextSecondary` — not overridable via Appearance panel
- `tooltipBackground`, `tooltipText` — not overridable via Appearance panel
- `statusColors`, `annotationColors` — separate systems, not affected
- `dividerColor`, `highlightBackground` (LC Night) — keep current values

### Step 3: Update `effectiveHeaderColor` fallback

**File:** `final final/Models/AppearanceSettings.swift` (line 309-315)

Change final fallback from `theme.editorText` to `theme.editorHeaderText`:
```swift
func effectiveHeaderColor(theme: AppColorScheme) -> Color {
    if let headerColor = settings.headerColor {
        return headerColor.color
    }
    return settings.textColor?.color ?? theme.editorHeaderText
}
```

### Step 4: Fix header color picker fallbacks in Preferences UI

**File:** `final final/Views/Preferences/PreferencesView+Actions.swift` (line 23)

Change header color load fallback:
```swift
// Before:
headerColor = settings.headerColor?.color ?? textColor
// After:
headerColor = settings.headerColor?.color ?? themeManager.currentTheme.editorHeaderText
```

**File:** `final final/Views/Preferences/PreferencesView.swift` (line 273)

Change header color reset fallback:
```swift
// Before:
headerColor = appearanceManager.effectiveTextColor(theme: themeManager.currentTheme)
// After:
headerColor = themeManager.currentTheme.editorHeaderText
```

Without these fixes, the header color picker would show the body text color when reset, but headings would actually render in the theme's `editorHeaderText` color — a confusing mismatch.

## Files Modified

1. `final final/Theme/ColorScheme.swift` — Add `editorHeaderText` property + CSS variable, update 4 theme definitions
2. `final final/Models/AppearanceSettings.swift` — Update `effectiveHeaderColor` fallback (line 314)
3. `final final/Views/Preferences/PreferencesView+Actions.swift` — Fix header color load fallback (line 23)
4. `final final/Views/Preferences/PreferencesView.swift` — Fix header color reset fallback (line 273)

## Verification

1. Build: `xcodegen generate && xcodebuild -scheme "final final" -destination 'platform=macOS' build`
2. Launch and switch to **High Contrast Night** — verify body text is darker orange (#BD6B15), headers are white, accent is golden amber
3. Switch to **Low Contrast Night** — verify body text is light cyan (#A5D6E7), headers are medium blue (#4C98CA), accent is bright cyan
4. Verify **day themes are unchanged** in appearance
5. Test **"Reset All to Theme Defaults"** — header color picker should show the theme's header color, not body text color
6. Test **existing saved presets** still load correctly (override system intact)
7. Open **Appearance panel** — header color picker should show white (HC Night) or medium blue (LC Night) when no override is active
