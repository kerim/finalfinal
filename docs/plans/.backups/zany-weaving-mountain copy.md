# Phase 1.1 Project Setup Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create the Xcode project skeleton with GRDB integration and `editor://` URL scheme handler.

**Architecture:** SwiftUI macOS app with GRDB database, WKWebView-based editors (Milkdown + CodeMirror), and custom URL scheme for serving bundled assets.

**Tech Stack:** Swift 5.9+, SwiftUI, macOS 13+, GRDB 7.x, WebKit

---

## Task 1: Create Xcode Project

**Files:**
- Create: `final final.xcodeproj` (via Xcode)
- Create: `final final/` source directory structure

**Step 1: Create project in Xcode**

Open Xcode and create a new project:
1. File > New > Project
2. Select macOS > App
3. Configure:
   - Product Name: `final final`
   - Organization Identifier: `com.kerim`
   - Interface: SwiftUI
   - Language: Swift
   - Storage: None
   - Include Tests: Yes
4. Location: `/Users/niyaro/Documents/Code/final final`
5. Uncheck "Create Git repository"

**Step 2: Set deployment target**

1. Select project in Navigator
2. Select target `final final`
3. General > Minimum Deployments: macOS 13.0

**Step 3: Verify project builds**

Run: `xcodebuild -scheme "final final" -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED

---

## Task 2: Add GRDB Dependency

**Files:**
- Modify: `final final.xcodeproj` (via Xcode)

**Step 1: Add GRDB package**

1. In Xcode: File > Add Package Dependencies...
2. Enter URL: `https://github.com/groue/GRDB.swift`
3. Dependency Rule: Up to Next Major Version, `7.0.0`
4. Click Add Package
5. Select target `final final`, click Add Package

**Step 2: Verify GRDB imports**

Run: `xcodebuild -scheme "final final" -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED

---

## Task 3: Create Directory Structure

**Step 1: Create folder groups in Xcode**

Right-click `final final` source folder, create these groups:
- `App/`
- `Models/`
- `ViewState/`
- `Views/`
- `Editors/`
- `Theme/`
- `Services/`
- `Resources/editor/` (folder reference, not group)

**Step 2: Create web directory structure**

```bash
mkdir -p "/Users/niyaro/Documents/Code/final final/web/milkdown/src"
mkdir -p "/Users/niyaro/Documents/Code/final final/web/codemirror/src"
```

---

## Task 4: Create AppDelegate

**Files:**
- Create: `final final/App/AppDelegate.swift`

**Step 1: Create AppDelegate.swift**

```swift
//
//  AppDelegate.swift
//  final final
//

import AppKit
import GRDB

class AppDelegate: NSObject, NSApplicationDelegate {
    /// Static shared reference - required because NSApp.delegate casting
    /// doesn't work with @NSApplicationDelegateAdaptor
    static var shared: AppDelegate?

