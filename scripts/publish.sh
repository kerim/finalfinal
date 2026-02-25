#!/bin/bash
#
# publish.sh
# Filters private files from main and pushes clean commits to origin/main.
#
# Private entries excluded from the public tree:
#   docs/  CLAUDE.md  .claude/  test-data/
#
# How it works:
#   For each new commit on main (since the last publish), create a new commit
#   with the same author/date/message but a tree that omits private entries.
#   Chain these filtered commits linearly on origin/main, then push.
#
# Tracks progress via refs/publish/last-local to avoid re-filtering commits.
# Use --force for first run or to clean up a diverged remote.
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

# Parse flags
FORCE=false
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        *) echo -e "${RED}Unknown flag: $arg${NC}"; exit 1 ;;
    esac
done

# Top-level entries to exclude from public tree
PRIVATE_ENTRIES=(docs CLAUDE.md .claude test-data)

# Ensure we have the latest remote state
echo -e "${YELLOW}Fetching origin...${NC}"
git fetch origin

ORIGIN_MAIN=$(git rev-parse origin/main)
LOCAL_MAIN=$(git rev-parse main)

# Read the tracking ref (last local commit we filtered)
LAST_LOCAL=$(git rev-parse --verify refs/publish/last-local 2>/dev/null || echo "")

if [ -n "$LAST_LOCAL" ]; then
    # Tracking ref exists — use it for the commit range
    # Verify the tracking ref is an ancestor of local main
    if ! git merge-base --is-ancestor "$LAST_LOCAL" "$LOCAL_MAIN"; then
        echo -e "${RED}Error: refs/publish/last-local (${LAST_LOCAL:0:7}) is not an ancestor of main.${NC}"
        echo -e "${RED}Local history may have been rewritten. Use --force to reset.${NC}"
        exit 1
    fi

    RANGE_BASE="$LAST_LOCAL"
    echo -e "${GREEN}Tracking ref found: ${LAST_LOCAL:0:7}${NC}"
else
    # No tracking ref — first run or migration
    MERGE_BASE=$(git merge-base main origin/main 2>/dev/null || echo "")

    if [ -z "$MERGE_BASE" ]; then
        echo -e "${RED}Error: No common ancestor between main and origin/main.${NC}"
        exit 1
    fi

    # Check if this is a diverged state (remote has commits not in local main)
    if ! git merge-base --is-ancestor "$ORIGIN_MAIN" "$LOCAL_MAIN"; then
        # Diverged: remote has filtered commits that aren't in local history
        if [ "$FORCE" = false ]; then
            echo -e "${RED}Diverged state detected: origin/main has commits not in local main.${NC}"
            echo -e "${RED}This likely means previous publishes duplicated commits on the remote.${NC}"
            echo -e "${YELLOW}Run with --force to clean up the remote:${NC}"
            echo -e "${YELLOW}  scripts/publish.sh --force${NC}"
            exit 1
        fi
        echo -e "${YELLOW}Force mode: will rebuild remote from merge-base (${MERGE_BASE:0:7})${NC}"
    fi

    RANGE_BASE="$MERGE_BASE"
fi

# Commits to filter: everything on main after the range base
COMMITS=$(git rev-list --reverse "$RANGE_BASE..main")

if [ -z "$COMMITS" ]; then
    echo -e "${GREEN}Nothing to publish -- main is up to date.${NC}"
    # Still set tracking ref if missing
    if [ -z "$LAST_LOCAL" ]; then
        git update-ref refs/publish/last-local "$LOCAL_MAIN"
        echo -e "${GREEN}Set tracking ref to ${LOCAL_MAIN:0:7}${NC}"
    fi
    exit 0
fi

COUNT=$(echo "$COMMITS" | wc -l | tr -d ' ')
echo -e "${YELLOW}Filtering $COUNT commit(s)...${NC}"

# Determine parent for the filtered chain
if [ -n "$LAST_LOCAL" ]; then
    # We have a tracking ref, so origin/main should be the correct parent
    PARENT="$ORIGIN_MAIN"
elif [ "$FORCE" = true ] || git merge-base --is-ancestor "$ORIGIN_MAIN" "$LOCAL_MAIN"; then
    # Force mode or non-diverged first run: chain onto merge-base
    # (merge-base commit exists on both sides)
    PARENT="$RANGE_BASE"
else
    PARENT="$ORIGIN_MAIN"
fi

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

# Push public -> origin/main
echo -e "${YELLOW}Pushing to origin/main...${NC}"

if [ "$FORCE" = true ] || [ -z "$LAST_LOCAL" ]; then
    # First run or force: need force push to replace diverged history
    if ! git merge-base --is-ancestor "$ORIGIN_MAIN" public; then
        echo -e "${YELLOW}Force pushing (replacing diverged remote history)...${NC}"
        git push --force-with-lease origin public:main
    else
        git push origin public:main
    fi
else
    # Normal incremental push — should fast-forward
    if ! git merge-base --is-ancestor "$ORIGIN_MAIN" public; then
        echo -e "${RED}Error: origin/main is not an ancestor of public. Aborting push.${NC}"
        echo -e "${RED}This could mean remote was updated externally. Use --force to override.${NC}"
        exit 1
    fi
    git push origin public:main
fi

# After successful push, update the tracking ref
git update-ref refs/publish/last-local "$LOCAL_MAIN"
echo -e "${GREEN}  Published to origin/main${NC}"
echo -e "${GREEN}  Tracking ref set to ${LOCAL_MAIN:0:7}${NC}"
