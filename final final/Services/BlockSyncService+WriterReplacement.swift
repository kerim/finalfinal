//
//  BlockSyncService+WriterReplacement.swift
//  final final
//
//  t-b7e3c791: the one routine that retires the service's old `DocumentWriter` and installs a new one. It used to exist three times
//  (`configure`'s replacement branch, `reconfigure`, `ensureWriter`), so a change to how a writer is retired could be made in one copy
//  and missed in the others.
//

import Foundation

extension BlockSyncService {
    /// Retires the current `writer` (if there is one) with `reason` and installs a new `DocumentWriter` for `database` and `projectId`,
    /// continuing the old writer's sequence numbers so stamps stay monotonic across the replacement (see "Sequence continuity" in the
    /// write-queue plan). Returns the first sequence number the new writer will hand out, which is the old writer's `nextSequence`
    /// (1 when there was no writer).
    ///
    /// What it does, in this order (each of the three former copies did exactly these five steps, in this order):
    ///
    /// 1. Reads the old writer's `nextSequence` (1 if there is no writer): the new writer's `firstSequence`.
    /// 2. DEBUG builds only: reads the old writer's four per-INSTANCE test knobs (`testEventHandler`, `testLateAfterSeconds`,
    ///    `testDrainTimeoutSeconds`, `testLateAbandonAfterSeconds`). They live on the writer instance, so replacing `writer` would
    ///    otherwise silently drop whatever a test wired onto the old one; carrying them forward mirrors the sequence continuity above.
    ///    The old writer is read BEFORE it is retired.
    /// 3. `writer?.retire(reason:)`: skips every turn the old writer has reserved, drops every held op and any open barrier, and
    ///    refuses anything reserved after. A no-op when there is no writer.
    /// 4. `writer = DocumentWriter(database:projectId:firstSequence:assertsMainActorCallers: true)`.
    /// 5. DEBUG builds only: writes the four carried knobs onto the new writer.
    ///
    /// What it does NOT do, because the three callers differ there and keep it themselves: the same-project/same-database check (only
    /// `configure` and `ensureWriter` have a no-replace case, each with its own rule), the service's own `projectDatabase`,
    /// `projectId` and `webView` fields (`configure` and `reconfigure` set them, `ensureWriter` deliberately does not), the
    /// `reportApplier` touch (`configure` only) and the `blockWriteEpoch` bump with its own log line (all three bump, after this
    /// returns). The only thing that really differed between the three copies was `reason`, so it is the one parameter:
    ///
    /// - `.writerReplaced`: `configure`'s replacement branch (a fresh WebView for another database or project) and `ensureWriter`
    ///   (Markdown's safety net replacing a retired or other-project writer).
    /// - `.projectSwitch`: `reconfigure` (a project switch, the WebView stays).
    ///
    /// The `database`/`projectId` parameters are the facts of the new writer; they are not read from, or written to, the service's
    /// own fields here.
    @discardableResult
    func replaceWriter(database: ProjectDatabase, projectId: String, retiringOldWriterFor reason: SkipReason) -> UInt64 {
        let next = writer?.nextSequence ?? 1
        #if DEBUG
        let carriedEventHandler = writer?.testEventHandler
        let carriedLateAfter = writer?.testLateAfterSeconds
        let carriedDrainTimeout = writer?.testDrainTimeoutSeconds
        let carriedLateAbandonAfter = writer?.testLateAbandonAfterSeconds
        #endif
        writer?.retire(reason: reason)
        writer = DocumentWriter(
            database: database, projectId: projectId, firstSequence: next, assertsMainActorCallers: true)
        #if DEBUG
        writer?.testEventHandler = carriedEventHandler
        writer?.testLateAfterSeconds = carriedLateAfter
        writer?.testDrainTimeoutSeconds = carriedDrainTimeout
        writer?.testLateAbandonAfterSeconds = carriedLateAbandonAfter
        #endif
        return next
    }
}
