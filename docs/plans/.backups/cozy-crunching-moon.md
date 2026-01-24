# Phase 1.2 Database Layer Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Complete the database layer with document CRUD, outline parsing, package-based persistence (.ff format), and reactive GRDB queries.

**Tech Stack:** Swift 5.9+, SwiftUI, macOS 14+, GRDB 7.x

---

## Architecture Decisions

### Database Strategy: Dual-Mode Access
- **App-level database** (Application Support): Recent projects list, global settings
- **Per-project database** (inside .ff package): Project content, outline cache, project settings

### CRUD Organization
- Database extension methods for low-level GRDB operations
- `ProjectStore` service class for coordinating operations and ValueObservation

### ValueObservation Pattern
- Use GRDB's async/await ValueObservation directly with `@Observable` classes
- No GRDBQuery package needed (macOS 14+ has native @Observable)

---

## Task 1: Create Package Support Infrastructure

**File:** `final final/Models/ProjectPackage.swift` (new)

**Step 1:** Create ProjectPackage.swift

```swift
//
//  ProjectPackage.swift
//  final final
//

import Foundation

struct ProjectPackage: Sendable {
    let packageURL: URL

    var databaseURL: URL { packageURL.appendingPathComponent("content.sqlite") }
    var referencesURL: URL { packageURL.appendingPathComponent("references") }

    /// Creates a new .ff package at the specified location
    static func create(at url: URL, title: String) throws -> ProjectPackage {
        let fm = FileManager.default
        let packageURL = url.pathExtension == "ff" ? url : url.appendingPathExtension("ff")

        // Create package directory
        try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)

        // Create references subdirectory
        let refsURL = packageURL.appendingPathComponent("references")
        try fm.createDirectory(at: refsURL, withIntermediateDirectories: true)

        print("[ProjectPackage] Created package at: \(packageURL.path)")
        return ProjectPackage(packageURL: packageURL)
    }

    /// Opens an existing .ff package
    static func open(at url: URL) throws -> ProjectPackage {
        let fm = FileManager.default
        var isDir: ObjCBool = false

        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw PackageError.notFound(url.path)
        }

        let package = ProjectPackage(packageURL: url)
        try package.validate()
        return package
    }

    /// Validates the package structure
    func validate() throws {
        let fm = FileManager.default

        // Database must exist
        guard fm.fileExists(atPath: databaseURL.path) else {
            throw PackageError.missingDatabase
        }
    }

    enum PackageError: Error, LocalizedError {
        case notFound(String)
        case missingDatabase

        var errorDescription: String? {
            switch self {
            case .notFound(let path): return "Package not found at: \(path)"
            case .missingDatabase: return "Package is missing content.sqlite"
            }
        }
    }
}
```

**Verification:** File compiles (build will be checked after Task 2)

---

## Task 2: Create ProjectDatabase

**File:** `final final/Models/ProjectDatabase.swift` (new)

**Step 1:** Create ProjectDatabase.swift

```swift
//
//  ProjectDatabase.swift
//  final final
//

import Foundation
import GRDB

final class ProjectDatabase: Sendable {
    let dbWriter: any DatabaseWriter & Sendable
    let package: ProjectPackage

    init(package: ProjectPackage) throws {
        self.package = package
        self.dbWriter = try DatabaseQueue(path: package.databaseURL.path)
        try migrate()
    }

    /// Creates a new project database with initial project and content
    static func create(package: ProjectPackage, title: String) throws -> ProjectDatabase {
        let db = try ProjectDatabase(package: package)
        try db.dbWriter.write { database in
            var project = Project(title: title)
            try project.insert(database)

            var content = Content(projectId: project.id)
            try content.insert(database)
        }
        return db
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

**Step 2:** Build to verify compilation

```bash
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED

---

## Task 3: Implement Document CRUD Operations

**File:** `final final/Models/Database+CRUD.swift` (new)

**Step 1:** Create Database+CRUD.swift with ProjectDatabase CRUD methods

