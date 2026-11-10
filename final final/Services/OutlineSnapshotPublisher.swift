//
//  OutlineSnapshotPublisher.swift
//  final final
//
//  t-94369a83 Phase 6 (numbered sidebar snapshots). The ONE reader of the Outline sidebar's data.
//
//  WHAT IT REPLACES. The sidebar's list used to come from a GRDB `ValueObservation` plus explicit refreshes, kept in order by a
//  generation counter (`outlineGeneration`) and a chain of refresh requests (`RefreshSignal`): all there to stop an older reading
//  landing on top of a newer one. This type reads the list itself, numbers each reading, and the sidebar
//  (`EditorViewState.acceptOutlineSnapshot`) shows a reading only if its number is higher than the one it shows.
//
//  WHERE THE NUMBERS COME FROM. The brief for this phase said the `DocumentWriter` would hand them out because every save goes
//  through it. It does not: a status, tag or goal edit (`ContentView.updateSection`), the zoomed Markdown save, the zoom flush and
//  the old-body fall-backs of the structural commands write the `block` table directly. So the trigger is the database's own
//  commit signal (`ProjectDatabase.observeBlockCommits`), which sees every writer, and the number is taken at READ time, in the order
//  the reads are made. One read at a time: a later number never carries older data than an earlier one. (A number taken from a commit
//  counter would not have that property: a read delayed between "read the counter" and "open the transaction" can carry a lower
//  label and newer data than a faster neighbour.)
//
//  THE DRAIN. Everything below hangs on one rule, and it is the part to keep intact: the drain takes the dirty flag and the list of
//  waiting callers and CLEARS the flag before it opens the read. A commit that lands during a read sets the flag again, so the loop
//  reads once more; none is lost. Waiters taken at the start of a read are answered by that read, because it starts after their call.
//  The read runs synchronously on a background task: never the main thread, never inside `DocumentWriter`, never on the writer queue,
//  so it cannot delay a save.
//
//  NO HANG. `snapshotNow()` always returns: with a snapshot, or with nil when the publisher was stopped or the read threw.
//

import Foundation
import GRDB
import Synchronization

/// One numbered reading of the Outline sidebar's data.
struct OutlineSnapshot: Sendable {
    /// Strictly increasing per publisher; never reused, never skipped.
    let rev: Int
    /// The publisher that took it; a snapshot of a stopped or replaced publisher is ignored.
    let publisherId: UUID
    let projectId: String
    /// Heading and section-break rows, bibliography last (raw: the sidebar's overlays are merged in when it is shown).
    let blocks: [Block]
    /// Word counts of the heading rows, from the same read transaction as `blocks`.
    let counts: [String: ProjectDatabase.HeadingWordCounts]
}

final class OutlineSnapshotPublisher: Sendable {

    private struct State {
        var dirty = false
        var waiters: [CheckedContinuation<OutlineSnapshot?, Never>] = []
        var draining = false
        var stopped = false
        var lastRev = 0
        var observation: AnyDatabaseCancellable?
    }

    let id = UUID()
    let projectId: String
    private let database: ProjectDatabase
    private let state = Mutex(State())
    private let tickContinuation: AsyncStream<OutlineSnapshot>.Continuation

    /// The snapshots a commit asked for, in number order. Only the newest unread one is kept: each snapshot is a complete reading, so
    /// a newer one makes an unread older one worthless.
    let ticks: AsyncStream<OutlineSnapshot>

    /// Test seam: called in the drain after a read has finished (successfully or not) and before its snapshot is delivered, with the
    /// number of that read. It lets a test commit a write while a read is "in flight" and prove the commit gets one more snapshot.
    private let afterRead: (@Sendable (Int) -> Void)?

