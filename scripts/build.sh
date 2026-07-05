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
RELEASES_DIR="$PROJECT_DIR/releases"
APP_NAME="FINAL|FINAL"
SIGN_IDENTITY="Developer ID Application"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Build: $APP_NAME${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Step 0: Build web bundle and run unit tests — fail fast, before the version
# bump, signing, and notarization. Nothing has been mutated yet, so a failure
# here exits cleanly with no rollback needed. The web bundle must be built
# first: the unit tests load the bundled editor, and Step 6's commit relies on
# this run (it commits with --no-verify to skip the pre-commit hook's re-run).
echo -e "${YELLOW}Step 0: Running unit tests...${NC}"

cd "$PROJECT_DIR"

echo "  Building web editors..."
cd web && pnpm build && cd ..

if ! bash "$PROJECT_DIR/scripts/check-xcode-not-holding-project.sh"; then
    echo -e "${RED}Error: Xcode is running with a build/test in flight, so it wasn't safe to quit automatically.${NC}"
    echo -e "${RED}Wait for that build/test to finish, then retry.${NC}"
    exit 1
fi

echo "  Generating Xcode project..."
xcodegen generate

echo "  Verifying scheme..."
bash "$PROJECT_DIR/scripts/verify-scheme.sh"

echo "  Running unit tests..."
xcodebuild test \
    -project "final final.xcodeproj" \
    -scheme "final final" \
    -destination 'platform=macOS' \
    -only-testing 'final finalTests' \
    CODE_SIGN_IDENTITY='-' \
    CODE_SIGN_STYLE=Manual
touch "$PROJECT_DIR/.last-test-pass"

echo -e "${GREEN}  Unit tests passed${NC}"
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

# Revert version bump and clean up leftover notarize zip if any later step fails.
# Without this, an aborted build leaves project.yml/package.json/pbxproj at the bumped
# version with no corresponding distribution zip — which breaks ffrelease.
cleanup_on_failure() {
    local exit_code=$?
    trap - EXIT
    if [ $exit_code -ne 0 ]; then
        echo ""
        echo -e "${RED}Build failed — reverting version bump and cleaning up...${NC}"
        sed -i '' "s/CURRENT_PROJECT_VERSION: \"$NEW_VERSION\"/CURRENT_PROJECT_VERSION: \"$CURRENT_VERSION\"/" "$PROJECT_YML" 2>/dev/null || true
        sed -i '' "s/\"version\": \"$NEW_VERSION\"/\"version\": \"$CURRENT_VERSION\"/" "$PACKAGE_JSON" 2>/dev/null || true
        sed -i '' "s/CURRENT_PROJECT_VERSION = $NEW_VERSION;/CURRENT_PROJECT_VERSION = $CURRENT_VERSION;/g" "$PROJECT_DIR/final final.xcodeproj/project.pbxproj" 2>/dev/null || true
        rm -f "$PROJECT_DIR/build/notarize-tmp.zip"
        rm -f "$RELEASES_DIR/FINAL-FINAL-v${NEW_VERSION}.zip" 2>/dev/null || true
        echo -e "${YELLOW}  Reverted to v$CURRENT_VERSION${NC}"
    fi
}
trap cleanup_on_failure EXIT

# Step 1b: Clean stale QuickLook extension registrations (DerivedData leftovers)
# Each xcodegen run creates a new project hash → new DerivedData dir → new .appex copy.
# Safe: build.sh uses its own -derivedDataPath "$PROJECT_DIR/build", not these.
echo "  Removing stale DerivedData directories..."
rm -rf ~/Library/Developer/Xcode/DerivedData/final_final-*

# Step 2: Build the app (web bundle already built in Step 0; regenerate the
# Xcode project again because the version bump changed project.yml)
echo -e "${YELLOW}Step 2: Building the app...${NC}"

cd "$PROJECT_DIR"

if ! bash "$PROJECT_DIR/scripts/check-xcode-not-holding-project.sh"; then
    echo -e "${RED}Error: Xcode is running with a build/test in flight, so it wasn't safe to quit automatically.${NC}"
    echo -e "${RED}Wait for that build/test to finish, then retry.${NC}"
    exit 1
fi

echo "  Generating Xcode project..."
xcodegen generate

echo "  Verifying scheme..."
bash "$PROJECT_DIR/scripts/verify-scheme.sh"

echo "  Building macOS app..."
xcodebuild -scheme "final final" -configuration Release -destination 'platform=macOS' -derivedDataPath "$PROJECT_DIR/build" build

# Verify build succeeded
BUILD_PATH="$PROJECT_DIR/build/Build/Products/Release/$APP_NAME.app"
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

# Step 4: Developer ID sign for distribution (Gatekeeper-compatible)
# Sign inside-out: extension first (with sandbox entitlement), then main app.
# WARNING: Never use --deep here — it strips entitlements from nested components.
echo -e "${YELLOW}Step 4: Developer ID signing for distribution...${NC}"

APPEX_PATH="/Applications/$APP_NAME.app/Contents/PlugIns/QuickLook Extension.appex"
QL_ENTITLEMENTS="$PROJECT_DIR/QuickLook Extension/QuickLook Extension.entitlements"
APP_ENTITLEMENTS="$PROJECT_DIR/final final/final final.entitlements"

# Sign embedded frameworks first (skip Sparkle — handled below with inside-out signing)
FRAMEWORKS_DIR="/Applications/$APP_NAME.app/Contents/Frameworks"
if [ -d "$FRAMEWORKS_DIR" ]; then
    echo "  Signing embedded frameworks..."
    for framework in "$FRAMEWORKS_DIR"/*.framework; do
        [[ "$(basename "$framework")" == "Sparkle.framework" ]] && continue
        [ -d "$framework" ] && codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$framework"
    done
fi

# Sign Sparkle's nested components inside-out before signing the framework.
# Sparkle 2.x ships these pre-signed with its own cert; all must be re-signed with Developer ID.
# --preserve-metadata=entitlements preserves Sparkle's embedded entitlements (XPC sandbox,
# network-client, privilege grants). Do not remove — stripping them breaks update functionality.
# Use Versions/Current (symlink) rather than Versions/B to survive future Sparkle version bumps.
SPARKLE_FW="/Applications/$APP_NAME.app/Contents/Frameworks/Sparkle.framework/Versions/Current"
if [ -d "$SPARKLE_FW" ]; then
    echo "  Signing Sparkle XPC services..."
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
        --preserve-metadata=entitlements \
        "$SPARKLE_FW/XPCServices/Downloader.xpc"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
        --preserve-metadata=entitlements \
        "$SPARKLE_FW/XPCServices/Installer.xpc"
    echo "  Signing Sparkle helper tools..."
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
        --preserve-metadata=entitlements \
        "$SPARKLE_FW/Autoupdate"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
        --preserve-metadata=entitlements \
        "$SPARKLE_FW/Updater.app"
    echo "  Signing Sparkle.framework..."
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
        "/Applications/$APP_NAME.app/Contents/Frameworks/Sparkle.framework"
fi

# Sign the QuickLook extension (must exist, must be sandboxed)
if [ ! -d "$APPEX_PATH" ]; then
    echo -e "${RED}Error: QuickLook extension not found at $APPEX_PATH${NC}"
    exit 1
fi

echo "  Signing QuickLook extension (sandboxed)..."
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --entitlements "$QL_ENTITLEMENTS" "$APPEX_PATH"

echo "  Signing main app..."
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --entitlements "$APP_ENTITLEMENTS" "/Applications/$APP_NAME.app"

# Verify the signature is valid
echo "  Verifying code signature..."
if ! codesign --verify --deep --strict "/Applications/$APP_NAME.app" 2>&1; then
    echo -e "${RED}Error: Code signature verification failed${NC}"
    exit 1
fi

echo -e "${GREEN}  Developer ID signed and verified${NC}"
echo ""

# Step 4b: Register QuickLook extension
echo -e "${YELLOW}Step 4b: Registering QuickLook extension...${NC}"
pluginkit -a "$APPEX_PATH"
echo -e "${GREEN}  QuickLook extension registered${NC}"
echo ""

# Step 4c: Notarize and staple
echo -e "${YELLOW}Step 4c: Notarizing...${NC}"

NOTARIZE_ZIP="$PROJECT_DIR/build/notarize-tmp.zip"
ditto -c -k --sequesterRsrc --keepParent "/Applications/$APP_NAME.app" "$NOTARIZE_ZIP"
xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "final-final-notary" --wait
rm -f "$NOTARIZE_ZIP"

echo "  Stapling notarization ticket..."
xcrun stapler staple "/Applications/$APP_NAME.app"

echo -e "${GREEN}  Notarized and stapled${NC}"
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

# Step 5b: Archive to releases/ and prune to last 5 zips
echo -e "${YELLOW}Step 5b: Archiving to releases/...${NC}"

mkdir -p "$RELEASES_DIR"
cp "$ZIP_PATH" "$RELEASES_DIR/"

# Prune: keep 5 most recent by mtime (ls -t is reliable for sequentially-written zips).
# Filenames are well-formed (no spaces) so ls + xargs is safe here.
ls -t "$RELEASES_DIR"/FINAL-FINAL-v*.zip 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true

echo -e "${GREEN}  Archived (kept last 5 releases)${NC}"
echo ""

# Step 6: Commit version bump. --no-verify skips the pre-commit test hook:
# Step 0 already ran the unit tests against this exact tree, and re-running
# them here would rebuild from cold DerivedData after notarization.
echo -e "${YELLOW}Step 6: Committing version bump...${NC}"
cd "$PROJECT_DIR"
git add project.yml web/package.json "final final.xcodeproj/project.pbxproj"
git commit --no-verify -m "Build v${NEW_VERSION}"
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
