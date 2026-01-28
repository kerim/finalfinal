# App Icon (FF Logo) Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add an app icon showing "FF" in orange on black background.

**Architecture:** Create Assets.xcassets with AppIcon.appiconset containing PNG images at all required macOS sizes. Use Python/Pillow to generate the images programmatically.

**Tech Stack:** Python + Pillow (image generation), xcodegen (project regeneration)

---

### Task 1: Create Asset Catalog Structure

**Files:**
- Create: `final final/Assets.xcassets/Contents.json`
- Create: `final final/Assets.xcassets/AppIcon.appiconset/Contents.json`

**Step 1: Create Assets.xcassets directory**

Run: `mkdir -p "final final/Assets.xcassets/AppIcon.appiconset"`

**Step 2: Create root Contents.json**

Write to `final final/Assets.xcassets/Contents.json`:
```json
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

**Step 3: Create AppIcon Contents.json**

Write to `final final/Assets.xcassets/AppIcon.appiconset/Contents.json`:
```json
{
  "images" : [
    {
      "filename" : "icon_16x16.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_16x16@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "16x16"
    },
    {
      "filename" : "icon_32x32.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_32x32@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "32x32"
    },
    {
      "filename" : "icon_128x128.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_128x128@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "128x128"
    },
    {
      "filename" : "icon_256x256.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_256x256@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "256x256"
    },
    {
      "filename" : "icon_512x512.png",
      "idiom" : "mac",
      "scale" : "1x",
      "size" : "512x512"
    },
    {
      "filename" : "icon_512x512@2x.png",
      "idiom" : "mac",
      "scale" : "2x",
      "size" : "512x512"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

**Step 4: Verify structure exists**

Run: `ls -la "final final/Assets.xcassets/AppIcon.appiconset/"`
Expected: Both Contents.json files present

---

### Task 2: Generate Icon Images

**Files:**
- Create: `/tmp/claude/generate_icon.py` (temporary script)
- Create: `final final/Assets.xcassets/AppIcon.appiconset/icon_*.png` (10 files)

**Step 1: Check Pillow availability**

Run: `python3 -c "from PIL import Image, ImageDraw, ImageFont; print('Pillow OK')"`
Expected: "Pillow OK"

If fails, run: `pip3 install Pillow`

**Step 2: Write icon generation script**

Write to `/tmp/claude/generate_icon.py`:
```python
#!/usr/bin/env python3
from PIL import Image, ImageDraw, ImageFont
import os

OUTPUT_DIR = "/Users/niyaro/Documents/Code/final final/final final/Assets.xcassets/AppIcon.appiconset"

# macOS icon sizes: (name, pixel_size)
SIZES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

ORANGE = (255, 102, 0)  # #FF6600
BLACK = (0, 0, 0)

def create_icon(size):
    """Create FF icon at given pixel size."""
    img = Image.new('RGB', (size, size), BLACK)
    draw = ImageDraw.Draw(img)

    # Try to use a bold system font, fall back to default
    font_size = int(size * 0.55)
    try:
        # Try macOS system fonts
        for font_name in ['/System/Library/Fonts/SFNSDisplayCondensed-Bold.otf',
                          '/System/Library/Fonts/Helvetica.ttc',
                          '/Library/Fonts/Arial Bold.ttf']:
            if os.path.exists(font_name):
                font = ImageFont.truetype(font_name, font_size)
                break
        else:
            font = ImageFont.load_default()
    except:
        font = ImageFont.load_default()

    text = "FF"

    # Get text bounding box for centering
    bbox = draw.textbbox((0, 0), text, font=font)
    text_width = bbox[2] - bbox[0]
    text_height = bbox[3] - bbox[1]

    x = (size - text_width) // 2 - bbox[0]
    y = (size - text_height) // 2 - bbox[1]

    draw.text((x, y), text, fill=ORANGE, font=font)

    return img

def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    for filename, pixel_size in SIZES:
        img = create_icon(pixel_size)
        path = os.path.join(OUTPUT_DIR, filename)
        img.save(path, 'PNG')
        print(f"Created: {filename} ({pixel_size}x{pixel_size})")

    print(f"\nAll icons saved to: {OUTPUT_DIR}")

if __name__ == "__main__":
    main()
```

**Step 3: Run the script**

Run: `python3 /tmp/claude/generate_icon.py`
Expected: 10 "Created:" messages, one per icon size

**Step 4: Verify icons created**

Run: `ls -la "final final/Assets.xcassets/AppIcon.appiconset/"*.png | wc -l`
Expected: 10

---

### Task 3: Regenerate Xcode Project and Build

**Files:**
- Modify: `final final.xcodeproj/` (auto-regenerated)

**Step 1: Regenerate Xcode project**

Run: `cd "/Users/niyaro/Documents/Code/final final" && xcodegen generate`
Expected: "Generated project" message

**Step 2: Build the app**

Run: `cd "/Users/niyaro/Documents/Code/final final" && xcodebuild -scheme "final final" -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: "BUILD SUCCEEDED"

**Step 3: Verify icon in built app**

Run: `ls "/Users/niyaro/Documents/Code/final final/build/Build/Products/Debug/final final.app/Contents/Resources/AppIcon.icns" 2>/dev/null && echo "Icon bundled" || echo "Check build output path"`
Expected: "Icon bundled" (path may vary based on build config)

---

### Task 4: Visual Verification

**Step 1: Open the app**

Run: `open "/Users/niyaro/Documents/Code/final final/build/Build/Products/Debug/final final.app"`

**Step 2: User confirms icon appears**

Check: App icon visible in Dock showing orange "FF" on black background

---

### Task 5: Commit

**Step 1: Stage new files**

Run: `cd "/Users/niyaro/Documents/Code/final final" && git add "final final/Assets.xcassets"`

**Step 2: Commit**

Run: `git commit -m "feat: add FF app icon (orange on black)"`

---

## Verification Checklist

- [ ] Assets.xcassets structure exists with Contents.json files
- [ ] 10 PNG icon files generated at correct sizes
- [ ] xcodegen regenerates project without errors
- [ ] App builds successfully
- [ ] Icon visible in Dock when app runs
- [ ] Icon visible in Finder for .app bundle