```swift
//
//  Database+CRUD.swift
//  final final
//

import Foundation
import GRDB

// MARK: - ProjectDatabase CRUD

extension ProjectDatabase {
    // MARK: Project

    func fetchProject() throws -> Project? {
        try read { db in
            try Project.fetchOne(db)
        }
    }

    func updateProject(_ project: Project) throws {
        var updated = project
        updated.updatedAt = Date()
        try write { db in
            try updated.update(db)
        }
    }

    // MARK: Content

    func fetchContent(for projectId: String) throws -> Content? {
        try read { db in
            try Content.filter(Column("projectId") == projectId).fetchOne(db)
        }
    }

    func saveContent(markdown: String, for projectId: String) throws {
        try write { db in
            // Update content
            if var content = try Content.filter(Column("projectId") == projectId).fetchOne(db) {
                content.markdown = markdown
                content.updatedAt = Date()
                try content.update(db)
            }

            // Update project timestamp
            if var project = try Project.fetchOne(db) {
                project.updatedAt = Date()
                try project.update(db)
            }
        }

        // Rebuild outline cache
        try rebuildOutlineCache(markdown: markdown, projectId: projectId)
    }

    // MARK: Outline Nodes

    func fetchOutlineNodes(for projectId: String) throws -> [OutlineNode] {
        try read { db in
            try OutlineNode
                .filter(Column("projectId") == projectId)
                .order(Column("sortOrder"))
                .fetchAll(db)
        }
    }

    func replaceOutlineNodes(_ nodes: [OutlineNode], for projectId: String) throws {
        try write { db in
            // Delete existing nodes
            try OutlineNode.filter(Column("projectId") == projectId).deleteAll(db)

            // Insert new nodes
            for var node in nodes {
                try node.insert(db)
            }
        }
    }

    private func rebuildOutlineCache(markdown: String, projectId: String) throws {
        let nodes = OutlineParser.parse(markdown: markdown, projectId: projectId)
        try replaceOutlineNodes(nodes, for: projectId)
        print("[ProjectDatabase] Rebuilt outline cache: \(nodes.count) nodes")
    }
}
```

**Step 2:** Build to verify

```bash
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED

---

## Task 4: Complete OutlineParser Implementation

**File:** `final final/Services/OutlineParser.swift` (modify)

**Step 1:** Replace entire file with complete implementation

```swift
//
//  OutlineParser.swift
//  final final
//

import Foundation

struct OutlineParser {

    // MARK: - Public API

    /// Parses markdown content into an array of OutlineNodes
    static func parse(markdown: String, projectId: String) -> [OutlineNode] {
        let headers = extractHeaders(from: markdown)
        guard !headers.isEmpty else { return [] }

        var headersWithEnds = calculateEndOffsets(headers, contentLength: markdown.count)
        assignParents(&headersWithEnds)

        return headersWithEnds.enumerated().map { index, header in
            OutlineNode(
                projectId: projectId,
                headerLevel: header.level,
                title: header.title,
                startOffset: header.startOffset,
                endOffset: header.endOffset,
                parentId: header.parentId,
                sortOrder: index,
                isPseudoSection: header.isPseudoSection
            )
        }
    }

