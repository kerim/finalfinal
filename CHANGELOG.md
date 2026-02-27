# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- **PDF export with citation support** — uses Pandoc `--citeproc` with bibliography fetched from Zotero/BBT in CSL-JSON format; bundles Chicago Author-Date citation style (`chicago-author-date.csl`)
- **Multilingual PDF font support** — automatic script detection (CJK, Devanagari, Thai, Bengali, Tamil) with appropriate font mapping; NLLanguageRecognizer disambiguates Simplified vs Traditional Chinese

### Fixed

- **Typing latency** — replaced polling-based editor↔database sync with push-based sync, switched to DatabasePool, improved spellcheck position mapping
- **Citations in PDF export** — PDF format now uses `--citeproc` pipeline instead of Lua filter, resolving broken citation rendering
- **Drag-and-drop reordering** — removed lower limit on heading levels, allowing sections of any depth to be reordered

### Changed

- **ExportService refactored** — extracted helpers (`pdfEngineArguments`, `citationArguments`, `zoteroWarnings`, `fontArguments`) to reduce cyclomatic complexity

## [0.2.58] - 2026-02-27

### Fixed

- **QuickLook extension not loading** — added `QLSupportsSecureCoding` to Info.plist, security-scoped resource access, `pluginkit` registration in build script, and fallback plain-text rendering if AppKit conversion fails
- **Build script signing** — replaced `codesign --deep` with inside-out signing (extension first with sandbox entitlements, then main app), added signature verification step

### Changed

- **Dark theme colors** — Night Owl: golden amber accents, darker orange body text (#BD6B15), white headers. Frost: bright cyan accents (#00C8FF), light cyan body text, medium blue headers (#4C98CA)
- **Separate header color** — added `editorHeaderText` property to theme system, with corresponding `--editor-heading-text` CSS variable

### Added

- **Zotero connectivity alert** — shows an alert (with 60-second cooldown) when Zotero isn't running, both during citation search and lazy citekey resolution

## [0.2.55] - 2026-02-27

### Added

- **Quick Look extension** — preview .ff files directly in Finder without opening the app. Renders the project title and markdown content with styled headers, code blocks, block quotes, and lists. Reads the SQLite database in read-only immutable mode. Strips annotations and footnotes from preview.
- **Update checker** — Help → Check for Updates queries the GitHub Releases API and shows an alert if a newer version is available, with a direct download link
- **Annotation edit popup** — click an annotation in WYSIWYG mode to open a popup with a textarea for editing. Supports multi-line text (Shift+Enter), Enter to save, Escape to cancel. Task annotations have a clickable icon to toggle completion state.
- **Report an Issue** menu item in Help menu linking to GitHub Issues

### Changed

- Annotations are now atomic ProseMirror nodes (text stored as attribute, no longer editable inline). Editing happens through the new popup.

## [0.2.54] - 2026-02-26

### Added

- **Configurable Focus Mode** — new Preferences → Focus tab with 5 toggles (hide outline sidebar, hide annotation panel, hide toolbar, hide status bar, paragraph highlighting). Settings persist in UserDefaults and are snapshot-at-entry, so focus mode only affects the elements you choose.

### Improved

- Footnote definitions (`[^N]:`) render as styled pills in WYSIWYG mode with click-to-navigate-back and tooltip fade transitions
- Status bar shows the current section name; clicking it opens a section navigation popup
- Slash menu filtering in both editors now matches label prefixes only, preventing false matches

### Fixed

- CodeMirror slash menu positioning uses `requestMeasure` instead of direct `coordsAtPos`, preventing layout glitches
- Status bar section popup display corrected
- Caret now renders properly after scrolling to a footnote definition

## [0.2.52] - 2026-02-24

### Added

- GitHub Releases publishing workflow with versioned zip downloads
- CHANGELOG.md in Keep a Changelog format
- AGPL-3.0 license

### Changed

- Renamed KARMA.md to KUDOS.md
- README.md updated for GitHub (installation links to Releases, roadmap cleaned up)
- Build script refactored: removes iCloud distribution, outputs versioned zip to build/
- Getting-started guide decoupled from README (now maintained independently)

### Fixed

- Removed hardcoded local paths from test files and build scripts

## [0.2.49]

### Fixed

- Fullscreen launch bug fixed

## [0.2.48]

### Changed

- Cleaned up menus

## [0.2.47]

### Added

- Toolbars, status bars, pop-up menus, and other UI niceties

## [0.2.43]

### Added

- Footnotes

## [0.2.42]

### Fixed

- Improved grammar and spell check, skipping annotations, citations, and non-latin script
