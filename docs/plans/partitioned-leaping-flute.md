# Rebrand: Replace Icon and Rename to FINAL|FINAL

## Overview

Replace the app icon with the new F|F image and rename user-facing text from "final final" to "FINAL|FINAL" while keeping all technical identifiers unchanged to avoid breaking functionality.

## Part 1: Icon Replacement

### Source Image
`/Users/niyaro/Downloads/ChatGPT Image Feb 5, 2026, 04_21_20 PM.png`

### Target Location
`final final/Assets.xcassets/AppIcon.appiconset/`

### Required Icon Sizes (10 files)

| Filename | Actual Pixels | Size/Scale |
|----------|---------------|------------|
| icon_16x16.png | 16×16 | 16pt @1x |
| icon_16x16@2x.png | 32×32 | 16pt @2x |
| icon_32x32.png | 32×32 | 32pt @1x |
| icon_32x32@2x.png | 64×64 | 32pt @2x |
| icon_128x128.png | 128×128 | 128pt @1x |
| icon_128x128@2x.png | 256×256 | 128pt @2x |
| icon_256x256.png | 256×256 | 256pt @1x |
| icon_256x256@2x.png | 512×512 | 256pt @2x |
| icon_512x512.png | 512×512 | 512pt @1x |
| icon_512x512@2x.png | 1024×1024 | 512pt @2x |

### Method
Use `sips` (macOS built-in) to resize the source image to each required size.

---

## Part 2: Text Rebrand

### Files to Modify

#### 1. project.yml (5 changes)
```yaml
# Line 39
PRODUCT_NAME: final final → PRODUCT_NAME: FINAL|FINAL

# Line 54
CFBundleDisplayName: final final → CFBundleDisplayName: FINAL|FINAL

# Line 55
CFBundleName: final final → CFBundleName: FINAL|FINAL

# Line 64
CFBundleTypeName: final final Document → CFBundleTypeName: FINAL|FINAL Document

# Line 71
UTTypeDescription: final final Document → UTTypeDescription: FINAL|FINAL Document
```

#### 2. ProjectPickerView.swift (1 change)
```swift
// Line 33
Text("final final") → Text("FINAL|FINAL")
```

#### 3. DocumentManager.swift (1 change)
```swift
// Line 555 (fallback welcome message)
"# Welcome to final final\n\n..." → "# Welcome to FINAL|FINAL\n\n..."
```

Note: Line 663 references "final final Projects" for demo project detection only - not a required folder location. Users store projects anywhere they choose.

#### 4. README.md
- Update all "FINAL FINAL" occurrences to "FINAL|FINAL"

#### 5. getting-started.md
- Update all "FINAL FINAL" occurrences to "FINAL|FINAL"

---

## Technical Identifiers (DO NOT CHANGE)

These must remain unchanged to avoid breaking functionality:

| Identifier | Current Value | Reason |
|------------|---------------|--------|
| Bundle ID | `com.kerim.final-final` | Apple restriction: no pipes allowed |
| URL scheme | `finalfinal` | No special characters in URL schemes |
| UTType (document) | `com.kerim.final-final.document` | Existing .ff files depend on this |
| UTType (section) | `com.kerim.final-final.section` | Drag-drop uses this |
| Directory names | `final final/` | Must match xcodegen target names |
| Target names | `final final`, `final finalTests` | Must match directory names |
| Database path | `~/Library/Application Support/com.kerim.final-final/` | User data lives here |

---

## Build Steps After Changes

1. Regenerate Xcode project: `xcodegen generate`
2. Rebuild web editors: `cd web && pnpm build`
3. Build the app: `xcodebuild -scheme "final final" -destination 'platform=macOS' build`

---

## Verification Checklist

- [ ] App icon shows F|F design in Dock and Finder
- [ ] App menu bar shows "FINAL|FINAL"
- [ ] Project picker welcome screen shows "FINAL|FINAL"
- [ ] File type in Finder shows "FINAL|FINAL Document"
- [ ] Getting Started guide displays "FINAL|FINAL"
- [ ] Existing .ff project files still open correctly
- [ ] New projects can be created and saved
- [ ] Database/content persists after restart
- [ ] Recent projects list still works

---

## Version Bump

Update `CURRENT_PROJECT_VERSION` in project.yml from `0.2.20` to `0.2.21`.
