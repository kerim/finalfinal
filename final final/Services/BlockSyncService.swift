//
//  BlockSyncService.swift
//  final final
//
//  Unified sync service for block-based content model.
//  Polls the editor for block changes and applies them to the database.
//

import Foundation
import WebKit

/// Service to sync editor block changes with the database
/// Uses poll-based pattern (similar to existing content polling) for change detection
@MainActor
@Observable
class BlockSyncService {
    private var pollTimer: Timer?
    /// 2s polling (block changes accumulate in JS). Not `private`: `EditorViewState.
    /// ReconcileSuppression`'s TTL is derived from this (plus a margin) rather than
    /// duplicating the constant -- see that type's doc comment. `nonisolated` (judge-review
    /// should-fix): not a real race (immutable, Sendable, literal-initialized), but without
    /// it this is a new warning under Swift 6 mode that would become a hard error.
    nonisolated static let pollInterval: TimeInterval = 2.0
    private let pollInterval: TimeInterval = BlockSyncService.pollInterval

    private var projectDatabase: ProjectDatabase?
    private var projectId: String?
    private weak var webView: WKWebView?
    /// Fetch content from the active WebView with a timeout.
    /// Returns nil if WebView is unavailable, JS call fails, or timeout elapses.
    func fetchContentFromWebView(timeout: Duration = .seconds(2)) async -> String? {
        guard let webView else { return nil }
        do {
            return try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask { @MainActor in
                    let result = try await webView.evaluateJavaScript(
                        "window.FinalFinal.getContent()"
                    )
                    return result as? String
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
        } catch {
            return nil
        }
    }

    /// Whether the service is properly configured
    var isConfigured: Bool {
        projectDatabase != nil && projectId != nil && webView != nil
    }

    /// Reference to editor state for contentGeneration and contentState checks
    weak var editorState: EditorViewState?

    /// Pending ID confirmations (temp ID -> permanent ID) to send back to editor
    private var pendingConfirmations: [String: String] = [:]

    /// Cumulative temp→permanent ID mapping across all poll cycles.
    /// Used to resolve stale temp IDs that arrive after confirmation
    /// (race between JS debounce and Swift confirmBlockIds).
    private var confirmedTempIds: [String: String] = [:]

    // MARK: - Stale-snapshot guard helpers (pure, testable)

    /// Reason a poll result was hard-rejected as a stale snapshot.
    enum StaleRejectReason: Equatable {
        case allDeletedNoInserts    // all blocks would be deleted with no inserts
    }

    /// Decide whether a poll payload should be hard-rejected.
    /// Preserves the pre-existing tight "100% delete, no inserts" signature —
    /// a tight pattern that never arises from a legitimate user action.
    /// Pure, nonisolated, no effects.
    nonisolated static func shouldRejectAsStale(
        changes: BlockChanges,
        blockCount: Int
    ) -> StaleRejectReason? {
        let deleteCount = changes.deletes.count
        let insertCount = changes.inserts.count
        if blockCount > 2 && deleteCount == blockCount && insertCount == 0 {
            return .allDeletedNoInserts
        }
        return nil
    }

    /// Detect the "balanced massive churn" pattern — the observed signature of the
    /// figure-ID-theft bug: large, balanced insert/delete churn together with
    /// non-trivial updates on a document bigger than the threshold. Pure, nonisolated.
    /// WARNING-only signal — never reject a payload based on this alone. Legitimate
    /// bulk operations (paste-replace, find-and-replace with block-splitting, etc.)
    /// can approach this signature, and rejecting silently discards user work.
    nonisolated static func hasBalancedMassiveChurnSignature(
        changes: BlockChanges,
        blockCount: Int
    ) -> Bool {
        let deleteCount = changes.deletes.count
        let insertCount = changes.inserts.count
        let updateCount = changes.updates.count
        guard blockCount > 10 else { return false }
        guard deleteCount + insertCount > blockCount / 2 && updateCount > 5 else { return false }
        let churn = max(deleteCount, insertCount)
        let balanceDelta = abs(deleteCount - insertCount)
        return churn > 0 && balanceDelta <= churn / 4
    }

    /// True when this poll cycle must abandon its batch because content was wholesale
    /// replaced since the cycle began. Applies in force mode too: `force` bypasses the
    /// contentState *precondition*, NOT mid-flight invalidation — a snapshot taken before
    /// a replaceBlocks() is stale no matter who asked for it.
    ///
    /// `currentGeneration == nil` is ambiguous on its own — it can mean either "no
    /// `editorState` was ever wired" (some test harnesses, or timing before
    /// `onWebViewReady`) or "`editorState` WAS wired when this poll started but has since
    /// been deallocated mid-poll" (e.g. a project switch tearing down the view). Those two
    /// cases must be treated oppositely: the first is not staleness, so we proceed; the
    /// second is itself evidence of a wholesale teardown — a live `editorState` going away
    /// mid-flight is exactly the kind of change this guard exists to catch — so we abandon
    /// rather than silently write a stale batch against `database`/`projectId` locals that
    /// were captured before the switch. `wasWiredAtPollStart` disambiguates the two: it's
    /// whether `editorState` was non-nil at the moment `generationAtPollStart` was captured.
    nonisolated static func shouldAbandonForGenerationChange(
        currentGeneration: Int?,
        generationAtPollStart: Int,
        wasWiredAtPollStart: Bool
    ) -> Bool {
        guard let currentGeneration else {
            // Nil now: abandon only if editorState was actually torn down mid-poll
            // (wired at capture, gone now) — not if it was simply never wired at all.
            return wasWiredAtPollStart
        }
        return currentGeneration != generationAtPollStart
    }

    // MARK: - Public API

    /// Configure the service for a specific project
    func configure(database: ProjectDatabase, projectId: String, webView: WKWebView) {
        self.projectDatabase = database
        self.projectId = projectId
        self.webView = webView
        self.confirmedTempIds.removeAll()
    }

    /// Reconfigure database references for project switch (WebView stays the same)
    func reconfigure(database: ProjectDatabase, projectId: String) {
        self.projectDatabase = database
        self.projectId = projectId
        self.confirmedTempIds.removeAll()
    }

    /// Start polling for block changes
    func startPolling() {
        stopPolling()

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.pollBlockChanges()
            }
        }
    }

    /// Stop polling for block changes
    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Cancel any pending sync operations
    func cancelPendingSync() {
        pendingConfirmations.removeAll()
        confirmedTempIds.removeAll()
    }

    /// Force an immediate poll of block changes (bypasses the 2s timer).
    /// Call before reading blocks from DB when fresh editor content is needed.
    /// Uses force mode to bypass contentState/generation guards, since callers
    /// explicitly need the flush to succeed regardless of current state.
    /// May block under contention: if a poll cycle is already running, this
    /// waits for it to finish before running a fresh cycle of its own, so the
    /// worst case is bounded by two 5-second watchdog periods rather than
    /// returning immediately with stale (or no) data.
    func pollBlockChangesNow() async {
        await pollBlockChanges(force: true)
    }

    /// Handle to whichever poll cycle is currently running, or nil if none is.
    /// Replaces a boolean `isPolling` reentrancy guard so a forced flush can
    /// *wait out* a concurrently-running cycle instead of silently skipping
    /// itself — see `pollBlockChanges(force:)` for the full reasoning. This was
    /// the root cause of a footnote/Notes data-loss bug: a forced flush arriving
    /// while a periodic poll was mid-flight used to return immediately without
    /// ever reading the caller's just-made edit.
    private var inFlightPoll: Task<Void, Never>?

    #if DEBUG
    /// Test-only hook, awaited at the very top of every poll cycle
    /// (`runPollCycle`). Lets a test hold a cycle deterministically suspended
    /// mid-flight to exercise the reentrancy paths below without racing real
    /// timers or sleeping. No cost in release builds (property doesn't exist).
    var testPollCycleHook: (() async -> Void)?

    /// Test-only counter, incremented every time `shouldAbandonForGenerationChange`
    /// causes a poll cycle to abandon its batch (see `checkGenerationGuard`). Lets
    /// tests assert precisely that THIS guard — not the pre-existing
    /// `contentState == .idle` guard or the stale-snapshot guard — caused a
    /// rejection, without scraping `DebugLog` console output.
    var testGenerationAbandonCount = 0

    /// Test-only hook, awaited immediately after `generationAtPoll` is captured in
    /// `doPollBlockChanges` — i.e. right at the point a wholesale content rewrite
    /// (mode toggle, zoom, bibliography/notes rebuild, project switch) landing here
    /// would make this cycle's snapshot stale. Unlike `testPollCycleHook` (awaited
    /// at the very top of the cycle, before this capture happens), gating here lets
    /// a test hold a cycle deterministically suspended with an already-captured
    /// generation snapshot, so it can simulate the race the mid-flight generation
    /// guard exists to close without a wall-clock sleep. Deliberately placed OUTSIDE
    /// `checkGenerationGuard` itself (not conditional on the guard existing) so a
    /// deletion-check that removes the guard still reaches this hook — the guard's
    /// absence must change the test's OBSERVED OUTCOME, not silently deadlock its
    /// synchronization. No cost in release builds (property doesn't exist).
    var testAfterGenerationCaptureHook: (() async -> Void)?

    /// Test-only entry point to the otherwise-private poll, so tests can drive
    /// forced/periodic cycles directly instead of waiting on the real timer.
    func pollBlockChangesForTest(force: Bool = false) async {
        await pollBlockChanges(force: force)
    }
    #endif

    // MARK: - Polling

    /// Poll the editor for block changes, guarding against reentrancy.
    ///
    /// - Unforced (periodic): cheap skip — if a cycle is already in flight, drop
    ///   this tick; the in-flight cycle will pick up any changes itself.
    /// - Forced: callers need a guarantee that everything up to and including
    ///   their own just-made edit has reached the DB. A merely-completed
    ///   in-flight cycle is not sufficient on its own — its snapshot may predate
    ///   the edit — so a forced call always (1) drains any cycle already in
    ///   flight, then (2) runs and awaits a *fresh* cycle of its own, whose
    ///   snapshot is guaranteed to be taken at or after the call.
    private func pollBlockChanges(force: Bool = false) async {
        if force {
            // Drain loop, not a single `if`/await: after `await inFlight.value`
            // returns, a *different* caller may have installed a new cycle
            // during that very suspension — recheck catches that.
            while let inFlight = inFlightPoll {
                await inFlight.value
            }
        } else {
            guard inFlightPoll == nil else { return }
        }

        // Spawn this cycle and register its handle so a concurrent caller can
        // drain (forced) or skip (unforced) against it.
        //
        // Safety-critical: this task clears `inFlightPoll` itself, from INSIDE
        // its own body, as its last action — never the spawner, after `await
        // task.value` returns out here. If the spawner cleared it from outside,
        // a concurrent drain loop elsewhere could observe this task as complete
        // (`await` on an already-completed `Task`'s `.value` can resume inline,
        // without yielding the MainActor's run loop) and loop back to recheck
        // `inFlightPoll` before the spawner's own post-await statement ever
        // runs. That is a deterministic hang: the drain loop spins forever on a
        // stale non-nil handle. Clearing inside the task body — guaranteed to
        // run before the task's result becomes observable to any awaiter —
        // means the slot is already nil (or has been reassigned to a newer
        // task) by the time anyone can see this task as finished.
        //
        // The clear is unconditional, with no identity check against a
        // captured self-reference: `inFlightPoll = task` immediately follows
        // `Task { ... }` with no `await` between them, and this whole method
        // runs on @MainActor, so no other call can install a different task
        // into the slot between this task's creation and its own eventual
        // completion — only this task's own body is ever "the" in-flight poll
        // for this particular slot occupancy.
        let task = Task { @MainActor [weak self] in
            await self?.runPollCycle(force: force)
            self?.inFlightPoll = nil
        }
        inFlightPoll = task
        await task.value
    }

    /// The poll cycle body: a 5-second watchdog racing the real poll work.
    /// Shared by both the forced and unforced paths in `pollBlockChanges(force:)`
    /// above — unchanged internals, just relocated so both can share it.
    private func runPollCycle(force: Bool) async {
        #if DEBUG
        await testPollCycleHook?()
        #endif
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.doPollBlockChanges(force: force)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw CancellationError()
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            DebugLog.log(.sync, "[BlockSync] Poll timed out or error: \(error)")
        }
    }

    /// Inner poll body — contains the actual polling logic.
    private func doPollBlockChanges(force: Bool = false) async {
        if !force {
            guard editorState?.contentState == .idle else {
                DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] SKIPPED: contentState=\(String(describing: editorState?.contentState))")
                return
            }
        }

        guard isConfigured, let webView, let database = projectDatabase, let projectId else { return }

        await flushPendingJSChanges(webView: webView, force: force)

        let generationAtPoll = editorState?.contentGeneration ?? 0
        // Captured alongside generationAtPoll so the guard can tell "editorState was
        // never wired" (not staleness) apart from "editorState was wired here but has
        // since gone nil" (a teardown mid-poll, which IS staleness) — see
        // `shouldAbandonForGenerationChange`.
        let wasEditorStateWiredAtPoll = editorState != nil

        #if DEBUG
        await testAfterGenerationCaptureHook?()
        #endif

        // Check if there are pending changes
        let hasChanges = await checkForChanges(webView: webView)
        // DIAGNOSTIC (temporary, footnote-export-race investigation): log the raw
        // hasBlockChanges() result even on the early-return path, so a forced flush
        // that races the JS-side detection debounce is visible in the log instead of
        // silently no-op'ing.
        DebugLog.log(.blockPoll, "[DIAG:BlockPoll] hasChanges=\(hasChanges) force=\(force) at \(Date())")
        guard hasChanges else { return }

        DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] changes detected, fetching... (force=\(force))")

        // Applies in force mode too: force bypasses the contentState *precondition*,
        // not mid-flight invalidation. Nothing has been consumed from JS yet at this
        // point, so an abandoned batch simply stays queued and is re-offered on the
        // next poll — this check is provably lossless.
        if checkGenerationGuard(generationAtPoll: generationAtPoll, wasWiredAtPoll: wasEditorStateWiredAtPoll, stage: "preFetch", force: force) {
            return
        }

        // Get the changes
        guard let changes = await getBlockChanges(webView: webView) else { return }
        logFetchedUpdates(changes, force: force)

        // Unlike the preFetch check above, abandoning HERE is NOT lossless: by this point
        // getBlockChanges() (block-sync-plugin.ts's getBlockChanges(), ~line 704-707) has
        // already cleared the JS-side pendingUpdates/pendingInserts/pendingDeletes, so this
        // batch will not be re-offered on a later poll — returning now genuinely discards
        // it. That's still the right call: there is no lossless option inside this window.
        // The alternative — re-queuing the already-fetched batch for a later poll — would
        // mean writing pre-rewrite content against a document that's actively being rebuilt
        // from the DB (mode toggle / zoom / bibliography-notes rebuild / project switch),
        // which corrupts the rebuild instead of just dropping one already-stale batch.
        if checkGenerationGuard(generationAtPoll: generationAtPoll, wasWiredAtPoll: wasEditorStateWiredAtPoll, stage: "postFetch", force: force) {
            return
        }

        // Skip if no actual changes
        guard !changes.updates.isEmpty || !changes.inserts.isEmpty || !changes.deletes.isEmpty else {
            return
        }

        logChangeDigest(changes, force: force)

        if shouldRejectStaleSnapshot(changes, database: database, projectId: projectId) {
            return
        }

        let resolvedChanges = resolvingStaleTempIds(changes)

        await applyAndConfirm(resolvedChanges, database: database, projectId: projectId, webView: webView)
    }

    /// Mid-flight generation re-check, shared by both call sites in `doPollBlockChanges`.
    /// Runs unconditionally — including in force mode — because `force` only bypasses the
    /// contentState *precondition* at the top of the cycle, never mid-flight invalidation:
    /// a snapshot taken before a wholesale content rewrite (mode toggle, zoom, bibliography/
    /// notes rebuild, project switch) is stale no matter who asked for the flush. Returns
    /// true (and logs + counts, DEBUG only) when the caller must abandon this poll's batch.
    ///
    /// Note: this guard is inert for the three force callers in
    /// `ContentView+NotificationHandlers.swift` (bibliography rebuild, notes rebuild,
    /// immediate footnote insertion) with respect to their OWN transition — each sets
    /// `editorState.contentState` to a non-idle value (bumping `contentGeneration`)
    /// *before* spawning the `Task` that calls `pollBlockChangesNow()`, so `generationAtPoll`
    /// is always captured post-bump and those callers never observe a mid-flight change
    /// from the very transition they're running. Not a defect — a *different*, concurrent
    /// rewrite landing during their poll would still be caught — just worth naming so a
    /// future reader doesn't assume those three callers are protected against every stale
    /// scenario by this guard alone.
    private func checkGenerationGuard(generationAtPoll: Int, wasWiredAtPoll: Bool, stage: String, force: Bool) -> Bool {
        guard Self.shouldAbandonForGenerationChange(
            currentGeneration: editorState?.contentGeneration,
            generationAtPollStart: generationAtPoll,
            wasWiredAtPollStart: wasWiredAtPoll
        ) else { return false }
        DebugLog.always(
            "[SYNC-DIAG:BlockPoll] REJECTED: reason=generationChangedMidFlight stage=\(stage) " +
            "generationAtPoll=\(generationAtPoll) wasWired=\(wasWiredAtPoll) current=\(String(describing: editorState?.contentGeneration)) force=\(force)"
        )
        #if DEBUG
        testGenerationAbandonCount += 1
        #endif
        return true
    }

    /// Check if the editor has pending block changes
    private func checkForChanges(webView: WKWebView) async -> Bool {
        let result = try? await webView.evaluateJavaScript("window.FinalFinal.hasBlockChanges()")
        return result as? Bool ?? false
    }

    /// Get block changes from the editor
    private func getBlockChanges(webView: WKWebView) async -> BlockChanges? {
        guard let jsonString = try? await webView.evaluateJavaScript(
            "JSON.stringify(window.FinalFinal.getBlockChanges())"
        ) as? String,
              let data = jsonString.data(using: .utf8) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(BlockChanges.self, from: data)
        } catch {
            DebugLog.log(.sync, "[BlockSyncService] Failed to decode block changes: \(error)")
            return nil
        }
    }

    /// Apply block changes to the database (off main thread).
    ///
    /// Known open window, not closed by the generation guard above: `checkGenerationGuard`'s
    /// postFetch check only proves the generation was still current the INSTANT before this
    /// call. `try await Task.detached { ... }.value` below then stays suspended for the
    /// ENTIRE `applyBlockChangesFromEditor` SQLite write, not just "one scheduling hop" —
    /// and GRDB's write serialization guarantees each write is atomic, but does NOT
    /// guarantee ordering between this write and a concurrent `replaceBlocks` call that a
    /// wholesale content rewrite might issue on MainActor while this await is suspended. A
    /// `replaceBlocks` that starts and finishes entirely within this window could still let
    /// this now-stale write land after it. Closing this fully would require making the
    /// rewrite path (e.g. `handleEditorModeToggle`) wait for any in-flight poll to drain
    /// before its own synchronous flush — deliberately out of scope for this guard.
    ///
    /// A second, related residual case, also not closed here: a forced poll that STARTS
    /// while `contentState` is ALREADY non-idle captures that already-bumped generation as
    /// its own `generationAtPoll` baseline — `contentGeneration` increments only on an
    /// idle→non-idle transition (see `contentState`'s `didSet`), never on the matching
    /// return-to-idle. If the in-flight rewrite this poll started alongside finishes
    /// underneath it before `applyChanges` runs, there's no generation delta left for
    /// either `checkGenerationGuard` call to detect. Neither residual case is a defect in
    /// this fix — the stale-write window is strictly narrower than before, not eliminated
    /// for every interleaving — but a future reader should not conclude force-mode polls
    /// are now fully immune to this class of race.
    private func applyChanges(_ changes: BlockChanges, database: ProjectDatabase, projectId: String) async throws {
        let idMapping = try await Task.detached(priority: .utility) {
            try database.applyBlockChangesFromEditor(changes, for: projectId)
        }.value

        // Back on MainActor — store the mapping for sending back to the editor
        for (tempId, permanentId) in idMapping {
            self.pendingConfirmations[tempId] = permanentId
        }
    }

    /// Send ID confirmations back to the editor
    private func confirmBlockIds(webView: WKWebView, mapping: [String: String]) async {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: mapping),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        let escaped = jsonString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")

        _ = try? await webView.evaluateJavaScript(
            "window.FinalFinal.confirmBlockIds(JSON.parse(`\(escaped)`)); true"
        )
    }

    // MARK: - Initial Parse

    /// Parse markdown content into blocks and store in database
    /// Called when loading a project or switching from section-based to block-based
    func parseAndStoreBlocks(markdown: String, preservingMetadata: [String: SectionMetadata]? = nil) async throws {
        guard let database = projectDatabase, let projectId else {
            throw SyncConfigurationError.notConfigured
        }

        let blocks = BlockParser.parse(
            markdown: markdown,
            projectId: projectId,
            existingSectionMetadata: preservingMetadata
        )

        try database.replaceBlocks(blocks, for: projectId)

        DebugLog.log(.sync, "[BlockSyncService] Parsed and stored \(blocks.count) blocks")
    }

    /// Assemble markdown from blocks in the database
    func assembleMarkdown() throws -> String {
        guard let database = projectDatabase, let projectId else {
            throw SyncConfigurationError.notConfigured
        }

        let blocks = try database.fetchBlocks(projectId: projectId)
        return BlockParser.assembleMarkdown(from: blocks)
    }

    // MARK: - Errors

    enum SyncConfigurationError: Error, LocalizedError {
        case notConfigured

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "BlockSyncService not configured"
            }
        }
    }
}

