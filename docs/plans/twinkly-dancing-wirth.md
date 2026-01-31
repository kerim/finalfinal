# Build & Distribute Script Plan

## Goal

Create a shell script that builds and distributes the app in one command.

## Script Location

`/Users/niyaro/Documents/Code/final final/scripts/build-and-distribute.sh`

## What the Script Does

### Step 1: Auto-increment Version
Read current version from `project.yml`, increment BUILD number (e.g., 0.2.2 → 0.2.3), update both:
- `project.yml` (CURRENT_PROJECT_VERSION)
- `web/package.json` (version field)

### Step 2: Build the App
```bash
cd "/Users/niyaro/Documents/Code/final final"
cd web && pnpm build && cd ..
xcodegen generate
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

### Step 3: Install to /Applications
```bash
rm -rf "/Applications/final final.app"
cp -R "build/Build/Products/Debug/final final.app" "/Applications/"
```

### Step 4: Copy README to iCloud Share Folder
```bash
cp "README.md" "/Users/niyaro/Library/Mobile Documents/com~apple~CloudDocs/To Share/apps/README.md"
```

### Step 5: Create Zip in iCloud Share Folder
```bash
cd "/Applications"
rm -f "/Users/niyaro/Library/Mobile Documents/com~apple~CloudDocs/To Share/apps/final final.zip"
zip -r "/Users/niyaro/Library/Mobile Documents/com~apple~CloudDocs/To Share/apps/final final.zip" "final final.app"
```

## Script Features

- **Auto-increment**: Bumps BUILD version before each build
- **Error handling**: `set -e` stops on first error
- **Progress messages**: Shows each step as it runs
- **Verification**: Checks build succeeded before copying
- **Portable**: Written in bash (works from fish via `bash script.sh`)

## Files to Create

| File | Purpose |
|------|---------|
| `scripts/build-and-distribute.sh` | Main build script |

## Critical Files Modified

| File | Change |
|------|--------|
| `project.yml` | CURRENT_PROJECT_VERSION incremented |
| `web/package.json` | version field incremented |

## Verification

After running the script:
1. Open `/Applications/final final.app` and verify it launches
2. Check About/version shows new number
3. Check iCloud folder has updated README.md and zip file
4. Verify zip file can be extracted and app runs