    /// - Parameter observesCommits: true for the publisher of an open project (`startObserving`): a commit to the `block` table then
    ///   asks for a snapshot, and the first reading is taken as soon as the commit signal exists (so a commit made before it was
    ///   established is inside that reading). false for a publisher made on demand for explicit refreshes only
    ///   (`refreshSectionsAwaiting` with no observation running).
    init(database: ProjectDatabase, projectId: String, observesCommits: Bool, afterRead: (@Sendable (Int) -> Void)? = nil) {
        self.database = database
        self.projectId = projectId
        self.afterRead = afterRead
        var continuation: AsyncStream<OutlineSnapshot>.Continuation!
        ticks = AsyncStream(OutlineSnapshot.self, bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        tickContinuation = continuation
        if observesCommits {
            // Started right here, on the caller's thread, as the old observation was: GRDB sets the region observation up inside the
            // writer queue and waits for a write access, which at project open is free (the maintenance writes have finished). The
            // first reading is asked for AFTER the signal exists, so a commit made before it was established is inside that reading.
            // (A background start was tried and put back: it changed nothing the user sees, and starting here keeps the open
            // sequence as it was.)
            let cancellable = database.observeBlockCommits { [weak self] in self?.noteCommit() }
            state.withLock { $0.observation = cancellable }
            noteCommit()
        }
    }

    deinit {
        stop()
    }

    /// True when this publisher reads `database` for `projectId`.
    func serves(database other: ProjectDatabase, projectId otherId: String) -> Bool {
        database === other && projectId == otherId
    }

    /// The number of the newest snapshot taken so far (0 before the first). Readable from any thread without waiting: the sidebar
    /// uses it to refuse an explicit snapshot that was numbered before one of its own local changes.
    var lastAssignedRev: Int {
        state.withLock { $0.lastRev }
    }

    /// A transaction that touched the block table has committed (or the first reading of an opened project is wanted): the next
    /// drain reads a snapshot and puts it on `ticks`. Cheap and safe from any thread, including the writer queue.
    func noteCommit() {
        let accepted = state.withLock { locked -> Bool in
            guard !locked.stopped else { return false }
            locked.dirty = true
            return true
        }
        if accepted { kickDrain() }
    }

    /// Waits for a snapshot whose read starts AFTER this call, and returns it. nil when the publisher is stopped (before or while
    /// waiting) or the read failed; the caller then simply goes on, as it did when the old fetch failed.
    func snapshotNow() async -> OutlineSnapshot? {
        await withCheckedContinuation { (continuation: CheckedContinuation<OutlineSnapshot?, Never>) in
            let accepted = state.withLock { locked -> Bool in
                guard !locked.stopped else { return false }
                locked.waiters.append(continuation)
                return true
            }
            if accepted {
                kickDrain()
            } else {
                continuation.resume(returning: nil)
            }
        }
    }

    /// Ends the publisher: no more commit signals, waiting callers get nil, `ticks` finishes. Safe to call twice.
    func stop() {
        let (waiters, observation) = state.withLock { locked -> ([CheckedContinuation<OutlineSnapshot?, Never>], AnyDatabaseCancellable?) in
            guard !locked.stopped else { return ([], nil) }
            locked.stopped = true
            locked.dirty = false
            let waiting = locked.waiters
            locked.waiters = []
            let observing = locked.observation
            locked.observation = nil
            return (waiting, observing)
        }
        observation?.cancel()
        for waiter in waiters { waiter.resume(returning: nil) }
        tickContinuation.finish()
    }

    // MARK: - The drain

    private func kickDrain() {
        let shouldStart = state.withLock { locked -> Bool in
            guard !locked.draining, !locked.stopped else { return false }
            locked.draining = true
            return true
        }
        guard shouldStart else { return }
        Task.detached(priority: .userInitiated) { [self] in
            await drain()
        }
    }

    private enum Step {
        case finished
        case read(wanted: Bool, waiters: [CheckedContinuation<OutlineSnapshot?, Never>], rev: Int)
    }

    private func drain() async {
        while true {
            let step = state.withLock { locked -> Step in
                if locked.stopped {
                    locked.draining = false
                    return .finished
                }
                guard locked.dirty || !locked.waiters.isEmpty else {
                    locked.draining = false
                    return .finished
                }
                let wanted = locked.dirty
                let waiting = locked.waiters
                locked.dirty = false          // cleared BEFORE the read: a commit during the read sets it again
                locked.waiters = []
                locked.lastRev += 1
                return .read(wanted: wanted, waiters: waiting, rev: locked.lastRev)
            }
            guard case let .read(wanted, waiters, rev) = step else { return }

            let snapshot: OutlineSnapshot?
            do {
                let data = try database.readOutlineSnapshotData(projectId: projectId)
                snapshot = OutlineSnapshot(rev: rev, publisherId: id, projectId: projectId, blocks: data.blocks, counts: data.counts)
            } catch {
                DebugLog.log(.outline, "[OutlineSnapshotPublisher] read failed: \(error)")
                snapshot = nil
            }
            afterRead?(rev)
            if let snapshot, wanted { tickContinuation.yield(snapshot) }
            for waiter in waiters { waiter.resume(returning: snapshot) }

            // A turn for others on this executor between two reads of a busy burst.
            await Task.yield()
        }
    }
}
