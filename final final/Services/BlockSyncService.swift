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
    private let pollInterval: TimeInterval = 2.0  // 2s polling (block changes accumulate in JS)

    private var projectDatabase: ProjectDatabase?
    private var projectId: String?
    private weak var webView: WKWebView?
    /// Fetch content from the active WebView with a timeout.
    /// Returns nil if WebView is unavailable, JS call fails, or timeout elapses.
    func fetchContentFromWebView(timeout: Duration = .seconds(2)) async -> String? {
        guard let webView else { return nil }
        do {
            return try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
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
        let d = changes.deletes.count
        let i = changes.inserts.count
        if blockCount > 2 && d == blockCount && i == 0 {
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
        let d = changes.deletes.count
        let i = changes.inserts.count
        let u = changes.updates.count
        guard blockCount > 10 else { return false }
        guard d + i > blockCount / 2 && u > 5 else { return false }
        let churn = max(d, i)
        let balanceDelta = abs(d - i)
        return churn > 0 && balanceDelta <= churn / 4
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

    /// Test-only entry point to the otherwise-private poll, so tests can drive
    /// forced/periodic cycles directly instead of waiting on the real timer.
    func pollBlockChangesForTest(force: Bool = false) async {
        await pollBlockChanges(force: force)
    }
    #endif

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
            let orderedIds = BlockParser.idsForProseMirrorAlignment(filtered.sorted { $0.sortOrder < $1.sortOrder })

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

            let zoomMode = range != nil ? "true" : "false"
            _ = try? await webView.evaluateJavaScript(
                "window.FinalFinal.syncBlockIds(JSON.parse(`\(escaped)`), \(zoomMode)); true"
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
        cursorBoundary: Int? = nil
    ) async {
        guard let webView else { return }

        DebugLog.log(.sync, "[SYNC-DIAG:BlockSync] setContentWithBlockIds: len=\(markdown.count) blocks=\(blockIds.count) firstH=\"\(markdown.components(separatedBy: "\n").first(where: { $0.hasPrefix("#") })?.prefix(60) ?? "(none)")\" scrollToStart=\(scrollToStart) cursorBoundary=\(String(describing: cursorBoundary))")

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
        if scrollToStart {
            optionParts.append("scrollToStart: true")
        }
        if !imageMeta.isEmpty {
            let metaArray = imageMeta.map { meta -> [String: Any] in
                var dict: [String: Any] = ["id": meta.id]
                if let w = meta.width { dict["width"] = w }
                if let c = meta.caption { dict["caption"] = c }
                if let a = meta.alt { dict["alt"] = a }
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
        if let boundary = cursorBoundary {
            optionParts.append("cursorBoundary: \(boundary)")
        }
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

        // Forced flush: the JS side (block-sync-plugin.ts) runs its own 100ms
        // debounce independent of this Swift-side force flag, so a forced poll
        // arriving in the gap before that timer fires would otherwise read a
        // stale, unconverted pending-changes entry (e.g. a footnote trigger's
        // raw text, not yet replaced by the confirming transaction). Flush that
        // JS-side timer synchronously before checking/reading changes.
        if force {
            do {
                _ = try await webView.evaluateJavaScript(
                    "window.FinalFinal.flushPendingBlockChanges(); true"
                )
            } catch {
                DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] flushPendingBlockChanges failed: \(error) — forced flush may read stale data")
            }
        }

        let generationAtPoll = editorState?.contentGeneration ?? 0

        // Check if there are pending changes
        let hasChanges = await checkForChanges(webView: webView)
        // DIAGNOSTIC (temporary, footnote-export-race investigation): log the raw
        // hasBlockChanges() result even on the early-return path, so a forced flush
        // that races the JS-side detection debounce is visible in the log instead of
        // silently no-op'ing.
        DebugLog.log(.blockPoll, "[DIAG:BlockPoll] hasChanges=\(hasChanges) force=\(force) at \(Date())")
        guard hasChanges else { return }

        DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] changes detected, fetching... (force=\(force))")

        // In force mode, skip generation check — caller explicitly needs flush
        if !force {
            guard editorState?.contentGeneration == generationAtPoll else { return }
        }

        // Get the changes
        guard let changes = await getBlockChanges(webView: webView) else { return }
        // DIAGNOSTIC (temporary, footnote-export-race investigation): dump the ACTUAL
        // textContent of every update JS handed back, not just id+length -- to see
        // directly whether getBlockChanges() returned a stale (pre-conversion) or
        // fresh (post-conversion) snapshot of the edited block.
        for u in changes.updates {
            DebugLog.log(.blockPoll, "[DIAG:BlockPoll] update id=\(u.id.prefix(8)) force=\(force) text=\"\(u.textContent ?? "<nil>")\" md=\"\(u.markdownFragment ?? "<nil>")\"")
        }

        // In force mode, skip generation check — caller explicitly needs flush
        if !force {
            guard editorState?.contentGeneration == generationAtPoll else { return }
        }

        // Skip if no actual changes
        guard !changes.updates.isEmpty || !changes.inserts.isEmpty || !changes.deletes.isEmpty else {
            return
        }

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

        // Stale-snapshot guard + telemetry. Hard-reject only the pre-existing
        // 100%-delete-no-inserts pattern. Warning logs for mass delete or the
        // balanced-churn type-theft signature — never reject on those.
        if !changes.deletes.isEmpty || !changes.inserts.isEmpty {
            do {
                let blockCount = try database.fetchBlockCount(projectId: projectId)
                if let reason = Self.shouldRejectAsStale(changes: changes, blockCount: blockCount) {
                    DebugLog.always(
                        "[SYNC-DIAG:BlockPoll] REJECTED: reason=\(reason) " +
                        "d=\(changes.deletes.count) i=\(changes.inserts.count) blockCount=\(blockCount)"
                    )
                    return
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

        // Resolve stale temp IDs using cumulative confirmation mapping (defense-in-depth)
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
                                   headingLevel: insert.headingLevel, afterBlockId: permanentId)
            }
            return insert
        }

        // Apply changes to database
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

    /// Apply block changes to the database (off main thread)
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