    /// The application's database connection
    var database: AppDatabase?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        do {
            database = try AppDatabase.makeDefault()
            print("[AppDelegate] Database initialized successfully")
        } catch {
            print("[AppDelegate] Failed to initialize database: \(error)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("[AppDelegate] Application terminating")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
```

**Step 2: Verify file compiles**

Build will fail until Database.swift exists - expected.

---

## Task 5: Create FinalFinalApp Entry Point

**Files:**
- Modify: `final final/final_finalApp.swift` → move to `final final/App/FinalFinalApp.swift`

**Step 1: Move and update the app entry point**

Move `final_finalApp.swift` to `App/FinalFinalApp.swift` in Xcode (drag in Navigator).

Replace contents:

```swift
//
//  FinalFinalApp.swift
//  final final
//

import SwiftUI

@main
struct FinalFinalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

---

## Task 6: Create Database Layer

**Files:**
- Create: `final final/Models/Database.swift`

**Step 1: Create Database.swift**

```swift
//
//  Database.swift
//  final final
//

import Foundation
import GRDB

struct AppDatabase {
    let dbWriter: any DatabaseWriter

    static func makeDefault() throws -> AppDatabase {
        let dbQueue = try DatabaseQueue()
        let database = AppDatabase(dbWriter: dbQueue)
        try database.migrate()
        return database
    }

    static func make(at path: String) throws -> AppDatabase {
        let dbQueue = try DatabaseQueue(path: path)
        let database = AppDatabase(dbWriter: dbQueue)
        try database.migrate()
        return database
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()

        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "project") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "content") { t in
                t.primaryKey("id", .text)
                t.column("projectId", .text).notNull()
                    .references("project", onDelete: .cascade)
                t.column("markdown", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "outlineNode") { t in
                t.primaryKey("id", .text)
                t.column("projectId", .text).notNull()
                    .references("project", onDelete: .cascade)
                t.column("headerLevel", .integer).notNull()
                t.column("title", .text).notNull()
                t.column("startOffset", .integer).notNull()
                t.column("endOffset", .integer).notNull()
                t.column("parentId", .text)
                    .references("outlineNode", onDelete: .cascade)
                t.column("sortOrder", .integer).notNull()
                t.column("isPseudoSection", .boolean).notNull().defaults(to: false)
            }

            try db.create(index: "outlineNode_projectId", on: "outlineNode", columns: ["projectId"])

            try db.create(table: "settings") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }

        try migrator.migrate(dbWriter)
    }

    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.read(block)
    }

    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.write(block)
    }
}
```

---

## Task 7: Create GRDB Models

**Files:**
- Create: `final final/Models/Document.swift`
- Create: `final final/Models/OutlineNode.swift`

**Step 1: Create Document.swift**

```swift
//
//  Document.swift
//  final final
//

import Foundation
import GRDB

struct Project: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date

    init(id: String = UUID().uuidString, title: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct Content: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var projectId: String
    var markdown: String
    var updatedAt: Date

    init(id: String = UUID().uuidString, projectId: String, markdown: String = "", updatedAt: Date = Date()) {
        self.id = id
        self.projectId = projectId
        self.markdown = markdown
        self.updatedAt = updatedAt
    }
}
```

**Step 2: Create OutlineNode.swift**

```swift
//
//  OutlineNode.swift
//  final final
//

import Foundation
import GRDB

struct OutlineNode: Codable, Identifiable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var projectId: String
    var headerLevel: Int
    var title: String
    var startOffset: Int
    var endOffset: Int
    var parentId: String?
    var sortOrder: Int
    var isPseudoSection: Bool

    init(
        id: String = UUID().uuidString,
        projectId: String,
        headerLevel: Int,
        title: String,
        startOffset: Int,
        endOffset: Int,
        parentId: String? = nil,
        sortOrder: Int,
        isPseudoSection: Bool = false
    ) {
        self.id = id
        self.projectId = projectId
        self.headerLevel = headerLevel
        self.title = title
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.parentId = parentId
        self.sortOrder = sortOrder
        self.isPseudoSection = isPseudoSection
    }
}
```

**Step 3: Verify build**

Run: `xcodebuild -scheme "final final" -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED

---

## Task 8: Create EditorSchemeHandler

**Files:**
- Create: `final final/Editors/EditorSchemeHandler.swift`

**Step 1: Create EditorSchemeHandler.swift**

```swift
//
//  EditorSchemeHandler.swift
//  final final
//
//  Custom URL scheme handler for serving bundled web editor assets.
//  Uses editor:// scheme to load HTML, JS, CSS from the app bundle.
//

import WebKit
import UniformTypeIdentifiers

final class EditorSchemeHandler: NSObject, WKURLSchemeHandler {
    private let resourceSubdirectory = "editor"

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(SchemeError.invalidURL)
            return
        }

        guard let fileURL = bundleURL(for: url) else {
            print("[EditorSchemeHandler] File not found: \(url)")
            urlSchemeTask.didFailWithError(SchemeError.fileNotFound)
            return
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            print("[EditorSchemeHandler] Failed to read: \(fileURL)")
            urlSchemeTask.didFailWithError(SchemeError.readError)
            return
        }

        let mimeType = self.mimeType(for: fileURL)

        let response = HTTPURLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        )

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()

        print("[EditorSchemeHandler] Served: \(url.path) (\(mimeType), \(data.count) bytes)")
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func bundleURL(for url: URL) -> URL? {
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard !pathComponents.isEmpty else { return nil }

        let relativePath = pathComponents.joined(separator: "/")

        return Bundle.main.url(
            forResource: relativePath,
            withExtension: nil,
            subdirectory: resourceSubdirectory
        )
    }

    private func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()

        if let utType = UTType(filenameExtension: ext),
           let mimeType = utType.preferredMIMEType {
            return mimeType
        }

        switch ext {
        case "html", "htm": return "text/html"
        case "js", "mjs": return "application/javascript"
        case "css": return "text/css"
        case "json", "map": return "application/json"
        case "svg": return "image/svg+xml"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        default: return "application/octet-stream"
        }
    }

