//
//  IntegrityResolution.swift
//  final final
//
//  Repair / force-open mechanics for a broken project, moved out of
//  ContentView+ProjectLifecycle.swift's handleRepair/handleOpenAnyway so
//  ProjectOpenErrorHost (which is not a ContentView and has no editor-lifecycle
//  state of its own) can drive them. The repair mechanics themselves (the retry
//  loop, the non-critical auto-force-open fallback) are unchanged from the code
//  this replaces. Behavior on SUCCESS is deliberately NOT unchanged, though: the
//  old code called configureForCurrentProject() directly, which skipped flushing
//  whatever project was open before the repair. The caller (ProjectOpenErrorHost)
//  posts .projectDidOpen instead, routing through the same flush-outgoing-project /
//  reset / reconfigure teardown every other open call site in the app already
//  uses -- a safer behavior change, not an oversight.
//

import Foundation

@MainActor
enum IntegrityResolution {
    enum Outcome {
        /// Project opened successfully (fully healthy, or non-critical issues
        /// force-opened with a warning already logged).
        case opened
        /// Still has critical, unrepaired issues -- show the updated report.
        case stillBroken(IntegrityReport)
        /// A repair step or the final open/force-open threw -- leave the caller's
        /// current state alone so the user still has a working Cancel.
        case failed(Error)
    }

    /// Repairs `report` at `url`, looping until every repairable issue is fixed or
    /// an unrepairable one is hit (max 5 passes -- some repairs reveal new issues).
    /// Mirrors the old ContentView+ProjectLifecycle.handleRepair exactly, including
    /// the non-critical/unrepairable fallback that force-opens with a warning
    /// rather than prompting again.
    static func repair(report: IntegrityReport, url: URL) async -> Outcome {
        let documentManager = DocumentManager.shared
        var currentReport = report
        var repairAttempts = 0
        let maxRepairAttempts = 5  // Prevent infinite loops

        do {
            // Loop to repair all issues (some repairs reveal new issues)
            while currentReport.canAutoRepair && repairAttempts < maxRepairAttempts {
                repairAttempts += 1
                DebugLog.log(.lifecycle, "[IntegrityResolution] Repair attempt \(repairAttempts) for \(currentReport.issues.count) issue(s)")

                let result = try documentManager.repairProject(report: currentReport)
                DebugLog.log(.lifecycle, "[IntegrityResolution] Repair result: \(result.message)")

                guard result.success else {
                    // Repair failed -- leave the sheet showing the report the user
                    // already sees, so they still have a working Cancel.
                    DebugLog.log(.lifecycle, "[IntegrityResolution] Repair failed for issues: \(result.failedIssues.map { $0.description })")
                    let error = NSError(
                        domain: "IntegrityResolution", code: 0,
                        userInfo: [NSLocalizedDescriptionKey: result.message]
                    )
                    return .failed(error)
                }

                // Re-validate after repair to check for remaining/new issues
                currentReport = try documentManager.checkIntegrity(at: url)

                if currentReport.isHealthy {
                    break
                }
                // Loop continues if there are more repairable issues
            }

            if currentReport.isHealthy {
                try documentManager.openProject(at: url)
                return .opened
            } else if !currentReport.hasCriticalIssues {
                // Non-critical, non-repairable issues remain - force open with warning
                DebugLog.log(.lifecycle, "[IntegrityResolution] Opening with non-critical issues: \(currentReport.issues.map { $0.description })")
                try documentManager.forceOpenProject(at: url)
                return .opened
            } else {
                // Critical unrepairable issues remain - show updated report
                return .stillBroken(currentReport)
            }
        } catch {
            DebugLog.log(.lifecycle, "[IntegrityResolution] Repair failed: \(error.localizedDescription)")
            return .failed(error)
        }
    }

    /// Opens `url` bypassing integrity checks entirely (user chose "Open Anyway").
    /// Mirrors the old ContentView+ProjectLifecycle.handleOpenAnyway exactly.
    static func openAnyway(url: URL) -> Outcome {
        DebugLog.log(.lifecycle, "[IntegrityResolution] Opening project despite integrity issues (user chose unsafe)")
        do {
            try DocumentManager.shared.forceOpenProject(at: url)
            return .opened
        } catch {
            DebugLog.log(.lifecycle, "[IntegrityResolution] Failed to force-open project: \(error.localizedDescription)")
            return .failed(error)
        }
    }
}
