//
//  EFJobRegistry.swift
//  final final
//
//  t-94369a83 Phase 4b, slice 2a (plan D2.5 and D7, addendum A1): one record per editor-first section-delete
//  job, with a one-shot future that ALWAYS resolves. Whoever has to wait for "the delete's own job" -- zoom, the switch to
//  Markdown, Save Version and export (`awaitPendingStructuralJobs`), the slow undo (`performUndo`'s `.sectionDelete` branch), the
//  close/quit wait for queued section commands (A1) -- awaits the record, never the whole writer queue.
//
//  The future resolves exactly once, on the first of:
//    - the system write returning ANY outcome (applied, failed, or refused for any reason: skipped by the stall backstop,
//      the writer retired, an identity mismatch, nested, out of turn, no writer, not wanted) -- `settle(_:with:)`;
//    - `abandonAll()`, which the lifecycle barrier (close, quit, project switch, Getting Started) calls so that no waiter
//      outlives the project;
//    - the registry being deallocated (its owner, the controller, going away).
//
//  It is NOT the `@MainActor` `OneShotContinuation` (coder obligation 6): a record is resolved from the writer's executor (the
//  system write returning) as well as from the MainActor (the barrier), and awaited from either, so the signal is a
//  lock-protected value plus a list of waiting continuations, with no actor isolation.
//

import Foundation
import os

/// How a job ended, as far as a waiter is concerned.
enum JobOutcome: Sendable, Equatable {
    /// The system write committed: the section's rows are deleted and the Version History snapshot is written.
    case applied
    /// The system write threw (the transaction rolled back, nothing changed in the database); the message is for the log.
    case failed(String)
    /// The writer refused the write without running its body (it never touched the database).
    case refused(SystemRefuseReason)
    /// The lifecycle barrier or the owner's deallocation resolved the record before the write finished (or before it
    /// was reported). The write itself may still apply later; a waiter treats the project as going away.
    case abandoned

    /// The record's outcome for a finished system write, whatever generic value it carried.
    init<R: Sendable>(_ outcome: SystemWriteOutcome<R>) {
        switch outcome {
        case .applied: self = .applied
        case .refused(let reason): self = .refused(reason)
        case .failed(let error): self = .failed(String(describing: error))
        }
    }

    var isApplied: Bool { self == .applied }
}

/// A future that resolves at most once, to a `JobOutcome`, and can be awaited any number of times, from any context, before
/// or after it resolves. Waiters are never cancelled by task cancellation: the future resolves on every path, so there is
/// nothing to bail out of.
final class JobOutcomeFuture: Sendable {
    private enum State: Sendable {
        case pending([CheckedContinuation<JobOutcome, Never>])
        case resolved(JobOutcome)
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: .pending([]))

    init() {}

    /// Resolves the future with `outcome` and resumes every waiter. Returns `true` for the call that resolved it, `false` (and
    /// changes nothing) for every later call.
    @discardableResult
    func resolve(_ outcome: JobOutcome) -> Bool {
        let waiters: [CheckedContinuation<JobOutcome, Never>]? = state.withLock { current in
            guard case .pending(let waiting) = current else { return nil }
            current = .resolved(outcome)
            return waiting
        }
        guard let waiters else { return false }
        for waiter in waiters { waiter.resume(returning: outcome) }
        return true
    }

    /// The outcome if the future has resolved, nil while it is still pending.
    var value: JobOutcome? {
        state.withLock { current in
            if case .resolved(let outcome) = current { return outcome }
            return nil
        }
    }

    /// Waits for the outcome; returns at once when the future has already resolved.
    func wait() async -> JobOutcome {
        await withCheckedContinuation { continuation in
            let alreadyResolved: JobOutcome? = state.withLock { current in
                switch current {
                case .resolved(let outcome):
                    return outcome
                case .pending(var waiting):
                    waiting.append(continuation)
                    current = .pending(waiting)
                    return nil
                }
            }
            if let alreadyResolved { continuation.resume(returning: alreadyResolved) }
        }
    }
}

/// One section-delete job's record: the operation id (the `StructuralEntry`'s id) and the future that says how the job ended.
final class EFJobRecord: Sendable {
    let opId: UUID
    let future = JobOutcomeFuture()

    init(opId: UUID) {
        self.opId = opId
    }

    /// The outcome once the job has ended, nil while it is outstanding.
    var outcome: JobOutcome? { future.value }
    var isResolved: Bool { future.value != nil }
}

/// The controller's table of job records, keyed by operation id.
///
/// Besides the job itself it tracks the work that FOLLOWS an applied job (the bibliography and footnote resyncs, the section and
/// annotation syncs, and the push of the database's Notes and Bibliography into the editor: `settle`, StructuralUndoController+
/// EditorFirstDelete.swift). That work is not part of the job's future (the future resolves when the system write returns), but
/// whoever waits for "the delete" before it saves or flushes the document must wait for it too: until it has finished the editor's
/// Notes are half updated, and a whole-document write of the editor's text writes that over the database's correct Notes. One
/// entry per registered job, from `register` until `markSettled` (or the lifecycle's `abandonAll`), kept apart from the job records
/// so that dropping a record (`forget`) never hides unfinished follow-up work.
final class EFJobRegistry: Sendable {
    private let records = OSAllocatedUnfairLock(initialState: [UUID: EFJobRecord]())
    /// The jobs whose follow-up work has not finished (a job that has not ended is in here too).
    private let unsettled = OSAllocatedUnfairLock(initialState: Set<UUID>())