    enum SchemeError: Error, LocalizedError {
        case invalidURL, fileNotFound, readError

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid URL in editor:// scheme request"
            case .fileNotFound: return "Requested file not found in bundle"
            case .readError: return "Failed to read file data"
            }
        }
    }
}
```

---

## Task 9: Create View Stubs

**Files:**
- Modify: `final final/ContentView.swift` → move to `final final/Views/ContentView.swift`
- Create: `final final/Views/StatusBar.swift`

**Step 1: Move and update ContentView.swift**

Move `ContentView.swift` to `Views/ContentView.swift` in Xcode.

Replace contents:

```swift
//
//  ContentView.swift
//  final final
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            VStack {
                Text("Outline Sidebar")
                    .font(.headline)
                    .padding()
                Spacer()
                Text("Phase 1.6 will implement\nthe full outline view")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
            .frame(minWidth: 200)
        } detail: {
            VStack {
                Spacer()
                Text("Editor Area")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("Phase 1.4-1.5 will add\nMilkdown and CodeMirror editors")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
                StatusBar()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview {
    ContentView()
}
```

**Step 2: Create StatusBar.swift**

```swift
//
//  StatusBar.swift
//  final final
//

import SwiftUI

struct StatusBar: View {
    var body: some View {
        HStack {
            Text("0 words")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text("No section")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text("WYSIWYG")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.2))
                .cornerRadius(4)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

#Preview {
    StatusBar()
}
```

---

## Task 10: Create Remaining Stubs

**Files:**
- Create: `final final/ViewState/EditorViewState.swift`
- Create: `final final/Services/OutlineParser.swift`
- Create: `final final/Theme/ColorScheme.swift`

**Step 1: Create EditorViewState.swift**

```swift
//
//  EditorViewState.swift
//  final final
//

import SwiftUI

enum EditorMode: String, CaseIterable {
    case wysiwyg = "WYSIWYG"
    case source = "Source"
}

@Observable
class EditorViewState {
    var editorMode: EditorMode = .wysiwyg
    var focusModeEnabled: Bool = false
    var zoomedSectionId: String? = nil
    var wordCount: Int = 0
    var characterCount: Int = 0
    var currentSectionName: String = ""

    func toggleEditorMode() {
        editorMode = editorMode == .wysiwyg ? .source : .wysiwyg
    }

    func toggleFocusMode() {
        focusModeEnabled.toggle()
    }

    func zoomToSection(_ sectionId: String) {
        zoomedSectionId = sectionId
    }

    func zoomOut() {
        zoomedSectionId = nil
    }
}
```

**Step 2: Create OutlineParser.swift**

```swift
//
//  OutlineParser.swift
//  final final
//
//  Stub - full implementation in Phase 1.2.
//

import Foundation

struct OutlineParser {
    static func parse(markdown: String, projectId: String) -> [OutlineNode] {
        []
    }

    static func extractPreview(from markdown: String, startOffset: Int, endOffset: Int, maxLines: Int = 4) -> String {
        ""
    }

    static func wordCount(in text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}
```

**Step 3: Create ColorScheme.swift**

```swift
//
//  ColorScheme.swift
//  final final
//
//  Stub - full theming in Phase 1.3.
//

import SwiftUI

struct AppColorScheme: Identifiable, Equatable {
    let id: String
    let name: String
    let sidebarBackground: Color
    let sidebarText: Color
    let sidebarSelectedBackground: Color
    let editorBackground: Color
    let editorText: Color
    let editorSelection: Color
    let accentColor: Color
    let dividerColor: Color
}

extension AppColorScheme {
    static let light = AppColorScheme(
        id: "light",
        name: "Light",
        sidebarBackground: Color(nsColor: .windowBackgroundColor),
        sidebarText: Color(nsColor: .labelColor),
        sidebarSelectedBackground: Color.accentColor.opacity(0.2),
        editorBackground: Color.white,
        editorText: Color.black,
        editorSelection: Color.accentColor.opacity(0.3),
        accentColor: Color.accentColor,
        dividerColor: Color(nsColor: .separatorColor)
    )

    static let dark = AppColorScheme(
        id: "dark",
        name: "Dark",
        sidebarBackground: Color(nsColor: .windowBackgroundColor),
        sidebarText: Color(nsColor: .labelColor),
        sidebarSelectedBackground: Color.accentColor.opacity(0.3),
        editorBackground: Color(white: 0.15),
        editorText: Color.white,
        editorSelection: Color.accentColor.opacity(0.4),
        accentColor: Color.accentColor,
        dividerColor: Color(nsColor: .separatorColor)
    )

    static let all: [AppColorScheme] = [.light, .dark]
}
```

---

## Task 11: Create Web Project Stubs

**Files:**
- Create: `web/package.json`
- Create: `web/pnpm-workspace.yaml`
- Create: `web/milkdown/package.json`
- Create: `web/milkdown/src/main.ts`
- Create: `web/codemirror/package.json`
- Create: `web/codemirror/src/main.ts`

**Step 1: Create web/package.json**

```json
{
  "name": "final-final-web",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "build": "pnpm -r build",
    "dev": "pnpm -r dev"
  },
  "devDependencies": {
    "typescript": "^5.3.0"
  }
}
```

**Step 2: Create web/pnpm-workspace.yaml**

```yaml
packages:
  - 'milkdown'
  - 'codemirror'
```

**Step 3: Create web/milkdown/package.json**

```json
{
  "name": "@final-final/milkdown-editor",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build"
  },
  "devDependencies": {
    "vite": "^5.0.0"
  }
}
```

**Step 4: Create web/milkdown/src/main.ts**

```typescript
// Milkdown WYSIWYG Editor - Stub for Phase 1.1

console.log('[Milkdown] Editor stub loaded');

declare global {
  interface Window {
    FinalFinal: {
      setContent: (markdown: string) => void;
      getContent: () => string;
      setFocusMode: (enabled: boolean) => void;
      getStats: () => { words: number; characters: number };
      scrollToOffset: (offset: number) => void;
    };
  }
}

let currentContent = '';

window.FinalFinal = {
  setContent(markdown: string) {
    currentContent = markdown;
    console.log('[Milkdown] setContent called');
  },
  getContent() {
    return currentContent;
  },
  setFocusMode(enabled: boolean) {
    console.log('[Milkdown] setFocusMode:', enabled);
  },
  getStats() {
    const words = currentContent.split(/\s+/).filter(w => w.length > 0).length;
    return { words, characters: currentContent.length };
  },
  scrollToOffset(offset: number) {
    console.log('[Milkdown] scrollToOffset:', offset);
  }
};

console.log('[Milkdown] window.FinalFinal API registered');
```

**Step 5: Create web/codemirror/package.json**

```json
{
  "name": "@final-final/codemirror-editor",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build"
  },
  "devDependencies": {
    "vite": "^5.0.0"
  }
}
```

**Step 6: Create web/codemirror/src/main.ts**

```typescript
// CodeMirror 6 Source Editor - Stub for Phase 1.1

