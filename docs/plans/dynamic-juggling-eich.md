# Plan: Update CHANGELOG.md for changes since v0.2.58

## Context

7 commits have landed on `main` after the `v0.2.58` tag (2026-02-27). The `[Unreleased]` section in `CHANGELOG.md` is currently empty and needs to be populated with these changes before the next release.

## File to modify

`/Users/niyaro/Documents/Code/final final/CHANGELOG.md` — line 7, the `[Unreleased]` section.

## Changes to document

### Added
- **PDF export with citation support** — uses Pandoc `--citeproc` with bibliography fetched from Zotero/BBT in CSL-JSON format; bundles Chicago Author-Date citation style (`chicago-author-date.csl`)
- **Multilingual PDF font support** — automatic script detection (CJK, Devanagari, Thai, Bengali, Tamil) with appropriate font mapping; NLLanguageRecognizer disambiguates Simplified vs Traditional Chinese

### Fixed
- **Typing latency** — replaced polling-based editor↔database sync with push-based sync, switched to DatabasePool, improved spellcheck position mapping
- **Citations in PDF export** — PDF format now uses `--citeproc` pipeline instead of Lua filter, resolving broken citation rendering
- **Drag-and-drop reordering** — removed lower limit on heading levels, allowing sections of any depth to be reordered

### Changed
- **ExportService refactored** — extracted helpers (`pdfEngineArguments`, `citationArguments`, `zoteroWarnings`, `fontArguments`) to reduce cyclomatic complexity

## Verification

- Open `CHANGELOG.md` and confirm the `[Unreleased]` section lists the entries above
- Confirm formatting matches existing Keep a Changelog style (bold lead, em-dash, description)
