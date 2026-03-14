# Finder Open URL Encoding (False Alarm)

**Date:** 2026-03-14
**Severity:** None (not a code bug)
**Status:** Resolved

## Symptom

Opening a .ff file via osascript failed: the integrity checker rejected the path as invalid (content.sqlite not found).

## Root Cause

Diagnostic logging revealed the URL received by `application(_:open:)` contained `%0A%20%20` (newline + 2 spaces) in the path. This was caused by iTerm copy-paste inserting line breaks into the long osascript command, NOT by Apple Events or app code.

The app's Finder-open code was correct. The integrity checker correctly rejected the malformed path.

## Lesson

When debugging Apple Events / URL-based open handlers, always verify the raw URL path for encoding artifacts from the invocation method before investigating app code.

## Related Changes

While investigating, the following improvements were made:

### Validate-before-close pattern

`DocumentManager.openProject(at:)` and `forceOpenProject(at:)` were refactored to validate the new project BEFORE calling `closeProject()`. Previously, `closeProject()` was called first, so if validation failed, the user was left with no project open.

### Launch guard

`DocumentManager.hasCompletedInitialOpen` prevents re-entrant project opens from macOS state restoration replaying menu actions or SwiftUI `.task` re-firing during launch. `FileCommands.openRecentProject()` checks this flag before proceeding.

### Finder file-open stash pattern

`AppDelegate.finderOpenURL` stashes the URL when `application(_:open:)` fires before the app has finished launching (no project open yet). `FinalFinalApp.determineInitialState()` consumes this stashed URL, avoiding a race where `restoreLastProject()` would overwrite the Finder intent.
