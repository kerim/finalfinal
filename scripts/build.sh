#!/bin/bash
#
# build.sh
# Builds the app, installs to /Applications, and creates a versioned zip in build/
#

set -e  # Exit on first error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Paths
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_YML="$PROJECT_DIR/project.yml"
PACKAGE_JSON="$PROJECT_DIR/web/package.json"
APP_NAME="FINAL|FINAL"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Build: $APP_NAME${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Step 1: Auto-increment version
echo -e "${YELLOW}Step 1: Incrementing version...${NC}"

# Read current version from project.yml
CURRENT_VERSION=$(grep -m1 'CURRENT_PROJECT_VERSION:' "$PROJECT_YML" | sed 's/.*"\(.*\)"/\1/')
echo "  Current version: $CURRENT_VERSION"

# Parse version parts (e.g., 0.2.2 -> MAJOR=0, MINOR=2, BUILD=2)
MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1)
MINOR=$(echo "$CURRENT_VERSION" | cut -d. -f2)
BUILD=$(echo "$CURRENT_VERSION" | cut -d. -f3)

# Increment BUILD
NEW_BUILD=$((BUILD + 1))
NEW_VERSION="$MAJOR.$MINOR.$NEW_BUILD"
echo "  New version: $NEW_VERSION"

# Update project.yml
sed -i '' "s/CURRENT_PROJECT_VERSION: \"$CURRENT_VERSION\"/CURRENT_PROJECT_VERSION: \"$NEW_VERSION\"/" "$PROJECT_YML"
echo "  Updated project.yml"

# Update web/package.json
sed -i '' "s/\"version\": \"$CURRENT_VERSION\"/\"version\": \"$NEW_VERSION\"/" "$PACKAGE_JSON"
echo "  Updated web/package.json"

echo -e "${GREEN}  Version incremented to $NEW_VERSION${NC}"
echo ""

# Step 1b: Clean stale QuickLook extension registrations (DerivedData leftovers)
echo "  Cleaning stale QuickLook extension registrations..."
pluginkit -r -i com.kerim.final-final.quicklook 2>/dev/null || true

# Step 2: Build the app
echo -e "${YELLOW}Step 2: Building the app...${NC}"

cd "$PROJECT_DIR"

echo "  Building web editors..."
cd web && pnpm build && cd ..

echo "  Generating Xcode project..."
xcodegen generate

echo "  Building macOS app..."
xcodebuild -scheme "final final" -destination 'platform=macOS' -derivedDataPath "$PROJECT_DIR/build" build

# Verify build succeeded
BUILD_PATH="$PROJECT_DIR/build/Build/Products/Debug/$APP_NAME.app"
if [ ! -d "$BUILD_PATH" ]; then
    echo -e "${RED}Error: Build failed - app not found at $BUILD_PATH${NC}"
    exit 1
fi

echo -e "${GREEN}  Build succeeded${NC}"
echo ""

# Step 3: Install to /Applications
echo -e "${YELLOW}Step 3: Installing to /Applications...${NC}"

if [ -d "/Applications/$APP_NAME.app" ]; then
    echo "  Removing existing installation..."
    rm -rf "/Applications/$APP_NAME.app"
fi

echo "  Copying to /Applications..."
cp -R "$BUILD_PATH" "/Applications/"

echo -e "${GREEN}  Installed to /Applications${NC}"
echo ""

# Step 4: Ad-hoc sign for distribution (allows right-click -> Open on other Macs)
# Sign inside-out: extension first (with sandbox entitlement), then main app.
# WARNING: Never use --deep here — it strips entitlements from nested components.
echo -e "${YELLOW}Step 4: Ad-hoc signing for distribution...${NC}"

APPEX_PATH="/Applications/$APP_NAME.app/Contents/PlugIns/QuickLook Extension.appex"
QL_ENTITLEMENTS="$PROJECT_DIR/QuickLook Extension/QuickLook Extension.entitlements"
APP_ENTITLEMENTS="$PROJECT_DIR/final final/final final.entitlements"

# Sign embedded frameworks first (if any exist)
FRAMEWORKS_DIR="/Applications/$APP_NAME.app/Contents/Frameworks"
if [ -d "$FRAMEWORKS_DIR" ]; then
    echo "  Signing embedded frameworks..."
    for framework in "$FRAMEWORKS_DIR"/*.framework; do
        [ -d "$framework" ] && codesign --force --sign - "$framework"
    done
fi

# Sign the QuickLook extension (must exist, must be sandboxed)
if [ ! -d "$APPEX_PATH" ]; then
    echo -e "${RED}Error: QuickLook extension not found at $APPEX_PATH${NC}"
    exit 1
fi

echo "  Signing QuickLook extension (sandboxed)..."
codesign --force --sign - --entitlements "$QL_ENTITLEMENTS" "$APPEX_PATH"

echo "  Signing main app..."
codesign --force --sign - --entitlements "$APP_ENTITLEMENTS" "/Applications/$APP_NAME.app"

# Verify the signature is valid
echo "  Verifying code signature..."
if ! codesign --verify --deep --strict "/Applications/$APP_NAME.app" 2>&1; then
    echo -e "${RED}Error: Code signature verification failed${NC}"
    exit 1
fi

echo -e "${GREEN}  Ad-hoc signed and verified${NC}"
echo ""

# Step 4b: Register QuickLook extension
echo -e "${YELLOW}Step 4b: Registering QuickLook extension...${NC}"
pluginkit -a "$APPEX_PATH"
echo -e "${GREEN}  QuickLook extension registered${NC}"
echo ""

# Step 5: Create versioned zip in build/
echo -e "${YELLOW}Step 5: Creating zip for distribution...${NC}"

mkdir -p "$PROJECT_DIR/build"

ZIP_NAME="FINAL-FINAL-v${NEW_VERSION}.zip"
ZIP_PATH="$PROJECT_DIR/build/$ZIP_NAME"

# Remove existing zip if present
if [ -f "$ZIP_PATH" ]; then
    rm -f "$ZIP_PATH"
fi

# Use ditto - properly handles macOS app bundles
# Zip from the codesigned copy in /Applications
ditto -c -k --sequesterRsrc --keepParent "/Applications/$APP_NAME.app" "$ZIP_PATH"
echo -e "${GREEN}  Zip created${NC}"
echo ""

# Step 6: Commit version bump
echo -e "${YELLOW}Step 6: Committing version bump...${NC}"
cd "$PROJECT_DIR"
git add project.yml web/package.json "final final.xcodeproj/project.pbxproj"
git commit -m "Build v${NEW_VERSION}"
echo -e "${GREEN}  Committed${NC}"
echo ""

# Summary
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Build Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "  Version: $NEW_VERSION"
echo "  App: /Applications/$APP_NAME.app"
echo "  Zip: $ZIP_PATH"
echo ""
echo -e "${GREEN}Done!${NC}"
