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

    /// Whether the service is properly configured with database and project ID
    var isConfigured: Bool {
        projectDatabase != nil && projectId != nil
    }

    /// When true, suppresses sync operations
    /// Set during drag operations to prevent race conditions
    var isSyncSuppressed: Bool = false

    /// When true, content is a zoomed subset - skip full document save to database
    var isContentZoomed: Bool = false

    /// Callback after zoomed sections are synced to database
    /// Passes the set of zoomed section IDs for targeted refresh
    var onZoomedSectionsUpdated: ((Set<String>) -> Void)?

    /// Content we last synced - prevents feedback loop from ValueObservation
    private var lastSyncedContent: String = ""

    // MARK: - Public API

    /// Configure the service for a specific project
    func configure(database: ProjectDatabase, projectId: String) {
        self.projectDatabase = database
        self.projectId = projectId
    }

    /// Verify the service is properly configured
    /// - Throws: SyncConfigurationError if not configured
    func verifyConfiguration() throws {
        if projectDatabase == nil {
            throw SyncConfigurationError.noDatabase
        }
        if projectId == nil {
            throw SyncConfigurationError.noProjectId
        }
    }

    /// Errors related to sync service configuration
    enum SyncConfigurationError: Error, LocalizedError {
        case noDatabase
        case noProjectId

        var errorDescription: String? {
            switch self {
            case .noDatabase:
                return "SectionSyncService not configured: no database"
            case .noProjectId:
                return "SectionSyncService not configured: no project ID"
            }
        }
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
        guard let db = projectDatabase, let pid = projectId else { return }

        // When zoomed, update zoomed sections in-place
        // Trust zoomedIds directly - it's passed synchronously from editorState.zoomedSectionIds
        // which is the source of truth (not the reactive isContentZoomed property)
        if let zoomedIds = zoomedIds, !zoomedIds.isEmpty {
            await syncZoomedSections(from: markdown, zoomedIds: zoomedIds)
            return
        }

        // 1. Get current DB sections first (need to identify bibliography by title)
        let dbSections: [Section]
        do {
            dbSections = try db.fetchSections(projectId: pid)
        } catch {
            print("[SectionSyncService] Error fetching sections: \(error.localizedDescription)")
            return
        }

        // 2. Parse headers from markdown (pass existing bibliography title for detection)
        let existingBibTitle = dbSections.first(where: { $0.isBibliography })?.title
        let headers = parseHeaders(from: markdown, existingBibTitle: existingBibTitle)
        guard !headers.isEmpty else { return }

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

        // Check if user made edits to Getting Started
        DocumentManager.shared.checkGettingStartedEdited(currentMarkdown: markdown)

        // Note: UI updates happen automatically via ValueObservation in EditorViewState
        // Hierarchy enforcement is handled via onChange in ContentView
    }

    /// Sync zoomed content without replacing the full sections array
    /// Updates zoomed sections in-place and saves only those to database
    private func syncZoomedSections(from markdown: String, zoomedIds: Set<String>) async {
        guard let db = projectDatabase, let pid = projectId else { return }

        // Fetch existing sections from database first (need bibliography title for detection)
        let existingSections: [Section]
        do {
            existingSections = try db.fetchSections(projectId: pid)
        } catch {
            print("[SectionSyncService] Error fetching sections: \(error)")
            return
        }

        // Parse zoomed markdown to extract section content (pass bibliography title for detection)
        let existingBibTitle = existingSections.first(where: { $0.isBibliography })?.title
        let headers = parseHeaders(from: markdown, existingBibTitle: existingBibTitle)

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

            // Check if title changed (e.g., user edited "# A" to "# A Renamed")
            if header.title != existing.title {
                updates.title = header.title
                hasChanges = true
            }

            // Check if header level changed (e.g., "##" → "#")
            if header.level != existing.headerLevel {
                updates.headerLevel = header.level
                hasChanges = true
            }

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
                // Notify for UI refresh - bypasses ValueObservation blocked by contentState
                onZoomedSectionsUpdated?(zoomedIds)
            } catch {
                print("[SectionSyncService] Error updating zoomed sections: \(error)")
            }
        }
    }

    /// Parse markdown content into ParsedHeader structs for reconciliation
    /// - Parameters:
    ///   - markdown: The markdown content to parse
    ///   - existingBibTitle: Title of the existing bibliography section (if any) to detect bibliography by title match
    private func parseHeaders(from markdown: String, existingBibTitle: String? = nil) -> [ParsedHeader] {

        var headers: [ParsedHeader] = []
        var currentOffset = 0
        var inCodeBlock = false
        var inAutoBibliography = false  // Track auto-bibliography section (managed by BibliographySyncService)

        // Track section boundaries
        struct SectionBoundary {
            let startOffset: Int
            let level: Int
            let title: String
            let isPseudoSection: Bool
        }

        var boundaries: [SectionBoundary] = []
        var lastActualHeaderLevel: Int = 1  // Default to H1 for pseudo-sections at document start

        // Track where bibliography section starts (to end preceding section there)
        var bibliographyStartOffset: Int?

        // Bibliography detection: use existing title if provided, otherwise fall back to configured name
        let bibHeaderName = existingBibTitle ?? ExportSettingsManager.shared.bibliographyHeaderName

        // First pass: find all headers and pseudo-sections
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let lineStr = String(line)
            let trimmed = lineStr.trimmingCharacters(in: .whitespaces)

            // Track code blocks
            if trimmed.hasPrefix("```") {
                inCodeBlock = !inCodeBlock
            }

            // Legacy marker support: still detect marker if present in old content
            // This ensures backward compatibility during transition
            if trimmed.hasPrefix("<!-- ::auto-bibliography:: -->") {
                inAutoBibliography = true
                bibliographyStartOffset = currentOffset
                currentOffset += lineStr.count + 1  // +1 for newline
                continue  // Skip - header on same line, don't parse as separate section
            }

            // Skip headers inside code blocks or auto-bibliography sections
            if !inCodeBlock && !inAutoBibliography {
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
                    // Detect bibliography by title match (when no marker is present)
                    // This allows detection even after marker is removed from stored content
                    if header.title == bibHeaderName && existingBibTitle != nil {
                        inAutoBibliography = true
                        bibliographyStartOffset = currentOffset
                        // Don't add to boundaries - bibliography is managed separately
                    } else {
                        lastActualHeaderLevel = header.level  // Track for subsequent pseudo-sections
                        boundaries.append(SectionBoundary(
                            startOffset: currentOffset,
                            level: header.level,
                            title: header.title,
                            isPseudoSection: false
                        ))
                    }
                }
            }

            currentOffset += lineStr.count + 1 // +1 for newline
        }

        guard !boundaries.isEmpty else { return [] }

        // Second pass: calculate content for each section
        let contentLength = markdown.count

        for (index, boundary) in boundaries.enumerated() {
            var endOffset: Int
            if index < boundaries.count - 1 {
                endOffset = boundaries[index + 1].startOffset
            } else {
                endOffset = contentLength
            }

            // If this is the last section before bibliography, end it at the bibliography marker
            // This prevents bibliography content from being absorbed into the preceding section
            if let bibStart = bibliographyStartOffset {
                // Check if this section would absorb the bibliography
                if boundary.startOffset < bibStart && endOffset > bibStart {
                    endOffset = bibStart
                }
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

    // MARK: - Section Anchor Support

    /// Regex pattern for section anchor comments
    /// Anchors are on the same line as headers (no newline in pattern)
    private static let anchorPattern = try! NSRegularExpression(
        pattern: #"<!-- @sid:([0-9a-fA-F-]+) -->"#,
        options: []
    )

    /// Inject section anchors before each header in markdown
    /// Used when switching from WYSIWYG to source mode
    /// Anchors are placed on the SAME LINE as headers (no newline after anchor)
    /// to prevent blank lines when CodeMirror hides the anchor comment
    /// - Parameters:
    ///   - markdown: The markdown content
    ///   - sections: Current sections with their IDs
    /// - Returns: Markdown with anchors injected before headers
    func injectSectionAnchors(markdown: String, sections: [SectionViewModel]) -> String {
        guard !sections.isEmpty else { return markdown }

        // Build a map of header text to section ID
        // We match by finding headers in the markdown and associating them with sections
        var result = markdown

        // Sort sections by startOffset in reverse order (inject from end to avoid offset drift)
        let sortedSections = sections.sorted { $0.startOffset > $1.startOffset }

        for section in sortedSections {
            // Find the header line at the section's start offset
            let offset = min(section.startOffset, result.count)
            let insertionIndex = result.index(result.startIndex, offsetBy: offset)

            // Inject anchor on SAME LINE as header (no newline)
            let anchor = "<!-- @sid:\(section.id) -->"
            result.insert(contentsOf: anchor, at: insertionIndex)
        }

        return result
    }

    /// Extract section anchors and their IDs from markdown
    /// Used when switching from source mode back to WYSIWYG
    /// Anchors are expected to be on the same line as headers: `<!-- @sid:UUID --># Header`
    /// - Parameter markdown: The markdown content with anchors
    /// - Returns: Tuple of (clean markdown, anchor mappings)
    func extractSectionAnchors(markdown: String) -> (markdown: String, anchors: [SectionAnchorMapping]) {
        var anchors: [SectionAnchorMapping] = []
        let nsRange = NSRange(markdown.startIndex..., in: markdown)

        // Find all anchors and their positions
        let matches = Self.anchorPattern.matches(in: markdown, options: [], range: nsRange)

        var offsetAdjustment = 0

        for match in matches {
            guard let idRange = Range(match.range(at: 1), in: markdown) else { continue }

            let anchorId = String(markdown[idRange])
            let originalOffset = match.range.location

            // Calculate the offset in the cleaned markdown (after previous anchors removed)
            let cleanedOffset = originalOffset - offsetAdjustment

            anchors.append(SectionAnchorMapping(
                sectionId: anchorId,
                headerOffset: cleanedOffset
            ))

            // Track how much we've removed for offset adjustment
            // match.range.length gives us the length of the full match
            offsetAdjustment += match.range.length
        }

        // Remove all anchors from the markdown
        let cleanedMarkdown = Self.anchorPattern.stringByReplacingMatches(
            in: markdown,
            options: [],
            range: nsRange,
            withTemplate: ""
        )

        return (cleanedMarkdown, anchors)
    }

    /// Strip all section anchors from markdown
    /// Used for clean export and display
    func stripSectionAnchors(from markdown: String) -> String {
        Self.anchorPattern.stringByReplacingMatches(
            in: markdown,
            options: [],
            range: NSRange(markdown.startIndex..., in: markdown),
            withTemplate: ""
        )
    }

    // MARK: - Bibliography Marker Support

    /// Inject bibliography marker before the bibliography section header
    /// Used when building sourceContent for CodeMirror (follows section anchor pattern)
    /// - Parameters:
    ///   - markdown: The markdown content (with section anchors already injected)
    ///   - sections: Current sections to identify bibliography
    /// - Returns: Markdown with bibliography marker injected before the bibliography header
    func injectBibliographyMarker(markdown: String, sections: [SectionViewModel]) -> String {
        // Find the bibliography section
        guard let bibSection = sections.first(where: { $0.isBibliography }) else {
            return markdown
        }

        // Find the bibliography header in the markdown
        // The header might be prefixed with a section anchor: <!-- @sid:UUID --># Bibliography
        let bibHeaderName = ExportSettingsManager.shared.bibliographyHeaderName

        // Try to find the header with or without anchor prefix
        // Pattern: optional anchor + "# HeaderName"
        let anchorPrefixPattern = #"(<!-- @sid:[0-9a-fA-F-]+ -->)?"#
        let headerPattern = anchorPrefixPattern + #"# \#(bibHeaderName)"#

        guard let regex = try? NSRegularExpression(pattern: headerPattern, options: []) else {
            return markdown
        }

        let nsRange = NSRange(markdown.startIndex..., in: markdown)
        guard let match = regex.firstMatch(in: markdown, options: [], range: nsRange),
              let range = Range(match.range, in: markdown) else {
            return markdown
        }

        // Insert the marker at the start of the matched range (before any anchor)
        var result = markdown
        let marker = "<!-- ::auto-bibliography:: -->"
        result.insert(contentsOf: marker, at: range.lowerBound)
        return result
    }

    /// Strip bibliography marker from markdown
    /// Used when cleaning content for Milkdown or export
    func stripBibliographyMarker(from markdown: String) -> String {
        markdown.replacingOccurrences(of: "<!-- ::auto-bibliography:: -->", with: "")
    }
}

/// Represents a mapping between a section ID and its header offset in markdown
struct SectionAnchorMapping: Equatable {
    let sectionId: String
    let headerOffset: Int
}
