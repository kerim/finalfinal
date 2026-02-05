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
    private(set) var projectDatabase: ProjectDatabase?

    /// The current project's package URL
    private(set) var projectURL: URL?

    /// The current project's ID in the database
    private(set) var projectId: String?

    /// The current project's title
    private(set) var projectTitle: String?

    /// The current content's ID in the database (for annotation binding)
    /// Cached on project open to avoid repeated database fetches
    private(set) var contentId: String?

    /// Whether there are unsaved changes (tracked by content updates)
    var hasUnsavedChanges: Bool = false

    /// Whether a project is currently open
    var hasOpenProject: Bool {
        projectDatabase != nil && projectId != nil
    }

    // MARK: - Recent Projects

    /// List of recently opened projects (stored as security-scoped bookmarks)
    private(set) var recentProjects: [RecentProjectEntry] = []

    /// Maximum number of recent projects to track
    private let maxRecentProjects = 10

    /// UserDefaults key for recent projects bookmarks
    private let recentProjectsKey = "com.kerim.final-final.recentProjects"

    /// UserDefaults key for last opened project bookmark
    private let lastProjectBookmarkKey = "com.kerim.final-final.lastProjectBookmark"

    /// UserDefaults key for last seen app version (for Getting Started)
    private let lastSeenVersionKey = "com.kerim.final-final.lastSeenVersion"

    // MARK: - Getting Started State

    /// Whether the currently open project is the Getting Started guide
    private(set) var isGettingStartedProject: Bool = false

    /// Whether the user has made edits to Getting Started (vs just viewing)
    private(set) var gettingStartedUserEdited: Bool = false

    /// Content hash after editor loads (post-normalization)
    private var gettingStartedLoadedHash: Int?

    /// Directory for the temporary Getting Started project
    private var gettingStartedDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("final-final-getting-started")
    }

    /// Path to the Getting Started project
    private var gettingStartedPath: URL {
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

        // Add to recent projects
        addToRecentProjects(url: packageURL, title: title)

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

        // Add to recent projects
        addToRecentProjects(url: url, title: project.title)

        // Save as last project for restore on launch
        saveAsLastProject(url: url)

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

        if let project = project {
            addToRecentProjects(url: url, title: project.title)
            saveAsLastProject(url: url)
            print("[DocumentManager] Force-opened project: \(project.title) at \(url.path)")
        } else {
            print("[DocumentManager] Force-opened project (no record) at \(url.path)")
        }

        return project?.id
    }

    /// Close the current project
    func closeProject() {
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

    // MARK: - Recent Projects

    /// Entry for a recent project with bookmark data
    struct RecentProjectEntry: Codable, Identifiable {
        let id: String
        var title: String
        var bookmarkData: Data
        var lastOpenedAt: Date

        init(id: String = UUID().uuidString, title: String, bookmarkData: Data, lastOpenedAt: Date = Date()) {
            self.id = id
            self.title = title
            self.bookmarkData = bookmarkData
            self.lastOpenedAt = lastOpenedAt
        }
    }

    /// Add a project to the recent projects list
    private func addToRecentProjects(url: URL, title: String) {
        do {
            // Create security-scoped bookmark
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            // Check if already in list
            if let existingIndex = recentProjects.firstIndex(where: { entry in
                resolveBookmark(entry.bookmarkData)?.path == url.path
            }) {
                // Update existing entry
                var entry = recentProjects[existingIndex]
                entry.title = title
                entry.lastOpenedAt = Date()
                entry.bookmarkData = bookmarkData
                recentProjects.remove(at: existingIndex)
                recentProjects.insert(entry, at: 0)
            } else {
                // Add new entry
                let entry = RecentProjectEntry(title: title, bookmarkData: bookmarkData)
                recentProjects.insert(entry, at: 0)

                // Trim to max size
                if recentProjects.count > maxRecentProjects {
                    recentProjects = Array(recentProjects.prefix(maxRecentProjects))
                }
            }

            saveRecentProjects()
        } catch {
            print("[DocumentManager] Failed to create bookmark for \(url.path): \(error)")
        }
    }

    /// Remove a project from the recent projects list
    func removeFromRecentProjects(_ entry: RecentProjectEntry) {
        recentProjects.removeAll { $0.id == entry.id }
        saveRecentProjects()
    }

    /// Clear all recent projects
    func clearRecentProjects() {
        recentProjects.removeAll()
        saveRecentProjects()
    }

    /// Resolve a bookmark to a URL (starting security-scoped access)
    func resolveBookmark(_ bookmarkData: Data) -> URL? {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                print("[DocumentManager] Bookmark is stale, may need refresh")
            }

            return url
        } catch {
            print("[DocumentManager] Failed to resolve bookmark: \(error)")
            return nil
        }
    }

    /// Open a recent project by entry
    @discardableResult
    func openRecentProject(_ entry: RecentProjectEntry) throws -> String {
        guard let url = resolveBookmark(entry.bookmarkData) else {
            throw DocumentError.bookmarkResolutionFailed
        }

        // Start security-scoped access
        guard url.startAccessingSecurityScopedResource() else {
            throw DocumentError.securityScopedAccessDenied
        }

        defer {
            // Note: We keep access open while project is open
            // Access is stopped when project is closed
        }

        return try openProject(at: url)
    }

    // MARK: - Last Project Persistence

    /// Stored bookmark data for the last opened project
    private var lastProjectBookmark: Data? {
        get { UserDefaults.standard.data(forKey: lastProjectBookmarkKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastProjectBookmarkKey) }
    }

    /// Save a project URL as the last opened project (for restore on launch)
    private func saveAsLastProject(url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            lastProjectBookmark = bookmarkData
        } catch {
            print("[DocumentManager] Failed to save last project bookmark: \(error)")
        }
    }

    /// Attempt to restore the last opened project
    /// - Returns: true if a project was successfully restored
    /// - Throws: DocumentError if bookmark resolution or project opening fails
    func restoreLastProject() throws -> Bool {
        guard let bookmarkData = lastProjectBookmark else { return false }

        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        guard url.startAccessingSecurityScopedResource() else {
            throw DocumentError.securityScopedAccessDenied
        }

        // Must stop access on any error path
        do {
            guard FileManager.default.fileExists(atPath: url.path) else {
                url.stopAccessingSecurityScopedResource()
                lastProjectBookmark = nil
                throw DocumentError.bookmarkResolutionFailed
            }

            try openProject(at: url)

            // Regenerate stale bookmark with fresh data
            if isStale {
                saveAsLastProject(url: url)
            }

            // Note: openProject now owns the security scope
            return true
        } catch {
            url.stopAccessingSecurityScopedResource()
            throw error
        }
    }

    // MARK: - Recent Projects Persistence

    private func loadRecentProjects() {
        guard let data = UserDefaults.standard.data(forKey: recentProjectsKey) else {
            recentProjects = []
            return
        }

        do {
            recentProjects = try JSONDecoder().decode([RecentProjectEntry].self, from: data)
            // Validate bookmarks on load
            recentProjects = recentProjects.filter { entry in
                resolveBookmark(entry.bookmarkData) != nil
            }
        } catch {
            print("[DocumentManager] Failed to load recent projects: \(error)")
            recentProjects = []
        }
    }

    private func saveRecentProjects() {
        do {
            let data = try JSONEncoder().encode(recentProjects)
            UserDefaults.standard.set(data, forKey: recentProjectsKey)
        } catch {
            print("[DocumentManager] Failed to save recent projects: \(error)")
        }
    }

    // MARK: - Getting Started Project

    /// Load Getting Started content from bundled markdown
    private func loadGettingStartedContent() -> String {
        guard let url = Bundle.main.url(forResource: "getting-started", withExtension: "md"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return "# Welcome to final final\n\nCreate a new project to get started."
        }
        return content
    }

    /// Open the Getting Started project (creates fresh each time)
    /// - Returns: The project ID
    @discardableResult
    func openGettingStarted() throws -> String {
        // Close any existing project first
        closeProject()

        let fm = FileManager.default

        // Always start fresh - delete existing if present
        if fm.fileExists(atPath: gettingStartedDirectory.path) {
            try? fm.removeItem(at: gettingStartedDirectory)
        }

        // Create directory
        try fm.createDirectory(at: gettingStartedDirectory, withIntermediateDirectories: true)

        // Load bundled content
        let content = loadGettingStartedContent()

        // Create the package
        let package = try ProjectPackage.create(at: gettingStartedPath, title: "Getting Started")

        // Create database with initial content
        let database = try ProjectDatabase.create(package: package, title: "Getting Started", initialContent: content)

        // Fetch the created project ID
        guard let project = try database.fetchProject() else {
            throw DocumentError.failedToCreateProject
        }

        // Set current state
        self.projectDatabase = database
        self.projectURL = gettingStartedPath
        self.projectId = project.id
        self.projectTitle = "Getting Started"
        self.contentId = try? database.fetchContent(for: project.id)?.id
        self.hasUnsavedChanges = false
        self.isGettingStartedProject = true

        // Do NOT add to recent projects - Getting Started is ephemeral

        print("[DocumentManager] Opened Getting Started project")
        return project.id
    }

    /// Check if the Getting Started project has been modified by the user
    func isGettingStartedModified() -> Bool {
        return isGettingStartedProject && gettingStartedUserEdited
    }

    /// Record the content hash after editor normalizes it
    /// Call this after the editor has loaded and processed the content
    func recordGettingStartedLoadedContent(_ markdown: String) {
        guard isGettingStartedProject else { return }
        gettingStartedLoadedHash = markdown.hashValue
        gettingStartedUserEdited = false
        #if DEBUG
        print("[DocumentManager] Recorded Getting Started loaded hash")
        #endif
    }

    /// Check if content differs from what was loaded (true user edit)
    /// Call this when content changes to detect actual user edits
    func checkGettingStartedEdited(currentMarkdown: String) {
        guard isGettingStartedProject, !gettingStartedUserEdited else { return }
        guard let loadedHash = gettingStartedLoadedHash else { return }

        if currentMarkdown.hashValue != loadedHash {
            gettingStartedUserEdited = true
            #if DEBUG
            print("[DocumentManager] User edited Getting Started content")
            #endif
        }
    }

    /// Get the current content (for pre-populating new project)
    func getCurrentContent() throws -> String? {
        guard let db = projectDatabase, let pid = projectId else { return nil }
        return try db.fetchContent(for: pid)?.markdown
    }

    // MARK: - Integrity Operations

    /// Check project integrity without opening
    /// - Parameter url: Path to the .ff package
    /// - Returns: IntegrityReport with any issues found
    func checkIntegrity(at url: URL) throws -> IntegrityReport {
        let checker = ProjectIntegrityChecker(packageURL: url)
        return try checker.validate()
    }

    /// Repair a project at the specified URL
    /// - Parameter report: The integrity report from checkIntegrity
    /// - Returns: RepairResult with details of what was repaired
    func repairProject(report: IntegrityReport) throws -> RepairResult {
        let repairService = ProjectRepairService(packageURL: report.packageURL)
        return try repairService.repair(report: report)
    }

    /// Check if a URL points to the demo project
    func isDemoProject(at url: URL) -> Bool {
        let projectsFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("final final Projects")
        let demoPath = projectsFolder.appendingPathComponent("demo.ff")
        return url.standardizedFileURL == demoPath.standardizedFileURL
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
    static let closeProject = Notification.Name("closeProject")
    static let importMarkdown = Notification.Name("importMarkdown")
    static let exportMarkdown = Notification.Name("exportMarkdown")
}
