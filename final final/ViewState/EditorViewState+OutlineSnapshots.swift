//
//  EditorViewState+OutlineSnapshots.swift
//  final final
//
//  t-94369a83 Phase 6 (numbered sidebar snapshots): how the Outline sidebar's list is brought up to date.
//
//  Before this phase the list came from a GRDB `ValueObservation` and from explicit refreshes (`refreshSections()`,
//  `refreshSectionsAwaiting()`), kept from landing on top of each other by `outlineGeneration` and a chain of `RefreshSignal`s. Now
//  `OutlineSnapshotPublisher` (Services/) reads the list, numbers each reading, and `acceptOutlineSnapshot` shows a reading only if
//  its number is higher than the one the sidebar already shows. The two ways in are kept:
//
//   - a TICK: a transaction that touched the block table committed and the publisher read a snapshot for it. As before, a tick is
//     ignored while `contentState != .idle` (a drag, a zoom, a hierarchy fix is in progress); `withContentStateRecovery` asks for a
//     fresh reading at every return to idle, so nothing is lost.
//   - an EXPLICIT refresh: a caller (`StructuralUndoController`'s sequences, the settles of the editor-first commands) wants the list
//     to be at least as fresh as its own database change. It waits for the first reading that STARTS after the call, and it is not
//     gated by `contentState`, as before.
//
//  The overlays (`pendingRemovalIds`, `pendingRestoreSections`, `pendingRestoreAnchors`, `pendingReorder`) are merged in by
//  `withoutPendingRemovals` at the moment a snapshot is shown, in the same main-actor turn. A snapshot numbered after an overlay was
//  set and shown after it therefore always shows the overlay; the word counts are inside the snapshot, so there is no `await`
//  between receiving a reading and showing it for an overlay to change under.
//

import Foundation

extension EditorViewState {

    /// How a snapshot reached the sidebar.
    enum OutlineSnapshotSource: Equatable {
        /// A commit asked for it (the publisher's tick stream).
        case tick
        /// A caller asked for it. `sectionsWritesAtCall` is `localSectionsWriteCount` when the call was made: if anything wrote
        /// `sections` locally since, the snapshot is dropped (see `acceptOutlineSnapshot`).
        case explicit(sectionsWritesAtCall: Int)
    }

    // MARK: - Starting and stopping

    /// Makes the publisher of the open project and starts the loop that shows its commit-driven snapshots. The publisher takes the
    /// first reading itself as soon as its commit signal exists (the old observation also delivered once at start, which is how the
    /// sidebar fills when a project opens). The loop holds the tick stream, not the publisher: if this state is freed without
    /// `stopObserving`, the publisher goes with it and the stream ends.
    func beginOutlineSnapshots(database: ProjectDatabase, projectId: String) {
        let ticks = replaceOutlinePublisher(database: database, projectId: projectId, observesCommits: true).ticks
        observationTask = Task { [weak self] in
            for await snapshot in ticks {
                guard !Task.isCancelled, let self else { break }
                self.acceptOutlineSnapshot(snapshot, source: .tick)
            }
        }
    }

    /// Stops the tick loop and the publisher. A caller still waiting for a snapshot is answered with nothing and goes on.
    func endOutlineSnapshots() {
        observationTask?.cancel()
        observationTask = nil
        outlinePublisher?.stop()
        outlinePublisher = nil
    }

    private func replaceOutlinePublisher(
        database: ProjectDatabase,
        projectId: String,
        observesCommits: Bool
    ) -> OutlineSnapshotPublisher {
        outlinePublisher?.stop()
        let publisher = OutlineSnapshotPublisher(database: database, projectId: projectId, observesCommits: observesCommits)
        outlinePublisher = publisher
        shownOutlineRev = 0
        return publisher
    }

    /// The publisher for an explicit refresh. Made on demand when there is none for this database and project (a rig that sets
    /// `projectDatabase` directly, or a refresh that arrives after `stopObserving`): such a publisher reads on request only and
    /// does not watch commits.
    private func outlinePublisher(serving database: ProjectDatabase, projectId: String) -> OutlineSnapshotPublisher {
        if let publisher = outlinePublisher, publisher.serves(database: database, projectId: projectId) {
            return publisher
        }
        return replaceOutlinePublisher(database: database, projectId: projectId, observesCommits: false)
    }

    // MARK: - Explicit refresh

    /// Re-read the outline and show it. Fire-and-forget wrapper around `refreshSectionsAwaiting()` for callers that don't need to
    /// know when it lands.
    func refreshSections() {
        StructuralTrace.log("refreshSections requested") // slice 0 measurement; silent unless tracing is on
        Task { [weak self] in
            await self?.refreshSectionsAwaiting()
        }
    }