console.log('[CodeMirror] Editor stub loaded');

declare global {
  interface Window {
    FinalFinal: {
      setContent: (markdown: string) => void;
      getContent: () => string;
      setFocusMode: (enabled: boolean) => void;
      getStats: () => { words: number; characters: number };
      scrollToOffset: (offset: number) => void;
    };
  }
}

let currentContent = '';

window.FinalFinal = {
  setContent(markdown: string) {
    currentContent = markdown;
    console.log('[CodeMirror] setContent called');
  },
  getContent() {
    return currentContent;
  },
  setFocusMode(enabled: boolean) {
    console.log('[CodeMirror] setFocusMode ignored (source mode)');
  },
  getStats() {
    const words = currentContent.split(/\s+/).filter(w => w.length > 0).length;
    return { words, characters: currentContent.length };
  },
  scrollToOffset(offset: number) {
    console.log('[CodeMirror] scrollToOffset:', offset);
  }
};

console.log('[CodeMirror] window.FinalFinal API registered');
```

---

## Task 12: Final Verification

**Step 1: Build the project**

```bash
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED

**Step 2: Run the app**

Open Xcode, press Cmd+R. Verify:
- App launches without crashing
- Console shows: `[AppDelegate] Database initialized successfully`
- Window displays sidebar placeholder and editor area placeholder
- Status bar visible at bottom

