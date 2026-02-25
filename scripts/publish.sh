#!/bin/bash
#
# publish.sh
# Filters private files from main and pushes clean commits to origin/main.
#
# Private entries excluded from the public tree:
#   docs/  CLAUDE.md  .claude/  test-data/
#
# How it works:
#   For each commit in origin/main..main, create a new commit with the same
#   author/date/message but a tree that omits private top-level entries.
#   Chain these filtered commits linearly on the "public" ref, then push
#   public -> origin/main.
#
# Idempotent: always rebuilds the public chain starting from origin/main,
# so re-running after a failed push is safe.
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

# Top-level entries to exclude from public tree
PRIVATE_ENTRIES=(docs CLAUDE.md .claude test-data)

# Ensure we have the latest remote state
echo -e "${YELLOW}Fetching origin...${NC}"
git fetch origin

# The base: where origin/main currently points
ORIGIN_MAIN=$(git rev-parse origin/main)

# Commits to filter: everything on main that origin/main doesn't have
COMMITS=$(git rev-list --reverse "$ORIGIN_MAIN..main")

if [ -z "$COMMITS" ]; then
    echo -e "${GREEN}Nothing to publish -- main is up to date with origin/main.${NC}"
    exit 0
fi

COUNT=$(echo "$COMMITS" | wc -l | tr -d ' ')
echo -e "${YELLOW}Filtering $COUNT commit(s)...${NC}"

# Start the public chain from origin/main
PARENT="$ORIGIN_MAIN"

for COMMIT in $COMMITS; do
    # Get the tree for this commit
    TREE=$(git rev-parse "$COMMIT^{tree}")

    # Build a filtered tree by removing private entries
    # git ls-tree format: "<mode> <type> <hash>\t<name>"  (one tab before name)
    FILTERED_TREE=$(git ls-tree "$TREE" | while IFS=$'\t' read -r mode_info name; do
        SKIP=false
        for ENTRY in "${PRIVATE_ENTRIES[@]}"; do
            if [ "$name" = "$ENTRY" ]; then
                SKIP=true
                break
            fi
        done
        if [ "$SKIP" = false ]; then
            printf '%s\t%s\n' "$mode_info" "$name"
        fi
    done | git mktree)

    # Preserve original author, committer, dates, and message
    AUTHOR_NAME=$(git log -1 --format='%an' "$COMMIT")
    AUTHOR_EMAIL=$(git log -1 --format='%ae' "$COMMIT")
    AUTHOR_DATE=$(git log -1 --format='%aI' "$COMMIT")
    COMMITTER_NAME=$(git log -1 --format='%cn' "$COMMIT")
    COMMITTER_EMAIL=$(git log -1 --format='%ce' "$COMMIT")
    COMMITTER_DATE=$(git log -1 --format='%cI' "$COMMIT")
    MESSAGE=$(git log -1 --format='%B' "$COMMIT")

    # Create the filtered commit with the same metadata
    NEW_COMMIT=$(
        GIT_AUTHOR_NAME="$AUTHOR_NAME" \
        GIT_AUTHOR_EMAIL="$AUTHOR_EMAIL" \
        GIT_AUTHOR_DATE="$AUTHOR_DATE" \
        GIT_COMMITTER_NAME="$COMMITTER_NAME" \
        GIT_COMMITTER_EMAIL="$COMMITTER_EMAIL" \
        GIT_COMMITTER_DATE="$COMMITTER_DATE" \
        git commit-tree "$FILTERED_TREE" -p "$PARENT" -m "$MESSAGE"
    )

    PARENT="$NEW_COMMIT"
done

# Update the public ref
git update-ref refs/heads/public "$PARENT"
echo -e "${GREEN}  public ref updated ($COUNT filtered commit(s))${NC}"

# Safety check: origin/main must be an ancestor of the new public tip
if ! git merge-base --is-ancestor "$ORIGIN_MAIN" public; then
    echo -e "${RED}Error: origin/main is not an ancestor of public. Aborting push.${NC}"
    echo -e "${RED}This could mean local history was rewritten. Investigate before pushing.${NC}"
    exit 1
fi

# Push public -> origin/main
echo -e "${YELLOW}Pushing to origin/main...${NC}"
git push origin public:main
echo -e "${GREEN}  Published to origin/main${NC}"
