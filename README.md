# final final

A macOS-native markdown editor designed for long-form academic writing.

**Core philosophy:** SQLite-first architecture where the database is the single source of truth. Documents are structured by headers, enabling section-based editing, reordering, and metadata tracking.

**Version:** 0.1.79 (Phase 1 complete)

## Requirements

- macOS 14.0+ (Sonoma or later)

## Installation (Pre-built App)

1. Download `final-final-X.X.XX.zip`
2. Unzip to extract `final final.app`
3. Move the app to `/Applications` (optional)
4. **First launch:** Right-click → Open (not double-click) to bypass Gatekeeper, or run:
   ```bash
   xattr -cr "final final.app"
   ```

The app isn't notarized, so macOS will warn about an unidentified developer.

## Implemented Features (Phase 1)

| Feature | Description |
|---------|-------------|
| Dual editor modes | WYSIWYG (Milkdown) and Source (CodeMirror) with Cmd+/ toggle |
| Outline sidebar | Hierarchical section cards showing headers with preview text |
| Drag-drop reordering | Move sections with their subtrees, respects hierarchy constraints |
| Focus mode | Dims non-current paragraphs for distraction-free writing |
| Section metadata | Status, tags, and word goals per section |
| Project management | `.ff` package format with embedded database |
| Recent projects | Tracks and displays recently opened projects |
| Color themes | Multiple themes (Dawn, Dusk, Ocean, Forest, Parchment) |
| Import/Export | Markdown import and export |
| Word counting | Real-time word and character statistics |

## Planned Features

| Phase | Features |
|-------|----------|
| 2 | Annotations (Task, Rewrite, Comment markers) |
| 3 | Zotero integration (citations, bibliography) |
| 4 | Version control (Git-based history) |
| 5 | Export (Pandoc integration, templates) |
| 6 | Reference pane (PDFs, images, web pages) |
| 7 | Sync (CloudKit or Cloudflare DO) |

## Architecture

SwiftUI shell + GRDB database + WKWebView editors communicating via custom `editor://` URL scheme.

```
final final/
├── App/          # App lifecycle, entry point
├── Models/       # GRDB models (Document, Section, Project)
├── Services/     # Sync, parsing, demo management
├── ViewState/    # @Observable state management
├── Views/        # SwiftUI views (sidebar, editor, toolbar)
├── Editors/      # WebView wrappers, scheme handler
├── Theme/        # Color schemes
└── web/          # TypeScript editors (Milkdown, CodeMirror)
```

See `CLAUDE.md` for detailed architecture documentation.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+/ | Toggle WYSIWYG/Source mode |
| Cmd+Shift+F | Toggle focus mode |
| Cmd+S | Save |
| Cmd+N | New project |
| Cmd+O | Open project |
| Cmd+W | Close project |
| Cmd+E | Export markdown |

## License

Private project - not for distribution.
