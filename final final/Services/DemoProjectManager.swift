//
//  DemoProjectManager.swift
//  final final
//
//  Manages the demo project lifecycle - creates/opens the demo.ff package
//  and provides database access for the sync service.
//

import Foundation

/// Manages the demo project package and database connection
@MainActor
@Observable
class DemoProjectManager {

    // MARK: - Static Properties

    /// Directory for storing projects (uses proper macOS Documents directory)
    static var projectsFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("final final Projects")
    }

    /// Path to the demo project package
    static var demoPath: URL {
        projectsFolder.appendingPathComponent("demo.ff")
    }

    // MARK: - Public Properties

    /// The project database (nil until initialized)
    private(set) var projectDatabase: ProjectDatabase?

    /// The current project ID (nil until initialized)
    private(set) var projectId: String?

    /// Any error that occurred during initialization
    private(set) var error: Error?

    /// Whether the manager has been initialized
    var isInitialized: Bool {
        projectDatabase != nil && projectId != nil
    }

    // MARK: - Initialization

    /// Ensure the demo project exists, creating it if necessary
    /// - Parameter demoContent: Initial markdown content for new projects
    func ensureDemoProjectExists(demoContent: String) async throws {
        let fm = FileManager.default

        do {
            // Create parent directory if needed
            if !fm.fileExists(atPath: Self.projectsFolder.path) {
                try fm.createDirectory(at: Self.projectsFolder, withIntermediateDirectories: true)
                print("[DemoProjectManager] Created projects folder: \(Self.projectsFolder.path)")
            }

            if fm.fileExists(atPath: Self.demoPath.path) {
                // Open existing project
                try openExistingProject()
            } else {
                // Create new project
                try createNewProject(with: demoContent)
            }
        } catch {
            self.error = error
            print("[DemoProjectManager] Error: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Private Methods

    private func openExistingProject() throws {
        print("[DemoProjectManager] Opening existing project at: \(Self.demoPath.path)")

        let package = try ProjectPackage.open(at: Self.demoPath)
        projectDatabase = try ProjectDatabase(package: package)
        projectId = try projectDatabase?.fetchProject()?.id

        if projectId == nil {
            throw DemoProjectError.noProjectFound
        }

        print("[DemoProjectManager] Opened project with ID: \(projectId ?? "nil")")
    }

    private func createNewProject(with demoContent: String) throws {
        print("[DemoProjectManager] Creating new project at: \(Self.demoPath.path)")

        let package = try ProjectPackage.create(at: Self.demoPath, title: "Demo")
        projectDatabase = try ProjectDatabase.create(package: package, title: "Demo Project")
        projectId = try projectDatabase?.fetchProject()?.id

        guard let pid = projectId else {
            throw DemoProjectError.noProjectFound
        }

        // Save initial content
        try projectDatabase?.saveContent(markdown: demoContent, for: pid)
        print("[DemoProjectManager] Created project with ID: \(pid)")
    }

    /// Load saved content from the database (returns nil if no content)
    func loadContent() throws -> String? {
        guard let db = projectDatabase, let pid = projectId else { return nil }

        let content = try db.fetchContent(for: pid)
        return content?.markdown
    }

    /// Save section metadata changes to database
    func saveSection(_ section: Section) throws {
        guard let db = projectDatabase else {
            throw DemoProjectError.notInitialized
        }
        try db.updateSection(section)
    }

    /// Save section status change
    func saveSectionStatus(id: String, status: SectionStatus) throws {
        guard let db = projectDatabase else {
            throw DemoProjectError.notInitialized
        }
        try db.updateSectionStatus(id: id, status: status)
    }

    /// Save section word goal change
    func saveSectionWordGoal(id: String, goal: Int?) throws {
        guard let db = projectDatabase else {
            throw DemoProjectError.notInitialized
        }
        try db.updateSectionWordGoal(id: id, goal: goal)
    }

    /// Save section tags change
    func saveSectionTags(id: String, tags: [String]) throws {
        guard let db = projectDatabase else {
            throw DemoProjectError.notInitialized
        }
        try db.updateSectionTags(id: id, tags: tags)
    }

    // MARK: - Errors

    enum DemoProjectError: Error, LocalizedError {
        case notInitialized
        case noProjectFound

        var errorDescription: String? {
            switch self {
            case .notInitialized:
                return "Demo project manager not initialized"
            case .noProjectFound:
                return "No project found in database"
            }
        }
    }
}
