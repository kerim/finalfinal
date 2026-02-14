//
//  DocumentManager+GettingStarted.swift
//  final final
//

import Foundation

// MARK: - Getting Started Project

extension DocumentManager {

    /// Load Getting Started content from bundled markdown
    func loadGettingStartedContent() -> String {
        guard let url = Bundle.main.url(forResource: "getting-started", withExtension: "md"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return "# Welcome to FINAL|FINAL\n\nCreate a new project to get started."
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
}