// MARK: - Editor Push / Heading Updates
//
// Split out of the main class body to keep it under SwiftLint's type_body_length
// limit. `private` is file-scoped in Swift, so `projectDatabase`, `projectId`, and
// `webView` stay `private` on the class and are still readable here — no
// access-level widening.
@MainActor
extension BlockSyncService {
    // MARK: - Push Block IDs to Editor

    /// Push block IDs from DB to JS editor (aligns temp IDs with real UUIDs)
    /// - Parameter range: Optional sort order range to filter blocks (for zoom state).
    ///   When nil, pushes all block IDs.
    func pushBlockIds(for range: (start: Double, end: Double?)? = nil) async {
        guard let database = projectDatabase, let projectId, let webView else { return }

        do {
            let blocks = try database.fetchBlocks(projectId: projectId)
            let filtered: [Block]
            if let range = range {
                if let end = range.end {
                    filtered = blocks.filter { $0.sortOrder >= range.start && !$0.isBibliography && !$0.isNotes && $0.sortOrder < end }
                } else {
                    filtered = blocks.filter { $0.sortOrder >= range.start && !$0.isBibliography && !$0.isNotes }
                }
            } else {
                filtered = blocks
            }
            let pairs = BlockParser.alignmentPairs(filtered.sorted { $0.sortOrder < $1.sortOrder })
            let orderedIds = pairs.map { $0.id }
            let expectedBlocks = pairs.map { $0.meta }

            if let range = range {
                DebugLog.log(.sync, "[BlockSyncService] pushBlockIds filtered: \(orderedIds.count) blocks " +
                    "(range start=\(range.start), end=\(String(describing: range.end)))")
            }

            guard let jsonData = try? JSONSerialization.data(withJSONObject: orderedIds),
                  let jsonString = String(data: jsonData, encoding: .utf8) else { return }

            let escaped = jsonString
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "${", with: "\\${")

            guard let expectedData = try? JSONEncoder().encode(expectedBlocks),
                  let expectedJsonString = String(data: expectedData, encoding: .utf8) else { return }

            let escapedExpected = expectedJsonString
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "${", with: "\\${")

