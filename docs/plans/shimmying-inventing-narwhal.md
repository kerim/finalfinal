# Plan: Update CHANGELOG.md for changes since v0.2.61

## Context

One commit (`718d77e`) landed after the v0.2.61 release. It adds two new export formats, improves PDF image handling, and fixes the Export Preferences menu item.

## Changes

Update the `[Unreleased]` section in `CHANGELOG.md` with:

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

## File to modify

- `CHANGELOG.md` (line 7, under `[Unreleased]`)

## Verification

- Open `CHANGELOG.md` and confirm the new entries are under `[Unreleased]`
- Confirm no duplication with v0.2.61 entries
