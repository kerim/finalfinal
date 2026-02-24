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

cd "$PROJECT_DIR"

# Step 1: Check working tree is clean
echo -e "${YELLOW}Step 1: Checking working tree...${NC}"
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo -e "${RED}Error: Working tree is not clean. Commit or stash changes first.${NC}"
    exit 1
fi
echo -e "${GREEN}  Working tree is clean${NC}"
echo ""

# Step 2: Read current version
VERSION=$(grep 'CURRENT_PROJECT_VERSION:' "$PROJECT_YML" | sed 's/.*"\(.*\)"/\1/')
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

# Step 4: Collect commits since last tag
echo -e "${YELLOW}Step 4: Collecting commits...${NC}"
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "")
if [ -z "$LAST_TAG" ]; then
    echo "  No previous tags found — using full history"
    COMMITS=$(git log --oneline)
else
    echo "  Since tag: $LAST_TAG"
    COMMITS=$(git log "$LAST_TAG..HEAD" --oneline)
fi

if [ -z "$COMMITS" ]; then
    echo -e "${RED}Error: No new commits since $LAST_TAG${NC}"
    exit 1
fi
echo ""

# Step 5: Draft changelog entry
TODAY=$(date +%Y-%m-%d)
TMPFILE=$(mktemp)

cat > "$TMPFILE" <<EOF
## [$VERSION] - $TODAY

### Changed

$(echo "$COMMITS" | sed 's/^[a-f0-9]* /- /')

EOF

echo -e "${YELLOW}Step 5: Edit the changelog entry...${NC}"
echo "  Opening editor. Save and close to continue, or empty the file to abort."
echo ""

# Open editor
${EDITOR:-nano} "$TMPFILE"

# Check if user emptied the file (abort)
if [ ! -s "$TMPFILE" ]; then
    echo -e "${YELLOW}Aborted: changelog entry was empty.${NC}"
    rm -f "$TMPFILE"
    exit 0
fi

# Step 6: Prepend entry to CHANGELOG.md (below ## [Unreleased])
echo -e "${YELLOW}Step 6: Updating CHANGELOG.md...${NC}"

# Read the draft entry
ENTRY=$(cat "$TMPFILE")

# Insert after the ## [Unreleased] line
awk -v entry="$ENTRY" '
    /^## \[Unreleased\]/ {
        print
        print ""
        print entry
        next
    }
    { print }
' "$CHANGELOG" > "$CHANGELOG.tmp" && mv "$CHANGELOG.tmp" "$CHANGELOG"

echo -e "${GREEN}  CHANGELOG.md updated${NC}"
echo ""

# Step 7: Commit
echo -e "${YELLOW}Step 7: Committing...${NC}"
git add CHANGELOG.md
git commit -m "Release v${VERSION}"
echo -e "${GREEN}  Committed${NC}"
echo ""

# Step 8: Tag
echo -e "${YELLOW}Step 8: Tagging v${VERSION}...${NC}"
git tag "v${VERSION}"
echo -e "${GREEN}  Tagged${NC}"
echo ""

# Step 9: Push
echo -e "${YELLOW}Step 9: Pushing to origin...${NC}"
git push origin main --tags
echo -e "${GREEN}  Pushed${NC}"
echo ""

# Step 10: Create GitHub release
echo -e "${YELLOW}Step 10: Creating GitHub release...${NC}"
gh release create "v${VERSION}" "$ZIP_PATH" \
    --title "v${VERSION}" \
    --notes-file "$TMPFILE"

rm -f "$TMPFILE"

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Release v${VERSION} published!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "  https://github.com/kerim/finalfinal/releases/tag/v${VERSION}"
echo ""
echo -e "${GREEN}Done!${NC}"
