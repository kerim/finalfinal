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
    var activeWebView: WKWebView? { webView }

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
    func pollBlockChangesNow() async {
        await pollBlockChanges(force: true)
    }

    /// Reentrancy guard for polling
    private var isPolling = false

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

    /// Poll the editor for block changes with a 5-second timeout to prevent permanent hangs.
    private func pollBlockChanges(force: Bool = false) async {
        guard !isPolling else {
            if force { DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] BLOCKED: force poll skipped (already polling)") }
            return
        }
        isPolling = true
        defer { isPolling = false }

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

        let generationAtPoll = editorState?.contentGeneration ?? 0

        // Check if there are pending changes
        let hasChanges = await checkForChanges(webView: webView)
        guard hasChanges else { return }

        DebugLog.log(.blockPoll, "[SYNC-DIAG:BlockPoll] changes detected, fetching... (force=\(force))")

        // In force mode, skip generation check — caller explicitly needs flush
        if !force {
            guard editorState?.contentGeneration == generationAtPoll else { return }
        }

        // Get the changes
        guard let changes = await getBlockChanges(webView: webView) else { return }

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

        // Safety logging: warn on mass deletes that may indicate a stale snapshot bug
        if !changes.deletes.isEmpty {
            do {
                let blockCount = try database.fetchBlockCount(projectId: projectId)
                let deleteCount = changes.deletes.count
                if blockCount > 2 && deleteCount > blockCount / 2 {
                    DebugLog.always("[SYNC-DIAG:BlockPoll] WARNING: Mass delete detected " +
                        "(\(deleteCount)/\(blockCount) blocks). May indicate stale snapshot.")
                }
                // Safety net: reject change sets that would delete ALL blocks with no inserts.
                if blockCount > 2 && deleteCount == blockCount && changes.inserts.isEmpty {
                    DebugLog.always("[SYNC-DIAG:BlockPoll] REJECTED: Mass delete of ALL \(blockCount) blocks " +
                        "with no inserts (updates=\(changes.updates.count)). Stale snapshot likely.")
                    return
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
