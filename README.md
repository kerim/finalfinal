# final final

A macOS-native markdown editor designed for long-form academic writing.

**Core philosophy:** SQLite-first architecture where the database is the single source of truth. Documents are structured by headers, enabling section-based editing, reordering, and metadata tracking.

**Version:** 0.2.0 (Alpha)

## Requirements

- macOS 14.0+ (Sonoma or later)
- [Zotero](https://www.zotero.org/) with [Better BibTeX](https://retorque.re/zotero-better-bibtex/) plugin (for citations)
- [Pandoc](https://pandoc.org/) installed at `/opt/homebrew/bin/pandoc` or `/usr/local/bin/pandoc` (for export)

## Installation

1. Download `final-final-0.1.87.zip`
2. Unzip to extract `final final.app`
3. Move the app to `/Applications` (optional)
4. **First launch:** Right-click → Open (not double-click) to bypass Gatekeeper, or run:
   ```bash
   xattr -cr "final final.app"
   ```

The app isn't notarized, so macOS will warn about an unidentified developer.

## Features

### Writing

| Feature | Description |
|---------|-------------|
| Dual editor modes | WYSIWYG (Milkdown) and Source (CodeMirror) with Cmd+/ toggle |
| Focus mode | Dims non-current paragraphs for distraction-free writing |
| Word counting | Real-time word and character statistics |
| Annotations | Task, Comment, Reference markers via `/task`, `/comment`, `/reference` |

### Document Structure

| Feature | Description |
|---------|-------------|
| Outline sidebar | Hierarchical section cards showing headers with preview text |
| Drag-drop reordering | Move sections with their subtrees, respects hierarchy constraints |
| Section metadata | Status, tags, and word goals per section |

### Citations & Bibliography

| Feature | Description |
|---------|-------------|
| Zotero integration | `/cite` command searches your Zotero library via Better BibTeX |
| Inline citations | Citations render as formatted text (Author, Year) in WYSIWYG mode |
| Auto-bibliography | Bibliography section generated from document citations |

**Zotero Setup:**

1. In Zotero settings, under `Advanced`, check `Allow other applications on this computer to communicate with Zotero`
2. Install [Better BibTeX](https://github.com/retorquere/zotero-better-bibtex/releases)
3. In the Better BibTeX section of your Zotero settings, set `Automatically pin citation key after X seconds` to `1`
4. Note: Citation keys need to be **both** set up and pinned in Zotero 8
5. Restart Zotero

**To use:** Keep Zotero running, type `/cite` in the editor to search and insert.

### Export

| Feature | Description |
|---------|-------------|
| Word (.docx) | Export with formatted citations |
| PDF | Export via LaTeX (bundled TinyTeX) |
| ODT | Export to OpenDocument format |
| Markdown | Plain markdown export |

**Export menu:** File → Export → Word/PDF/ODT

### Project Management

| Feature | Description |
|---------|-------------|
| Package format | `.ff` package with embedded SQLite database |
| Recent projects | Quick access to recently opened projects |
| Color themes | Dawn, Dusk, Ocean, Forest, Parchment |

## Planned Features

- Find & Replace
- Editor toolbar (formatting buttons)
- Expanded appearance settings
- Reference pane (PDFs, images, documents)
- Cross-device sync

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
