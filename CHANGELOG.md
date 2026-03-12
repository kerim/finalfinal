# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- **Bibliography corruption from block ID proximity theft** — `assignBlockIds()` used greedy proximity matching in document order, so new paragraphs near the bibliography boundary could steal a bibliography entry's ID before the real entry claimed it. Refactored to two-phase matching: Phase 1 claims exact-position matches, Phase 2 collects all proximity candidates globally and assigns closest-first. Added `isBibliography` guard in `applyBlockChangesFromEditor` to reject editor-sync updates to machine-generated bibliography blocks. Supporting fixes: split bibliography into per-entry blocks, filter empty fragments in `assembleMarkdown`, reorder inserts before updates, cursor clamping at bibliography boundary, force-flush JS changes before DB reads, queue bibliography/notes notifications when contentState is non-idle.

### Changed

- **DebugLog category system replaces ~336 print() calls** — added `DebugLog.swift` with 14 toggleable categories (sync, editor, scheme, lifecycle, zotero, etc.). Only `.lifecycle` and `.zotero` enabled by default. Migrated all `#if DEBUG`/`print()`/`#endif` blocks to `DebugLog.log(.category, ...)` one-liners across 59 files. JS `errorHandler` bridge now routes by message type (`sync-diag` → `.sync`, others → `.editor`). Mass-delete safety guards use `DebugLog.always()` (prints in all builds). 11 previously unguarded error-path prints are now debug-only. Net reduction: ~460 lines removed.
- **Minor cleanup** — replaced `pendingIdRemap = new Map()` with `.clear()` at 4 sites; removed wasteful full-row `fetchOutlineBlocks` query in DEBUG block (only needed `.count`)

### Added

- **BlockParser alignment tests** — test coverage for `idsForProseMirrorAlignment()` list-item collapsing

## [0.2.74] - 2026-03-10

### Fixed

- **Version history empty after block migration** — `sectionSyncService.contentChanged()` was removed during the block-based architecture migration, leaving the section table empty. Re-added the call in the content change handler. Also added `syncNow()` on project load and before snapshot creation to ensure sections are always fresh.
- **Snapshots using stale content** — `SnapshotService` now assembles fresh markdown from blocks (the source of truth) instead of reading the potentially stale `content.markdown` field, for both manual and auto snapshots
- **Version history showing all sections as New** — `parseAndGetSections()` created random UUIDs for current sections, so they never matched snapshot section IDs. Replaced with `syncNow()` + `loadSections()` which fetches real DB sections with stable IDs. Also added title+headerLevel fallback matching for old snapshots that lack `snapshotSection` rows.
- **Old snapshots showing no sections** — added `fetchOrParseSnapshotSections()` fallback that parses sections from `previewMarkdown` when the `snapshotSection` table has no rows for a given snapshot
- **Version history contrast in High Contrast Day theme** — toolbar uses dark `sidebarBackground` instead of `.preferredColorScheme`; explicit `.listRowBackground` for sidebar selection highlight; column headers use full `sidebarBackground` + `sidebarText`; section hover uses universal `editorText.opacity(0.08)`
- **Coordinator stale project after window close** — `VersionHistoryCoordinator.close()` now clears `projectId` to prevent stale state on reopen

## [0.2.73] - 2026-03-08

### Fixed

- **Image sizing regression in CodeMirror** — non-resized images now display at the same size as Milkdown (fixed CSS `max-height` override that removed inline style instead of overriding the stylesheet rule); resized image widths are now preserved when switching editors (Cmd+/) and when reopening documents (fixed initialization ordering so image metadata is pushed before content)

## [0.2.72] - 2026-03-08

### Changed

- **Keyboard shortcuts cleaned up** — removed conflicting and redundant keyboard shortcuts: spelling/grammar toggles (Cmd+;), insert shortcuts (section break, highlight, footnote, task, comment, reference, image), export shortcuts (Cmd+Option+E, Cmd+Option+P), version history (Cmd+Option+V), import (Cmd+Shift+I), refresh citations (Cmd+Shift+R), and per-theme shortcuts. Fixed Find and Replace shortcut from Cmd+H to Cmd+Option+F.
- **Build script stale DerivedData cleanup** — replaced `pluginkit -r` with direct removal of stale `DerivedData/final_final-*` directories to fix duplicate QuickLook extension registrations caused by xcodegen project hash changes

### Added

