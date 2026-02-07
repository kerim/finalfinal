//
//  BibliographySyncService.swift
//  final final
//
//  Service for auto-updating bibliography sections based on citations in the document.
//  Uses state machine to prevent race conditions during sync operations.
//

import Foundation
import GRDB

/// State machine for bibliography sync to prevent race conditions
enum BibliographySyncState: Sendable {
    case idle
    case syncing
    case userEditPending
}

@MainActor
@Observable
final class BibliographySyncService {
    // MARK: - State

    /// Current sync state
    private(set) var state: BibliographySyncState = .idle

    /// Last known citekeys (to prevent unnecessary regeneration)
    private var lastKnownCitekeys: Set<String> = []

    /// Hash of last generated bibliography content
    private var lastGeneratedHash: Int = 0

    /// Debounce timer for bibliography updates
    private var debounceTask: Task<Void, Never>?

    /// Debounce interval (2 seconds for bibliography, longer than section sync)
    private let debounceInterval: TimeInterval = 2.0

    // MARK: - Configuration

    /// Whether auto-update is enabled (false if user has manually edited)
    var isAutoUpdateEnabled: Bool = true

    // MARK: - Dependencies

    weak var database: ProjectDatabase?

    // MARK: - Static Helpers

    /// Pre-compiled regex for citekey extraction
    /// Matches both [@citekey and ; @citekey for combined citations like [@key1; @key2]
    /// Stops at comma to handle page locators like [@citekey, p. 123]
    private static let citationPattern = try! NSRegularExpression(
        pattern: #"(?:\[|; )@([^\],;\s]+)"#,
        options: []
    )

