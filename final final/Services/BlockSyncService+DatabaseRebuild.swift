//
//  BlockSyncService+DatabaseRebuild.swift
//  final final
//
//  Finding #1 (Calm_Bibliography, docs/architecture/tla/README.md), fixed for
//  t-7c1d3fd8: a bibliography/Notes/footnote rebuild force-flushes pending editor
//  changes and THEN reads the database to rebuild editor content. A routine 2-second
//  poll cycle that is parked between its own fetch and its post-fetch generation
//  re-check when the rebuild bumps `contentGeneration` used to be discarded as
//  "stale" by `BlockSyncService.checkGenerationGuard` — even though, for THIS kind of
//  rewrite, the parked batch is the FRESHER copy and the database the rebuild is
//  about to read is the OLDER one. This file adds the narrow exception that lets that
//  one specific parked batch be kept instead of discarded, and the two entry points a
//  rebuild handler uses to mark the exception's window.
//
//  See `BlockSyncService.checkGenerationGuard`'s doc comment for why this is safe.
//

extension BlockSyncService {
    /// Pure decision for the Finding #1 exception. Keep the batch ONLY if the one and
    /// only generation transition since this poll cycle's snapshot was taken
    /// (`generationAtPollStart`) is the pending database rebuild itself
    /// (`rebuildGeneration`) — i.e. `currentGeneration == rebuildGeneration ==
    /// generationAtPollStart + 1`. Two or more transitions (e.g. a hierarchy fix
    /// followed by a rebuild) mean this batch predates a database rewrite unrelated to
    /// the rebuild being tracked, so the pre-existing ce564961/53e6777b hierarchy-race
    /// discard must still apply — keeping in that case could resurrect text a DIFFERENT,
    /// intervening rewrite already replaced.
    nonisolated static func shouldKeepBatchForDatabaseRebuild(
        currentGeneration: Int?, generationAtPollStart: Int, rebuildGeneration: Int?
    ) -> Bool {
        guard let currentGeneration, let rebuildGeneration else { return false }
        return currentGeneration == rebuildGeneration && rebuildGeneration == generationAtPollStart + 1
    }

    /// Called synchronously by a bibliography/Notes/footnote rebuild handler
    /// (`ContentView+NotificationHandlers.swift`) the instant it sets
    /// `editorState.contentState = .bibliographyUpdate` — before any `Task { ... }` is
    /// spawned — so `databaseRebuildGeneration` is set before any poll cycle can
    /// observe the generation bump. Records the POST-bump generation: that is the value
    /// a parked routine cycle's live re-check will see once the bump lands, and exactly
    /// what `shouldKeepBatchForDatabaseRebuild` compares against.
    func beginDatabaseRebuild() {
        databaseRebuildGeneration = editorState?.contentGeneration
    }

    /// The rebuild's own forced flush. Identical to `pollBlockChangesNow()` except that
    /// it clears `databaseRebuildGeneration` in its `defer` once this cycle returns —
    /// i.e. NORMALLY after any parked routine cycle this forced flush has awaited has
    /// already finished applying its (possibly kept) batch, and before the caller goes on
    /// to read the database. That ordering is what makes the exception in
    /// `checkGenerationGuard` safe in the overwhelming common case: the marker is live for
    /// the whole window in which a kept batch could still be written, and gone before the
    /// database read that must see it. See that function's doc comment's KNOWN RESIDUAL
    /// for the narrow hung-WebKit-watchdog window where the SPAWNER returns (and this
    /// `defer` fires) before the underlying work task's write has actually landed — not
    /// closed here, same class as the pre-existing L8/L10 residuals.
    ///
    /// The `defer` clears the marker only if it still holds THIS call's own value
    /// (`myMarker`, captured at entry) — never a blind `= nil`. Two rebuilds can
    /// overlap: the 5s `contentStateWatchdog` (`EditorViewState.swift`) can free
    /// `contentState` back to `.idle` while THIS flush (up to the 8s poll watchdog,
    /// doubled by a drain) is still running, letting a second rebuild start and call
    /// `beginDatabaseRebuild()` — overwriting the marker with ITS OWN generation —
    /// before this flush's `defer` fires. A blind clear there would wipe the SECOND
    /// rebuild's marker out from under it, and a routine cycle parked in the second
    /// rebuild's window would then be wrongly discarded instead of kept — the exact
    /// t-7c1d3fd8 bug reappearing one rebuild later. Comparing against the captured
    /// value before clearing means this flush only ever cleans up after ITSELF.
    func pollBlockChangesNowForDatabaseRebuild() async {
        let myMarker = databaseRebuildGeneration
        #if DEBUG
        // Test-only synchronization point, awaited immediately after THIS call captures
        // its own `myMarker` — i.e. before `pollBlockChangesNow()` below can suspend on
        // anything (the drain loop, a fetch, a chain wait). Swift gives no guarantee about
        // WHEN a freshly spawned `Task`'s body first runs relative to its spawning code's
        // own subsequent statements (it is not "deferred until the spawner's next await" —
        // a test that assumed that got a false pass/fail from a marker captured at the
        // wrong moment). This hook lets a test PROVE this call's entry — and therefore the
        // exact value it captured as `myMarker` — happened at a specific, controlled point,
        // instead of assuming scheduler ordering. No cost in release builds (property
        // doesn't exist).
        await testAfterMarkerCaptureHook?()
        #endif
        defer {
            if databaseRebuildGeneration == myMarker {
                databaseRebuildGeneration = nil
            }
        }
        await pollBlockChangesNow()
    }

    #if DEBUG
    /// Test-only observation of the rebuild marker. Lets a test assert it clears once
    /// the forced flush returns, without exposing the property for mutation.
    var testDatabaseRebuildGeneration: Int? { databaseRebuildGeneration }
    #endif
}