    /// Extracts preview text from a section (first non-header lines)
    static func extractPreview(from markdown: String, startOffset: Int, endOffset: Int, maxLines: Int = 4) -> String {
        guard startOffset < endOffset, startOffset < markdown.count else { return "" }

        let start = markdown.index(markdown.startIndex, offsetBy: startOffset)
        let end = markdown.index(markdown.startIndex, offsetBy: min(endOffset, markdown.count))
        let section = String(markdown[start..<end])

        var lines: [String] = []
        var foundContent = false

        for line in section.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip header line at start
            if !foundContent && trimmed.hasPrefix("#") {
                continue
            }

            // Skip empty lines before content
            if !foundContent && trimmed.isEmpty {
                continue
            }

            foundContent = true

            // Skip empty lines between content (but not within)
            if trimmed.isEmpty && lines.count < maxLines {
                continue
            }

            if lines.count < maxLines {
                lines.append(String(line))
            } else {
                break
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Counts words in text
    static func wordCount(in text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    // MARK: - Private Types

    private struct ParsedHeader {
        let level: Int
        let title: String
        let startOffset: Int
        var endOffset: Int
        let isPseudoSection: Bool
        var parentId: String?
        let id: String

        init(level: Int, title: String, startOffset: Int, isPseudoSection: Bool) {
            self.level = level
            self.title = title
            self.startOffset = startOffset
            self.endOffset = startOffset // Will be calculated later
            self.isPseudoSection = isPseudoSection
            self.parentId = nil
            self.id = UUID().uuidString
        }
    }

    // MARK: - Private Methods

    private static func extractHeaders(from markdown: String) -> [ParsedHeader] {
        var headers: [ParsedHeader] = []
        var currentOffset = 0
        var inCodeBlock = false

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineStr = String(line)
            let trimmed = lineStr.trimmingCharacters(in: .whitespaces)

            // Track code blocks to avoid parsing # in code
            if trimmed.hasPrefix("```") {
                inCodeBlock = !inCodeBlock
            }

            // Parse header if not in code block
            if !inCodeBlock, let header = parseHeaderLine(trimmed, at: currentOffset) {
                headers.append(header)
            }

            // Advance offset (+1 for newline, use utf8 for accurate byte counting)
            currentOffset += lineStr.utf8.count + 1
        }

        return headers
    }

    private static func parseHeaderLine(_ line: String, at offset: Int) -> ParsedHeader? {
        // Match # through ###### followed by space and text
        guard line.hasPrefix("#") else { return nil }

        var level = 0
        var idx = line.startIndex

        while idx < line.endIndex && line[idx] == "#" && level < 6 {
            level += 1
            idx = line.index(after: idx)
        }

        // Must have at least one # and be followed by space
        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }

        // Extract title (everything after "# ")
        let titleStart = line.index(after: idx)
        let title = String(line[titleStart...]).trimmingCharacters(in: .whitespaces)

        guard !title.isEmpty else { return nil }

        return ParsedHeader(
            level: level,
            title: title,
            startOffset: offset,
            isPseudoSection: isPseudoSection(title: title)
        )
    }

    private static func calculateEndOffsets(_ headers: [ParsedHeader], contentLength: Int) -> [ParsedHeader] {
        var result = headers

        for i in 0..<result.count {
            if i == result.count - 1 {
                // Last header ends at content end
                result[i].endOffset = contentLength
            } else {
                // Each header ends where the next one starts
                result[i].endOffset = result[i + 1].startOffset
            }
        }

        return result
    }

    private static func assignParents(_ headers: inout [ParsedHeader]) {
        // Stack of (level, id) pairs - start with virtual root
        var parentStack: [(level: Int, id: String?)] = [(0, nil)]

        for i in 0..<headers.count {
            let currentLevel = headers[i].level

            // Pop stack until we find a parent with lower level
            while parentStack.count > 1 && parentStack.last!.level >= currentLevel {
                parentStack.removeLast()
            }

            // Assign parent
            headers[i].parentId = parentStack.last?.id

            // Push current header onto stack
            parentStack.append((currentLevel, headers[i].id))
        }
    }

    private static func isPseudoSection(title: String) -> Bool {
        let lower = title.lowercased()
        let patterns = [
            "-part ",
            "- part ",
            "-continued",
            "- continued",
            "-part\t",
            "- part\t"
        ]
        return patterns.contains { lower.contains($0) }
    }
}
```

**Step 2:** Build to verify

```bash
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED

---

## Task 5: Implement ProjectStore with ValueObservation

**File:** `final final/Services/ProjectStore.swift` (new)

**Step 1:** Create ProjectStore.swift

```swift
//
//  ProjectStore.swift
//  final final
//

import Foundation
import GRDB

@MainActor
@Observable
final class ProjectStore {
    // MARK: - Published State

    private(set) var project: Project?
    private(set) var content: Content?
    private(set) var outlineNodes: [OutlineNode] = []
    private(set) var isLoading = false
    private(set) var error: Error?

    // MARK: - Private State

    private var database: ProjectDatabase?
    private var observationTask: Task<Void, Never>?

    // MARK: - Lifecycle

    /// Opens a project from an existing .ff package
    func open(package: ProjectPackage) async throws {
        isLoading = true
        error = nil

        do {
            database = try ProjectDatabase(package: package)
            project = try database?.fetchProject()

            if let projectId = project?.id {
                content = try database?.fetchContent(for: projectId)
                outlineNodes = try database?.fetchOutlineNodes(for: projectId) ?? []
            }

            startObserving()
            isLoading = false
            print("[ProjectStore] Opened project: \(project?.title ?? "unknown")")
        } catch {
            self.error = error
            isLoading = false
            throw error
        }
    }

    /// Creates a new project
    func createNew(at url: URL, title: String) async throws {
        isLoading = true
        error = nil

        do {
            let package = try ProjectPackage.create(at: url, title: title)
            database = try ProjectDatabase.create(package: package, title: title)
            project = try database?.fetchProject()

            if let projectId = project?.id {
                content = try database?.fetchContent(for: projectId)
            }

            outlineNodes = []
            startObserving()
            isLoading = false
            print("[ProjectStore] Created project: \(title)")
        } catch {
            self.error = error
            isLoading = false
            throw error
        }
    }

    /// Closes the current project
    func close() {
        observationTask?.cancel()
        observationTask = nil
        database = nil
        project = nil
        content = nil
        outlineNodes = []
        error = nil
        print("[ProjectStore] Closed project")
    }

    // MARK: - Content Operations

    /// Updates the markdown content (triggers outline rebuild)
    func updateContent(_ markdown: String) throws {
        guard let projectId = project?.id else {
            throw ProjectStoreError.noProjectOpen
        }

        try database?.saveContent(markdown: markdown, for: projectId)

        // Update local state immediately
        content?.markdown = markdown
        content?.updatedAt = Date()
    }

    // MARK: - Observation

    private func startObserving() {
        guard let db = database, let projectId = project?.id else { return }

        observationTask?.cancel()
        observationTask = Task { [weak self] in
            let observation = ValueObservation.tracking { database in
                try OutlineNode
                    .filter(Column("projectId") == projectId)
                    .order(Column("sortOrder"))
                    .fetchAll(database)
            }

            do {
                for try await nodes in observation.values(in: db.dbWriter) {
                    guard let self, !Task.isCancelled else { return }
                    await MainActor.run {
                        self.outlineNodes = nodes
                    }
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                await MainActor.run {
                    self.error = error
                }
            }
        }
    }

    // MARK: - Errors

    enum ProjectStoreError: Error, LocalizedError {
        case noProjectOpen

        var errorDescription: String? {
            switch self {
            case .noProjectOpen: return "No project is currently open"
            }
        }
    }
}
```

**Step 2:** Build to verify

```bash
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED

---

## Task 6: Add RecentProject Model and App Database Extension

**File:** `final final/Models/RecentProject.swift` (new)

**Step 1:** Create RecentProject.swift

```swift
//
//  RecentProject.swift
//  final final
//

import Foundation
import GRDB

struct RecentProject: Codable, Identifiable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var path: String
    var title: String
    var lastOpenedAt: Date