            let zoomMode = range != nil ? "true" : "false"
            _ = try? await webView.evaluateJavaScript(
                "window.FinalFinal.syncBlockIds(JSON.parse(`\(escaped)`), \(zoomMode), JSON.parse(`\(escapedExpected)`)); true"
            )

            DebugLog.log(.sync, "[BlockSyncService] Pushed \(orderedIds.count) block IDs to editor")
        } catch {
            DebugLog.log(.sync, "[BlockSyncService] pushBlockIds failed: \(error)")
        }
    }

    /// Set content AND block IDs atomically (for initial load, zoom, rebuild)
    func setContentWithBlockIds(
        markdown: String,
        blockIds: [String],
        scrollToStart: Bool = false,
        imageMeta: [ContentView.ImageBlockMeta] = [],
        cursorBoundary: Int? = nil,
        /// Node index one PAST the last bibliography block — companion end bound for
        /// `cursorBoundary` so the JS-side clamp only fires for a cursor actually INSIDE the
        /// bibliography section, not merely at-or-after its start. See
        /// `BlockParser.lastBibliographyNodeIndex`'s doc comment.
        cursorBoundaryEnd: Int? = nil,
        detectPausedEdits: Bool = false,
        expectedBlocks: [BlockParser.BlockAlignmentMeta] = [],
        zoomMode: Bool = false
    ) async {
        guard let webView else { return }

        DebugLog.log(.sync, {
            let firstHeading = markdown.components(separatedBy: "\n")
                .first(where: { $0.hasPrefix("#") })?.prefix(60) ?? "(none)"
            return "[SYNC-DIAG:BlockSync] setContentWithBlockIds: len=\(markdown.count) "
                + "blocks=\(blockIds.count) firstH=\"\(firstHeading)\" "
                + "scrollToStart=\(scrollToStart) cursorBoundary=\(String(describing: cursorBoundary))"
        }())

        // Escape markdown for JS template literal
        let escapedMarkdown = markdown
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")

        guard let idsData = try? JSONSerialization.data(withJSONObject: blockIds),
              let idsJson = String(data: idsData, encoding: .utf8) else { return }

        let escapedIds = idsJson
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "${", with: "\\${")

        // Build options object
        var optionParts: [String] = []
        appendFlagOption(&optionParts, scrollToStart, "scrollToStart")
        if !imageMeta.isEmpty {
            let metaArray = imageMeta.map { meta -> [String: Any] in
                var dict: [String: Any] = ["id": meta.id]
                if let width = meta.width { dict["width"] = width }
                if let caption = meta.caption { dict["caption"] = caption }
                if let alt = meta.alt { dict["alt"] = alt }
                return dict
            }
            if let metaData = try? JSONSerialization.data(withJSONObject: metaArray),
               let metaJson = String(data: metaData, encoding: .utf8) {
                let escapedMeta = metaJson
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "`", with: "\\`")
                    .replacingOccurrences(of: "${", with: "\\${")
                optionParts.append("imageMeta: JSON.parse(`\(escapedMeta)`)")
            }
        }
        appendOption(&optionParts, cursorBoundary) { "cursorBoundary: \($0)" }
        appendOption(&optionParts, cursorBoundaryEnd) { "cursorBoundaryEnd: \($0)" }
        appendFlagOption(&optionParts, detectPausedEdits, "detectPausedEdits")
        if !expectedBlocks.isEmpty {
            if let expectedData = try? JSONEncoder().encode(expectedBlocks),
               let expectedJson = String(data: expectedData, encoding: .utf8) {
                let escapedExpected = expectedJson
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "`", with: "\\`")
                    .replacingOccurrences(of: "${", with: "\\${")
                optionParts.append("expected: JSON.parse(`\(escapedExpected)`)")
            }
        }
        appendFlagOption(&optionParts, zoomMode, "zoomMode")
        let options = optionParts.isEmpty ? "" : ", {\(optionParts.joined(separator: ", "))}"
        let js = "window.FinalFinal.setContentWithBlockIds(`\(escapedMarkdown)`, JSON.parse(`\(escapedIds)`)\(options))"

        _ = try? await webView.evaluateJavaScript("\(js); true")

        // Notify coordinator so it updates lastPushedContent (prevents redundant updateNSView push)
        NotificationCenter.default.post(
            name: .blockSyncDidPushContent,
            object: nil,
            userInfo: ["markdown": markdown]
        )

        DebugLog.log(.sync, "[BlockSyncService] Set content with \(blockIds.count) block IDs atomically")
    }

    /// Appends a JS option-string entry (`"key: value"`) to `optionParts` iff `value` is
    /// non-nil, formatting it with `format`. Factored out of `setContentWithBlockIds`'s long
    /// chain of "if let X { optionParts.append(...) }" blocks to keep that function's branch
    /// count down — pure, no side effects beyond mutating the passed-in array.
    private func appendOption<T>(_ optionParts: inout [String], _ value: T?, format: (T) -> String) {
        if let value {
            optionParts.append(format(value))
        }
    }

    /// Appends a JS option-string boolean flag (`"key: true"`) to `optionParts` iff `flag`
    /// is true. Companion to `appendOption(_:_:format:)` for the simple boolean-flag cases.
    private func appendFlagOption(_ optionParts: inout [String], _ flag: Bool, _ key: String) {
        if flag {
            optionParts.append("\(key): true")
        }
    }

    /// Surgically update heading levels in the editor without replacing the document.
    /// Returns the updated content string (via getContent()) or nil on failure.
    func updateHeadingLevels(_ changes: [(blockId: String, newLevel: Int)]) async -> String? {
        guard let webView else { return nil }

        let changesArray = changes.map { ["blockId": $0.blockId, "newLevel": $0.newLevel] as [String: Any] }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: changesArray),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return nil }

        // Single JS call: update headings then get canonical content
        let script = """
            (() => {
                window.FinalFinal.updateHeadingLevels(\(jsonString));
                return window.FinalFinal.getContent();
            })()
        """

        let result = try? await webView.evaluateJavaScript(script)
        guard let markdown = result as? String else { return nil }

        // Sync lastPushedContent to prevent updateNSView from firing plain setContent()
        NotificationCenter.default.post(
            name: .blockSyncDidPushContent,
            object: nil,
            userInfo: ["markdown": markdown]
        )

        return markdown
    }

    // MARK: - Poll Helpers

    /// Forced flush: the JS side (block-sync-plugin.ts) runs its own 100ms
    /// debounce independent of this Swift-side force flag, so a forced poll
    /// arriving in the gap before that timer fires would otherwise read a
    /// stale, unconverted pending-changes entry (e.g. a footnote trigger's
    /// raw text, not yet replaced by the confirming transaction). Flush that
    /// JS-side timer synchronously before checking/reading changes.
    private func flushPendingJSChanges(webView: WKWebView, force: Bool) async {
        if force {
            do {
                _ = try await webView.evaluateJavaScript(
                    "window.FinalFinal.flushPendingBlockChanges(); true"
                )
            } catch {
                DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] flushPendingBlockChanges failed: \(error) — forced flush may read stale data")
            }
        }
    }

    /// DIAGNOSTIC (temporary, footnote-export-race investigation): dump the ACTUAL
    /// textContent of every update JS handed back, not just id+length -- to see
    /// directly whether getBlockChanges() returned a stale (pre-conversion) or
    /// fresh (post-conversion) snapshot of the edited block.
    private func logFetchedUpdates(_ changes: BlockChanges, force: Bool) {
        for update in changes.updates {
            DebugLog.log(.blockPoll, {
                "[DIAG:BlockPoll] update id=\(update.id.prefix(8)) force=\(force) "
                    + "text=\"\(update.textContent ?? "<nil>")\" md=\"\(update.markdownFragment ?? "<nil>")\""
            }())
        }
    }

    /// Change-digest logging for a non-empty batch: processing counts, delete IDs,
    /// and the Phase 0 update digest.
    private func logChangeDigest(_ changes: BlockChanges, force: Bool) {
        DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] Processing: u=\(changes.updates.count) i=\(changes.inserts.count) d=\(changes.deletes.count) force=\(force)")
        if !changes.deletes.isEmpty {
            DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] Deleting IDs: \(changes.deletes.prefix(5))")
        }
        // [SYNC-DIAG Phase 0] Dump first 10 updates as (idPrefix, textContentLength) tuples
        // to correlate suspicious empty-textContent UPDATEs with DB row state.
        if !changes.updates.isEmpty {
            let digest = changes.updates.prefix(10).map { ($0.id.prefix(8), $0.textContent?.count ?? -1) }
            DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] Phase0 updateDigest=\(digest) u=\(changes.updates.count) i=\(changes.inserts.count) d=\(changes.deletes.count)")
        } else if !changes.deletes.isEmpty || !changes.inserts.isEmpty {
            DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] Phase0 u=0 i=\(changes.inserts.count) d=\(changes.deletes.count) delIds=\(changes.deletes.prefix(5))")
        }
    }

    /// Stale-snapshot guard + telemetry. Hard-reject only the pre-existing
    /// 100%-delete-no-inserts pattern. Warning logs for mass delete or the
    /// balanced-churn type-theft signature — never reject on those.
    private func shouldRejectStaleSnapshot(_ changes: BlockChanges, database: ProjectDatabase, projectId: String) -> Bool {
        if !changes.deletes.isEmpty || !changes.inserts.isEmpty {
            do {
                let blockCount = try database.fetchBlockCount(projectId: projectId)
                if let reason = Self.shouldRejectAsStale(changes: changes, blockCount: blockCount) {
                    DebugLog.always(
                        "[SYNC-DIAG:BlockPoll] REJECTED: reason=\(reason) " +
                        "d=\(changes.deletes.count) i=\(changes.inserts.count) blockCount=\(blockCount)"
                    )
                    return true
                }
                if changes.deletes.count > blockCount / 2 && blockCount > 2 {
                    DebugLog.always(
                        "[SYNC-DIAG:BlockPoll] WARNING: Mass delete detected " +
                        "(\(changes.deletes.count)/\(blockCount) blocks). May indicate stale snapshot."
                    )
                }
                if Self.hasBalancedMassiveChurnSignature(changes: changes, blockCount: blockCount) {
                    DebugLog.always(
                        "[SYNC-DIAG:BlockPoll] WARNING: Balanced massive churn signature " +
                        "(d=\(changes.deletes.count) i=\(changes.inserts.count) u=\(changes.updates.count) " +
                        "blockCount=\(blockCount)). If this fires frequently, a regression of the " +
                        "block-id-plugin type-theft bug is likely."
                    )
                }
            } catch {
                DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] fetchBlockCount failed: \(error)")
            }
        }
        return false
    }

    /// Resolve stale temp IDs using cumulative confirmation mapping (defense-in-depth)
    private func resolvingStaleTempIds(_ changes: BlockChanges) -> BlockChanges {
        var resolvedChanges = changes
        resolvedChanges.updates = changes.updates.map { update in
            if update.id.hasPrefix("temp-"), let permanentId = confirmedTempIds[update.id] {
                DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] Resolved stale temp ID: \(update.id.prefix(13)) → \(permanentId.prefix(8))")
                return BlockUpdate(id: permanentId, textContent: update.textContent,
                                   markdownFragment: update.markdownFragment, headingLevel: update.headingLevel)
            }
            return update
        }
        resolvedChanges.inserts = changes.inserts.map { insert in
            if let afterId = insert.afterBlockId, afterId.hasPrefix("temp-"),
               let permanentId = confirmedTempIds[afterId] {
                return BlockInsert(tempId: insert.tempId, blockType: insert.blockType,
                                   textContent: insert.textContent, markdownFragment: insert.markdownFragment,
                                   headingLevel: insert.headingLevel, afterBlockId: permanentId,
                                   atDocumentStart: insert.atDocumentStart)
            }
            return insert
        }
        return resolvedChanges
    }

    /// Apply changes to database: writes the resolved changes, merges the resulting
    /// pending confirmations into the cumulative `confirmedTempIds` tracker, and — if
    /// any inserts produced temp→permanent ID mappings — pushes those ID confirmations
    /// back to the editor via `confirmBlockIds`.
    private func applyAndConfirm(_ resolvedChanges: BlockChanges, database: ProjectDatabase, projectId: String, webView: WKWebView) async {
        do {
            try await applyChanges(resolvedChanges, database: database, projectId: projectId)

            // Merge new mappings into cumulative tracker
            for (tempId, permanentId) in pendingConfirmations {
                confirmedTempIds[tempId] = permanentId
            }

            DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] Applied changes to DB successfully")

            // Send ID confirmations back to editor if there were inserts
            if !pendingConfirmations.isEmpty {
                DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] Confirming \(pendingConfirmations.count) IDs")
                await confirmBlockIds(webView: webView, mapping: pendingConfirmations)
                pendingConfirmations.removeAll()
            }
        } catch {
            DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] Error applying changes: \(error)")
        }
    }
}
