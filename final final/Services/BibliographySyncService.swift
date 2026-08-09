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

/// Snapshot captured when a debounced bibliography update is scheduled but not yet consumed.
/// The `generation` always travels with the rest of the snapshot — see `flushPendingSync()`
/// for why it must be the one captured at schedule time, not a freshly-read `syncGeneration`.
private struct PendingBibliographyUpdate {
    let citekeys: [String]
    let projectId: String
    let generation: Int
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

    /// Debounce interval (1 second for bibliography, longer than section sync's 500ms)
    private let debounceInterval: TimeInterval = 1.0

    /// Monotonic counter bumped by every scheduled debounce and by `regenerateBibliography`'s
    /// immediate write. A debounced rebuild captures this at schedule time; if a newer
    /// schedule or an immediate regeneration has bumped it since, the older debounced
    /// rebuild is stale and must not run.
    private var syncGeneration: Int = 0

    /// Snapshot captured at the moment a debounced update was scheduled but not yet
    /// consumed by `performBibliographyUpdate`. Cleared inside the debounce closure
    /// immediately before it fires, so `pendingUpdate != nil` reliably means "there is
    /// unconsumed scheduled work" — see `flushPendingSync()`.
    private var pendingUpdate: PendingBibliographyUpdate?

    // MARK: - Configuration

    /// Whether auto-update is enabled (false if user has manually edited)
    var isAutoUpdateEnabled: Bool = true

    // MARK: - Dependencies

    weak var database: ProjectDatabase?

    /// Hook invoked at the start of every bibliography update, BEFORE any bibliography row
    /// is written, so the block table reflects the live editor's current text.
    ///
    /// Wired unconditionally by ContentView (both editor modes) to a closure that calls
    /// `EditorViewState.flushContentToDatabase()`, but the closure itself gates on
    /// `editorMode == .source` and self-guards to a no-op in WYSIWYG, where
    /// `BlockSyncService`'s incremental poll already keeps the block table current.
    ///
    /// Exists because in Source Mode the ONLY writer of live editor text into the block
    /// table is a 1s-debounced re-parse whose fire-time guard silently drops the write --
    /// and this update is about to make that guard false. `BlockSyncService.pollBlockChangesNow()`,
    /// which the bibliography rebuild relies on for the same purpose, is inert in Source Mode
    /// (its WebView is only ever assigned to the Milkdown editor).
    ///
    /// Same targeted per-consumer-flush pattern already shipped for export
    /// (`DocumentManager.flushBeforeExport`) and snapshot/auto-backup
    /// (`EditorViewState.flushLiveContentToDatabase`).
    ///
    /// The closure receives the projectId this bibliography update was scheduled for
    /// (captured at schedule time) and must verify it still matches the live editor's
    /// current project before flushing -- protects against a project switch landing
    /// between scheduling and this update actually running. Bails (no-ops) on mismatch.
    var flushLiveEditorContentToBlocks: ((_ scheduledForProjectId: String) async -> Void)?

    // MARK: - Public Methods

    // Citekey extraction (citationSpanPattern, citationKeyPattern, extractCitekeys) lives in
    // BibliographySyncService+CitationExtraction.swift — a distinct, self-contained concern
    // from this class's sync state machine, and split out to keep type_body_length in range.

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
        syncGeneration += 1
        let scheduledGeneration = syncGeneration
        pendingUpdate = PendingBibliographyUpdate(
            citekeys: currentCitekeys, projectId: projectId, generation: scheduledGeneration
        )
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard !Task.isCancelled else { return }

            // Wait for debounce interval (derived from property to prevent drift)
            try? await Task.sleep(for: .seconds(debounceInterval))