    /// Awaited version of `refreshSections()` (`StructuralUndoController`'s audited sequences run hierarchy enforcement in-sequence
    /// afterwards, so they need the sidebar to be as fresh as their own database change when this returns). Returns when the first
    /// snapshot that starts after the call has been shown, or has been refused because a higher number is already shown, or when no
    /// snapshot came (the publisher stopped, the project changed, the read failed): the caller then goes on, as it did when the old
    /// fetch failed. It never waits behind another refresh: two refreshes are two readings, in order.
    func refreshSectionsAwaiting() async {
        let traceSpan = StructuralTrace.span("refreshSectionsAwaiting") // slice 0 measurement; silent unless tracing is on
        defer { traceSpan.end() }
        // Taken before any suspension: a local write to `sections` after this point makes the snapshot stale (see acceptOutlineSnapshot).
        let sectionsWritesAtCall = localSectionsWriteCount
        guard let database = projectDatabase, let projectId = currentProjectId else {
            DebugLog.log(.outline, "[EditorViewState:refresh] BAIL: no db/pid")
            return
        }
        let publisher = outlinePublisher(serving: database, projectId: projectId)
        let fetchSpan = MdSpeed.span("refreshSections.outlineFetch")   // an await; the read runs on the publisher's own task
        let snapshot = await publisher.snapshotNow()
        fetchSpan.end()
        guard let snapshot else {
            DebugLog.log(.outline, "[EditorViewState:refresh] no snapshot (publisher stopped or read failed)")
            return
        }
        let applySpan = MdSpeed.span("refreshSections.apply")   // main thread: the merge, the assignment and the sidebar callback
        defer { applySpan.end() }
        acceptOutlineSnapshot(snapshot, source: .explicit(sectionsWritesAtCall: sectionsWritesAtCall))
    }

    // MARK: - Showing a snapshot

    /// Shows `snapshot` in the sidebar if it is allowed to be shown. Returns whether it was shown.
    ///
    /// Not shown, in this order:
    ///  1. it comes from a publisher that is not the current one, or for another project (a project switch overtook it): ignored
    ///     without a trace, as the old fetch bailed;
    ///  2. a TICK while `contentState != .idle`: skipped (the return to idle asks again). The check happens HERE, when the snapshot
    ///     is about to be shown. The old observation checked before its word-count `await` and could still show a tick after the
    ///     state had left idle; now such a tick is skipped.
    ///  3. its number is not higher than the one already shown: counted in `staleOutlineDropCount`. An explicit refresh still calls
    ///     `onSectionsUpdated` (the structural sequences run hierarchy enforcement from it);
    ///  4. an EXPLICIT snapshot when something has written `sections` locally since the call (`localSectionsWriteCount` moved):
    ///     hierarchy enforcement's local level fix and the old reorder path's `mutate` closure write `sections` ahead of their
    ///     database change, and the snapshot may have been read before that change. The old generation counter dropped it for the
    ///     same reason. Ticks are not held to this rule, as they never were.
    ///
    /// Otherwise the overlays are merged into the rows, the equality cache decides whether anything changed, the merge by id updates
    /// `sections`, and `onSectionsUpdated` runs (hierarchy enforcement and the like).
    @discardableResult
    func acceptOutlineSnapshot(_ snapshot: OutlineSnapshot, source: OutlineSnapshotSource) -> Bool {
        guard let publisher = outlinePublisher, snapshot.publisherId == publisher.id, snapshot.projectId == currentProjectId else {
            return false
        }
        if source == .tick, contentState != .idle {
            DebugLog.log(.outline, "[EditorViewState:snapshot] SKIPPED tick \(snapshot.rev): contentState=\(contentState)")
            return false
        }
        var explicit = false
        var droppedByLocalWrite = false
        if case let .explicit(writesAtCall) = source {
            explicit = true
            droppedByLocalWrite = writesAtCall != localSectionsWriteCount
        }
        guard snapshot.rev > shownOutlineRev, !droppedByLocalWrite else {
            staleOutlineDropCount += 1
            DebugLog.log(.outline, "[EditorViewState:snapshot] refused \(snapshot.rev) (shown \(shownOutlineRev), local: \(droppedByLocalWrite))")
            if explicit { onSectionsUpdated?() }
            return false
        }
        shownOutlineRev = snapshot.rev
        let visibleBlocks = withoutPendingRemovals(snapshot.blocks)
        DebugLog.log(.outline, "[EditorViewState:snapshot] \(snapshot.rev) shown: \(visibleBlocks.count) sections (contentState=\(contentState))")
        if !isOutlineUnchanged(blocks: visibleBlocks, counts: snapshot.counts) {
            // `applySectionsUpdate` merges into a local copy and only assigns back when something actually changed: `inout` access to
            // a tracked `@Observable` property fires its array-level notification unconditionally on exit, which would defeat the
            // merge on every single snapshot.
            applySectionsUpdate(from: visibleBlocks, counts: snapshot.counts)
        }
        onSectionsUpdated?()
        return true
    }
}
