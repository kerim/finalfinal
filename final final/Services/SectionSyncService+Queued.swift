//
//  SectionSyncService+Queued.swift
//  final final
//
//  Phase 5 job B3-0 (SectionSyncQueued, `b2-b4-design.md` section 3.7): the section sync's two database writes (the `section`
//  table and the content row) are ONE system write on the `DocumentWriter` queue, so two runs land in the queue's order and a
//  run overtaken by a newer one writes nothing. Before this the two writes ran from a `Task.detached` straight to the database,
//  so two runs could land out of order and leave the content row (which Version History snapshots read) older than the editor
//  (the model's finding (e): `P5B_SSDirect_*` R and Q VIOLATED, `P5B_SSQueued_*` ok).
//

import Foundation
import GRDB

/// Orders the section-sync writes by the run that asked for them. `claim(_:)` runs inside the write transaction, on the writer's
/// thread, so it is linearised by the writer's own queue: a run older than one already written writes nothing (a fallback direct
/// write and a queued one can never put an older text over a newer one either).
final class SectionSyncWriteOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var newestWritten = 0

    /// True when run `request` may write (no newer run has written yet); records it as the newest written.
    func claim(_ request: Int) -> Bool {
        lock.withLock {
            guard request > newestWritten else { return false }
            newestWritten = request
            return true
        }
    }
}

/// What a section-sync run prepared off the main thread: the parsed headers, and the bibliography/Notes titles they were parsed
/// with (the write re-reads the titles inside its transaction and parses again only when they changed meanwhile).
struct PreparedSectionSync: Sendable {
    let headers: [ParsedHeader]
    let existingBibTitle: String?
    let existingNotesTitle: String?
}

/// Everything the write body needs, captured on the main actor before the run's first `await`.
struct SectionSyncWriteInput: Sendable {
    let markdown: String
    let projectId: String
    let request: Int
    let isZoomed: Bool
    let suppressReconcile: Bool
    let fallbackBibTitle: String
    let reconciler: SectionReconciler
    let order: SectionSyncWriteOrder
}

extension SectionSyncService {
    /// The off-main-thread half of a run: one consistent snapshot read and the header parse (C6: every value the parse depends on
    /// comes from one snapshot).
    nonisolated static func prepareSectionSync(
        db: ProjectDatabase, markdown: String, projectId: String, fallbackBibTitle: String
    ) throws -> PreparedSectionSync {
        let snapshot = try MdSpeed.timed("sectionSync.fetchSnapshot") { try db.fetchSectionSyncSnapshot(projectId: projectId) }
        let headers = MdSpeed.timed("sectionSync.parseHeaders") {
            SectionSyncService.parseHeaders(
                from: markdown, existingBibTitle: snapshot.existingBibTitle,
                existingNotesTitle: snapshot.existingNotesTitle, fallbackBibTitle: fallbackBibTitle)
        }
        return PreparedSectionSync(
            headers: headers, existingBibTitle: snapshot.existingBibTitle, existingNotesTitle: snapshot.existingNotesTitle)
    }

    /// The write itself, inside ONE transaction: re-read the snapshot (the rows as they are at this write's turn, so the reconcile
    /// never works from rows an earlier write has since changed), reconcile, apply, then the content row unless zoomed. Returns
    /// false, writing nothing, when a newer run has already written (`SectionSyncWriteOrder.claim`).
    nonisolated static func writeSectionSync(
        db: Database, input: SectionSyncWriteInput, prepared: PreparedSectionSync
    ) throws -> Bool {
        guard input.order.claim(input.request) else { return false }
        // 3-4. Reconcile + apply -- skipped while suppressed (P3 section 4d) or when the text has no headers.
        if !input.suppressReconcile {
            try MdSpeed.timed("sectionSync.reconcileApply") {
                let snapshot = try ProjectDatabase.sectionSyncSnapshot(db: db, projectId: input.projectId)
                let headers: [ParsedHeader]
                if snapshot.existingBibTitle == prepared.existingBibTitle,
                   snapshot.existingNotesTitle == prepared.existingNotesTitle {
                    headers = prepared.headers
                } else {
                    headers = SectionSyncService.parseHeaders(
                        from: input.markdown, existingBibTitle: snapshot.existingBibTitle,
                        existingNotesTitle: snapshot.existingNotesTitle, fallbackBibTitle: input.fallbackBibTitle)
                }
                guard !headers.isEmpty else { return }
                let changes = input.reconciler.reconcile(
                    headers: headers, dbSections: snapshot.dbSections, projectId: input.projectId,
                    bibliographyExistsInBlocks: snapshot.bibliographyExistsInBlocks,
                    notesExistsInBlocks: snapshot.notesExistsInBlocks)
                if !changes.isEmpty {
                    try ProjectDatabase.applySectionChanges(db: db, changes)
                }
            }
        }
        // 5. The content row, ONLY when not zoomed -- ALWAYS otherwise, suppression or not (content-of-record is never suppressed).
        if !input.isZoomed {
            try MdSpeed.timed("sectionSync.saveContent") {
                try ProjectDatabase.saveContent(db: db, markdown: input.markdown, projectId: input.projectId)
            }
        }
        return true
    }

    /// Runs the write: on the writer's queue when a writer is wired (`systemWriter`), else (and when the queue refuses before
    /// reserving because there is no writer, the identity differs, or the call is nested) directly, as before B3-0. `explicit`
    /// runs (`syncNow`, a caller that reads the rows right after) always write unless a newer run already wrote; a debounced run
    /// that finds a newer run requested by its turn writes nothing (the newer one carries newer text).
    func performSectionSyncWrite(
        db: ProjectDatabase, input: SectionSyncWriteInput, prepared: PreparedSectionSync, explicit: Bool
    ) async throws {
        if let systemWriter {
            let identity = SystemWriteIdentity(projectId: input.projectId, database: db)
            let request = input.request
            let result = await systemWriter.perform(
                identity: identity, kind: .sectionSync,
                stillWanted: { [weak self] in explicit || self?.sectionWriteRequests == request },
                body: { database in
                    SystemWriteBody(value: try Self.writeSectionSync(db: database, input: input, prepared: prepared))
                })
            switch result.outcome {
            case .applied(let wrote):
                noteSectionSyncOutcome(wrote ? "written" : "overtaken at write")
                return
            case .refused(.notWanted):
                noteSectionSyncOutcome("overtaken at turn")
                return
            case .refused(.noWriter), .refused(.identityMismatch), .refused(.nested):
                DebugLog.log(.sync, "[SectionSyncService] queued write refused (\(result.outcome)) -- writing directly")
                noteSectionSyncOutcome("direct")
            case .refused(let reason):
                DebugLog.log(.sync, "[SectionSyncService] queued write refused: \(reason)")
                noteSectionSyncOutcome("refused")
                return
            case .failed(let error):
                throw error
            }
        }
        _ = try await Task.detached(priority: .utility) {
            try db.dbWriter.write { database in try Self.writeSectionSync(db: database, input: input, prepared: prepared) }
        }.value
    }

    private func noteSectionSyncOutcome(_ outcome: String) {
        #if DEBUG
        testSectionSyncOutcomes.append(outcome)
        #endif
    }
}
