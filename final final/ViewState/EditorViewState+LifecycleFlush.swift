//
//  EditorViewState+LifecycleFlush.swift
//  final final
//
//  t-d2061b27 (review F24, lint): STEP 6 (FB) of the lifecycle save sequence, moved out of EditorViewState+Lifecycle.swift so that file
//  stays under SwiftLint's file-length limit. A mechanical move: no behaviour changed. The only difference is that
//  `writeWholeDocumentForLifecycle` lost its `private` (it is called from `runLifecycleFlush`, which stays in EditorViewState+Lifecycle.swift);
//  the two helpers it uses stay `private static` here. The types it works with (`LifecycleCapture`, `LifecycleFlushResult`,
//  `LifecycleFBReservedSignal`, `LifecycleFBOutcome`) are declared in EditorViewState+Lifecycle.swift.
//

import Foundation
import WebKit

extension EditorViewState {

    // MARK: Step 6 (FB)

    /// The gate for checked FB (Phase 3a-2, plan-v2 section 0, "Option A, per the user's decision"): whether FB
    /// may write NOTHING when the stored rows already match what it would write. All of these must hold:
    ///   - Rich Text mode (in Markdown there is no per-edit path: FB is the only write of the typing);
    ///   - not zoomed, which means BOTH `zoomedRange` and `zoomedSectionId` are nil (the zoom-in-flight shape,
    ///     section id set and range nil, must stay the counted `.refused(.notWanted)` loss, N15; a zoomed
    ///     close also writes Mini-Notes, N17);
    ///   - F finished cleanly: no poll watchdog hit, no drain or forced-poll timeout (the editor answered);
    ///   - the fresh fetch really answered (`fetchedContent != nil`, not the `usedFallback` content on hand).
    /// "A writer exists" is NOT part of the gate: it cannot be known here. The direct-write fallback
    /// (no queue writer, or a writer of another project) never inherits the decision: it writes with
    /// `prepared.forcingWrite()` and keeps reporting `.appliedDirectly` (plan-v2 C6).
    static func fbMaySkipWhenUnchanged(capture: LifecycleCapture, result: LifecycleFlushResult) -> Bool {
        capture.editorMode == .wysiwyg
            && capture.zoomedRange == nil
            && capture.zoomedSectionId == nil
            && !result.watchdogHit && !result.drainTimedOut && !result.forcedPollTimedOut
            && result.fetchedContent != nil
            && !result.usedFallback
    }

    /// FB: prepare (parse before reserving, item 17), then the queued whole-document write in its OWN Task,
    /// raced at `bound(fb)`. Losing the race is neither a failure nor a loss (E1): the race cannot cancel
    /// the Task, the sequence goes on, and the barrier (round C3b), queued behind FB, is what waits for it.
    func writeWholeDocumentForLifecycle(   // internal (was private): called from runLifecycleFlush in EditorViewState+Lifecycle.swift
        content: String,
        capture: LifecycleCapture,
        raceBound: TimeInterval,
        result: inout LifecycleFlushResult
    ) async {
        guard let blockSync = capture.blockSync, let database = capture.database, let projectId = capture.projectId else {
            DebugLog.log(.lifecycle, "[LifecycleFlush] FB skipped: no block-sync service, database or project id")
            result.fbStatus = .skippedNoWriteTarget
            return
        }
        // Checked FB (Phase 3a-2): the gate for "write nothing if the stored rows already match" is decided
        // HERE, from the sequence's own results; the comparison itself runs inside FB's queued transaction.
        let skipIfUnchanged = Self.fbMaySkipWhenUnchanged(capture: capture, result: result)
        guard let prepared = LifecycleWholeDocumentWrite.prepare(
            content: content,
            database: database,
            projectId: projectId,
            zoomedRange: capture.zoomedRange,
            zoomedSectionId: capture.zoomedSectionId,
            skipIfUnchanged: skipIfUnchanged
        ) else {
            result.fbStatus = .skippedEmptyContent
            return
        }
        // N9: step 8 must enqueue the barrier only AFTER FB reserved its place, or the barrier would park FB
        // behind itself. `reserved` is marked by `performSystemWrite` right after its reservation (same
        // MainActor turn), and, belt and braces, when FB's Task ends having reserved nothing.
        let reserved = LifecycleFBReservedSignal()
        let fbTask: Task<LifecycleFBOutcome, Never> = Task { @MainActor in
            defer { reserved.mark() }
            return await Self.performLifecycleWholeDocument(
                blockSync: blockSync, database: database, projectId: projectId, prepared: prepared,
                onReserved: { reserved.mark() })
        }
        result.fbStatus = .started
        result.fbTask = fbTask
        result.fbReserved = reserved
        switch await raceAgainstTimeout(.seconds(raceBound), { await fbTask.value }) {
        case .finished(let outcome):
            result.fbOutcome = outcome
            result.fbSettledOutcome = outcome
        case .timedOut:
            DebugLog.log(.lifecycle, "[LifecycleFlush] FB still queued after \(raceBound)s: not a failure, the barrier waits for it")
        }
    }

    /// FB's body: the queued write, and the plan's direct-write fallbacks. `.refused(.noWriter)` (no writer
    /// yet, e.g. a launch straight into Markdown) is not a loss: the same body runs directly. An
    /// `.identityMismatch` was already counted lost by `performSystemWrite`'s hook, then gets the direct
    /// write. `.refused(.notWanted)` is `performLifecycleWholeDocumentWrite`'s zoomed-without-range refusal
    /// (judge adjustment B1), counted there, and a loss here (N15).
    private static func performLifecycleWholeDocument(
        blockSync: BlockSyncService,
        database: ProjectDatabase,
        projectId: String,
        prepared: LifecycleWholeDocumentPrepared,
        onReserved: @escaping () -> Void
    ) async -> LifecycleFBOutcome {
        let identity = SystemWriteIdentity(projectId: projectId, database: database)
        let written = await blockSync.performLifecycleWholeDocumentWrite(
            identity: identity, prepared: prepared, onReserved: onReserved)
        switch written.outcome {
        case .applied(.written):
            return .applied
        case .applied(.unchanged(let rowCount)):
            // Checked FB: this is where "unchanged" is counted (the writer's ledger cannot see it).
            DebugLog.log(.lifecycle, "[LifecycleFlush] FB unchanged: \(rowCount) rows already match -- nothing written, no epoch bump")
            return .unchanged
        case .refused(.noWriter), .refused(.identityMismatch):
            // The direct write NEVER inherits the skip decision: it always writes (plan-v2 C6).
            return writeLifecycleWholeDocumentDirectly(
                blockSync: blockSync, database: database, prepared: prepared.forcingWrite())
        case .refused(let reason):
            return .lost("refused(\(reason))")
        case .failed(let error):
            return .lost("failed(\(error))")
        }
    }

    private static func writeLifecycleWholeDocumentDirectly(
        blockSync: BlockSyncService,
        database: ProjectDatabase,
        prepared: LifecycleWholeDocumentPrepared
    ) -> LifecycleFBOutcome {
        let body = LifecycleWholeDocumentWrite.body(prepared)
        do {
            _ = try database.write { try body($0) }
            DebugLog.log(.lifecycle, "[LifecycleFlush] FB written directly (no queue writer for this project)")
            return .appliedDirectly
        } catch {
            blockSync.reportLifecycleWholeDocumentLost(reason: "direct write failed: \(error)")
            return .lost("direct write failed: \(error)")
        }
    }
}
