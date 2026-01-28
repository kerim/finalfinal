//
//  SectionSyncService.swift
//  final final
//

import Foundation

/// Service to sync editor content with sections database
/// Uses position-based reconciliation with surgical database updates
@MainActor
@Observable
class SectionSyncService {
    private var debounceTask: Task<Void, Never>?
    private let debounceInterval: Duration = .milliseconds(500)
    private let reconciler = SectionReconciler()

    private var projectDatabase: ProjectDatabase?
    private var projectId: String?

    /// When true, suppresses sync operations
    /// Set during drag operations to prevent race conditions
    var isSyncSuppressed: Bool = false

    /// When true, content is a zoomed subset - skip full document save to database
    var isContentZoomed: Bool = false

    /// Content we last synced - prevents feedback loop from ValueObservation
    private var lastSyncedContent: String = ""

    // MARK: - Public API

    /// Configure the service for a specific project
    func configure(database: ProjectDatabase, projectId: String) {
        self.projectDatabase = database
        self.projectId = projectId
    }

    /// Cancel any pending debounced sync operation
    /// Call this before starting drag operations to prevent race conditions
    func cancelPendingSync() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// Rebuild document markdown from sections in their current order
    /// Used after drag-drop reordering to sync sections back to document
    /// NOTE: Caller must pass sections in correct order - no sorting is performed
    func rebuildDocument(from sections: [Section]) -> String {
        sections
            .map { $0.markdownContent }
            .joined()  // Content already includes trailing newlines
    }

    /// Update header level in markdown content
    /// Used when section level changes during drag-drop
    func updateHeaderLevel(in markdown: String, to newLevel: Int) -> String {
        guard newLevel > 0 else { return markdown }  // Pseudo-sections don't have headers

        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard let firstLine = lines.first else { return markdown }

        let lineStr = String(firstLine)
        // Check if first line is a header
        guard lineStr.trimmingCharacters(in: .whitespaces).hasPrefix("#") else {
            return markdown
        }

        // Replace the header prefix
        let newPrefix = String(repeating: "#", count: newLevel)
        var idx = lineStr.startIndex
        while idx < lineStr.endIndex && lineStr[idx] == "#" {
            idx = lineStr.index(after: idx)
        }
        // Skip space after #
        if idx < lineStr.endIndex && lineStr[idx] == " " {
            idx = lineStr.index(after: idx)
        }

        let title = String(lineStr[idx...])
        let newFirstLine = "\(newPrefix) \(title)"

        var result = [newFirstLine]
        if lines.count > 1 {
            result.append(contentsOf: lines.dropFirst().map { String($0) })
        }
        return result.joined(separator: "\n")
    }

