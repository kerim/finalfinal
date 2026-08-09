//
//  DocumentManager.swift
//  final final
//
//  Manages project lifecycle: create, open, close, save.
//  Replaces DemoProjectManager for user-controlled projects.
//

import Foundation
import AppKit

// MARK: - Path Normalization

extension URL {
    /// Normalized path used to decide whether two URLs refer to the same project on disk.
    ///
    /// Resolves symlinks (in addition to standardizing `.`/`..` components), so a project
    /// reached via a symlinked path compares equal to the same project reached via its real
    /// path. This is the single normalization both the "is this project already open" check
    /// (below) and the Recent Projects de-duplication logic (`DocumentManager+RecentProjects`)
    /// use — they used to disagree (`standardizedFileURL` there vs. `resolvingSymlinksInPath()`
    /// here), which could produce a duplicate Recent Projects entry, or a false "not already
    /// open" result, for a project reachable via a symlinked path.
    ///
    /// If the path doesn't exist on disk, `resolvingSymlinksInPath()` falls back to a purely
    /// lexical standardization, so this remains safe to call on not-yet-verified paths.
    var normalizedProjectPath: String {
        resolvingSymlinksInPath().path
    }
}

/// Manages the current project and recent projects list
@MainActor
@Observable
final class DocumentManager {

    // MARK: - Singleton

    static let shared = DocumentManager()

    // MARK: - Current Project State

    /// The currently open project database (nil if no project open)
    var projectDatabase: ProjectDatabase?

    /// The current project's package URL
    var projectURL: URL?

    /// The current project's ID in the database
    var projectId: String?

    /// The current project's title
    var projectTitle: String?

    /// The current content's ID in the database (for annotation binding)
    /// Cached on project open to avoid repeated database fetches
    var contentId: String?

    /// Whether there are unsaved changes (tracked by content updates)
    var hasUnsavedChanges: Bool = false

    /// Whether a project is currently open
    var hasOpenProject: Bool {
        projectDatabase != nil && projectId != nil
    }

    // MARK: - Recent Projects

    /// List of recently opened projects (stored as security-scoped bookmarks)
    var recentProjects: [RecentProjectEntry] = []

    /// Maximum number of recent projects to track
    let maxRecentProjects = 10

    /// UserDefaults key for recent projects bookmarks
    let recentProjectsKey = "com.kerim.final-final.recentProjects"

    /// UserDefaults key for last opened project bookmark
    let lastProjectBookmarkKey = "com.kerim.final-final.lastProjectBookmark"

    /// Default filesystem roots excluded from Recent Projects: internal scratch/test/dev-tool
    /// locations, not places a user would keep a real project. Unit and UI tests create
    /// throwaway `.ff` packages under system temp directories and (before this existed) would
    /// leak them into the user's real Recent Projects list via `addToRecentProjects`.
    ///
    /// Trade-off (accepted): a real `.ff` file a user legitimately opens from one of these
    /// locations — a Mail attachment, an archive extracted to `/tmp`, etc. — will silently
    /// never appear in Recent Projects. Judged preferable to a fragile filename-based
    /// heuristic. See `isExcludedFromRecentProjects(path:)` for the matching rule.
    static let defaultExcludedRecentProjectRoots: [String] = {
        let fm = FileManager.default
        return [
            fm.temporaryDirectory.path,
            "/private/tmp",
            "/private/var/folders",
            fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Developer/Xcode/DerivedData").path
        ]
    }()

    /// Filesystem roots currently excluded from Recent Projects. Settable so tests whose
    /// fixtures deliberately live under one of the default roots (e.g. `/tmp/claude`) can
    /// override this to `[]` for the test's duration and restore it via `defer`.
    var excludedRecentProjectRoots: [String] = DocumentManager.defaultExcludedRecentProjectRoots

    /// UserDefaults key for last seen app version (for Getting Started)
    private let lastSeenVersionKey = "com.kerim.final-final.lastSeenVersion"

    // MARK: - Launch State

    /// Whether the initial app-launch project open has completed.
    /// Used to prevent re-entrant opens from state restoration or SwiftUI `.task` re-fires.
    var hasCompletedInitialOpen = false

    // MARK: - Getting Started State

    /// Whether the currently open project is the Getting Started guide
    var isGettingStartedProject: Bool = false

    /// Whether the user has made edits to Getting Started (vs just viewing)
    var gettingStartedUserEdited: Bool = false

    /// Content hash after editor loads (post-normalization)
    var gettingStartedLoadedHash: Int?

    /// When gettingStartedLoadedHash was captured. Used with gettingStartedBaselineWindow
    /// to absorb a differing settle shortly after the first as baseline noise (e.g. a second
    /// Milkdown re-serialization pass) rather than a real edit.
    var gettingStartedBaselineCapturedAt: Date?