    /// Extract citekeys from markdown content
    static func extractCitekeys(from markdown: String) -> [String] {
        let range = NSRange(markdown.startIndex..., in: markdown)
        let matches = citationPattern.matches(in: markdown, range: range)
        return matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: markdown) else { return nil }
            return String(markdown[range])
        }
    }

    // MARK: - Public Methods

    /// Configure the service with a database
    func configure(database: ProjectDatabase, projectId: String) {
        self.database = database
    }

    /// Called after SectionSyncService completes a sync
    /// Checks if bibliography needs updating based on current document citekeys
    func checkAndUpdateBibliography(
        currentCitekeys: [String],
        projectId: String
    ) {
        // Skip if auto-update is disabled
        guard isAutoUpdateEnabled else { return }

        // Skip if currently syncing
        guard state == .idle else { return }

        // Check if citekeys have changed
        // Allow transition-to-empty so bibliography can be removed when all citations are deleted
        let currentSet = Set(currentCitekeys)
        let isTransitioningToEmpty = currentSet.isEmpty && !lastKnownCitekeys.isEmpty
        guard currentSet != lastKnownCitekeys || isTransitioningToEmpty else { return }

        // Debounce the update
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard !Task.isCancelled else { return }

            // Wait for debounce interval
            try? await Task.sleep(nanoseconds: UInt64(2_000_000_000))

            guard !Task.isCancelled else { return }
            await self?.performBibliographyUpdate(citekeys: currentCitekeys, projectId: projectId)
        }
    }

    /// Regenerate bibliography (manual trigger)
    func regenerateBibliography(projectId: String, citekeys: [String]) async {
        isAutoUpdateEnabled = true
        await performBibliographyUpdate(citekeys: citekeys, projectId: projectId)
    }

    /// Mark bibliography as manually edited (disables auto-update)
    func markAsManuallyEdited() {
        isAutoUpdateEnabled = false
    }

    /// Reset service state (call when switching projects)
    func reset() {
        debounceTask?.cancel()
        debounceTask = nil
        lastKnownCitekeys = []
        lastGeneratedHash = 0
        isAutoUpdateEnabled = true
        state = .idle
    }

    // MARK: - Private Methods

    private func performBibliographyUpdate(citekeys: [String], projectId: String) async {
        // Deduplicate citekeys early - a citation may appear multiple times in document
        var seen = Set<String>()
        let uniqueCitekeys = citekeys.filter { seen.insert($0).inserted }

        guard let database else { return }

        let zoteroService = ZoteroService.shared
        guard zoteroService.isConnected else { return }

        state = .syncing
        defer { state = .idle }

        // Update last known citekeys
        lastKnownCitekeys = Set(uniqueCitekeys)

        // Remove bibliography if no citations
        guard !uniqueCitekeys.isEmpty else {
            await removeBibliographyBlock(projectId: projectId)
            return
        }

        // Check for missing items and fetch them from Zotero
        let missingKeys = uniqueCitekeys.filter { !zoteroService.hasItem(citekey: $0) }
        if !missingKeys.isEmpty {
            do {
                _ = try await zoteroService.fetchItemsForCitekeys(missingKeys)
            } catch {
                print("[BibliographySyncService] Failed to fetch items: \(error)")
            }
        }

        // Generate bibliography markdown (items now in cache)
        let bibliographyContent = generateBibliographyMarkdown(citekeys: uniqueCitekeys)

        // Check if content actually changed
        let contentHash = bibliographyContent.hashValue
        guard contentHash != lastGeneratedHash else { return }
        lastGeneratedHash = contentHash

        // Find or create bibliography section
        do {
            try await updateBibliographyBlock(
                content: bibliographyContent,
                projectId: projectId,
                database: database
            )
            // Post notification directly - don't rely on ValueObservation
            // ValueObservation may be blocked by contentState guard during editing
            NotificationCenter.default.post(name: .bibliographySectionChanged, object: nil)
        } catch {
            print("[BibliographySyncService] Failed to update bibliography: \(error)")
        }
    }

    private func generateBibliographyMarkdown(citekeys: [String]) -> String {
        let zoteroService = ZoteroService.shared

        // Get items for citekeys
        let items = zoteroService.getItems(citekeys: citekeys)
        guard !items.isEmpty else { return "" }

        // Sort by author name, then year
        let sorted = items.sorted { a, b in
            let aName = a.firstAuthorName.lowercased()
            let bName = b.firstAuthorName.lowercased()
            if aName != bName {
                return aName < bName
            }
            return a.year < b.year
        }

        // Generate formatted entries
        var entries: [String] = []
        for item in sorted {
            let entry = formatBibliographyEntry(item)
            entries.append(entry)
        }

        // Build markdown WITHOUT marker (marker is injected only for CodeMirror source mode)
        // This follows the section anchor pattern: store clean content, inject markers for source view
        let headerName = ExportSettingsManager.shared.bibliographyHeaderName
        var markdown = "# \(headerName)\n\n"
        markdown += entries.joined(separator: "\n\n")
        markdown += "\n\n"

        return markdown
    }

    /// Format a single bibliography entry
    /// Uses Chicago author-date format as default
    private func formatBibliographyEntry(_ item: CSLItem) -> String {
        var parts: [String] = []

        // Authors
        if let authors = item.author, !authors.isEmpty {
            let authorNames = authors.map { author -> String in
                if let literal = author.literal {
                    return literal
                }
                let family = author.family ?? ""
                let given = author.given ?? ""
                if !family.isEmpty && !given.isEmpty {
                    return "\(family), \(given)"
                }
                return family.isEmpty ? given : family
            }

            if authorNames.count == 1 {
                parts.append(authorNames[0] + ".")
            } else if authorNames.count == 2 {
                parts.append("\(authorNames[0]), and \(authorNames[1]).")
            } else {
                let allButLast = authorNames.dropLast().joined(separator: ", ")
                let last = authorNames.last ?? ""
                parts.append("\(allButLast), and \(last).")
            }
        }

        // Year
        parts.append("(\(item.year)).")

        // Title
        if let title = item.title {
            // Italicize if book/thesis, quote if article
            let isBook = item.type.rawValue == "book" || item.type.rawValue == "thesis"
            if isBook {
                parts.append("*\(title)*.")
            } else {
                parts.append("\"\(title).\"")
            }
        }

        // Container title (journal, book for chapters)
        if let container = item.containerTitle {
            parts.append("*\(container)*")

            // Volume/issue
            var volIssue: [String] = []
            if let vol = item.volume {
                volIssue.append(vol)
            }
            if let issue = item.issue {
                volIssue.append("(\(issue))")
            }
            if !volIssue.isEmpty {
                parts.append(volIssue.joined())
            }

            // Page
            if let page = item.page {
                parts.append(": \(page).")
            } else {
                // Ensure period after container/volume
                if let last = parts.last, !last.hasSuffix(".") {
                    parts[parts.count - 1] = last + "."
                }
            }
        }

        // Publisher
        if let publisher = item.publisher {
            var pubParts: [String] = []
            if let place = item.publisherPlace {
                pubParts.append(place)
            }
            pubParts.append(publisher)
            parts.append(pubParts.joined(separator: ": ") + ".")
        }

        // DOI/URL
        if let doi = item.DOI {
            parts.append("https://doi.org/\(doi)")
        } else if let url = item.URL {
            parts.append(url)
        }

        return parts.joined(separator: " ")
    }

    private func updateBibliographyBlock(
        content: String,
        projectId: String,
        database: ProjectDatabase
    ) async throws {
        // Read @MainActor property BEFORE entering GRDB write closure
        let headerName = ExportSettingsManager.shared.bibliographyHeaderName
        try database.write { db in
            // Delete ALL existing bibliography blocks (handles duplicates)
            try Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.isBibliography == true)
                .deleteAll(db)

            // Get max sort order from blocks
            let maxSortOrder = try Block
                .filter(Block.Columns.projectId == projectId)
                .order(Block.Columns.sortOrder.desc)
                .fetchOne(db)?.sortOrder ?? 0

            // Create bibliography block (single block with full content)
            var block = Block(
                projectId: projectId,
                sortOrder: maxSortOrder + 1,
                blockType: .heading,
                textContent: headerName,
                markdownFragment: content,
                headingLevel: 1,
                status: .final_,
                wordCount: MarkdownUtils.wordCount(for: content),
                isBibliography: true
            )
            try block.insert(db)
        }
    }

    /// Remove bibliography blocks when all citations are deleted
    private func removeBibliographyBlock(projectId: String) async {
        guard let database else { return }

        do {
            try database.write { db in
                try Block
                    .filter(Block.Columns.projectId == projectId)
                    .filter(Block.Columns.isBibliography == true)
                    .deleteAll(db)
            }
            // Post notification directly - don't rely on ValueObservation
            NotificationCenter.default.post(name: .bibliographySectionChanged, object: nil)
            // Reset hash so next creation triggers notification
            lastGeneratedHash = 0
            // Reset citekeys so future removals don't get skipped by the guard
            lastKnownCitekeys = []
        } catch {
            print("[BibliographySyncService] Error removing bibliography: \(error)")
        }
    }
}