    init(id: String = UUID().uuidString, path: String, title: String, lastOpenedAt: Date = Date()) {
        self.id = id
        self.path = path
        self.title = title
        self.lastOpenedAt = lastOpenedAt
    }
}
```

**Step 2:** Modify Database.swift to add v2 migration and CRUD methods

Add after the v1_initial migration:

```swift
migrator.registerMigration("v2_recent_projects") { db in
    try db.create(table: "recentProject") { t in
        t.primaryKey("id", .text)
        t.column("path", .text).notNull().unique()
        t.column("title", .text).notNull()
        t.column("lastOpenedAt", .datetime).notNull()
    }
    try db.create(index: "recentProject_lastOpened", on: "recentProject", columns: ["lastOpenedAt"])
}
```

Add extension to Database.swift (or Database+CRUD.swift):

```swift
// MARK: - AppDatabase Recent Projects

extension AppDatabase {
    func fetchRecentProjects(limit: Int = 10) throws -> [RecentProject] {
        try read { db in
            try RecentProject
                .order(Column("lastOpenedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func addRecentProject(path: String, title: String) throws {
        try write { db in
            // Check if already exists
            if var existing = try RecentProject.filter(Column("path") == path).fetchOne(db) {
                existing.title = title
                existing.lastOpenedAt = Date()
                try existing.update(db)
            } else {
                var recent = RecentProject(path: path, title: title)
                try recent.insert(db)
            }
        }
    }

    func removeRecentProject(at path: String) throws {
        try write { db in
            try RecentProject.filter(Column("path") == path).deleteAll(db)
        }
    }

    func clearRecentProjects() throws {
        try write { db in
            try RecentProject.deleteAll(db)
        }
    }
}
```

**Step 3:** Build to verify

```bash
xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED

---

## Task 7: Register .ff Document Type

**File:** `project.yml` (modify)

**Step 1:** Add document type configuration to the info section

In the `info:` → `properties:` section, add:

```yaml
    CFBundleDocumentTypes:
      - CFBundleTypeName: final final Document
        CFBundleTypeRole: Editor
        LSHandlerRank: Owner
        LSItemContentTypes:
          - com.kerim.final-final.document
    UTExportedTypeDeclarations:
      - UTTypeIdentifier: com.kerim.final-final.document
        UTTypeDescription: final final Document
        UTTypeConformsTo:
          - com.apple.package
          - public.composite-content
        UTTypeTagSpecification:
          public.filename-extension:
            - ff
```

**Step 2:** Regenerate Xcode project and build

```bash
cd "/Users/niyaro/Documents/Code/final final" && xcodegen generate && xcodebuild -scheme "final final" -destination 'platform=macOS' build
```

Expected: BUILD SUCCEEDED

---

## Task 8: Add Unit Tests

**File:** `final finalTests/OutlineParserTests.swift` (new)

**Step 1:** Create OutlineParserTests.swift

```swift
//
//  OutlineParserTests.swift
//  final finalTests
//

import Testing
@testable import final_final

struct OutlineParserTests {

    @Test func parsesSimpleHeaders() {
        let markdown = """
        # Title

        Some content

        ## Chapter 1

        More content
        """

        let nodes = OutlineParser.parse(markdown: markdown, projectId: "test")

        #expect(nodes.count == 2)
        #expect(nodes[0].title == "Title")
        #expect(nodes[0].headerLevel == 1)
        #expect(nodes[1].title == "Chapter 1")
        #expect(nodes[1].headerLevel == 2)
    }

    @Test func parsesNestedHeaders() {
        let markdown = """
        # Book
        ## Chapter 1
        ### Section 1.1
        ### Section 1.2
        ## Chapter 2
        """

        let nodes = OutlineParser.parse(markdown: markdown, projectId: "test")

        #expect(nodes.count == 5)
        #expect(nodes[0].parentId == nil) // Book has no parent
        #expect(nodes[1].parentId == nodes[0].id) // Chapter 1 -> Book
        #expect(nodes[2].parentId == nodes[1].id) // Section 1.1 -> Chapter 1
        #expect(nodes[3].parentId == nodes[1].id) // Section 1.2 -> Chapter 1
        #expect(nodes[4].parentId == nodes[0].id) // Chapter 2 -> Book
    }

    @Test func calculatesCorrectOffsets() {
        let markdown = "# First\nContent\n# Second\nMore"
        let nodes = OutlineParser.parse(markdown: markdown, projectId: "test")

        #expect(nodes.count == 2)
        #expect(nodes[0].startOffset == 0)
        #expect(nodes[1].startOffset == 16) // "# First\nContent\n" = 16 bytes
    }

    @Test func detectsPseudoSections() {
        let markdown = """
        ## Chapter 1
        ## Chapter 1-part 2
        ## Chapter 2 - continued
        ## Chapter 3
        """

        let nodes = OutlineParser.parse(markdown: markdown, projectId: "test")

        #expect(nodes[0].isPseudoSection == false)
        #expect(nodes[1].isPseudoSection == true)
        #expect(nodes[2].isPseudoSection == true)
        #expect(nodes[3].isPseudoSection == false)
    }

    @Test func handlesEmptyContent() {
        let nodes = OutlineParser.parse(markdown: "", projectId: "test")
        #expect(nodes.isEmpty)
    }

    @Test func ignoresHeadersInCodeBlocks() {
        let markdown = """
        # Real Header

        ```
        # Not a header
        ## Also not
        ```

        ## Another Real Header
        """

        let nodes = OutlineParser.parse(markdown: markdown, projectId: "test")

        #expect(nodes.count == 2)
        #expect(nodes[0].title == "Real Header")
        #expect(nodes[1].title == "Another Real Header")
    }

    @Test func extractsPreviewText() {
        let markdown = """
        # Title

        First line of content.
        Second line of content.
        Third line.
        Fourth line.
        Fifth line.
        """

        let preview = OutlineParser.extractPreview(from: markdown, startOffset: 0, endOffset: markdown.count, maxLines: 4)

        #expect(preview.contains("First line"))
        #expect(preview.contains("Fourth line"))
        #expect(!preview.contains("Fifth line"))
        #expect(!preview.contains("# Title"))
    }

    @Test func wordCountWorks() {
        #expect(OutlineParser.wordCount(in: "Hello world") == 2)
        #expect(OutlineParser.wordCount(in: "One two three four five") == 5)
        #expect(OutlineParser.wordCount(in: "") == 0)
        #expect(OutlineParser.wordCount(in: "   spaces   ") == 1)
    }
}
```

**Step 2:** Build and run tests

```bash
xcodebuild -scheme "final final" -destination 'platform=macOS' test
```

Expected: All tests pass

---

## Verification Checklist

Phase 1.2 is complete when:

**Package operations:**
- [ ] Can create new .ff package at specified path
- [ ] Package contains content.sqlite after creation
- [ ] Can open existing .ff package
- [ ] Opening non-existent package throws error

**CRUD operations:**
- [ ] Creating project inserts Project and Content rows
- [ ] Saving content updates markdown and triggers outline rebuild
- [ ] Fetching project/content returns saved data
- [ ] Timestamps update on save

**Outline parsing:**
- [ ] Headers H1-H6 parsed correctly
- [ ] Parent-child relationships correct (nested hierarchy)
- [ ] Character offsets accurate for scroll sync
- [ ] Pseudo-sections detected (-part, -continued patterns)
- [ ] Code blocks don't create false headers
- [ ] Preview text extracts non-header lines

**Reactive updates:**
- [ ] ValueObservation updates ProjectStore.outlineNodes on content change
- [ ] Observation cancels cleanly on close()

**Recent projects:**
- [ ] Recent projects stored in app database
- [ ] Sorted by lastOpenedAt descending
- [ ] Duplicate paths update existing entry

**Tests:**
- [ ] OutlineParserTests all pass

---

## Critical Files

| File | Purpose |
|------|---------|
| `Models/ProjectPackage.swift` | .ff package management |
| `Models/ProjectDatabase.swift` | Per-project database |
| `Models/Database+CRUD.swift` | CRUD operations |
| `Models/RecentProject.swift` | Recent projects model |
| `Services/OutlineParser.swift` | Markdown → nodes |
| `Services/ProjectStore.swift` | Reactive state coordinator |
| `project.yml` | Document type registration |

---

## Next Phase

**Phase 1.3: Theme System** will implement:
- Color scheme structure with multiple themes
- Theme switching and persistence
- CSS variables for web editors
