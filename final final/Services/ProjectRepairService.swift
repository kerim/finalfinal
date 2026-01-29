//
//  ProjectRepairService.swift
//  final final
//
//  Repairs project database integrity issues.
//  Creates backups before any repair operation.
//

import Foundation
import GRDB

/// Result of a repair operation
struct RepairResult {
    let success: Bool
    let repairedIssues: [IntegrityIssue]
    let failedIssues: [IntegrityIssue]
    let backupURL: URL?

    var message: String {
        if success {
            return "Successfully repaired \(repairedIssues.count) issue(s)"
        } else {
            let failedDescriptions = failedIssues.map { $0.description }.joined(separator: ", ")
            return "Repair failed for: \(failedDescriptions)"
        }
    }
}

/// Error during repair operations
enum RepairError: Error, LocalizedError {
    case backupFailed(Error)
    case repairFailed(issue: IntegrityIssue, error: Error)
    case cannotRepair(issues: [IntegrityIssue])
    case noProjectId

    var errorDescription: String? {
        switch self {
        case .backupFailed(let error):
            return "Failed to create backup: \(error.localizedDescription)"
        case .repairFailed(let issue, let error):
            return "Failed to repair '\(issue.description)': \(error.localizedDescription)"
        case .cannotRepair(let issues):
            let descriptions = issues.map { $0.description }.joined(separator: ", ")
            return "Cannot auto-repair: \(descriptions)"
        case .noProjectId:
            return "Cannot repair: no project ID available"
        }
    }
}

/// Service to repair project database issues
struct ProjectRepairService {
    let packageURL: URL

    var databaseURL: URL {
        packageURL.appendingPathComponent("content.sqlite")
    }

    /// Create a timestamped backup of the database
    /// - Returns: URL of the backup file
    func createBackup() throws -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let uniqueId = UUID().uuidString.prefix(8)
        let backupName = "content.sqlite.backup-\(timestamp)-\(uniqueId)"
        let backupURL = packageURL.appendingPathComponent(backupName)

