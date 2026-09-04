#!/bin/bash
#
# release.sh
# Publishes a GitHub release with versioned zip and changelog entry.
# Run ./scripts/build.sh first to create the zip.
#
# Release-only — see CLAUDE.md §Release-Artifact Guardrails and
# .claude/hooks/deny-build-sh.sh, which denies this to Claude everywhere
# except one run /ship has just authorized via build/.ship-authorized.
#
# Flags:
#   --no-verify        Skip the Build-v-commit / tested-commit check below.
#   --non-interactive  Never open bbedit for a changelog draft (Option C) —
#                       abort instead if CHANGELOG.md has no usable entry.
#   --detach           Relaunch this same invocation detached (setsid),
#                       writing build/release.log and, on exit,
#                       build/release.exit with the real exit code. Poll
#                       build/release.exit; its absence means still running.
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

NO_VERIFY=0
NON_INTERACTIVE=0
DETACH=0
for arg in "$@"; do
  case "$arg" in
    --no-verify) NO_VERIFY=1 ;;
    --non-interactive) NON_INTERACTIVE=1 ;;
    --detach) DETACH=1 ;;
    *) echo "release.sh: unknown option: $arg" >&2; exit 1 ;;
  esac
done

if [ "$DETACH" = 1 ]; then
  mkdir -p "$PROJECT_DIR/build"
  rm -f "$PROJECT_DIR/build/release.exit"
  child_args=""
  [ "$NO_VERIFY" = 1 ] && child_args="$child_args --no-verify"
  [ "$NON_INTERACTIVE" = 1 ] && child_args="$child_args --non-interactive"
  /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' -- \
    /bin/bash -c "\"$0\" $child_args > \"$PROJECT_DIR/build/release.log\" 2>&1; echo \$? > \"$PROJECT_DIR/build/release.exit\"" \
    < /dev/null &
  disown
  echo "detached — poll build/release.exit (absent = still running); tail -f build/release.log to watch"
  exit 0
fi

# Single-use token, deleted as the first real action — see build.sh's
# identical comment.
rm -f "$PROJECT_DIR/build/.ship-authorized"

# The pre-existing appcast-tmp-dir trap (below, once APPCAST_TMP exists)
# REPLACES this one when it's installed — that's fine, this one has nothing
# left to do by the time execution gets that far, and Step 1 through the
# changelog step below all still want an EXIT trap covering the token, which
# is why this one exists at all rather than leaving that gap.
trap 'rm -f "$PROJECT_DIR/build/.ship-authorized"' EXIT

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

# Gate: this version's Build v$VERSION commit must be HEAD (or HEAD reached
# only via release.sh's own "Release v$VERSION" commit — the documented
# re-run path after a partial failure), and build.sh's own marker must say
# it tested that Build commit's parent. Prevents releasing a build.sh run
# that tested one commit while a DIFFERENT one ended up as "Build v$VERSION"
# (e.g. from stacking two release attempts without an intervening build).
NOTES_LINE=""
if [ "$NO_VERIFY" = 1 ]; then
    echo -e "${YELLOW}--no-verify: skipping the Build-commit / tested-commit check.${NC}"
    SHIP_HASH="$(git rev-parse --short HEAD)"
    LAST_GREEN_NOTE="none"
    if [ -f "$PROJECT_DIR/build/.release-verification" ]; then
        LAST_GREEN_LINE="$(grep '^last_green=' "$PROJECT_DIR/build/.release-verification" | cut -d= -f2-)"
        [ -n "$LAST_GREEN_LINE" ] && LAST_GREEN_NOTE="$LAST_GREEN_LINE"
    fi
    NOTES_LINE="Full UI suite: check skipped (--no-verify); last green run on ${LAST_GREEN_NOTE}, shipping ${SHIP_HASH}"
    echo ""