    init() {}

    /// Registers the job for `opId` before it is reserved and returns its record. A second `register` for the same id returns the
    /// record already there (so a retry can never leave two futures for one entry).
    @discardableResult
    func register(_ opId: UUID) -> EFJobRecord {
        unsettled.withLock { table in _ = table.insert(opId) }
        return records.withLock { table in
            if let existing = table[opId] { return existing }
            let record = EFJobRecord(opId: opId)
            table[opId] = record
            return record
        }
    }

    /// The job of `opId` AND the work that follows it have finished (or the entry was abandoned). Idempotent; a no-op for an id that
    /// was never registered or was already settled.
    func markSettled(_ opId: UUID) {
        unsettled.withLock { table in _ = table.remove(opId) }
    }

    func record(for opId: UUID) -> EFJobRecord? {
        records.withLock { $0[opId] }
    }

    /// Waits for the job of `opId` to end. Returns at once when it already has (the outcome stays on the record until `forget`).
    /// Returns nil when no job was ever registered under that id, or its record was forgotten.
    func awaitOutcome(_ opId: UUID) async -> JobOutcome? {
        guard let record = record(for: opId) else { return nil }
        return await record.future.wait()
    }

    /// Resolves the record of `opId` with `outcome`. Returns `true` when this call resolved it, `false` when it was already
    /// resolved (the first outcome stays) or no such record exists.
    @discardableResult
    func resolve(_ opId: UUID, _ outcome: JobOutcome) -> Bool {
        guard let record = record(for: opId) else { return false }
        return record.future.resolve(outcome)
    }

    /// Resolves the record of `opId` from a finished system write, whatever its outcome was.
    @discardableResult
    func settle<R: Sendable>(_ opId: UUID, with outcome: SystemWriteOutcome<R>) -> Bool {
        resolve(opId, JobOutcome(outcome))
    }

    /// Resolves every outstanding record `.abandoned` (the lifecycle barrier's `cancelAll`, and this registry's own deinit).
    /// Returns how many records it resolved.
    @discardableResult
    func abandonAll() -> Int {
        let outstanding = records.withLock { table in table.values.filter { !$0.isResolved } }
        let abandoned = outstanding.reduce(0) { count, record in count + (record.future.resolve(.abandoned) ? 1 : 0) }
        // Nobody waits for follow-up work on a project that is going away either.
        unsettled.withLock { table in table.removeAll() }
        return abandoned
    }

    /// How many jobs have not ended yet.
    var outstandingCount: Int {
        records.withLock { table in table.values.filter { !$0.isResolved }.count }
    }

    /// How many jobs have not finished all of their work: the job itself, or what follows it.
    var unsettledCount: Int {
        unsettled.withLock { $0.count }
    }

    /// True while any delete is still being carried through: its job has not ended, or the work after it has not finished. This is
    /// what the close/quit wait, the zoom, the switch to Markdown, Save Version and export wait on (never the writer's whole queue).
    var hasUnsettledWork: Bool { outstandingCount > 0 || unsettledCount > 0 }

    /// Waits until every job registered so far, and any registered while waiting, has ended (A1's "every pending future has
    /// resolved"). Returns at once when none is outstanding.
    func awaitAllOutstanding() async {
        while true {
            let outstanding = records.withLock { table in table.values.filter { !$0.isResolved } }
            guard !outstanding.isEmpty else { return }
            for record in outstanding { _ = await record.future.wait() }
        }
    }

    /// Waits until every job registered so far has ended AND the work that follows each applied job has finished, however many
    /// are registered while waiting. The first part waits on the jobs' futures, as `awaitAllOutstanding` does; the follow-up part is
    /// checked every 10 ms and gives up after `settleBound` (the follow-up is a handful of small writes through the same queue, which
    /// has its own five-second stall backstop; the bound only guarantees that a follow-up that never ends cannot hold a zoom, a
    /// switch or an export for ever, and is logged when it happens).
    func awaitAllSettled(settleBound: Duration = .seconds(15)) async {
        await awaitAllOutstanding()
        guard unsettledCount > 0 else { return }
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: settleBound)
        while unsettledCount > 0 {
            if clock.now >= end {
                DebugLog.alwaysPersisted(
                    "[EFJobRegistry] gave up waiting for \(unsettledCount) delete(s) to finish their follow-up work after \(settleBound)")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Drops the record of `opId` (the entry was evicted or its timeline invalidated). An unresolved record is resolved
    /// `.abandoned` first, so nobody keeps waiting on a record nobody can reach. Follow-up work that is still running stays
    /// counted until it finishes (`markSettled`).
    func forget(_ opId: UUID) {
        let removed = records.withLock { table in table.removeValue(forKey: opId) }
        removed?.future.resolve(.abandoned)
    }

    deinit {
        // "On deinit of the owner": nothing may wait forever on a registry that is gone.
        for record in records.withLock({ table in Array(table.values) }) { record.future.resolve(.abandoned) }
    }
}
