# Plan: Create Project README

## Overview

Create a README.md document for the "final final" project that provides:
1. Project description and purpose
2. Technology stack
3. Implemented features (Phase 1 complete)
4. Planned features (Phase 2-7)
5. Build instructions
6. Architecture overview

## Target File

`/Users/niyaro/Documents/Code/final final/README.md`

## README Structure

### 1. Header & Description
- Project name: "final final"
- One-line description: macOS-native markdown editor for long-form academic writing
- Core philosophy: SQLite-first, database as source of truth, header-based structure

### 2. Requirements
- macOS 14.0+
- Node.js/pnpm (for web editor builds)
- Xcode + xcodegen

### 3. Build Instructions
- Web editor build: `cd web && pnpm install && pnpm build`
- Xcode project generation: `xcodegen generate`
- Full build command sequence

### 4. Implemented Features (Phase 1)
- Dual editor modes (WYSIWYG/Source) with Cmd+/ toggle
- Outline sidebar with hierarchical section cards
- Drag-drop section reordering with subtree support
- Focus mode (paragraph dimming)
- Section metadata (status, tags, word goals)
- Project management (.ff packages)
- Recent projects tracking
- Multiple color themes
- Import/export markdown
- Real-time word counting

### 5. Planned Features
| Phase | Features |
|-------|----------|
| 2 | Reference pane (PDFs, images) |
| 3 | Annotations (Task, Rewrite, Comment) |
| 4 | Zotero integration (citations) |
| 5 | Version control (Git-based) |
| 6 | Export (Pandoc, templates) |
| 7 | Sync (CloudKit or Cloudflare DO) |

### 6. Architecture Summary
- Brief overview of Swift ↔ Web communication
- Key directories (Models/, Views/, Services/, web/)
- Link to CLAUDE.md for detailed architecture

### 7. Keyboard Shortcuts
- Table of main shortcuts (Cmd+/, Cmd+Shift+F, theme switches, etc.)

## Verification

After writing the README:
1. Read the file to verify formatting
2. Ensure all sections are present and accurate
3. Check that build commands match CLAUDE.md

## Notes

- Keep the README concise (scan-friendly)
- Use tables for structured information
- Include the current version (0.1.79)
- No badges or unnecessary decorations