- **Pre-build script for stale DerivedData cleanup** — added xcodegen pre-build phase to remove old DerivedData directories, preventing duplicate QuickLook extension registrations during Xcode builds
- **Developer ID signing and notarization** — added `CODE_SIGN_IDENTITY`, `DEVELOPMENT_TEAM`, and hardened runtime to both targets in `project.yml`; build script now uses Developer ID signing with timestamp, notarization via `notarytool`, and stapling before zip creation; README updated to remove Gatekeeper workaround instructions

## [0.2.71] - 2026-03-07

### Fixed

- **Portrait images rendering smaller in CodeMirror than Milkdown** — removed orientation-based max-height logic that capped portrait images at 400px; images without explicit width now render at full container width in both editors. Added image metadata bridge from Swift to CodeMirror for width/height awareness.

## [0.2.70] - 2026-03-07

### Added

- **Document-level annotations** — annotations not anchored to markdown text (charOffset = -1), stored in the database only. Includes CRUD operations, menu commands (Edit > Add Document Note), and a collapsible "Document Notes" section in the annotation panel.
- **Annotation panel section headers** — centered headers for "Document Notes" and "Inline Notes" sections
- **Version history comparison mode** — picker to compare snapshots against current version or previous snapshot, with section-level change highlighting
- **Snapshot deduplication** — auto-backups use SHA256 content hash to skip duplicate snapshots

### Fixed

- **Version history window restoration** — fixed window not restoring on launch using `defaultLaunchBehavior` and AppDelegate cleanup; use `dismissWindow(id:)` instead of `dismiss()` for standalone Window scene
- **Version history loading flash** — prioritize loading state in view body to avoid flash of wrong content
- **Version history stale data** — fetch sections from database instead of potentially stale editorState

## [0.2.68] - 2026-03-07

### Added

- **Heading level filter** — `###` filter button in outline sidebar to toggle visibility of sub-subsection cards
- **Section highlight on hover** — hovering a sidebar card highlights the corresponding section in the editor; optimized with `highlightSection()`/`clearHighlight()` API to avoid repeated `evaluateJavaScript` overhead
- **Hover tooltip on card titles** — instant tooltip showing full section title when text is truncated, using NSFont measurement for truncation detection

### Fixed

- **#Notes scroll failure in Milkdown** — Swift's BlockParser creates separate blocks per list item, but ProseMirror merges consecutive same-type list items into single nodes, causing block ID count mismatch. Added `idsForProseMirrorAlignment()` to collapse consecutive same-type list block IDs before sending to JS.
- **Scroll to zoomed section on exit zoom** — saved `zoomedSectionId` before async `zoomOut` clears it, then scrolls after zoom-out completes; wired `onContentAcknowledged` through CodeMirrorEditor
- **CodeMirror horizontal overflow** — fixed width issues causing horizontal scrollbar in source editor
- **Tooltip z-index rendering behind next card** — moved tooltip from per-card overlay to ScrollView-level overlay to fix NSViewRepresentable z-order issue where cards drew on top of previous cards' SwiftUI overlays

## [0.2.67] - 2026-03-04

### Fixed

- **Annotation click-to-scroll drift in CodeMirror** — CodeMirror used `charOffset` from raw markdown, but `sourceContent` has section anchors (~40-46 bytes each) injected before headings, causing cumulative position drift. Switched both editors to ordinal index matching: annotation's zero-based index is looked up via each editor's own `getAnnotations()` function.
- **More/less button in annotation cards** — separate hover zone from card highlight, full-width clickable hit target instead of small centered pill, keep "less" button visible when expanded, correct SwiftUI gesture ordering (double-tap priority over single-tap), reset expansion state when annotation text changes.

### Changed

- **Annotation sidebar simplified** — rewritten `AnnotationCardView` and `AnnotationPanel` with reduced complexity (~70 lines net reduction); removed `AnnotationViewModel`.
- **Image caption prompt hidden when not hovering** — Milkdown caption prompt only appears on mouse hover, reducing visual noise.
- **Zoom into section** — section zoom now correctly loads in the editor (1-line fix enabling the feature).

## [0.2.66] - 2026-03-03

### Added

- **Scroll sync between editors** — anchor-map interpolation system (`scroll-map.ts`) walks PM nodes and markdown lines in parallel with type-dispatch matching, replacing text-matching approach that drifted on duplicate text. Uses linear interpolation for sub-line precision with floating-point `topLine`. Cached by PM doc identity.
- **Shared popup positioning utility** (`web/shared/position-popup.ts`) — viewport-aware positioning (flip above/below, horizontal clamping) extracted from annotation, citation, and link popups
- **`updateHeadingLevels()` API** — new `window.FinalFinal` method for surgical heading-level changes without full-document DB round-trips

