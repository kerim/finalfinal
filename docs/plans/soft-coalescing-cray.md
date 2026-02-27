# Plan: Update CHANGELOG.md with v0.2.60

## Context

Today (2026-02-28) a critical bug fix was committed and built as v0.2.60: content was being silently lost when switching projects, closing, or quitting the app. The CHANGELOG.md needs to be updated to document this release.

## Change

Edit `CHANGELOG.md` — replace the empty `[Unreleased]` section with a new `[0.2.60] - 2026-02-28` entry:

### Fixed

- **Content loss on project switch/close/quit** — editor content polled every 2s by BlockSyncService was silently discarded when `stopPolling()` was called during project transitions. Added `flushAllPendingContent()` that fetches fresh content from the WebView, writes blocks to the database, and flushes section/annotation metadata before any lifecycle transition (project switch, close, and app quit).

## Files Modified

- `CHANGELOG.md` (line 7–8: replace empty `[Unreleased]` with the new versioned entry)

## Verification

- Read the updated file to confirm formatting matches Keep a Changelog conventions
