# Phase 1.7: Project Management

## Overview

Implement project lifecycle management: creating, opening, saving, and exporting `.ff` package documents.

## Prerequisites

- [x] Phase 1.1: Project Setup
- [x] Phase 1.2: Database Layer
- [x] Phase 1.3: Theme System
- [x] Phase 1.4: Milkdown Editor
- [x] Phase 1.5: CodeMirror Editor
- [x] Phase 1.6: Outline Sidebar (v0.1.48)

## Goals

1. New project creation (creates `.ff` package)
2. Open existing project (file picker for `.ff` packages)
3. Recent projects list
4. Auto-save (debounced 500ms)
5. Import from markdown file
6. Export to markdown file

---

## Package Structure

Each project is a macOS package (folder appearing as single file):

```
MyBook.ff/
├── content.sqlite        # SQLite database (GRDB)
└── references/           # Reference files (Phase 2+)
    └── (user-organized folders)
```

---

## Implementation Tasks

### Task 1: Document Package Type Registration

Register `.ff` as a macOS document package type in `Info.plist`:

```xml
<key>CFBundleDocumentTypes</key>
<array>
    <dict>
        <key>CFBundleTypeName</key>
        <string>final final Document</string>
        <key>CFBundleTypeExtensions</key>
        <array><string>ff</string></array>
        <key>CFBundleTypeRole</key>
        <string>Editor</string>
        <key>LSTypeIsPackage</key>
        <true/>
        <key>LSHandlerRank</key>
        <string>Owner</string>
    </dict>
</array>
```

### Task 2: DocumentManager Service

Create `Services/DocumentManager.swift` to handle project lifecycle:

```swift
@MainActor
@Observable
class DocumentManager {
    var currentProject: Project?
    var recentProjects: [URL] = []
    var hasUnsavedChanges = false

    func newProject(title: String) async throws -> URL
    func openProject(at url: URL) async throws
    func saveProject() async throws
    func closeProject() async throws
    func importMarkdown(from url: URL) async throws -> URL
    func exportMarkdown(to url: URL) async throws
}
```

### Task 3: New Project Flow

1. Show save panel for `.ff` location
2. Create package directory structure
3. Initialize SQLite database with GRDB migrations
4. Create default Project and Content records
5. Open the new project

### Task 4: Open Project Flow

1. Show open panel filtering for `.ff` packages
2. Validate package structure
3. Open SQLite database
4. Load Project and Content into EditorViewState
5. Update recent projects list

### Task 5: Auto-Save Implementation

- Use Combine debounce (500ms) on content changes
- Save to existing database location
- Update `hasUnsavedChanges` flag
- Handle save failures gracefully

### Task 6: Recent Projects

- Store in UserDefaults as array of bookmark data (sandboxing-compatible)
- Show in File menu
- Remove invalid entries on startup

### Task 7: Import/Export Markdown

**Import:**
1. Read `.md` file content
2. Create new project
3. Set content to imported markdown
4. Parse headers for initial outline

**Export:**
1. Get current markdown content
2. Show save panel for `.md` file
3. Write content to file

### Task 8: Menu Commands

Update `Commands/` to add:
- File → New Project (Cmd+N)
- File → Open Project (Cmd+O)
- File → Save (Cmd+S) - manual save
- File → Import Markdown...
- File → Export Markdown...
- File → Recent Projects submenu

---

## Files to Create/Modify

| File | Action |
|------|--------|
| `Services/DocumentManager.swift` | Create |
| `Commands/FileCommands.swift` | Create |
| `Info.plist` | Add document type |
| `project.yml` | Add Info.plist properties |
| `FinalFinalApp.swift` | Integrate DocumentManager |
| `ContentView.swift` | Connect to project lifecycle |

---

## Verification

- [ ] Can create new `.ff` project via File → New
- [ ] New project appears as single file in Finder
- [ ] "Show Package Contents" reveals `content.sqlite`
- [ ] Can open existing `.ff` project
- [ ] Content persists after close and reopen
- [ ] Auto-save triggers 500ms after edits
- [ ] Recent projects appear in File menu
- [ ] Can import `.md` file to new project
- [ ] Can export current project to `.md` file
- [ ] Proper sandboxing with security-scoped bookmarks

---

## Notes

- Currently using in-memory database in `~/Library/Application Support/`
- This phase transitions to per-document SQLite files inside packages
- Security-scoped bookmarks needed for sandbox compatibility with recent files