**Step 3: Verify database operations**

Temporarily add to AppDelegate.applicationDidFinishLaunching after database init:

```swift
// Test CRUD
if let db = database {
    do {
        try db.write { database in
            var project = Project(title: "Test")
            try project.insert(database)
            print("[Test] Created project: \(project.id)")
        }
        let count = try db.read { db in try Project.fetchCount(db) }
        print("[Test] Project count: \(count)")
    } catch {
        print("[Test] Failed: \(error)")
    }
}
```

Expected console:
```
[AppDelegate] Database initialized successfully
[Test] Created project: <uuid>
[Test] Project count: 1
```

Remove test code after verification.

**Step 4: Commit**

```bash
cd "/Users/niyaro/Documents/Code/final final"
git init
git add .
git commit -m "feat: Phase 1.1 - Project setup with GRDB and editor:// scheme

- Create Xcode project (SwiftUI, macOS 13+)
- Add GRDB 7.x via SPM
- Implement AppDatabase with migrations
- Create Project, Content, OutlineNode GRDB models
- Implement EditorSchemeHandler for editor:// URLs
- Add view stubs (ContentView, StatusBar)
- Add state/service/theme stubs
- Create web project structure for future editors

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Verification Checklist

Phase 1.1 is complete when:

- [ ] Xcode project builds without errors
- [ ] App runs and displays main window
- [ ] GRDB initializes and creates tables (console log confirms)
- [ ] Database CRUD operations work (insert/fetch test passes)
- [ ] EditorSchemeHandler compiles and is ready for use
- [ ] All directory structure matches plan
- [ ] All stub files in place

---

## Critical Files

| File | Purpose |
|------|---------|
| `final final/App/AppDelegate.swift` | Lifecycle + static shared pattern |
| `final final/App/FinalFinalApp.swift` | App entry point |
| `final final/Models/Database.swift` | GRDB setup + migrations |
| `final final/Models/Document.swift` | Project + Content models |
| `final final/Models/OutlineNode.swift` | Outline cache model |
| `final final/Editors/EditorSchemeHandler.swift` | Custom URL scheme handler |
| `final final/Views/ContentView.swift` | Main layout |

---

## Next Phase

**Phase 1.2: Database Layer** will implement:
- Full document CRUD operations
- Complete OutlineParser (markdown → nodes)
- Package-based persistence (.ff folder format)
- Reactive GRDB queries for sidebar
