//
//  ProjectIntegrityChecker.swift
//  final final
//
//  Validates project database integrity before opening.
//  Detects corruption, missing records, and structural issues.
//

import Foundation
import GRDB

/// Severity level for integrity issues
enum IntegritySeverity: Int, Comparable {
    case warning = 0   // Project opens but may have issues
    case error = 1     // Project may open but data is missing
    case critical = 2  // Cannot open project at all

    static func < (lhs: IntegritySeverity, rhs: IntegritySeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Specific integrity issues that can be detected
enum IntegrityIssue: Equatable {
    case sqliteCorruption(message: String)
    case missingDatabase
    case missingProjectTable
    case missingProjectRecord
    case missingContentTable
    case missingContentRecord
    case missingSectionTable
    case orphanedSections(count: Int)
    case contentSectionMismatch(contentLength: Int, sectionsTotal: Int)
    case staleBookmark
    /// A `block.sectionParentId` row whose persisted value no longer matches what
    /// `SectionHierarchy.parentIds(for:)` computes fresh from the current document structure --
    /// i.e. `recomputeSectionParents` was skipped or failed on some write, and the column has
    /// drifted from the truth. NOT the same check as `orphanedSections` above: that one reads
    /// the LEGACY `section` table's own separately-maintained `parentId` column (a real,
    /// pre-existing DB-level referential check); this one reads the `block` table's
    /// `sectionParentId` column, added by this feature specifically because it previously had
    /// no reader at all once written. See `checkSectionParentDrift`.
    case driftedSectionParents(count: Int)

    var severity: IntegritySeverity {
        switch self {
        case .sqliteCorruption, .missingDatabase, .missingProjectTable, .missingProjectRecord:
            return .critical
        case .missingContentTable, .missingContentRecord:
            return .error
        case .missingSectionTable, .orphanedSections, .contentSectionMismatch, .staleBookmark,
             .driftedSectionParents:
            return .warning
        }
    }

    var description: String {
        switch self {
        case .sqliteCorruption(let message):
            return "Database corruption detected: \(message)"
        case .missingDatabase:
            return "Database file (content.sqlite) is missing"
        case .missingProjectTable:
            return "Project table does not exist in database"
        case .missingProjectRecord:
            return "No project record found in database"
        case .missingContentTable:
            return "Content table does not exist in database"
        case .missingContentRecord:
            return "No content record found for project"
        case .missingSectionTable:
            return "Section table does not exist in database"
        case .orphanedSections(let count):
            return "Found \(count) orphaned section(s) with invalid parent references"
        case .contentSectionMismatch(let contentLength, let sectionsTotal):
            return "Content length (\(contentLength)) doesn't match sections total (\(sectionsTotal))"
        case .staleBookmark:
            return "Project bookmark is stale (file may have moved)"
        case .driftedSectionParents(let count):
            return "Found \(count) block(s) whose stored section parent doesn't match the current document structure"
        }
    }

    var canAutoRepair: Bool {
        switch self {
        case .sqliteCorruption, .missingDatabase:
            return false  // Cannot repair - must recreate
        case .missingProjectTable, .missingProjectRecord, .missingContentTable,
             .missingContentRecord, .missingSectionTable:
            return true  // Can create missing records
        case .orphanedSections:
            return true  // Can delete orphans
        case .contentSectionMismatch:
            return false  // Ambiguous - needs manual review
        case .staleBookmark:
            return false  // Requires user to re-open via File > Open to refresh bookmark
        case .driftedSectionParents:
            return true  // Can recompute deterministically from current document structure
        }
    }
}

/// Result of integrity validation
struct IntegrityReport {
    let issues: [IntegrityIssue]
    let packageURL: URL

    var isHealthy: Bool {
        issues.isEmpty
    }

    var hasCriticalIssues: Bool {
        issues.contains { $0.severity == .critical }
    }

    var hasErrors: Bool {
        issues.contains { $0.severity >= .error }
    }

    /// Returns true if ALL issues can be auto-repaired, regardless of severity.
    /// Critical issues that are individually repairable (like missingProjectRecord)
    /// should still allow the Repair button to appear.
    var canAutoRepair: Bool {
        issues.allSatisfy { $0.canAutoRepair }
    }

    var criticalIssues: [IntegrityIssue] {
        issues.filter { $0.severity == .critical }
    }

    var errorIssues: [IntegrityIssue] {
        issues.filter { $0.severity == .error }
    }

    var warningIssues: [IntegrityIssue] {
        issues.filter { $0.severity == .warning }
    }
}

/// Error thrown when integrity check fails
enum IntegrityError: Error, LocalizedError {
    case corrupted(IntegrityReport)
    case checkFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .corrupted(let report):
            let descriptions = report.issues.map { "• \($0.description)" }.joined(separator: "\n")
            return "Project integrity check failed:\n\(descriptions)"
        case .checkFailed(let error):
            return "Failed to check project integrity: \(error.localizedDescription)"
        }
    }