            guard !Task.isCancelled else { return }
            self?.pendingUpdate = nil
            await self?.performBibliographyUpdate(
                citekeys: currentCitekeys, projectId: projectId, scheduledGeneration: scheduledGeneration
            )
        }
    }

    /// Force any already-scheduled (but not yet fired) debounced bibliography update to
    /// run immediately. Used on quit/project-close so the derived Bibliography section
    /// isn't left stale behind the 1s debounce.
    ///
    /// If a natural debounce fire is already in flight (`state == .syncing`), waits for it
    /// to finish rather than starting a second, overlapping update. After the wait (or
    /// immediately, if nothing was in flight), re-checks for pending work rather than
    /// unconditionally returning: a new update can become pending in the moments between
    /// the in-flight run finishing and this method's poll loop waking up, and that update
    /// must still be picked up rather than silently dropped right before the process quits.
    ///
    /// Replays using the STORED generation captured at schedule time, not a freshly-read
    /// `syncGeneration` — this is what lets `performBibliographyUpdate`'s existing
    /// `scheduledGeneration == syncGeneration` guard correctly reject a snapshot that a
    /// newer `checkAndUpdateBibliography` call or `regenerateBibliography` has since superseded.
    func flushPendingSync() async {
        if state == .syncing {
            let deadline = Date().addingTimeInterval(2.0)
            while state == .syncing, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        guard state == .idle, let pending = pendingUpdate else { return }

        debounceTask?.cancel()
        debounceTask = nil
        pendingUpdate = nil
        await performBibliographyUpdate(
            citekeys: pending.citekeys, projectId: pending.projectId, scheduledGeneration: pending.generation
        )
    }

    /// Regenerate bibliography (manual trigger)
    func regenerateBibliography(projectId: String, citekeys: [String]) async {
        isAutoUpdateEnabled = true
        debounceTask?.cancel()
        debounceTask = nil
        syncGeneration += 1        // supersede any debounced rebuild scheduled before now
        await performBibliographyUpdate(
            citekeys: citekeys, projectId: projectId, scheduledGeneration: syncGeneration
        )
    }

    /// Mark bibliography as manually edited (disables auto-update)
    func markAsManuallyEdited() {
        isAutoUpdateEnabled = false
    }

    /// Reset service state (call when switching projects)
    func reset() {
        debounceTask?.cancel()
        debounceTask = nil
        pendingUpdate = nil
        lastKnownCitekeys = []
        lastGeneratedHash = 0
        isAutoUpdateEnabled = true
        state = .idle
    }

    // MARK: - Private Methods

    /// Internal (not private) so the race-condition guard can be unit-tested directly.
    func performBibliographyUpdate(citekeys: [String], projectId: String, scheduledGeneration: Int) async {
        // Deduplicate citekeys early - a citation may appear multiple times in document
        var seen = Set<String>()
        let uniqueCitekeys = citekeys.filter { seen.insert($0).inserted }

        guard let database else { return }

        // Execution-time mutual exclusion: a newer scheduled debounce or an immediate
        // `regenerateBibliography` call may have bumped syncGeneration since this update was
        // scheduled. A stale debounced rebuild must NOT run against its now-superseded
        // citekeys snapshot.
        guard !Task.isCancelled, scheduledGeneration == syncGeneration, state == .idle else { return }

        let zoteroService = ZoteroService.shared
        guard zoteroService.isConnected else { return }

        state = .syncing
        defer { state = .idle }

        // Flush the live editor's text into the block table before writing anything.
        // MUST run BEFORE both write branches below: the Source-Mode flush is a wholesale
        // delete-and-reinsert of every block parsed from the live editor content, so running
        // it afterwards would re-parse the editor's now-stale bibliography text and clobber
        // the fresh rows this update is about to write.
        // Safe to place here: this function never reads block/body content itself -- it
        // derives the bibliography purely from the citekey snapshot -- and the markdown that
        // actually reaches the editor is assembled later, elsewhere (ContentView's
        // handleBibliographySectionChanged -> fetchBlocksWithIds), from a fresh block read.
        // Not logged here: the closure is always wired (both editor modes -- see the property's
        // doc comment above) and self-guards to a no-op in WYSIWYG, so a log statement at this
        // call site would fire unconditionally and misleadingly claim a flush happened even when
        // the closure's own guards skipped it. The actual flush is logged from inside the
        // closure itself (ContentView+ProjectLifecycle.swift), right before it calls
        // flushContentToDatabase() -- the one place that knows whether a flush is really occurring.
        if let flush = flushLiveEditorContentToBlocks {
            await flush(projectId)
        }

        // The flush is the first suspension point since the staleness guard above. Re-check
        // that a manual regenerateBibliography() hasn't superseded this snapshot while it ran.
        guard scheduledGeneration == syncGeneration else { return }

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
                DebugLog.log(.bib, "[BibliographySyncService] Failed to fetch items: \(error)")
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
            DebugLog.log(.bib, "[BibliographySyncService] Failed to update bibliography: \(error)")
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
            parts.append(formatAuthorList(authors))
        }

        // Year
        parts.append("(\(item.year)).")

        // Title
        if let title = item.title {
            parts.append(formatTitle(title, type: item.type))
        }

        // Container title (journal, book for chapters)
        if let container = item.containerTitle {
            parts.append(contentsOf: formatContainerParts(
                container: container,
                volume: item.volume,
                issue: item.issue,
                page: item.page
            ))
        }

        // Publisher
        if let publisher = item.publisher {
            parts.append(formatPublisher(publisher, place: item.publisherPlace))
        }

        // DOI/URL
        if let doi = item.DOI {
            parts.append("https://doi.org/\(doi)")
        } else if let url = item.URL {
            parts.append(url)
        }

        return parts.joined(separator: " ")
    }

    /// Formats the author list for a bibliography entry (Chicago author-date style):
    /// single author, two authors joined with "and", or three-plus with a serial comma.
    private func formatAuthorList(_ authors: [CSLName]) -> String {
        let authorNames = authors.map(formatAuthorName)

        if authorNames.count == 1 {
            return authorNames[0] + "."
        } else if authorNames.count == 2 {
            return "\(authorNames[0]), and \(authorNames[1])."
        } else {
            let allButLast = authorNames.dropLast().joined(separator: ", ")
            let last = authorNames.last ?? ""
            return "\(allButLast), and \(last)."
        }
    }

    /// Formats a single author as "Family, Given", falling back to whichever name part
    /// is present, or the literal name for institutional authors.
    private func formatAuthorName(_ author: CSLName) -> String {
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

    /// Formats the title, italicized for books/theses or quoted for articles.
    private func formatTitle(_ title: String, type: CSLItemType) -> String {
        let isBook = type.rawValue == "book" || type.rawValue == "thesis"
        if isBook {
            return "*\(title)*."
        } else {
            return "\"\(title).\""
        }
    }

    /// Formats the container title (journal, or book for chapters) along with its
    /// volume/issue and page range, ensuring the section ends with a trailing period.
    private func formatContainerParts(
        container: String,
        volume: String?,
        issue: String?,
        page: String?
    ) -> [String] {
        var parts: [String] = ["*\(container)*"]

        // Volume/issue
        var volIssue: [String] = []
        if let volume {
            volIssue.append(volume)
        }
        if let issue {
            volIssue.append("(\(issue))")
        }
        if !volIssue.isEmpty {
            parts.append(volIssue.joined())
        }

        // Page
        if let page {
            parts.append(": \(page).")
        } else {
            // Ensure period after container/volume
            if let last = parts.last, !last.hasSuffix(".") {
                parts[parts.count - 1] = last + "."
            }
        }

        return parts
    }

    /// Formats the publisher, with an optional place prefixed before a colon.
    private func formatPublisher(_ publisher: String, place: String?) -> String {
        var pubParts: [String] = []
        if let place {
            pubParts.append(place)
        }
        pubParts.append(publisher)
        return pubParts.joined(separator: ": ") + "."
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

            let maxSortOrder = try Block
                .filter(Block.Columns.projectId == projectId)
                .order(Block.Columns.sortOrder.desc)
                .fetchOne(db)?.sortOrder ?? 0

            // Split "# Bibliography\n\nEntry1\n\nEntry2\n\n" into individual fragments
            // so each DB block maps 1:1 with a ProseMirror top-level node.
            // This prevents block-sync from seeing temp-ID paragraphs as spurious INSERTs.
            let rawBlocks = content
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            for (index, fragment) in rawBlocks.enumerated() {
                let isHeading = fragment.hasPrefix("#")
                let textContent = isHeading
                    ? headerName
                    : BlockParser.extractTextContent(from: fragment, blockType: .paragraph)
                var block = Block(
                    projectId: projectId,
                    sortOrder: maxSortOrder + Double(index) + 1.0,
                    blockType: isHeading ? .heading : .paragraph,
                    textContent: textContent,
                    markdownFragment: fragment,
                    headingLevel: isHeading ? 1 : nil,
                    status: isHeading ? .final_ : nil,
                    wordCount: MarkdownUtils.wordCount(for: textContent),
                    isBibliography: true
                )
                try block.insert(db)
            }
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
            DebugLog.log(.bib, "[BibliographySyncService] Error removing bibliography: \(error)")
        }
    }
}
