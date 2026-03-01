//
//  DocumentManager.swift
//  final final
//
//  Manages project lifecycle: create, open, close, save.
//  Replaces DemoProjectManager for user-controlled projects.
//

import Foundation
import AppKit

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

    /// UserDefaults key for last seen app version (for Getting Started)
    private let lastSeenVersionKey = "com.kerim.final-final.lastSeenVersion"

    // MARK: - Getting Started State

    /// Whether the currently open project is the Getting Started guide
    var isGettingStartedProject: Bool = false

    /// Whether the user has made edits to Getting Started (vs just viewing)
    var gettingStartedUserEdited: Bool = false

    /// Content hash after editor loads (post-normalization)
    var gettingStartedLoadedHash: Int?

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
        loadRecentProjects()
    }

    // MARK: - Version Tracking

    /// The last version the user has seen Getting Started for
    var lastSeenVersion: String? {
        get { UserDefaults.standard.string(forKey: lastSeenVersionKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastSeenVersionKey) }
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
        // Close any existing project first
        closeProject()

        // Integrity check BEFORE opening database
        let checker = ProjectIntegrityChecker(packageURL: url)
        let report = try checker.validate()

        if report.hasCriticalIssues {
            throw IntegrityError.corrupted(report)
        }

        // Log any non-critical issues
        if !report.isHealthy {
            for issue in report.issues {
                print("[DocumentManager] Warning: \(issue.description)")
            }
        }

        // Validate and open the package
        let package = try ProjectPackage.open(at: url)
        let database = try ProjectDatabase(package: package)

        // Fetch the project
        guard let project = try database.fetchProject() else {
            throw DocumentError.noProjectInDatabase
        }

        // Set current state
        self.projectDatabase = database
        self.projectURL = url
        self.projectId = project.id
        self.projectTitle = project.title
        self.contentId = try? database.fetchContent(for: project.id)?.id
        self.hasUnsavedChanges = false

        // Wire media scheme handler
        MediaSchemeHandler.shared.mediaDirectoryURL = package.mediaURL

        // Add to recent projects
        addToRecentProjects(url: url, title: project.title)

        // Save as last project for restore on launch
        saveAsLastProject(url: url)

        // Open spell check document for this project session
        SpellCheckService.shared.openDocument()

        print("[DocumentManager] Opened project: \(project.title) at \(url.path)")
        return project.id
    }

    /// Open a project bypassing integrity checks (use with caution)
    /// For use after user explicitly chooses "Open Anyway"
    /// - Returns: The project ID, or nil if no project record exists
    /// - Throws: Package or database errors (but NOT missing project record)
    @discardableResult
    func forceOpenProject(at url: URL) throws -> String? {
        // Close any existing project first
        closeProject()

        let package = try ProjectPackage.open(at: url)
        let database = try ProjectDatabase(package: package)

        // Explicitly handle "no project" vs database errors
        let project: Project?
        do {
            project = try database.fetchProject()
        } catch {
            // Log but don't fail - we're force-opening
            print("[DocumentManager] Force-open: fetchProject error (continuing): \(error)")
            project = nil
        }

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
            print("[DocumentManager] Force-opened project: \(project.title) at \(url.path)")
        } else {
            print("[DocumentManager] Force-opened project (no record) at \(url.path)")
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

        // Clear media scheme handler
        MediaSchemeHandler.shared.mediaDirectoryURL = nil

        print("[DocumentManager] Project closed")
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

    /// Load content for export, excluding bibliography blocks.
    /// Bibliography is regenerated by each export format's own mechanism:
    /// PDF uses pandoc --citeproc, DOCX/ODT use Zotero field codes via Lua filter.
    func loadContentForExport() throws -> String? {
        guard let db = projectDatabase, let pid = projectId else { return nil }
        let blocks = try db.fetchBlocks(projectId: pid)
        let exportBlocks = blocks.filter { !$0.isBibliography }
        return BlockParser.assembleMarkdownForExport(from: exportBlocks)
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

    /// Load document goal settings from the current project
    func loadDocumentGoalSettings() throws -> (goal: Int?, goalType: GoalType, excludeBibliography: Bool)? {
        guard let db = projectDatabase else { return nil }
        guard let project = try db.fetchProject() else { return nil }
        return (project.documentGoal, project.documentGoalType, project.excludeBibliography)
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
