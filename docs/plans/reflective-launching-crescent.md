# Plan: Update CHANGELOG.md

## Context

Five commits have been made since the last changelog entry (v0.2.60, 2026-02-28). These include a major new feature (image support), several bug fixes, documentation updates, and cleanup. The `[Unreleased]` section is currently empty and needs to be populated.

## Changes to Document

Based on commits `01f0bff` through `18058f0`:

### Added
- **Image support with paste/drop import** — paste or drag images into either editor; copies to `media/` directory inside `.ff` project package; inserts standard markdown image syntax. Includes `/image` slash command and toolbar button.
- **Inline image previews** — both Milkdown and CodeMirror render previews below image markdown lines using `projectmedia://` custom URL scheme (MediaSchemeHandler)
- **Image caption editing popup** — click-to-edit caption popup in CodeMirror for image captions

### Fixed
- **CodeMirror caption lookup** — captions were never found because `buildDecorations()` only checked the immediately preceding line (always blank). Added backward scan (up to 3 lines, skipping blanks) to find caption comments.
- **Image caption contrast** — changed captions from `--editor-muted` to `--editor-text` in both editors; captions are user content, not UI chrome
- **CodeMirror inline styles** — moved static inline styles from `image-preview-plugin.ts` to CSS classes in `styles.css`
- **Caption duplication on roundtrips** — BlockParser now keeps `<!-- caption: -->` comments attached to following image lines in `splitIntoRawBlocks`, preventing remark-stringify blank-line insertion from splitting them into separate blocks
- **CodeMirror blank display** — block decorations (image previews) use StateField instead of ViewPlugin; CM6 throws RangeError otherwise

### Changed
- Removed diagnostic logging from image-preview-plugin

## File to Modify

- `CHANGELOG.md` — populate the `[Unreleased]` section with the above entries

## Verification

- Read the updated CHANGELOG.md to confirm formatting matches Keep a Changelog style
- Confirm all 5 commits are represented