    /// Called when editor content changes
    /// Debounces and triggers sync after delay
    /// - Parameters:
    ///   - markdown: The markdown content to sync
    ///   - zoomedIds: Optional set of zoomed section IDs (pass when zoomed to avoid replacing full array)
    func contentChanged(_ markdown: String, zoomedIds: Set<String>? = nil) {
        // Skip if suppressed (during drag operations)
        guard !isSyncSuppressed else { return }

        // Idempotent check: skip if this is content we just synced
        guard markdown != lastSyncedContent else { return }

        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }
            await syncContent(markdown, zoomedIds: zoomedIds)
        }
    }

    /// Reset sync tracking (call when manually setting content)
    func resetSyncTracking() {
        lastSyncedContent = ""
    }

    /// Force immediate sync (e.g., before app quit)
    func syncNow(_ markdown: String) async {
        debounceTask?.cancel()
        await syncContent(markdown)
    }

    /// Load sections from database as view models
    func loadSections() async -> [SectionViewModel] {
        guard let db = projectDatabase, let pid = projectId else { return [] }

        do {
            let sections = try db.fetchSections(projectId: pid)
            return sections.map { SectionViewModel(from: $0) }
        } catch {
            print("[SectionSyncService] Error loading sections: \(error.localizedDescription)")
            return []
        }
    }

    /// Parse markdown and return sections without saving to database
    /// Used for initial sync when database has no sections yet
    func parseAndGetSections(from markdown: String) -> [SectionViewModel] {
        guard let pid = projectId else { return [] }
        let headers = parseHeaders(from: markdown)
        let sections = headers.map { header in
            Section(
                projectId: pid,
                sortOrder: header.position,
                headerLevel: header.level,
                title: header.title,
                markdownContent: header.markdownContent,
                wordCount: header.wordCount,
                startOffset: header.startOffset
            )
        }
        return sections.map { SectionViewModel(from: $0) }
    }

    // MARK: - Private Methods

    /// Core sync method using position-based reconciliation
    private func syncContent(_ markdown: String, zoomedIds: Set<String>? = nil) async {
        guard let db = projectDatabase, let pid = projectId else {
            print("[SectionSyncService] syncContent skipped - database not configured")
            return
        }

        // When zoomed, update zoomed sections in-place
        if let zoomedIds = zoomedIds, isContentZoomed {
            await syncZoomedSections(from: markdown, zoomedIds: zoomedIds)
            return
        }

        // 1. Parse headers from markdown
        let headers = parseHeaders(from: markdown)
        guard !headers.isEmpty else { return }

        // 2. Get current DB sections
        let dbSections: [Section]
        do {
            dbSections = try db.fetchSections(projectId: pid)
        } catch {
            print("[SectionSyncService] Error fetching sections: \(error.localizedDescription)")
            return
        }

        // 3. Reconcile to find minimal changes
        let changes = reconciler.reconcile(headers: headers, dbSections: dbSections, projectId: pid)

        // 4. Apply changes to database (if any)
        if !changes.isEmpty {
            do {
                try db.applySectionChanges(changes, for: pid)
            } catch {
                print("[SectionSyncService] Error applying changes: \(error.localizedDescription)")
            }
        }

        // 5. Save full content to database ONLY when not zoomed
        if !isContentZoomed {
            do {
                try db.saveContent(markdown: markdown, for: pid)
            } catch {
                print("[SectionSyncService] Error saving content: \(error.localizedDescription)")
            }
        }

        // Track synced content to prevent feedback loops
        lastSyncedContent = markdown

        // Note: UI updates happen automatically via ValueObservation in EditorViewState
    }

    /// Sync zoomed content without replacing the full sections array
    /// Updates zoomed sections in-place and saves only those to database
    private func syncZoomedSections(from markdown: String, zoomedIds: Set<String>) async {
        guard let db = projectDatabase, let pid = projectId else { return }

        // Parse zoomed markdown to extract section content
        let headers = parseHeaders(from: markdown)

        // Fetch existing sections from database
        let existingSections: [Section]
        do {
            existingSections = try db.fetchSections(projectId: pid)
        } catch {
            print("[SectionSyncService] Error fetching sections: \(error)")
            return
        }

        // Build lookup of zoomed sections by sortOrder within zoomed subset
        let zoomedExisting = existingSections
            .filter { zoomedIds.contains($0.id) }
            .sorted { $0.sortOrder < $1.sortOrder }

        // Match parsed headers to existing zoomed sections by position and update
        var changes: [SectionChange] = []
        for (index, header) in headers.enumerated() {
            guard index < zoomedExisting.count else { break }

            let existing = zoomedExisting[index]
            var updates = SectionUpdates()
            var hasChanges = false

            if header.markdownContent != existing.markdownContent {
                updates.markdownContent = header.markdownContent
                updates.wordCount = header.wordCount
                hasChanges = true
            }
            if header.startOffset != existing.startOffset {
                updates.startOffset = header.startOffset
                hasChanges = true
            }

            if hasChanges {
                changes.append(.update(id: existing.id, updates: updates))
            }
        }

        if !changes.isEmpty {
            do {
                try db.applySectionChanges(changes, for: pid)
            } catch {
                print("[SectionSyncService] Error updating zoomed sections: \(error)")
            }
        }
    }

    /// Parse markdown content into ParsedHeader structs for reconciliation
    private func parseHeaders(from markdown: String) -> [ParsedHeader] {

        var headers: [ParsedHeader] = []
        var currentOffset = 0
        var inCodeBlock = false

        // Track section boundaries
        struct SectionBoundary {
            let startOffset: Int
            let level: Int
            let title: String
            let isPseudoSection: Bool
        }

        var boundaries: [SectionBoundary] = []
        var lastActualHeaderLevel: Int = 1  // Default to H1 for pseudo-sections at document start

        // First pass: find all headers and pseudo-sections
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let lineStr = String(line)
            let trimmed = lineStr.trimmingCharacters(in: .whitespaces)

            // Track code blocks
            if trimmed.hasPrefix("```") {
                inCodeBlock = !inCodeBlock
            }

            if !inCodeBlock {
                // Check for pseudo-section marker
                if trimmed == "<!-- ::break:: -->" {
                    // Pseudo-sections inherit level from preceding header (not 0!)
                    boundaries.append(SectionBoundary(
                        startOffset: currentOffset,
                        level: lastActualHeaderLevel,
                        title: "§ Section Break",
                        isPseudoSection: true
                    ))
                    // Do NOT update lastActualHeaderLevel - pseudo-sections don't affect it
                }
                // Check for header
                else if let header = parseHeaderLine(trimmed) {
                    lastActualHeaderLevel = header.level  // Track for subsequent pseudo-sections
                    boundaries.append(SectionBoundary(
                        startOffset: currentOffset,
                        level: header.level,
                        title: header.title,
                        isPseudoSection: false
                    ))
                }
            }

            currentOffset += lineStr.count + 1 // +1 for newline
        }

        guard !boundaries.isEmpty else { return [] }

        // Second pass: calculate content for each section
        let contentLength = markdown.count

        for (index, boundary) in boundaries.enumerated() {
            let endOffset: Int
            if index < boundaries.count - 1 {
                endOffset = boundaries[index + 1].startOffset
            } else {
                endOffset = contentLength
            }

            // Extract markdown content for this section
            let startIdx = markdown.index(markdown.startIndex, offsetBy: min(boundary.startOffset, markdown.count))
            let endIdx = markdown.index(markdown.startIndex, offsetBy: min(endOffset, markdown.count))
            let sectionMarkdown = String(markdown[startIdx..<endIdx])

            let wordCount = MarkdownUtils.wordCount(for: sectionMarkdown)

            // For pseudo-sections, extract title from first paragraph after break
            let finalTitle: String
            if boundary.isPseudoSection {
                finalTitle = extractPseudoSectionTitle(from: sectionMarkdown)
            } else {
                finalTitle = boundary.title
            }

            headers.append(ParsedHeader(
                position: index,
                title: finalTitle,
                level: boundary.level,
                isPseudoSection: boundary.isPseudoSection,
                startOffset: boundary.startOffset,
                markdownContent: sectionMarkdown,
                wordCount: wordCount
            ))
        }

        return headers
    }

    private struct LocalParsedHeader {
        let level: Int
        let title: String
    }

    private func parseHeaderLine(_ line: String) -> LocalParsedHeader? {
        guard line.hasPrefix("#") else { return nil }

        var level = 0
        var idx = line.startIndex

        while idx < line.endIndex && line[idx] == "#" && level < 6 {
            level += 1
            idx = line.index(after: idx)
        }

        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }

        let titleStart = line.index(after: idx)
        let title = String(line[titleStart...]).trimmingCharacters(in: .whitespaces)

        guard !title.isEmpty else { return nil }

        return LocalParsedHeader(level: level, title: title)
    }

    /// Extract a title for pseudo-sections from the first paragraph after the break marker
    /// Returns "§ " followed by the first few words (up to ~30 chars), or "§ Section Break" if no content
    private func extractPseudoSectionTitle(from markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)

        // Skip the break marker line and any empty lines to find the first paragraph
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip the break marker itself
            if trimmed == "<!-- ::break:: -->" {
                continue
            }

            // Skip empty lines
            if trimmed.isEmpty {
                continue
            }

            // Skip other markdown constructs that shouldn't be titles
            if trimmed.hasPrefix("#") ||      // Headers
               trimmed.hasPrefix("```") ||    // Code blocks
               trimmed.hasPrefix(">") ||      // Block quotes
               trimmed.hasPrefix("-") ||      // Lists
               trimmed.hasPrefix("*") ||      // Lists
               trimmed.hasPrefix("1.") ||     // Numbered lists
               trimmed.hasPrefix("|") {       // Tables
                continue
            }

            // Found paragraph text - extract first ~30 characters at word boundary
            let excerpt = extractExcerpt(from: trimmed, maxLength: 30)
            if !excerpt.isEmpty {
                return "§ \(excerpt)"
            }
        }

        // Fallback if no paragraph content found
        return "§ Section Break"
    }

    /// Extract an excerpt from text, truncating at word boundary with ellipsis
    private func extractExcerpt(from text: String, maxLength: Int) -> String {
        // Strip any markdown formatting (bold, italic, links)
        let plainText = text
            .replacingOccurrences(of: "\\*\\*([^*]+)\\*\\*", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\\*([^*]+)\\*", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "_([^_]+)_", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)

        if plainText.count <= maxLength {
            return plainText
        }

        // Find a word boundary near maxLength
        let prefix = String(plainText.prefix(maxLength))
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "…"
        }

        // No space found - just truncate
        return prefix + "…"
    }
}
