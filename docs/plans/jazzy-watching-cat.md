# Plan: Write changelog for v0.2.58

## Context

The current version is 0.2.58. The CHANGELOG.md has entries through v0.2.55 with an empty `[Unreleased]` section. Need to add an entry for v0.2.58 covering all changes since v0.2.55 (builds 0.2.56–0.2.58).

## Changes to document

Based on commits `38318c1..HEAD`:

### Fixed
- **QuickLook extension not loading** — added `QLSupportsSecureCoding` to Info.plist, security-scoped resource access, `pluginkit` registration in build script, and fallback plain-text rendering if AppKit conversion fails
- **Build script signing** — replaced `codesign --deep` with inside-out signing (extension first with sandbox entitlements, then main app), added signature verification step

### Changed
- **Dark theme colors** — Night Owl: golden amber accents, darker orange body text (#BD6B15), white headers. Frost: bright cyan accents (#00C8FF), light cyan body text, medium blue headers (#4C98CA)
- **Separate header color** — added `editorHeaderText` property to theme system, with corresponding `--editor-heading-text` CSS variable

### Added
- **Zotero connectivity alert** — shows an alert (with 60-second cooldown) when Zotero isn't running, both during citation search and lazy citekey resolution

## File to modify

- `CHANGELOG.md` — replace `## [Unreleased]` with the new v0.2.58 entry dated 2026-02-27, add fresh `## [Unreleased]` above it

## Answer to user's question

No rebuild needed. `CHANGELOG.md` is a project-level file that isn't bundled in the app binary. It only matters for the GitHub release page.

## Verification

- Read the updated CHANGELOG.md to confirm formatting matches existing entries
