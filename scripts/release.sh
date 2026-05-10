#!/bin/bash
#
# release.sh
# Publishes a GitHub release with versioned zip and changelog entry.
# Run ./scripts/build.sh first to create the zip.
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_YML="$PROJECT_DIR/project.yml"
CHANGELOG="$PROJECT_DIR/CHANGELOG.md"
RELEASES_DIR="$PROJECT_DIR/releases"
HOMEPAGE_DIR="/Users/niyaro/Documents/GitHub/finalfinal-homepage"

cd "$PROJECT_DIR"

# Step 1: Check working tree is clean
echo -e "${YELLOW}Step 1: Checking working tree...${NC}"
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo -e "${RED}Error: Working tree is not clean. Commit or stash changes first.${NC}"
    exit 1
fi
if [ ! -d "$HOMEPAGE_DIR/public" ]; then
    echo -e "${RED}Error: Homepage repo not found at $HOMEPAGE_DIR/public${NC}"
    echo -e "${RED}Clone kerim/finalfinal-homepage to $HOMEPAGE_DIR first.${NC}"
    exit 1
fi
if [ ! -d "$RELEASES_DIR" ]; then
    echo -e "${RED}Error: releases/ not found. Run build.sh first.${NC}"
    exit 1
fi
echo -e "${GREEN}  Working tree is clean${NC}"
echo ""

# Step 2: Read current version
VERSION=$(grep -m1 'CURRENT_PROJECT_VERSION:' "$PROJECT_YML" | sed 's/.*"\(.*\)"/\1/')
echo -e "${YELLOW}Step 2: Version is $VERSION${NC}"
echo ""

# Step 3: Check zip exists
ZIP_PATH="$PROJECT_DIR/build/FINAL-FINAL-v${VERSION}.zip"
if [ ! -f "$ZIP_PATH" ]; then
    echo -e "${RED}Error: Zip not found at $ZIP_PATH${NC}"
    echo -e "${RED}Run ./scripts/build.sh first.${NC}"
    exit 1
fi
echo -e "${GREEN}  Zip found: $ZIP_PATH${NC}"
echo ""

# Step 4: Get or create changelog entry
TMPFILE=$(mktemp)
TODAY=$(date +%Y-%m-%d)

# Option A: CHANGELOG.md already has a versioned entry for this version
EXISTING_ENTRY=$(awk "/^## \[$VERSION\]/{found=1; next} /^## \[/{if(found) exit} found" "$CHANGELOG")

if [ -n "$EXISTING_ENTRY" ]; then
    echo -e "${GREEN}Step 4: Found existing changelog entry for $VERSION${NC}"
    echo "$EXISTING_ENTRY" > "$TMPFILE"
    echo ""
else
    # Option B: Non-empty content under ## [Unreleased]
    UNRELEASED=$(awk '/^## \[Unreleased\]/{found=1; next} /^## \[/{if(found) exit} found' "$CHANGELOG")
    UNRELEASED_TRIMMED=$(echo "$UNRELEASED" | sed '/^[[:space:]]*$/d')

    if [ -n "$UNRELEASED_TRIMMED" ]; then
        echo -e "${GREEN}Step 4: Using [Unreleased] changelog content${NC}"
        echo "$UNRELEASED" > "$TMPFILE"
        echo ""

        # Replace [Unreleased] header with fresh empty one + versioned header
        echo -e "${YELLOW}Step 5: Updating CHANGELOG.md...${NC}"
        awk -v version="$VERSION" -v date="$TODAY" '
            /^## \[Unreleased\]/ {
                print "## [Unreleased]"
                print ""
                print "## [" version "] - " date
                next
            }
            { print }
        ' "$CHANGELOG" > "$CHANGELOG.tmp" && mv "$CHANGELOG.tmp" "$CHANGELOG"

        echo -e "${GREEN}  CHANGELOG.md updated${NC}"
        echo ""

        git add CHANGELOG.md
        git commit -m "Release v${VERSION}"

    # Option C: Draft from commits and open editor
    else
        echo -e "${YELLOW}Step 4: No changelog entry found - drafting from commits...${NC}"
        LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
        if [ -z "$LAST_TAG" ]; then
            COMMITS=$(git log --oneline)
        else
            COMMITS=$(git log "$LAST_TAG..HEAD" --oneline)
        fi

        if [ -z "$COMMITS" ]; then
            echo -e "${RED}Error: No new commits since $LAST_TAG${NC}"
            exit 1
        fi

        printf "### Changed\n\n%s\n\n" "$(echo "$COMMITS" | sed 's/^[a-f0-9]* /- /')" > "$TMPFILE"

        echo "  Opening editor. Save and close to continue, or empty the file to abort."
        echo ""
        bbedit --wait "$TMPFILE"

        if [ ! -s "$TMPFILE" ]; then
            echo -e "${YELLOW}Aborted: changelog entry was empty.${NC}"
            rm -f "$TMPFILE"
            exit 0
        fi

        # Prepend entry to CHANGELOG.md (below ## [Unreleased])
        echo -e "${YELLOW}Step 5: Updating CHANGELOG.md...${NC}"
        HEADER="## [$VERSION] - $TODAY"
        BODY=$(cat "$TMPFILE")
        ENTRY=$(printf "%s\n\n%s" "$HEADER" "$BODY")

        awk -v entry="$ENTRY" '/^## \[Unreleased\]/ { print; print ""; print entry; next } { print }' "$CHANGELOG" > "$CHANGELOG.tmp" && mv "$CHANGELOG.tmp" "$CHANGELOG"

        echo -e "${GREEN}  CHANGELOG.md updated${NC}"
        echo ""

        git add CHANGELOG.md
        git commit -m "Release v${VERSION}"
    fi