    var integrityReport: IntegrityReport? {
        if case .corrupted(let report) = self {
            return report
        }
        return nil
    }
}

/// Validates project database integrity before opening
struct ProjectIntegrityChecker {
    let packageURL: URL

    var databaseURL: URL {
        packageURL.appendingPathComponent("content.sqlite")
    }

    /// Whether a check helper wants `validate()` to return the report immediately, or continue
    /// on to the next check. Threaded through explicitly so extracting the checklist below into
    /// helpers keeps each one's early-return decision visible as a return value instead of
    /// buried in ad hoc control flow. This is NOT compiler-enforced: nothing stops a future
    /// `validate()` call site from ignoring a helper's returned `CheckFlow` beyond Swift's
    /// ordinary "result of call is unused" warning (`CheckFlow` isn't `@discardableResult`),
    /// and even a call site that does read the value still has to spell out `== .stop`
    /// correctly by hand, exactly as `validate()` does at each of its call sites above -- the
    /// only things actually preventing a dropped or reordered early return are that warning
    /// plus those manual comparisons.
    private enum CheckFlow {
        case proceed
        case stop
    }

    /// Perform all integrity checks on the project
    /// - Returns: IntegrityReport with any issues found
    func validate() throws -> IntegrityReport {
        var issues: [IntegrityIssue] = []

        // Check 1: Database file exists
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            issues.append(.missingDatabase)
            return IntegrityReport(issues: issues, packageURL: packageURL)
        }

        // Open database for remaining checks
        guard let dbQueue = openDatabase(issues: &issues) else {
            return IntegrityReport(issues: issues, packageURL: packageURL)
        }

        // Check 2: SQLite integrity
        if runSQLiteIntegrityCheck(db: dbQueue, issues: &issues) == .stop {
            return IntegrityReport(issues: issues, packageURL: packageURL)
        }

        // Check 3: Required tables exist; stops here on critical table issues
        if runTableChecks(db: dbQueue, issues: &issues) == .stop {
            return IntegrityReport(issues: issues, packageURL: packageURL)
        }

        // Checks 4-5: project record, then (if a project was found) content record
        if runRecordChecks(db: dbQueue, issues: &issues) == .stop {
            return IntegrityReport(issues: issues, packageURL: packageURL)
        }

        // Checks 6-7: section integrity + section-parent drift; never abort early
        runStructuralChecks(db: dbQueue, issues: &issues)

