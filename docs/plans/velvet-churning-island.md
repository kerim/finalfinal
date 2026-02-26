# Plan: Write Changelog for Changes Since v0.2.54

## Context

The user wants a changelog entry for all changes since the last release (v0.2.54, 2026-02-26). These changes span about one day of development.

## Proposed Changelog Entry

To be appended under the existing `## [Unreleased]` section in `CHANGELOG.md`:

```markdown
## [Unreleased]

### Added

- **Quick Look extension** — preview .ff files directly in Finder without opening the app. Renders the project title and markdown content with styled headers, code blocks, block quotes, and lists. Reads the SQLite database in read-only immutable mode. Strips annotations and footnotes from preview.
- **Update checker** — Help → Check for Updates queries the GitHub Releases API and shows an alert if a newer version is available, with a direct download link
- **Annotation edit popup** — click an annotation in WYSIWYG mode to open a popup with a textarea for editing. Supports multi-line text (Shift+Enter), Enter to save, Escape to cancel. Task annotations have a clickable icon to toggle completion state.
- **Report an Issue** menu item in Help menu linking to GitHub Issues

### Changed

- Annotations are now atomic ProseMirror nodes (text stored as attribute, no longer editable inline). Editing happens through the new popup.

### Files Modified

- `QuickLook Extension/` (new: `PreviewViewController.swift`, `MarkdownRenderer.swift`, `SQLiteReader.swift`, `Info.plist`, entitlements)
- `final final/Services/UpdateChecker.swift` (new)
- `final final/Commands/HelpCommands.swift` (modified — added Check for Updates and Report an Issue)
- `web/milkdown/src/annotation-edit-popup.ts` (new)
- `web/milkdown/src/annotation-plugin.ts` (modified — atomic node refactor)
- `web/milkdown/src/annotation-display-plugin.ts` (modified)
- `web/milkdown/src/api-annotations.ts` (modified)
- `project.yml` (modified — Quick Look extension target)
- `CHANGELOG.md`
```

## Steps

1. Edit `CHANGELOG.md` to add the entry under `## [Unreleased]`
2. No version number bump (this is unreleased)

## Verification

- Read back `CHANGELOG.md` to confirm formatting matches existing entries