        do {
            try FileManager.default.copyItem(at: databaseURL, to: backupURL)
            print("[RepairService] Created backup at: \(backupURL.lastPathComponent)")
            return backupURL
        } catch {
            throw RepairError.backupFailed(error)
        }
    }

    /// Repair the project based on integrity report
    /// - Parameter report: The integrity report from ProjectIntegrityChecker
    /// - Returns: RepairResult with details of what was repaired
    func repair(report: IntegrityReport) throws -> RepairResult {
        // Check if repair is possible
        let unrepairable = report.issues.filter { !$0.canAutoRepair }
        if !unrepairable.isEmpty {
            throw RepairError.cannotRepair(issues: unrepairable)
        }

        // Create backup before any repairs
        let backupURL = try createBackup()

        // Open database
        let dbQueue = try DatabaseQueue(path: databaseURL.path)

        var repairedIssues: [IntegrityIssue] = []
        var failedIssues: [IntegrityIssue] = []

        // Repair each issue in order of severity (most critical first)
        let sortedIssues = report.issues.sorted { $0.severity > $1.severity }

        for issue in sortedIssues {
            do {
                try repairIssue(issue, db: dbQueue)
                repairedIssues.append(issue)
                print("[RepairService] Repaired: \(issue.description)")
            } catch {
                failedIssues.append(issue)
                print("[RepairService] Failed to repair '\(issue.description)': \(error)")
            }
        }

        return RepairResult(
            success: failedIssues.isEmpty,
            repairedIssues: repairedIssues,
            failedIssues: failedIssues,
            backupURL: backupURL
        )
    }

    /// Delete the project package entirely (for recreate)
    func deletePackage() throws {
        try FileManager.default.removeItem(at: packageURL)
        print("[RepairService] Deleted package at: \(packageURL.path)")
    }

    // MARK: - Private Repair Methods

    private func repairIssue(_ issue: IntegrityIssue, db: DatabaseQueue) throws {
        switch issue {
        case .missingProjectTable:
            try createProjectTable(db: db)

        case .missingProjectRecord:
            try createProjectRecord(db: db)

        case .missingContentTable:
            try createContentTable(db: db)

        case .missingContentRecord:
            try createContentRecord(db: db)

        case .missingSectionTable:
            try createSectionTable(db: db)

        case .orphanedSections:
            try deleteOrphanedSections(db: db)

        case .staleBookmark:
            // Bookmark repair is handled at the DocumentManager level
            // when re-opening the project after repair
            break

        case .sqliteCorruption, .missingDatabase, .contentSectionMismatch:
            // These cannot be auto-repaired
            throw RepairError.cannotRepair(issues: [issue])
        }
    }

    private func createProjectTable(db: DatabaseQueue) throws {
        try db.write { database in
            try database.create(table: "project", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }
    }

    private func createProjectRecord(db: DatabaseQueue) throws {
        try db.write { database in
            // Check for existing projectId in sections or content tables
            // This preserves foreign key relationships with existing data
            let existingProjectId: String?
            if let sectionProjectId = try String.fetchOne(database, sql: "SELECT projectId FROM section LIMIT 1") {
                existingProjectId = sectionProjectId
                print("[RepairService] Found existing projectId from sections: \(sectionProjectId)")
            } else if let contentProjectId = try String.fetchOne(database, sql: "SELECT projectId FROM content LIMIT 1") {
                existingProjectId = contentProjectId
                print("[RepairService] Found existing projectId from content: \(contentProjectId)")
            } else {
                existingProjectId = nil
            }

            let projectId = existingProjectId ?? UUID().uuidString
            let now = Date()
            try database.execute(
                sql: """
                    INSERT INTO project (id, title, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [projectId, "Recovered Project", now, now]
            )

            if existingProjectId != nil {
                print("[RepairService] Recreated project record with existing ID: \(projectId)")
            } else {
                print("[RepairService] Created new project record: \(projectId)")
            }
        }
    }

    private func createContentTable(db: DatabaseQueue) throws {
        try db.write { database in
            try database.create(table: "content", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("projectId", .text).notNull()
                    .references("project", onDelete: .cascade)
                t.column("markdown", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try database.create(index: "content_projectId", on: "content", columns: ["projectId"], ifNotExists: true)
        }
    }

    private func createContentRecord(db: DatabaseQueue) throws {
        try db.write { database in
            // Get project ID
            guard let projectId = try String.fetchOne(database, sql: "SELECT id FROM project LIMIT 1") else {
                throw RepairError.noProjectId
            }

            let now = Date()
            try database.execute(
                sql: """
                    INSERT INTO content (id, projectId, markdown, updatedAt)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [UUID().uuidString, projectId, "", now]
            )
        }
    }

    private func createSectionTable(db: DatabaseQueue) throws {
        try db.write { database in
            try database.create(table: "section", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("projectId", .text).notNull()
                    .references("project", onDelete: .cascade)
                t.column("parentId", .text)
                    .references("section", onDelete: .cascade)
                t.column("sortOrder", .integer).notNull()
                t.column("headerLevel", .integer).notNull()
                t.column("isPseudoSection", .boolean).notNull().defaults(to: false)
                t.column("title", .text).notNull()
                t.column("markdownContent", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "next")
                t.column("tags", .text).notNull().defaults(to: "[]")
                t.column("wordGoal", .integer)
                t.column("wordCount", .integer).notNull().defaults(to: 0)
                t.column("startOffset", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try database.create(index: "section_projectId", on: "section", columns: ["projectId"], ifNotExists: true)
            try database.create(index: "section_parentId", on: "section", columns: ["parentId"], ifNotExists: true)
            try database.create(
                index: "section_sortOrder",
                on: "section",
                columns: ["projectId", "sortOrder"],
                ifNotExists: true
            )
        }
    }

    private func deleteOrphanedSections(db: DatabaseQueue) throws {
        try db.write { database in
            // Get project ID
            guard let projectId = try String.fetchOne(database, sql: "SELECT id FROM project LIMIT 1") else {
                throw RepairError.noProjectId
            }

            // Delete sections whose parentId doesn't exist
            try database.execute(
                sql: """
                    DELETE FROM section
                    WHERE projectId = ?
                    AND parentId IS NOT NULL
                    AND parentId NOT IN (SELECT id FROM section WHERE projectId = ?)
                    """,
                arguments: [projectId, projectId]
            )
        }
    }
}