        return IntegrityReport(issues: issues, packageURL: packageURL)
    }

    /// Check 1.5: open the database, appending `.sqliteCorruption` and returning `nil` on failure
    /// (mirroring `validate()`'s original catch-then-return for this step).
    private func openDatabase(issues: inout [IntegrityIssue]) -> DatabaseQueue? {
        do {
            return try DatabaseQueue(path: databaseURL.path)
        } catch {
            issues.append(.sqliteCorruption(message: error.localizedDescription))
            return nil
        }
    }

    /// Check 2: SQLite integrity. Stops on either a non-"ok" result or a thrown error.
    private func runSQLiteIntegrityCheck(db: DatabaseQueue, issues: inout [IntegrityIssue]) -> CheckFlow {
        do {
            let integrityResult = try db.read { database -> String in
                try String.fetchOne(database, sql: "PRAGMA integrity_check") ?? "error"
            }
            if integrityResult != "ok" {
                issues.append(.sqliteCorruption(message: integrityResult))
                return .stop
            }
        } catch {
            issues.append(.sqliteCorruption(message: error.localizedDescription))
            return .stop
        }
        return .proceed
    }

    /// Check 3: required tables exist. Stops on a thrown error, or when the accumulated issues
    /// (including any appended just now) contain a critical one.
    private func runTableChecks(db: DatabaseQueue, issues: inout [IntegrityIssue]) -> CheckFlow {
        do {
            let tableIssues = try checkRequiredTables(db: db)
            issues.append(contentsOf: tableIssues)
        } catch {
            issues.append(.sqliteCorruption(message: "Failed to check tables: \(error.localizedDescription)"))
            return .stop
        }

        // If critical table issues, stop here
        if issues.contains(where: { $0.severity == .critical }) {
            return .stop
        }
        return .proceed
    }

    /// Checks 4-5: project record then content record. These two are NOT symmetric: Check 4's
    /// catch does not itself stop (it only appends `.sqliteCorruption` and falls through to the
    /// missing-project-record gate below, same as the failure path); the gate immediately after
    /// Check 4 is the only early return in this pair. Check 5 never stops -- its catch just
    /// appends and control returns to `validate()` as `.proceed` regardless of outcome.
    private func runRecordChecks(db: DatabaseQueue, issues: inout [IntegrityIssue]) -> CheckFlow {
        // Check 4: Project record exists
        do {
            let projectIssues = try checkProjectRecord(db: db)
            issues.append(contentsOf: projectIssues)
        } catch {
            issues.append(.sqliteCorruption(message: "Failed to check project: \(error.localizedDescription)"))
        }

        // If no project, can't check content
        if issues.contains(where: { if case .missingProjectRecord = $0 { return true }; return false }) {
            return .stop
        }

        // Check 5: Content record exists
        do {
            let contentIssues = try checkContentRecord(db: db)
            issues.append(contentsOf: contentIssues)
        } catch {
            issues.append(.sqliteCorruption(message: "Failed to check content: \(error.localizedDescription)"))
        }

        return .proceed
    }

    /// Checks 6-7: section integrity, then block.sectionParentId drift. Neither ever stops --
    /// both treat a thrown error as non-critical and just log it, matching the original inline
    /// checks exactly.
    private func runStructuralChecks(db: DatabaseQueue, issues: inout [IntegrityIssue]) {
        // Check 6: Section integrity (if section table exists)
        if !issues.contains(where: { if case .missingSectionTable = $0 { return true }; return false }) {
            do {
                let sectionIssues = try checkSectionIntegrity(db: db)
                issues.append(contentsOf: sectionIssues)
            } catch {
                // Section check failure is non-critical
                DebugLog.log(.data, "[IntegrityChecker] Warning: Failed to check sections: \(error.localizedDescription)")
            }
        }

        // Check 7: block.sectionParentId drift (if the block table exists -- a project on a
        // pre-block-architecture schema, or one whose database was hand-built without it in a
        // test, has nothing here to check).
        do {
            let driftIssues = try checkSectionParentDrift(db: db)
            issues.append(contentsOf: driftIssues)
        } catch {
            // Drift check failure is non-critical, same treatment as Check 6 above.
            DebugLog.log(.data, "[IntegrityChecker] Warning: Failed to check section parent drift: \(error.localizedDescription)")
        }
    }

    /// Validate bookmark data for staleness
    /// - Parameter bookmarkData: The bookmark data to validate
    /// - Returns: Tuple of (resolvedURL, isStale) or nil if unresolvable
    static func validateBookmark(_ bookmarkData: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        } catch {
            return nil
        }
    }

    // MARK: - Private Check Methods

    private func checkRequiredTables(db: DatabaseQueue) throws -> [IntegrityIssue] {
        var issues: [IntegrityIssue] = []

        try db.read { database in
            // Check project table
            let hasProjectTable = try database.tableExists("project")
            if !hasProjectTable {
                issues.append(.missingProjectTable)
            }

            // Check content table
            let hasContentTable = try database.tableExists("content")
            if !hasContentTable {
                issues.append(.missingContentTable)
            }

            // Check section table (warning only)
            let hasSectionTable = try database.tableExists("section")
            if !hasSectionTable {
                issues.append(.missingSectionTable)
            }
        }

        return issues
    }

    private func checkProjectRecord(db: DatabaseQueue) throws -> [IntegrityIssue] {
        var issues: [IntegrityIssue] = []

        try db.read { database in
            let projectCount = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM project") ?? 0
            if projectCount == 0 {
                issues.append(.missingProjectRecord)
            }
        }

        return issues
    }

    private func checkContentRecord(db: DatabaseQueue) throws -> [IntegrityIssue] {
        var issues: [IntegrityIssue] = []

        try db.read { database in
            // Get project ID first
            guard let projectId = try String.fetchOne(database, sql: "SELECT id FROM project LIMIT 1") else {
                return  // Already caught by project check
            }

            // Check content exists for this project
            let contentCount = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM content WHERE projectId = ?",
                arguments: [projectId]
            ) ?? 0

            if contentCount == 0 {
                issues.append(.missingContentRecord)
            }
        }

        return issues
    }

    private func checkSectionIntegrity(db: DatabaseQueue) throws -> [IntegrityIssue] {
        var issues: [IntegrityIssue] = []

        try db.read { database in
            // Get project ID
            guard let projectId = try String.fetchOne(database, sql: "SELECT id FROM project LIMIT 1") else {
                return
            }

            // Check for orphaned sections (parentId points to non-existent section)
            let orphanCount = try Int.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*) FROM section
                    WHERE projectId = ?
                    AND parentId IS NOT NULL
                    AND parentId NOT IN (SELECT id FROM section WHERE projectId = ?)
                    """,
                arguments: [projectId, projectId]
            ) ?? 0

            if orphanCount > 0 {
                issues.append(.orphanedSections(count: orphanCount))
            }
        }

        return issues
    }

    /// Reads every outline block's persisted `sectionParentId` (heading or pseudo-section
    /// rows, the block table's exact equivalent of the LEGACY `section` table's own
    /// `parentId` orphan check above) and flags rows where it has drifted from what
    /// `SectionHierarchy.parentIds(for:)` computes fresh from the block table's current
    /// structure -- i.e. `ProjectDatabase.recomputeSectionParents` was skipped or failed on
    /// some write. This is a READ-ONLY validation pass: it independently RE-DERIVES the
    /// expected value from the same shared rule rather than calling
    /// `recomputeSectionParents` (which writes) or `fetchOutlineBlocks` (which wraps its own
    /// `ProjectDatabase.read`, a different connection than this checker's raw `DatabaseQueue`).
    /// The query mirrors `fetchOutlineBlocks`'s exact filter (heading OR pseudo-section) and
    /// ordering (`isBibliography.asc, sortOrder.asc`) so "the current document structure" means
    /// the same thing here as it does to every DB-write call site.
    private func checkSectionParentDrift(db: DatabaseQueue) throws -> [IntegrityIssue] {
        var issues: [IntegrityIssue] = []

        try db.read { database in
            guard try database.tableExists("block") else { return }

            // This checker runs against a raw connection BEFORE ProjectDatabase's migrator has
            // had a chance to run (see DocumentManager, which validates before constructing a
            // ProjectDatabase) -- on a pre-v15 schema, `sectionParentId` doesn't exist yet.
            // GRDB's `decodeIfPresent` silently reads a missing column as `nil`, which would
            // otherwise compare a phantom `nil` against a real computed parent and report false
            // drift on every project with any heading below level 1. Skip the check entirely
            // when the column isn't there -- there is nothing to have drifted yet.
            guard try database.columns(in: "block").contains(where: { $0.name == "sectionParentId" }) else {
                return
            }

            guard let projectId = try String.fetchOne(database, sql: "SELECT id FROM project LIMIT 1") else {
                return  // Already caught by the project-record check
            }

            let outlineBlocks = try Block
                .filter(Block.Columns.projectId == projectId)
                .filter(
                    Block.Columns.blockType == BlockType.heading.rawValue ||
                    Block.Columns.isPseudoSection == true
                )
                .order(Block.Columns.isBibliography.asc, Block.Columns.sortOrder.asc)
                .fetchAll(database)

            // `?? 1` coalescing matches SectionViewModel.headerLevel / recomputeSectionParents
            // exactly -- see SectionHierarchy.parentIds' doc comment for why this must agree.
            let entries = outlineBlocks.map { (id: $0.id, level: $0.headingLevel ?? 1) }
            let expectedParentIds = SectionHierarchy.parentIds(for: entries)

            let driftCount = zip(outlineBlocks, expectedParentIds)
                .filter { block, expected in block.sectionParentId != expected }
                .count

            if driftCount > 0 {
                issues.append(.driftedSectionParents(count: driftCount))
            }
        }

        return issues
    }
}