fi

# Generate appcast (before publishing — validates signing before any public artifact)
echo -e "${YELLOW}Generating appcast...${NC}"

GENERATE_APPCAST="$PROJECT_DIR/build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [ ! -f "$GENERATE_APPCAST" ]; then
    GENERATE_APPCAST=$(find "$PROJECT_DIR/build" -name "generate_appcast" 2>/dev/null | head -1)
fi
if [ -z "$GENERATE_APPCAST" ]; then
    GENERATE_APPCAST=$(find ~/Library/Developer/Xcode/DerivedData -name "generate_appcast" 2>/dev/null | grep "final_final" | head -1)
fi
if [ -z "$GENERATE_APPCAST" ]; then
    echo -e "${RED}Error: generate_appcast not found. Re-run build.sh to restore DerivedData.${NC}"
    exit 1
fi

# Run against a temp dir with ONLY the current zip — generate_appcast rewrites all
# enclosure URLs from scratch, so isolating to one zip ensures correct URL scoping.
APPCAST_TMP=$(mktemp -d)
trap 'rm -rf "$APPCAST_TMP"' EXIT

cp "$RELEASES_DIR/FINAL-FINAL-v${VERSION}.zip" "$APPCAST_TMP/"

# Fetch the EdDSA private key via `security` and pipe to generate_appcast.
# This bypasses the keychain ACL, which breaks whenever Sparkle's adhoc-signed
# generate_appcast is rebuilt with a fresh code-signature hash.
ED_KEY=$(security find-generic-password -s "https://sparkle-project.org" -a "ed25519" -w)
echo "$ED_KEY" | "$GENERATE_APPCAST" \
    --ed-key-file - \
    --download-url-prefix "https://github.com/kerim/finalfinal/releases/download/v${VERSION}/" \
    --maximum-deltas 0 \
    "$APPCAST_TMP/"
unset ED_KEY

cp "$APPCAST_TMP/appcast.xml" "$RELEASES_DIR/appcast.xml"

echo -e "${GREEN}  Appcast generated${NC}"
echo ""

# Publish filtered commits to GitHub
echo -e "${YELLOW}Publishing to GitHub...${NC}"
"$PROJECT_DIR/scripts/publish.sh"
echo -e "${GREEN}  Published${NC}"
echo ""

# Tag the public (filtered) commit, not main
echo -e "${YELLOW}Tagging v${VERSION}...${NC}"
git tag "v${VERSION}" public
echo -e "${GREEN}  Tagged${NC}"
echo ""

# Push the tag
echo -e "${YELLOW}Pushing tag...${NC}"
git push origin "v${VERSION}"
echo -e "${GREEN}  Pushed${NC}"
echo ""

# Create GitHub release
echo -e "${YELLOW}Creating GitHub release...${NC}"
gh release create "v${VERSION}" "$ZIP_PATH" --title "v${VERSION}" --notes-file "$TMPFILE"

rm -f "$TMPFILE"

# Publish appcast to finalfinalapp.cc (after GitHub release asset is live)
echo -e "${YELLOW}Publishing appcast to finalfinalapp.cc...${NC}"
(
    cd "$HOMEPAGE_DIR"
    git pull --rebase
    cp "$RELEASES_DIR/appcast.xml" public/appcast.xml
    git add public/appcast.xml
    git diff --cached --quiet || git commit -m "Update appcast for v${VERSION}"
    git push
) || {
    echo -e "${RED}  Appcast push failed. Retry manually:${NC}"
    echo -e "${RED}  cd $HOMEPAGE_DIR && git push${NC}"
    exit 1
}
echo -e "${GREEN}  Appcast published (Cloudflare build deploys in ~1-3 min)${NC}"
echo ""

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Release v${VERSION} published!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "  https://github.com/kerim/finalfinal/releases/tag/v${VERSION}"
echo ""
echo -e "${GREEN}Done!${NC}"
