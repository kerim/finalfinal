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
    ///
    /// The second parameter, `overrideContent`, is threaded straight through from
    /// `performBibliographyUpdate`'s own `overrideContent` parameter -- see that
    /// function's doc comment for why a project-switch caller must pass a non-nil value
    /// here rather than let the closure fall back to reading `editorState.content`
    /// itself (review round 1 must-fix: the bibliography-flush clobber).
    var flushLiveEditorContentToBlocks: ((_ scheduledForProjectId: String, _ overrideContent: String?) async -> Void)?

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
    ///
    /// `overrideContent` (default `nil`, preserving prior behavior for every existing
    /// caller) is forwarded verbatim to `performBibliographyUpdate` -- see its doc comment.
    /// `ContentView.handleProjectOpened()` is the one caller that passes a non-nil value,
    /// via `EditorViewState.flushPendingBibliographyAndFootnoteSync(overrideContent:)`.
    func flushPendingSync(overrideContent: String? = nil) async {
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
            citekeys: pending.citekeys, projectId: pending.projectId, scheduledGeneration: pending.generation,
            overrideContent: overrideContent
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
    ///
    /// `overrideContent` (default `nil`): forwarded verbatim as the second argument to
    /// `flushLiveEditorContentToBlocks` below. `nil` preserves the original behavior --
    /// the flush hook falls back to reading `editorState.content` directly, which is
    /// correct for every caller except a project switch in progress (see
    /// `ContentView.flushAllPendingContent()`'s doc comment for why `editorState.content`
    /// is deliberately stale during that specific window, and
    /// `flushPendingSync(overrideContent:)`'s doc comment for how a non-nil value reaches
    /// here).
    func performBibliographyUpdate(
        citekeys: [String], projectId: String, scheduledGeneration: Int, overrideContent: String? = nil
    ) async {
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
            await flush(projectId, overrideContent)
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

    // Bibliography markdown/entry formatting (generateBibliographyMarkdown,
    // formatBibliographyEntry, formatAuthorList, formatAuthorName, formatTitle,
    // formatContainerParts, formatPublisher) lives in
    // BibliographySyncService+EntryFormatting.swift — a distinct, self-contained concern
    // from this class's sync state machine and block persistence, split out to keep
    // type_body_length in range.

    private func updateBibliographyBlock(
        content: String,
        projectId: String,
        database: ProjectDatabase
    ) async throws {
        try database.write { db in
            // Re-derive the effective header name from INSIDE this serialized GRDB write
            // section -- NOT from a read captured on the MainActor before this closure was
            // scheduled to run (the prior shape here). `content`'s own heading text was
            // already baked in by `generateBibliographyMarkdown`, called before this
            // function, using whatever name was current at THAT moment. If a rename's write
            // (`BibliographyHeadingRenamer.rename`) commits in between, that baked-in name
            // goes stale. GRDB serializes writes, so reading the effective name again here --
            // inside the write closure, rather than before it -- is what makes BOTH
            // write-orderings converge on whichever name is actually current in settings at
            // the moment EACH write actually commits, regardless of which of the two closures
            // was scheduled first. See `BibliographyHeadingRenamer.rename`'s doc comment for
            // the counterpart half of this fix (why IT doesn't need a busy-guard against this
            // function).
            let headerName = ExportSettings.load().effectiveBibliographyHeaderName
            // Fetch the existing bibliography blocks BEFORE deleting them, so the regenerated
            // bibliography can be reinserted back where the old one was, instead of always
            // landing past whatever the user has typed after it since. See the anchor/step
            // derivation below for how that position is reconstructed after the delete.
            let existingBib = try Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.isBibliography == true)
                .order(Block.Columns.sortOrder)
                .fetchAll(db)

            // Anchor = the sortOrder the regenerated bibliography should return to: the REAL
            // bibliography section's own heading position. The insert-time path (see
            // `Database+BlocksInsert.swift`'s `resolveInsertPlacement`/`buildInsertedBlock`)
            // only flags a heading `isBibliography = true` when it carries the literal
            // `<!-- ::auto-bibliography:: -->` marker (`BlockParser.hasBibliographyMarker`) --
            // a bare-title heading a user types or pastes (e.g. an ordinary "# Bibliography"
            // chapter heading, a completely normal thing to write) is NOT flagged by that path
            // at all, regardless of where in the document it lands. A second flagged heading
            // can still occur, though: pasted text that happens to carry the marker literally,
            // or a historical orphan already flagged in the DB from before this and the
            // insert-time fix (see the "Historical orphans" comment further below) -- so
            // picking the lowest-sortOrder flagged heading unconditionally could still pick the
            // wrong one instead of the real section's, relocating the entire regenerated
            // bibliography to the wrong position.
            //
            // Disambiguate with the same containment rule `resolveInsertPlacement` already
            // applies: a flagged heading is the REAL bibliography heading only if the block
            // immediately following it (by sortOrder, among ALL blocks -- not just
            // bibliography-flagged ones) is ALSO bibliography-flagged. `generateBibliographyMarkdown`
            // always emits heading-plus-entries together, so the real section's heading always
            // has a bibliography-flagged block right after it; a lone stray heading with
            // ordinary content after it does not.
            //
            // Falls back to the simpler "first flagged heading, unconditional" selector -- and,
            // failing that, the first surviving bibliography block that is NOT a bare opening
            // marker (see `isBareOpeningMarker` below) -- when no heading satisfies the stricter
            // check. Covers first-ever generation (no heading exists yet to satisfy anything)
            // and an already-degenerate state (e.g. a heading-only bibliography with no
            // surviving entries after it) so those cases don't regress. The bare-marker
            // exclusion at this last level exists because a marker orphan (an entire block
            // whose content IS the bare opening-marker literal, left behind when CodeMirror's
            // Source Mode hides the marker as an invisible atomic decoration and the user
            // deletes the visible bibliography section around it) is not a heading, so it can
            // only ever surface here -- unexcluded, it would hijack regeneration to the
            // orphan's stale mid-document position instead of the document end. `nil` means
            // there was no prior bibliography at all (or the only surviving block WAS a bare
            // marker orphan), which keeps today's append-at-the-end behavior.
            let realBibliographyHeadingAnchor = try existingBib.first { candidate in
                guard candidate.blockType == .heading else { return false }
                let nextBlock = try Block
                    .filter(Block.Columns.projectId == projectId)
                    .filter(Block.Columns.sortOrder > candidate.sortOrder)
                    .order(Block.Columns.sortOrder)
                    .fetchOne(db)
                return nextBlock?.isBibliography ?? false
            }?.sortOrder
            let anchor = realBibliographyHeadingAnchor
                ?? existingBib.first { $0.blockType == .heading }?.sortOrder
                ?? existingBib.first { !$0.isBareOpeningMarker }?.sortOrder

            // Delete ALL existing bibliography blocks (handles duplicates)
            try Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.isBibliography == true)
                .deleteAll(db)

            // Split "# Bibliography\n\nEntry1\n\nEntry2\n\n" into individual fragments
            // so each DB block maps 1:1 with a ProseMirror top-level node.
            // This prevents block-sync from seeing temp-ID paragraphs as spurious INSERTs.
            let rawBlocks = content
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            // Placement: `start` is where the first fragment (the heading, always index 0 --
            // see generateBibliographyMarkdown) lands; `step` is the sortOrder distance
            // between consecutive fragments.
            let start: Double
            let step: Double
            if let anchor {
                start = anchor
                // Whatever now immediately follows the anchor position (e.g. a trailing
                // paragraph the user typed after the old bibliography) bounds how far the
                // regenerated fragments can spread before colliding with it.
                let nextBlock = try Block
                    .filter(Block.Columns.projectId == projectId)
                    .filter(Block.Columns.sortOrder > anchor)
                    .order(Block.Columns.sortOrder)
                    .fetchOne(db)
                if let nextBlock {
                    let gap = nextBlock.sortOrder - anchor
                    step = min(1.0, gap / Double(max(rawBlocks.count, 1)))
                    if step < 1e-6 {
                        // Defensive logging only -- no block mutation. `gap / N` still keeps
                        // every insert strictly increasing and correctly ordered relative to
                        // `nextBlock` for any positive gap; this just makes an unusually tight
                        // squeeze visible if it ever happens.
                        DebugLog.log(.bib, "[BibliographySyncService] Tight bibliography sortOrder gap: " +
                            "anchor=\(anchor) next=\(nextBlock.sortOrder) step=\(step)")
                    }
                } else {
                    // Bibliography was already the last thing in the document -- nothing to
                    // pack against, so it simply stays put without needing to shift.
                    step = 1.0
                }
            } else {
                // First-ever generation: no prior bibliography blocks existed, so there is
                // nothing to anchor back to. Unchanged existing behavior -- append at the end.
                let maxSortOrder = try Block
                    .filter(Block.Columns.projectId == projectId)
                    .order(Block.Columns.sortOrder.desc)
                    .fetchOne(db)?.sortOrder ?? 0
                start = maxSortOrder + 1.0
                step = 1.0
            }

            // No self-heal sweep here (deliberately removed — a prior version tried to
            // delete unflagged orphan rows by exact-text match, position-bounded to
            // "at/after the bibliography heading"). That bound was unsound in both
            // directions at once: computed from `maxSortOrder` AFTER the delete above, an
            // orphan surviving in the table shifts the next heading's placement above it,
            // permanently excluding that orphan from future sweeps; widened to catch it,
            // the same unbounded-above range would just as readily delete a trailing user
            // paragraph that happens to exact-match a regenerated fragment, silently and
            // without undo. `Database+Blocks.swift`'s insert-time containment fix (see
            // `resolveInsertPlacement`) prevents new orphans from being created at all, and
            // `BlockParser.parse()`'s `sectionFlagCarriedForward` re-derives every block's
            // `isBibliography` flag from scratch — no drift possible — on every full
            // document reparse (project open with no existing blocks, Source Mode's
            // debounced re-parse, snapshot restore).
            //
            // Historical orphans (rows already mis-flagged `isBibliography == true` from
            // before the insert-time fix) do NOT self-heal from any of that, and must not be
            // assumed to: `assembleMarkdownForEditor` inserts the terminator immediately
            // after the LAST block flagged `isBibliography`, which in an already-corrupted
            // document IS the orphaned paragraph itself, so the regenerated markdown places
            // the terminator AFTER the orphan every time — a reparse of that markdown
            // re-derives the identical wrong flag via `sectionFlagCarriedForward`, not a
            // corrected one. Worse, `ContentView+ProjectLifecycle.swift`'s
            // `loadInitialContent` only calls `BlockParser.parse()` when no blocks exist yet
            // for the project; once blocks exist (which they do for any already-corrupted
            // document) project open just reassembles them via `assembleMarkdownForEditor`
            // and never reparses at all. Clearing existing historical orphans would need a
            // dedicated one-time migration — out of scope here.
            //
            // UPDATE: the orphan-as-anchor half of this harm is now closed. The `anchor`
            // derivation above excludes any bare-opening-marker block (`isBareOpeningMarker`,
            // both the unstripped-literal and legacy-load stripped-empty shapes) from its last
            // fallback level, so a historical orphan row can no longer hijack regeneration to
            // its own stale position. Deriving the anchor is not this comment's job, so it does
            // not delete anything on its own — but that is not the end of the story for a project
            // that actually regenerates: the orphan row is still flagged `isBibliography == true`
            // (that flag is exactly why it had to be excluded above), so the SAME regeneration's
            // own `deleteAll(isBibliography == true)` call just below removes it as a side effect,
            // like any other stale bibliography row — see `BibliographyOrphanMarkerAnchorTests.
            // swift`, which asserts this twice. The genuine remaining gap is narrower than "the
            // orphan is never cleaned up": a project that has an orphan but NEVER regenerates (no
            // citation is ever added or removed afterward) still has that orphan sitting in the
            // database forever, since nothing on the read/display path deletes it either. That
            // case alone still requires the dedicated one-time migration described above.

            for (index, fragment) in rawBlocks.enumerated() {
                let isHeading = fragment.hasPrefix("#")
                // Rewrite the heading's own markdown text to the freshly-read `headerName`
                // too, not just `textContent` below -- otherwise a rename landing between
                // this write being scheduled and it actually committing would leave the
                // persisted `markdownFragment` (what both editors actually render) showing
                // the stale name baked into `content` while `textContent` showed the fresh
                // one, self-desyncing the very row this write is about to insert. Idempotent
                // when the name hasn't changed: `fragment` already reads "# \(headerName)" in
                // that case, so this just rebuilds the identical string.
                let effectiveFragment = isHeading ? "# \(headerName)" : fragment
                let textContent = isHeading
                    ? headerName
                    : BlockParser.extractTextContent(from: fragment, blockType: .paragraph)
                var block = Block(
                    projectId: projectId,
                    sortOrder: start + Double(index) * step,
                    blockType: isHeading ? .heading : .paragraph,
                    textContent: textContent,
                    markdownFragment: effectiveFragment,
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

/// Single use: `updateBibliographyBlock`'s anchor-fallback chain above.
private extension Block {
    /// A "bare opening marker" block names no real bibliography content: it is either the
    /// unstripped marker literal on its own (a document parsed WITHOUT
    /// strippingBibliographyMarkerFromBlocks), or — on the legacy-load path, where the
    /// marker literal is stripped out of the stored fragment before classification — an
    /// EMPTY fragment on a block that is NOT `.heading`-typed (the only way an
    /// `isBibliography`-flagged, non-heading block can have empty content is if its entire
    /// original text WAS the marker, stripped away). Both shapes must be excluded from the
    /// anchor fallback, or a legacy-document orphan can still hijack regeneration.
    var isBareOpeningMarker: Bool {
        let trimmedFragment = markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedFragment == BlockParser.bibliographyStartMarker { return true }
        return trimmedFragment.isEmpty && blockType != .heading
    }
}
