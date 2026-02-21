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
    private let pollInterval: TimeInterval = 0.3  // 300ms polling

    private var projectDatabase: ProjectDatabase?
    private var projectId: String?
    private weak var webView: WKWebView?

    /// Whether the service is properly configured
    var isConfigured: Bool {
        projectDatabase != nil && projectId != nil && webView != nil
    }

    /// When true, suppresses sync operations (during drag operations, etc.)
    var isSyncSuppressed: Bool = false

    /// Pending ID confirmations (temp ID -> permanent ID) to send back to editor
    private var pendingConfirmations: [String: String] = [:]

    // MARK: - Public API

    /// Configure the service for a specific project
    func configure(database: ProjectDatabase, projectId: String, webView: WKWebView) {
        self.projectDatabase = database
        self.projectId = projectId
        self.webView = webView
    }

    /// Reconfigure database references for project switch (WebView stays the same)
    func reconfigure(database: ProjectDatabase, projectId: String) {
        self.projectDatabase = database
        self.projectId = projectId
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
    }

    /// Reentrancy guard for polling
    private var isPolling = false

    // MARK: - Push Block IDs to Editor

    /// Push block IDs from DB to JS editor (aligns temp IDs with real UUIDs)
    /// - Parameter range: Optional sort order range to filter blocks (for zoom state).
    ///   When nil, pushes all block IDs.
    func pushBlockIds(for range: (start: Double, end: Double?)? = nil) async {
        guard let database = projectDatabase, let projectId, let webView else { return }

        // Suppress polling during push to prevent race conditions
        isSyncSuppressed = true
        defer { isSyncSuppressed = false }

        do {
            let blocks = try database.fetchBlocks(projectId: projectId)
            let filtered: [Block]
            if let range = range {
                if let end = range.end {
                    filtered = blocks.filter { $0.sortOrder >= range.start && !$0.isBibliography && $0.sortOrder < end }
                } else {
                    filtered = blocks.filter { $0.sortOrder >= range.start && !$0.isBibliography }
                }
            } else {
                filtered = blocks
            }
            let orderedIds = filtered.sorted { $0.sortOrder < $1.sortOrder }.map { $0.id }

            #if DEBUG
            if let range = range {
                print("[BlockSyncService] pushBlockIds filtered: \(orderedIds.count) blocks " +
                    "(range start=\(range.start), end=\(String(describing: range.end)))")
            }
            #endif

            guard let jsonData = try? JSONSerialization.data(withJSONObject: orderedIds),
                  let jsonString = String(data: jsonData, encoding: .utf8) else { return }

            let escaped = jsonString
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "${", with: "\\${")

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                webView.evaluateJavaScript("window.FinalFinal.syncBlockIds(JSON.parse(`\(escaped)`))") { _, _ in
                    continuation.resume()
                }
            }

            #if DEBUG
            print("[BlockSyncService] Pushed \(orderedIds.count) block IDs to editor")
            #endif
        } catch {
            #if DEBUG
            print("[BlockSyncService] pushBlockIds failed: \(error)")
            #endif
        }
    }

    /// Set content AND block IDs atomically (for initial load, zoom, rebuild)
    func setContentWithBlockIds(markdown: String, blockIds: [String], scrollToStart: Bool = false) async {
        guard let webView else { return }

        // Suppress polling during atomic set
        isSyncSuppressed = true
        defer { isSyncSuppressed = false }

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

        let options = scrollToStart ? ", {scrollToStart: true}" : ""
        let js = "window.FinalFinal.setContentWithBlockIds(`\(escapedMarkdown)`, JSON.parse(`\(escapedIds)`)\(options))"

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            webView.evaluateJavaScript(js) { _, _ in
                continuation.resume()
            }
        }

        // Notify coordinator so it updates lastPushedContent (prevents redundant updateNSView push)
        NotificationCenter.default.post(
            name: .blockSyncDidPushContent,
            object: nil,
            userInfo: ["markdown": markdown]
        )

        #if DEBUG
        print("[BlockSyncService] Set content with \(blockIds.count) block IDs atomically")
        #endif
    }

    // MARK: - Polling

    /// Poll the editor for block changes and apply them to the database
    private func pollBlockChanges() async {
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }

        guard !isSyncSuppressed, isConfigured, let webView, let database = projectDatabase, let projectId else {
            return
        }

        // Check if there are pending changes
        let hasChanges = await checkForChanges(webView: webView)
        guard hasChanges else { return }

        // Get the changes
        guard let changes = await getBlockChanges(webView: webView) else { return }

        // Skip if no actual changes
        guard !changes.updates.isEmpty || !changes.inserts.isEmpty || !changes.deletes.isEmpty else {
            return
        }

        #if DEBUG
        print("[BlockSyncService] Processing changes: \(changes.updates.count) updates, " +
            "\(changes.inserts.count) inserts, \(changes.deletes.count) deletes")
        #endif

        // Apply changes to database
        do {
            try await applyChanges(changes, database: database, projectId: projectId)

            // Send ID confirmations back to editor if there were inserts
            if !pendingConfirmations.isEmpty {
                await confirmBlockIds(webView: webView, mapping: pendingConfirmations)
                pendingConfirmations.removeAll()
            }
        } catch {
            #if DEBUG
            print("[BlockSyncService] Error applying changes: \(error)")
            #endif
        }
    }

    /// Check if the editor has pending block changes
    private func checkForChanges(webView: WKWebView) async -> Bool {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("window.FinalFinal.hasBlockChanges()") { result, _ in
                if let hasChanges = result as? Bool {
                    continuation.resume(returning: hasChanges)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Get block changes from the editor
    private func getBlockChanges(webView: WKWebView) async -> BlockChanges? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("JSON.stringify(window.FinalFinal.getBlockChanges())") { result, error in
                guard let jsonString = result as? String,
                      let data = jsonString.data(using: .utf8) else {
                    continuation.resume(returning: nil)
                    return
                }

                do {
                    let changes = try JSONDecoder().decode(BlockChanges.self, from: data)
                    continuation.resume(returning: changes)
                } catch {
                    #if DEBUG
                    print("[BlockSyncService] Failed to decode block changes: \(error)")
                    #endif
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Apply block changes to the database
    private func applyChanges(_ changes: BlockChanges, database: ProjectDatabase, projectId: String) async throws {
        // Apply changes and get the actual ID mapping from the database method
        let idMapping = try database.applyBlockChangesFromEditor(changes, for: projectId)

        // Store the mapping for sending back to the editor
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

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            webView.evaluateJavaScript("window.FinalFinal.confirmBlockIds(JSON.parse(`\(escaped)`))") { _, _ in
                continuation.resume()
            }
        }
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

        #if DEBUG
        print("[BlockSyncService] Parsed and stored \(blocks.count) blocks")
        #endif
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
