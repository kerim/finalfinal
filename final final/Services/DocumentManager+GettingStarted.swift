//
//  DocumentManager+GettingStarted.swift
//  final final
//

import Foundation

// MARK: - Getting Started Project

extension DocumentManager {

    /// Open the Getting Started project (copies bundled .ff template fresh each time)
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

        // Create parent directory
        try fm.createDirectory(at: gettingStartedDirectory, withIntermediateDirectories: true)

        // Copy bundled .ff template to temp
        guard let bundledURL = Bundle.main.url(forResource: "getting-started", withExtension: "ff") else {
            throw DocumentError.failedToCreateProject
        }
        try fm.copyItem(at: bundledURL, to: gettingStartedPath)

        // Open the copied package
        let package = try ProjectPackage.open(at: gettingStartedPath)
        let database = try ProjectDatabase(package: package)

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

        // Wire media scheme handler
        MediaSchemeHandler.shared.mediaDirectoryURL = package.mediaURL

        // Load embedded citations (renders without Zotero)
        loadEmbeddedCitations(from: package)

        // Do NOT add to recent projects - Getting Started is ephemeral

        DebugLog.log(.lifecycle, "[DocumentManager] Opened Getting Started project")
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
        DebugLog.log(.lifecycle, "[DocumentManager] Recorded Getting Started loaded hash")
    }

    /// Check if content differs from what was loaded (true user edit)
    /// Call this when content changes to detect actual user edits
    func checkGettingStartedEdited(currentMarkdown: String) {
        guard isGettingStartedProject, !gettingStartedUserEdited else { return }
        guard let loadedHash = gettingStartedLoadedHash else { return }

        if currentMarkdown.hashValue != loadedHash {
            gettingStartedUserEdited = true
            DebugLog.log(.lifecycle, "[DocumentManager] User edited Getting Started content")
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
