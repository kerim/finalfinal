# Deferred: Block-Based Snapshot System

## Problem

The snapshot/version history system (`SnapshotService.swift`, `Snapshot.swift`) was designed for the legacy section-based architecture. It stores `previewMarkdown` (full content text) and `SnapshotSection` records. After the migration to block-based content (v8), the snapshot system was not updated to capture block-level metadata.

This means:
- Block-specific metadata (image caption, width, alt text; section status, tags, word goals on blocks) is lost on snapshot restore
- After restoring, blocks are re-parsed from markdown text, and block-specific DB columns are NULL
- This affects any future block-level metadata (not just images)

## Proposed Solution

Replace the section-based snapshot storage with block-based snapshot storage:

1. Create a `snapshotBlock` table that mirrors the `block` table's columns
2. Snapshot creation: copy all blocks (including image metadata columns) to `snapshotBlock`
3. Snapshot restore: delete current blocks, re-insert from `snapshotBlock` records
4. Keep `previewMarkdown` for display/preview purposes only
5. Deprecate/migrate `snapshotSection` to `snapshotBlock`

## Dependencies

- Must be done before image metadata (caption, width) can survive snapshot round-trips
- Should also capture existing block metadata: status, tags, wordGoal, goalType, aggregateGoal, isBibliography, isNotes, isPseudoSection

## Created

2026-02-28 — discovered during image insertion feature design
