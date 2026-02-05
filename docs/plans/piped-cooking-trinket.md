# Plan: Replace App Icon

## Goal
Replace the current app icon with the new FIF image at all required macOS icon sizes.

## Source Image
`/Users/niyaro/Downloads/ChatGPT Image Feb 5, 2026, 05_08_14 PM.png`

## Target Location
`/Users/niyaro/Documents/Code/final final/final final/Assets.xcassets/AppIcon.appiconset/`

## Required Icon Files

| Filename | Pixel Dimensions |
|----------|------------------|
| `icon_16x16.png` | 16×16 |
| `icon_16x16@2x.png` | 32×32 |
| `icon_32x32.png` | 32×32 |
| `icon_32x32@2x.png` | 64×64 |
| `icon_128x128.png` | 128×128 |
| `icon_128x128@2x.png` | 256×256 |
| `icon_256x256.png` | 256×256 |
| `icon_256x256@2x.png` | 512×512 |
| `icon_512x512.png` | 512×512 |
| `icon_512x512@2x.png` | 1024×1024 |

## Implementation Steps

1. **Use `sips` to resize** the source image to each required size
   - `sips` is macOS's built-in image processing tool
   - No external dependencies needed

2. **Generate all 10 icon files** directly into the AppIcon.appiconset directory

3. **Verify** by building the app and checking the icon appears correctly

## Commands

```bash
# Resize source image to all required sizes
sips -z 16 16 "source.png" --out "icon_16x16.png"
sips -z 32 32 "source.png" --out "icon_16x16@2x.png"
sips -z 32 32 "source.png" --out "icon_32x32.png"
sips -z 64 64 "source.png" --out "icon_32x32@2x.png"
sips -z 128 128 "source.png" --out "icon_128x128.png"
sips -z 256 256 "source.png" --out "icon_256x256.png"
sips -z 256 256 "source.png" --out "icon_128x128@2x.png"
sips -z 512 512 "source.png" --out "icon_256x256@2x.png"
sips -z 512 512 "source.png" --out "icon_512x512.png"
sips -z 1024 1024 "source.png" --out "icon_512x512@2x.png"
```

## Verification
- Build the app with `xcodebuild -scheme "final final" -destination 'platform=macOS' build`
- Check the app icon in Finder
- Launch the app and verify dock icon
