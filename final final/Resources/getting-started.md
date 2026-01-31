# Welcome to final final

final final is a distraction-free writing app for long-form projects. Whether you're working on a novel, academic paper, or documentation, final final helps you focus on your words.

## What's New in Version 1

- **WYSIWYG editing** with Milkdown — see your formatting as you type
- **Source mode** with CodeMirror — edit raw markdown with syntax highlighting
- **Outline sidebar** — navigate, organize, and track sections
- **Focus mode** — dim surrounding text to concentrate on your current paragraph
- **Section management** — status tracking, word goals, and tags
- **Citations** — integrate with Zotero via Better BibTeX
- **Version history** — save and restore snapshots of your work

## Quick Start

1. **Create a project** — Use File → New Project to start writing
2. **Start typing** — Your work saves automatically to the project
3. **Organize with headings** — Use # for H1, ## for H2, and so on
4. **Navigate** — Click sections in the sidebar to jump to them

## Key Features

### Focus Mode
Press **⌘⇧F** to dim everything except the paragraph you're editing. This helps maintain flow during longer writing sessions.

### Source View
Press **⌘/** to toggle between WYSIWYG and source view. Source mode shows raw markdown for precise editing.

### Section Management
Each heading becomes a section in the sidebar. Right-click sections to:
- Set a **status** (Next, Writing, Waiting, Review, Final)
- Add **word goals** with progress tracking
- Organize with **tags**

### Drag and Drop
Reorganize your document by dragging sections in the sidebar. Heading levels adjust automatically to maintain proper hierarchy.

### Version History
Press **⌘⇧S** to save a named version. Access all versions with **⌘⌥V** to compare or restore previous drafts.

## Keyboard Shortcuts

| Action | Shortcut |
|--------|----------|
| New Project | ⌘N |
| Open Project | ⌘O |
| Save | ⌘S |
| Save Version | ⌘⇧S |
| Version History | ⌘⌥V |
| Toggle Source View | ⌘/ |
| Toggle Focus Mode | ⌘⇧F |
| Export Markdown | ⌘⇧E |
| Import Markdown | ⌘⇧I |

## Slash Commands

Type `/` in the editor to access quick commands:
- `/h1` through `/h6` — Insert headings
- `/break` — Insert a section break
- `/cite` — Search and insert citations (requires Zotero + BBT)

## Citations

To use citations, install [Zotero](https://www.zotero.org) with the [Better BibTeX](https://retorque.re/zotero-better-bibtex/) plugin. Then:
1. Type `/cite` in the editor
2. Search your library
3. Select a reference to insert

Citations appear as formatted text (Author, Year) and a bibliography section is generated automatically.

## Giving Feedback

We'd love to hear from you! Report bugs and request features at:

**GitHub Issues:** [github.com/kerim/final-final/issues](https://github.com/kerim/final-final/issues)

---

*This is the Getting Started guide. Your changes won't be saved here — create a new project to start your own work.*
