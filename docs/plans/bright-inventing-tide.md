# Update CHANGELOG for Save As feature

## Context

Commit `ad65518` added a "Save As" feature after the v0.2.62 release. The `[Unreleased]` section in `CHANGELOG.md` is currently empty and needs this entry.

## Changes

**File:** `CHANGELOG.md` (line 7, under `[Unreleased]`)

Add under `### Added`:
- **Save As** — File > Save As... copies the current `.ff` project to a new location; uses PASSIVE WAL checkpoint to avoid database lock errors; updates the project title in the copied database to match the new filename

## Verification

- Review the updated CHANGELOG.md to confirm formatting matches existing entries