### Fixed

- **Image width/caption lost on heading change** — hierarchy enforcement did a full-document DB round-trip that discarded figure attributes (width, blockId); replaced with surgical ProseMirror `setNodeMarkup()` for WYSIWYG, string replacement for source mode
- **Image width regression during `setContent()`** — figure attributes (width, blockId) now captured before markdown re-parse and restored after via positional matching with src verification

### Changed

- **Annotation panel font size increased** for readability
- **CursorPosition.topLine** changed from `Int` to `Double` for fractional scroll positions
- **Popup positioning consolidated** — annotation-edit, citation-edit, link-tooltip, and image-caption popups now use shared `positionPopup()` utility
- **Diagnostic logging reduced** — ~71→~20 focused logs; added `sync-debug` module for conditional JS logging

## [0.2.64] - 2026-03-02

### Added

- **CodeMirror image paste/drop handlers** — images can now be pasted or dropped into CodeMirror editor
- **Image metadata preservation** — `replaceBlocks`/`replaceBlocksInRange` now preserve image metadata through block operations
- **Sheet-modal alerts for image import errors**

### Fixed

- **5 race conditions** — continuation guard (nil-before-resume for CheckedContinuation), atomic flush (remove redundant metadata pre-read), generation counters for debounce tasks, stale poll detection via contentGeneration counter, consolidation of 6 suppression flags into centralized contentState checks
- **Image width/caption lost on editor switch** — `batchInitialize()` and `setContentWithBlockIds()` raced on the JS thread when switching CM→Milkdown; fix skips content in `performBatchInitialize()` when `isResettingContent` is true
- **Image placement: sizing, drag-and-drop, and scrolling** — remembering image size, drag-and-drop, and scroll position for images
- **`evaluateJavaScript` threading violation** — `TaskGroup.addTask` doesn't inherit `@MainActor` isolation, causing WKWebView call on cooperative pool; wrapped in `DispatchQueue.main.async`
- **WAL checkpoint self-contention** — Save As used `write {}` which opened `BEGIN IMMEDIATE`, causing SQLite error 6; switched to `writeWithoutTransaction` + passive checkpoint
- **Main Thread Checker violation** — same root cause as threading fix above

### Changed

- **Debug logging cleanup** — wrapped ~189 `print()` statements in `#if DEBUG` guards across 40 Swift files; removed verbose loop/iteration prints; cleaned up `console.log` in find-replace.ts
- **Removed color header log spam**

## [0.2.63] - 2026-03-01

### Added

- **Save As** — File > Save As... copies the current `.ff` project to a new location; uses PASSIVE WAL checkpoint to avoid database lock errors; updates the project title in the copied database to match the new filename

## [0.2.62] - 2026-03-01

### Added

- **Markdown with Images export** — exports `.md` file + `<name>_images/` folder with copied images
- **TextBundle export** — exports `.textbundle` package (`text.md` + `assets/` + `info.json`) with standard markdown (no Pandoc attributes)
- **DOCX/ODT heading numbering** — `native_numbering` Pandoc extension for Word/LibreOffice exports

### Fixed

- **Export Preferences menu** — replaced private `showSettingsWindow:` selector with `@Environment(\.openSettings)`; added `NSApp.activate()` for fullscreen focus; PreferencesView now switches to Export tab on notification
- **PDF image handling** — unsupported formats (WebP, HEIC, GIF, TIFF, SVG) are now auto-converted to PNG for xelatex; Pandoc receives `--resource-path` for correct `media/` image resolution
- **PDF image alt text** — uses `fig-alt` attribute instead of caption comments

### Changed

- Registered `org.textbundle.package` UTType

## [0.2.61] - 2026-03-01

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

## [0.2.60] - 2026-02-28

### Fixed

- **Content loss on project switch/close/quit** — editor content polled every 2s by BlockSyncService was silently discarded when `stopPolling()` was called during project transitions. Added `flushAllPendingContent()` that fetches fresh content from the WebView, writes blocks to the database, and flushes section/annotation metadata before any lifecycle transition (project switch, close, and app quit).

## [0.2.59] - 2026-02-27

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