else
    echo -e "${YELLOW}Checking Build v${VERSION} provenance...${NC}"
    MARKER="$PROJECT_DIR/build/.release-verification"
    if [ ! -f "$MARKER" ]; then
        echo -e "${RED}Error: no build/.release-verification marker — run build.sh first (or pass --no-verify).${NC}"
        exit 1
    fi
    BUILD_COMMIT="$(git log -1 --first-parent --grep="^Build v${VERSION}\$" --format=%H 2>/dev/null || true)"
    if [ -z "$BUILD_COMMIT" ]; then
        echo -e "${RED}Error: no 'Build v${VERSION}' commit found on this branch's first-parent history.${NC}"
        exit 1
    fi
    cur="$(git rev-parse HEAD)"
    reached=0
    for _ in 1 2 3 4 5; do
        if [ "$cur" = "$BUILD_COMMIT" ]; then
            reached=1
            break
        fi
        subject="$(git log -1 --format=%s "$cur" 2>/dev/null || true)"
        if [ "$subject" = "Release v${VERSION}" ]; then
            cur="$(git rev-parse "${cur}^" 2>/dev/null || true)"
            [ -n "$cur" ] || break
            continue
        fi
        break
    done
    if [ "$reached" != 1 ]; then
        echo -e "${RED}Error: HEAD isn't 'Build v${VERSION}' ($BUILD_COMMIT), and isn't reachable from it only through this version's own 'Release v${VERSION}' commit.${NC}"
        echo -e "${RED}Run build.sh again, or pass --no-verify.${NC}"
        exit 1
    fi
    TESTED_COMMIT="$(grep '^tested_commit=' "$MARKER" | cut -d= -f2-)"
    BUILD_PARENT="$(git rev-parse "${BUILD_COMMIT}^")"
    if [ "$TESTED_COMMIT" != "$BUILD_PARENT" ]; then
        echo -e "${RED}Error: build/.release-verification tested $TESTED_COMMIT, but Build v${VERSION}'s parent is $BUILD_PARENT — stale marker from an earlier build.${NC}"
        echo -e "${RED}Run build.sh again, or pass --no-verify.${NC}"
        exit 1
    fi
    MARKER_STATUS="$(grep '^status=' "$MARKER" | cut -d= -f2-)"
    if [ "$MARKER_STATUS" = "verified" ]; then
        NOTES_LINE="Full UI suite: passed on $(git rev-parse --short "$TESTED_COMMIT")"
    else
        LAST_GREEN_LINE="$(grep '^last_green=' "$MARKER" | cut -d= -f2-)"
        [ -n "$LAST_GREEN_LINE" ] || LAST_GREEN_LINE="none"
        NOTES_LINE="Full UI suite: check skipped (--no-verify at build time); last green run on ${LAST_GREEN_LINE}, shipping $(git rev-parse --short "$TESTED_COMMIT")"
    fi
    echo -e "${GREEN}  Verified: Build v${VERSION} tested $TESTED_COMMIT${NC}"
    echo ""
fi

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

        # --no-verify: this commit contains only CHANGELOG.md (Step 1 requires a
        # clean tree), so the pre-commit hook's unit-test run would test nothing new.
        git add CHANGELOG.md
        git commit --no-verify -m "Release v${VERSION}"

    # Option C: Draft from commits and open editor
    else
        if [ "$NON_INTERACTIVE" = 1 ]; then
            echo -e "${RED}Error: no versioned or [Unreleased] changelog entry for v${VERSION}, and --non-interactive can't open an editor to draft one.${NC}"
            echo -e "${RED}Add content under ## [Unreleased] in CHANGELOG.md first, or run release.sh without --non-interactive.${NC}"
            exit 1
        fi
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

        # --no-verify: changelog-only commit, same reasoning as Option B above.
        git add CHANGELOG.md
        git commit --no-verify -m "Release v${VERSION}"
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
# Replaces the token-only trap installed near the top of this script — that
# one has nothing left to do by this point (the token is already gone), and
# an EXIT trap installed later always replaces an earlier one rather than
# stacking, so this consolidates cleanup into the one that's actually live
# for the rest of the script: token (idempotent — already deleted) + the
# appcast temp dir.
trap 'rm -f "$PROJECT_DIR/build/.ship-authorized"; rm -rf "$APPCAST_TMP"' EXIT

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

# Tag the public (filtered) commit, not main.
# Reuse an existing tag so a re-run after a partial failure picks up where it
# left off instead of erroring (versions are never reused, so an existing
# v${VERSION} tag can only come from an earlier attempt at this same release).
echo -e "${YELLOW}Tagging v${VERSION}...${NC}"
if git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null; then
    echo -e "${GREEN}  Tag already exists (previous attempt) - reusing${NC}"
else
    git tag "v${VERSION}" public
    echo -e "${GREEN}  Tagged${NC}"
fi
echo ""

# Push the tag (no-op if the remote already has it)
echo -e "${YELLOW}Pushing tag...${NC}"
git push origin "v${VERSION}"
echo -e "${GREEN}  Pushed${NC}"
echo ""

# Record the tested-commit provenance in the release notes themselves —
# NOTES_LINE was set by the Build-v-commit gate above (or its --no-verify
# branch), so this always has a value by the time we reach here.
if [ -n "$NOTES_LINE" ]; then
    printf '\n---\n%s\n' "$NOTES_LINE" >> "$TMPFILE"
fi

# Create GitHub release (or finish a partially-created one on re-run)
echo -e "${YELLOW}Creating GitHub release...${NC}"
if gh release view "v${VERSION}" >/dev/null 2>&1; then
    echo "  Release already exists (previous attempt) - re-uploading zip..."
    gh release upload "v${VERSION}" "$ZIP_PATH" --clobber
else
    gh release create "v${VERSION}" "$ZIP_PATH" --title "v${VERSION}" --notes-file "$TMPFILE"
fi

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
