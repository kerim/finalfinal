# Zoom Word Count Stale During Editing

Word counts in the sidebar didn't update while zoomed into a section.

---

## Symptom

When zoomed into a section, typing text didn't update the section's word count in the sidebar. Word counts only refreshed when exiting zoom.

## Root Cause

`observeOutlineBlocks` in `Database+BlocksObservation.swift` used `.removeDuplicates()`. This observation queries heading blocks only. When body text changes:

1. BlockSyncService polls (300ms) and updates body blocks in DB
2. DB write triggers re-evaluation of the heading-only observation
3. Query returns identical heading rows (body text changed, not headings)
4. `.removeDuplicates()` suppresses the emission
5. Word count recalculation in `EditorViewState` never runs

**Why it worked on zoom-out:** `withContentStateRecovery()` in `ViewNotificationModifiers.swift` calls `refreshSections()` on every `contentState` transition back to idle.

**Why it was less noticeable outside zoom:** Non-zoomed mode has more frequent `contentState` transitions (bibliography sync, hierarchy enforcement), each triggering `refreshSections()`. During zoom, hierarchy enforcement is skipped (`zoomedSectionIds == nil` guard), so `refreshSections()` is rarely called.

## Fix

Removed `.removeDuplicates()` from `observeOutlineBlocks` in `Database+BlocksObservation.swift`.

**Why this is safe:**
- GRDB fires ValueObservation once per committed transaction, not per row (~3 emissions/sec max)
- Existing guards (`isObservationSuppressed`, `contentState == .idle`) prevent processing during unsafe states
- The observation returns <100 rows — below GRDB's threshold where `.removeDuplicates()` provides meaningful benefit
- Word count queries (`sectionOnlyWordCount`, `wordCountForHeading`) are simple SQL aggregates

## Related Changes (same branch)

This was the second fix on the `section-goals` branch. The first commit added aggregate goals and section-only word counts (see word-count.md).