    /// How long after the first baseline capture a differing settle is still re-adopted as
    /// the baseline instead of being flagged as an edit. Injectable for tests.
    var gettingStartedBaselineWindow: TimeInterval = 2.0

    /// Directory for the temporary Getting Started project
    var gettingStartedDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("final-final-getting-started")
    }

    /// Path to the Getting Started project
    var gettingStartedPath: URL {
        gettingStartedDirectory.appendingPathComponent("getting-started.ff")
    }

    // MARK: - Initialization

    private init() {
        // Skip bookmark resolution during unit tests to avoid TCC prompts
        // for ~/Documents (bookmarks resolve to real user paths)
        if !TestMode.isUnitTesting {
            loadRecentProjects()
        }
    }

    // MARK: - Version Tracking

    /// The last version the user has seen Getting Started for
    var lastSeenVersion: String? {
        get { AppDefaults.store.string(forKey: lastSeenVersionKey) }
        set { AppDefaults.store.set(newValue, forKey: lastSeenVersionKey) }
    }

    /// The current app version from the bundle
    var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
    }

    /// Whether to show Getting Started (first launch or version update)
    var shouldShowGettingStarted: Bool {
        lastSeenVersion != currentAppVersion
    }

    /// Mark that the user has seen Getting Started for the current version
    func markGettingStartedSeen() {
        lastSeenVersion = currentAppVersion
    }

    // MARK: - Project Lifecycle

    /// Create a new project at the specified URL
    /// - Parameters:
    ///   - url: Where to save the .ff package
    ///   - title: Project title
    ///   - initialContent: Optional markdown content to initialize the project with
    /// - Returns: The project ID
    @discardableResult
    func newProject(at url: URL, title: String, initialContent: String = "") throws -> String {
        // Close any existing project first
        closeProject()

        // Ensure .ff extension
        let packageURL = url.pathExtension == "ff" ? url : url.appendingPathExtension("ff")

        // Create the package
        let package = try ProjectPackage.create(at: packageURL, title: title)

        // Create database with initial project and content
        let database = try ProjectDatabase.create(package: package, title: title, initialContent: initialContent)

        // Fetch the created project ID
        guard let project = try database.fetchProject() else {
            throw DocumentError.failedToCreateProject
        }

        // Set current state
        self.projectDatabase = database
        self.projectURL = packageURL
        self.projectId = project.id
        self.projectTitle = title
        self.contentId = try? database.fetchContent(for: project.id)?.id
        self.hasUnsavedChanges = false

        // Wire media scheme handler
        MediaSchemeHandler.shared.mediaDirectoryURL = package.mediaURL

        // Add to recent projects
        addToRecentProjects(url: packageURL, title: title)

        // Open spell check document for this project session
        SpellCheckService.shared.openDocument()

        return project.id
    }

    /// Open an existing project at the specified URL
    /// - Parameter url: Path to the .ff package
    /// - Returns: The project ID
    /// - Throws: IntegrityError if critical integrity issues are found
    @discardableResult
    func openProject(at url: URL) throws -> String {
        // Skip if this exact project is already open
        if projectURL?.normalizedProjectPath == url.normalizedProjectPath {
            DebugLog.log(.lifecycle, "[DocumentManager] Project already open, skipping: \(url.lastPathComponent)")
            return projectId ?? ""
        }

        // VALIDATE FIRST — before touching current project
        let checker = ProjectIntegrityChecker(packageURL: url)
        let report = try checker.validate()

        if report.hasCriticalIssues {
            throw IntegrityError.corrupted(report)
        }

        // Log any non-critical issues
        if !report.isHealthy {
            for issue in report.issues {
                DebugLog.log(.lifecycle, "[DocumentManager] Warning: \(issue.description)")
            }
        }

        // Open and validate the new project before closing the old one
        let package = try ProjectPackage.open(at: url)
        let database = try ProjectDatabase(package: package)

        guard let project = try database.fetchProject() else {
            throw DocumentError.noProjectInDatabase
        }

        // All validation passed — NOW close the old project
        closeProject()

        // Set new state (cannot fail from here)
        self.projectDatabase = database
        self.projectURL = url
        self.projectId = project.id
        self.projectTitle = project.title
        self.contentId = try? database.fetchContent(for: project.id)?.id
        self.hasUnsavedChanges = false

        // Wire media scheme handler
        MediaSchemeHandler.shared.mediaDirectoryURL = package.mediaURL

        // Load embedded citations if available (renders without Zotero)
        loadEmbeddedCitations(from: package)

        // Add to recent projects
        addToRecentProjects(url: url, title: project.title)

        // Save as last project for restore on launch
        saveAsLastProject(url: url)

        // Open spell check document for this project session
        SpellCheckService.shared.openDocument()

        DebugLog.log(.lifecycle, "[DocumentManager] Opened project: \(project.title) at \(url.path)")
        return project.id
    }

    /// Open a project bypassing integrity checks (use with caution)
    /// For use after user explicitly chooses "Open Anyway"
    /// - Returns: The project ID, or nil if no project record exists
    /// - Throws: Package or database errors (but NOT missing project record)
    @discardableResult
    func forceOpenProject(at url: URL) throws -> String? {
        // Validate the new project BEFORE closing the current one
        let package = try ProjectPackage.open(at: url)
        let database = try ProjectDatabase(package: package)

        // Explicitly handle "no project" vs database errors
        let project: Project?
        do {
            project = try database.fetchProject()
        } catch {
            // Log but don't fail - we're force-opening
            DebugLog.log(.lifecycle, "[DocumentManager] Force-open: fetchProject error (continuing): \(error)")
            project = nil
        }

        // Package and database opened successfully — NOW close the old project
        closeProject()

        self.projectDatabase = database
        self.projectURL = url
        self.projectId = project?.id
        self.projectTitle = project?.title ?? url.deletingPathExtension().lastPathComponent
        self.hasUnsavedChanges = false

        // Wire media scheme handler
        MediaSchemeHandler.shared.mediaDirectoryURL = package.mediaURL

        if let project = project {
            addToRecentProjects(url: url, title: project.title)
            saveAsLastProject(url: url)
            DebugLog.log(.lifecycle, "[DocumentManager] Force-opened project: \(project.title) at \(url.path)")
        } else {
            DebugLog.log(.lifecycle, "[DocumentManager] Force-opened project (no record) at \(url.path)")
        }

        // Open spell check document for this project session
        SpellCheckService.shared.openDocument()

        return project?.id
    }

    /// Close the current project
    func closeProject() {
        // Close spell check document for this project session
        SpellCheckService.shared.closeDocument()

        // Note: Database changes are auto-committed by GRDB
        projectDatabase = nil
        projectURL = nil
        projectId = nil
        projectTitle = nil
        contentId = nil
        hasUnsavedChanges = false
        isGettingStartedProject = false
        gettingStartedLoadedHash = nil
        gettingStartedUserEdited = false
        gettingStartedBaselineCapturedAt = nil
        gettingStartedBaselineWindow = 2.0

        // Clear media scheme handler
        MediaSchemeHandler.shared.mediaDirectoryURL = nil

        // Clear citation cache to prevent stale items leaking between projects
        ZoteroService.shared.clearCache()

        DebugLog.log(.lifecycle, "[DocumentManager] Project closed")
    }

    /// Mark the project as having unsaved changes
    func markDirty() {
        hasUnsavedChanges = true
    }

    /// Mark the project as saved (changes committed)
    func markClean() {
        hasUnsavedChanges = false
    }

    // MARK: - Content Operations

    /// Load content from the current project
    func loadContent() throws -> String? {
        guard let db = projectDatabase, let pid = projectId else { return nil }
        let content = try db.fetchContent(for: pid)
        return content?.markdown
    }

    /// Hook invoked before any export reads blocks from the database.
    /// Wired by ContentView to `EditorViewState.flushLiveContentToDatabase(currentContent:)`,
    /// which fetches fresh content from the live WebView, does a full block
    /// re-parse (`flushContentToDatabase()`), and re-syncs block ids
    /// (`pushBlockIds(for:)`) -- so exports see live editor edits, including pure
    /// block moves the incremental block-sync diff alone would miss.
    var flushBeforeExport: (() async -> Void)?

    /// Fetch and flush the current project's blocks, unfiltered. Shared by `exportBlocks()`
    /// and `loadContentForExport(bibliographyPlaceholder:)` so both see the exact same
    /// flush-then-fetch sequence.
    /// Awaits `flushBeforeExport` first so exports don't read stale, unflushed edits.
    private func allBlocksForExport() async throws -> [Block] {
        await flushBeforeExport?()
        guard let db = projectDatabase, let pid = projectId else { return [] }
        return try db.fetchBlocks(projectId: pid)
    }

    /// Fetch the current project's blocks for export, excluding bibliography blocks.
    /// Bibliography is regenerated by each export format's own mechanism:
    /// PDF uses pandoc --citeproc, DOCX/ODT use Zotero field codes via Lua filter.
    /// See `allBlocksForExport()` for the flush-before-read behavior.
    func exportBlocks() async throws -> [Block] {
        try await allBlocksForExport().filter { !$0.isBibliography }
    }

    /// Load content for export. `bibliographyPlaceholder` is forwarded to
    /// `BlockParser.assembleMarkdownForExport` unchanged -- see that function's doc comment.
    /// See `allBlocksForExport()` for the flush-before-read behavior.
    func loadContentForExport(bibliographyPlaceholder: Bool = false) async throws -> String? {
        let blocks = try await allBlocksForExport()
        return BlockParser.assembleMarkdownForExport(from: blocks, bibliographyPlaceholder: bibliographyPlaceholder)
    }

    /// Save content to the current project
    func saveContent(_ markdown: String) throws {
        guard let db = projectDatabase, let pid = projectId else {
            throw DocumentError.noProjectOpen
        }
        try db.saveContent(markdown: markdown, for: pid)
        hasUnsavedChanges = false
    }

    // MARK: - Section Operations (delegated to database)

    func saveSection(_ section: Section) throws {
        guard let db = projectDatabase else {
            throw DocumentError.noProjectOpen
        }
        try db.updateSection(section)
    }

    func saveSectionStatus(id: String, status: SectionStatus) throws {
        guard let db = projectDatabase else {
            throw DocumentError.noProjectOpen
        }
        try db.updateSectionStatus(id: id, status: status)
    }

    func saveSectionWordGoal(id: String, goal: Int?) throws {
        guard let db = projectDatabase else {
            throw DocumentError.noProjectOpen
        }
        try db.updateSectionWordGoal(id: id, goal: goal)
    }

    func saveSectionTags(id: String, tags: [String]) throws {
        guard let db = projectDatabase else {
            throw DocumentError.noProjectOpen
        }
        try db.updateSectionTags(id: id, tags: tags)
    }

    func saveSectionGoalType(id: String, goalType: GoalType) throws {
        guard let db = projectDatabase else {
            throw DocumentError.noProjectOpen
        }
        try db.updateSectionGoalType(id: id, goalType: goalType)
    }

    // MARK: - Document Goal Operations

    /// Save document goal settings to the project
    func saveDocumentGoalSettings(
        goal: Int?,
        goalType: GoalType,
        excludeBibliography: Bool
    ) throws {
        guard let db = projectDatabase else {
            throw DocumentError.noProjectOpen
        }
        try db.updateDocumentGoal(goal: goal, goalType: goalType, excludeBibliography: excludeBibliography)
    }

    /// The project's document-level word-goal configuration.
    struct DocumentGoalSettings {
        let goal: Int?
        let goalType: GoalType
        let excludeBibliography: Bool
    }

    /// Load document goal settings from the current project
    func loadDocumentGoalSettings() throws -> DocumentGoalSettings? {
        guard let db = projectDatabase else { return nil }
        guard let project = try db.fetchProject() else { return nil }
        return DocumentGoalSettings(
            goal: project.documentGoal,
            goalType: project.documentGoalType,
            excludeBibliography: project.excludeBibliography
        )
    }

    // MARK: - Embedded Citations

    /// Load pre-embedded CSL-JSON citation data from a project's references directory.
    /// Enables citation rendering without Zotero running.
    func loadEmbeddedCitations(from package: ProjectPackage) {
        let citationsURL = package.referencesURL.appendingPathComponent("citations.json")
        guard FileManager.default.fileExists(atPath: citationsURL.path) else { return }
        do {
            let data = try Data(contentsOf: citationsURL)
            let items = try JSONDecoder().decode([CSLItem].self, from: data)
            for item in items {
                ZoteroService.shared.loadItem(item)
            }
            DebugLog.log(.zotero, "[Citations] Loaded \(items.count) embedded citation items")
        } catch {
            DebugLog.log(.zotero, "[Citations] Failed to decode citations.json: \(error)")
        }
    }

    // MARK: - Errors

    enum DocumentError: Error, LocalizedError {
        case noProjectOpen
        case noProjectInDatabase
        case failedToCreateProject
        case bookmarkResolutionFailed
        case securityScopedAccessDenied
        case integrityCheckFailed(IntegrityReport)

        var errorDescription: String? {
            switch self {
            case .noProjectOpen:
                return "No project is currently open"
            case .noProjectInDatabase:
                return "The project file does not contain a valid project"
            case .failedToCreateProject:
                return "Failed to create project in database"
            case .bookmarkResolutionFailed:
                return "Could not access the project file. It may have been moved or deleted."
            case .securityScopedAccessDenied:
                return "Permission denied to access the project file"
            case .integrityCheckFailed(let report):
                let descriptions = report.issues.map { $0.description }.joined(separator: "; ")
                return "Project integrity check failed: \(descriptions)"
            }
        }

        /// Get the integrity report if this is an integrity error
        var integrityReport: IntegrityReport? {
            if case .integrityCheckFailed(let report) = self {
                return report
            }
            return nil
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let newProject = Notification.Name("newProject")
    static let openProject = Notification.Name("openProject")
    static let saveProject = Notification.Name("saveProject")
    static let saveProjectAs = Notification.Name("saveProjectAs")
    static let closeProject = Notification.Name("closeProject")
    static let importMarkdown = Notification.Name("importMarkdown")
}
