//
//  ContentView+ProjectLifecycle.swift
//  final final
//
//  Project lifecycle: initialization, configuration, open/close, version history, integrity.
//

import SwiftUI

extension ContentView {
    /// Initialize the project - configure for currently open project
    func initializeProject() async {
        // Check if a project is already open (opened by FinalFinalApp)
        if documentManager.hasOpenProject {
            // The same sequence a project switch runs, minus the reset (EditorViewState.runProjectOpenSequence).
            await editorState.runProjectOpenSequence(kind: .launch, publish: annotationDisplayPublisher) { publishAfterContent in
                await configureForCurrentProject()
                publishAfterContent()
            }
            return
        }

        // No project open - this shouldn't happen as FinalFinalApp handles launch state
        // but if it does, just wait for a project to be opened
        DebugLog.log(.lifecycle, "[ContentView] No project open at initialization")
    }

    /// Configure UI for the currently open project
    func configureForCurrentProject() async {
        guard let db = documentManager.projectDatabase,
              let pid = documentManager.projectId,
              let cid = documentManager.contentId else {
            return
        }

        configureSyncServices(db: db, pid: pid, cid: cid)

        runProjectMaintenance(db: db, pid: pid)

        // Start reactive observation (now uses blocks internally)
        editorState.startObserving(database: db, projectId: pid)
        editorState.startObservingAnnotations(database: db, contentId: cid)

        applyDocumentGoalSettings()

        loadInitialContent(db: db, pid: pid)

        // Populate section table from loaded content so version history has fresh data.
        // For Getting Started, this pre-round-trip programmatic sync intentionally does NOT
        // count as `fromEditorChange` — the Getting Started baseline is instead captured
        // lazily from the first genuinely editor-settled `contentChanged` event (see
        // DocumentManager.checkGettingStartedEdited), because Milkdown reformats content when
        // it re-serializes and this string predates that round-trip.
        if !editorState.content.isEmpty {
            await sectionSyncService.syncNow(editorState.content)
        }

        // Connect to Zotero (just verify it's available - search is on-demand)
        Task {
            await connectToZotero()
        }

    }

    /// Configure sync services with the database, and wire up their editorState
    /// callbacks. Must run before the caller (`configureForCurrentProject`) calls
    /// `startObserving*` -- the callbacks assigned here (`flushLiveEditorContentToBlocks`,
    /// `onSectionsUpdated`) need to be in place before observation can fire them.
    private func configureSyncServices(db: ProjectDatabase, pid: String, cid: String) {
        // Configure sync services with database
        sectionSyncService.configure(database: db, projectId: pid)
        sectionSyncService.editorState = editorState
        annotationSyncService.configure(database: db, contentId: cid)
        annotationSyncService.editorState = editorState
        bibliographySyncService.configure(database: db, projectId: pid)
        bibliographySyncService.flushLiveEditorContentToBlocks = makeBibliographyFlushHandler()
        // Phase 2 (t-94369a83), §2.0: the typed handle bibliography/Notes sync route
        // their writes through -- see DocumentWriter+SystemWrite.swift's `SystemWriter`.
        bibliographySyncService.systemWriter = SystemWriter(blockSync: blockSyncService)
        footnoteSyncService.configure(database: db, projectId: pid)
        footnoteSyncService.systemWriter = SystemWriter(blockSync: blockSyncService)
        autoBackupService.configure(database: db, projectId: pid)
        autoBackupService.editorState = editorState

        // Inject sectionSyncService reference for zoom sourceContent updates
        editorState.sectionSyncService = sectionSyncService

        // Inject blockSyncService for atomic content+blockID pushes (hierarchy enforcement)
        editorState.blockSyncService = blockSyncService
        editorState.annotationSyncService = annotationSyncService
        editorState.bibliographySyncService = bibliographySyncService
        editorState.footnoteSyncService = footnoteSyncService

        // Wire up hierarchy enforcement after sections are updated from database
        // This ensures slash commands that create new headings trigger rebalancing
        editorState.onSectionsUpdated = makeSectionsUpdatedHandler()
    }

    /// Builds the closure assigned to `bibliographySyncService.flushLiveEditorContentToBlocks`.
    ///
    /// `overrideContent`, when non-nil, is what actually gets flushed instead of
    /// `editorState.content` -- see the parameter's own note below for why this exists
    /// (review round 1's must-fix: the bibliography-flush clobber).
    private func makeBibliographyFlushHandler() -> (_ scheduledForProjectId: String, _ overrideContent: String?) async -> Void {
        Self.makeBibliographyFlushHandler(for: editorState)
    }

    /// The closure itself, static so a unit test drives the REAL hook (not a copy of its guards).
    @MainActor
    static func makeBibliographyFlushHandler(
        for editorState: EditorViewState
    ) -> (_ scheduledForProjectId: String, _ overrideContent: String?) async -> Void {
        { [weak editorState] scheduledForProjectId, overrideContent in
            // t-94369a83 3a-1b round C4 (N50): while a close / switch / quit holds the editor this is a SILENT
            // skip, ahead of every other guard and of any write. FB already wrote this content through the ordered
            // queue; a write from here would land after it. Step 7's own bibliography refresh reaches this hook, so
            // it must neither write, nor assert, nor report.
            guard let editorState, editorState.activeLifecycle == nil else { return }
            // Same three guards as the sibling debounced re-parse this flush stands in for
            // (ViewNotificationModifiers.swift's blockReparseTask, contentState/editorMode/
            // zoomedSectionId check): both write the editor's text into the block table, so
            // both must refuse to run mid-transition (drag reorder, zoom, project switch,
            // editor-mode switch) against stale or partial editorState.content.
            guard editorState.contentState == .idle,
                  editorState.editorMode == .source,
                  editorState.zoomedSectionId == nil else { return }
            // Hardening: verify this update is still for the currently-open project. Checked
            // against editorState.currentProjectId specifically -- not
            // documentManager.projectId -- because currentProjectId (together with
            // editorState.projectDatabase) is exactly what flushContentToDatabase() itself
            // reads; guarding on a different property here could diverge from what the flush
            // actually operates on during a project switch.
            // (final final has no document concept distinct from project -- one project IS
            // one document, DocumentManager.openProject is the only switch mechanism -- so
            // this also covers the "document switch" case.) Making this explicit rather than
            // relying on ordering of state resets during a project switch.
            //
            // NOTE this guard is a no-op during a project-switch flush specifically:
            // `editorState.currentProjectId` isn't reassigned to the NEW project until
            // `configureForCurrentProject()` runs later in the open tail
            // (`configureAndPushContentAfterProjectSwitch`), so it
            // still holds the OLD (matching) project id for this entire call. That's exactly
            // why `overrideContent` below matters -- this closure WILL run during a project
            // switch, on every occasion its other three guards pass.
            guard editorState.currentProjectId == scheduledForProjectId else { return }
            // In the ordinary (non-switch) case, editorState.content is already fresh here --
            // CodeMirror pushes via a 50ms debounce and the bibliography debounce is scheduled
            // from the same onChange handler that sets editorState.content, so it can never be
            // scheduled from stale content there.
            //
            // During a project-switch flush, though, `editorState.content` is DELIBERATELY
            // stale for the entire duration of the lifecycle window -- see
            // `EditorViewState.switchInProgressContent`'s doc comment for the mechanism (review
            // round 1 finding: this closure used to call `flushContentToDatabase()` with no
            // override, reading that deliberately-stale property, which clobbered the fresh
            // blocks the old `flushAllPendingContent()` had just written moments earlier with a
            // second, stale `replaceBlocks`). `overrideContent`, which the old
            // `ContentView.handleProjectOpened()` threaded here via `EditorViewState.
            // flushPendingBibliographyAndFootnoteSync(overrideContent:)` ->
            // `BibliographySyncService.flushPendingSync(overrideContent:)` ->
            // `performBibliographyUpdate(..., overrideContent:)` (no production caller does since
            // 3a-1b; the guard above skips this hook while a lifecycle is armed), was the SAME
            // freshly-fetched value `flushAllPendingContent()` already flushed, so this call either
            // no-ops-equivalently re-flushes the identical content or (outside a project
            // switch, where callers pass `nil`) falls back to reading `editorState.content`
            // exactly as before. The write also cancels the pending debounced re-parse task,
            // closing the other half of the race.
            //
            // Phase 4a (t-94369a83, plan v2 section 1(f), judge M5/C3): the write goes through the
            // per-block Markdown writer (`MarkdownBlockWriter.writeNow`), ON THE QUEUE: the rebuild
            // that follows reads the rows, so the user's typing must land first and in order, and a
            // direct whole-document write would re-create every paragraph id on every citation edit.
            // `writeNow` waits for the write already in flight, and that wait can span a lifecycle
            // arming, a mode change, a zoom or a project switch, so it RE-CHECKS every guard above
            // after the wait (the same `guardsHold` below) and writes nothing if one failed. It falls
            // back to today's `flushContentToDatabase(overrideContent:)` when there is no writer, and
            // when the open-fence guard trips (the text ends inside an open code fence or `$$`
            // block: a per-block write would skip, and the rebuild would then read rows without the
            // user's text and could push them over what is on screen). The legacy UI-test flag
            // (`FF_UI_TESTING_MD_LEGACY_REPARSE`) always takes that fallback.
            //
            // Deliberately does NOT call pushBlockIds(for:) afterward, unlike
            // flushLiveContentToDatabase's other callers (see EditorViewState+Zoom.swift's doc
            // comment on that method): that follow-up exists to keep BlockSyncService's
            // incremental block-id tracking in sync with the fresh ids a full re-parse
            // assigns. BlockSyncService's WebView is only ever assigned to the Milkdown
            // editor, so Source Mode has no JS-side block-id tracking for it to update --
            // there is nothing for pushBlockIds to re-sync here.
            //
            // Logged here rather than in BibliographySyncService.performBibliographyUpdate:
            // this is the one place that actually knows a flush is happening (past all the
            // guards above) -- logging at the call site there would fire unconditionally,
            // including on the WYSIWYG path where this closure no-ops.
            DebugLog.log(.bib, "[BibSync] flushing live editor content to blocks before bibliography write")
            guard editorState.markdownWriter.isEnabled else {
                editorState.flushContentToDatabase(overrideContent: overrideContent)
                return
            }
            let outcome = await editorState.markdownWriter.writeNow(
                overrideContent: overrideContent,
                editorState: editorState,
                guardsHold: { [weak editorState] in
                    guard let editorState else { return false }
                    return Self.bibliographyFlushGuardsHold(editorState, scheduledForProjectId: scheduledForProjectId)
                },
                refire: { [weak editorState] in
                    guard let editorState else { return }
                    editorState.lifecycleHost?.scheduleSourceModeReparse(editorState.content)
                }
            )
            if outcome == .fallBackToDirectWrite {
                editorState.flushContentToDatabase(overrideContent: overrideContent)
            }
        }
    }

    /// Every guard of the bibliography flush hook, as one answer: no lifecycle holds the editor, the content is idle, the
    /// editor is in Markdown and not zoomed, and it is still on the project the update was scheduled for. The hook checks it
    /// once up front (as five separate guards) and `MarkdownBlockWriter.writeNow` checks it AGAIN after waiting for the write
    /// already in flight (judge M5).
    @MainActor
    static func bibliographyFlushGuardsHold(_ editorState: EditorViewState, scheduledForProjectId: String) -> Bool {
        editorState.activeLifecycle == nil
            && editorState.contentState == .idle
            && editorState.editorMode == .source
            && editorState.zoomedSectionId == nil
            && editorState.currentProjectId == scheduledForProjectId
    }

    /// Builds the closure assigned to `editorState.onSectionsUpdated`.
    private func makeSectionsUpdatedHandler() -> () -> Void {
        { [weak editorState, weak sectionSyncService] in
            guard let editorState = editorState,
                  let sectionSyncService = sectionSyncService else { return }

            if DebugLog.isEnabled(.outline) {
                let hasViolations = Self.hasHierarchyViolations(in: editorState.sections)
                DebugLog.log(.outline, "[onSectionsUpdated] contentState=\(editorState.contentState), "
                    + "zoomed=\(editorState.zoomedSectionIds != nil), hasViolations=\(hasViolations)")
            }

            // Skip during content transitions (drag, zoom, etc.)
            guard editorState.contentState == .idle else { return }

            // Skip hierarchy enforcement while zoomed to prevent feedback loop:
            // User adds headings → DB observation fires → enforcement modifies levels →
            // rebuilds content → content change triggers block reparse → loop.
            // After zoom-out, zoomedSectionIds is nil so enforcement resumes naturally.
            guard editorState.zoomedSectionIds == nil else { return }

            // Check and enforce hierarchy constraints if violations exist
            if Self.hasHierarchyViolations(in: editorState.sections) {
                // P3 §4d (undo-mode-switch-focus second timing gap, WYSIWYG mirror, M1
                // fix): this is the REAL re-trigger mechanism for WYSIWYG mode.
                // BlockSyncService polls independently of SectionSyncService (own ~2s
                // timer, own doc-vs-DB diff) -- undoing a heading-level correction in
                // Milkdown reverts the ProseMirror doc immediately, but the DB (and
                // therefore editorState.sections, and THIS handler firing) only catches up
                // once BlockSyncService's next poll pushes that reverted level, ~2s later.
                // Without this guard, that poll's own DB write would re-trigger
                // hasHierarchyViolations here and immediately re-run the exact correction
                // the user just undid -- well before SectionSyncService.contentChanged ever
                // sees anything, since nothing has touched editorState.content at this
                // point. This is the hierarchy consumer: consumes its OWN one-shot flag
                // (`consumedByHierarchy`) on the shared token, independent of
                // ViewNotificationModifiers.handleContentChange's `consumedByContentSync`
                // flag -- the whole reason the earlier plain-Bool design failed here is
                // that consumer fires almost immediately (clearing a shared Bool) while
                // THIS consumer doesn't fire until the ~2s poll catches up. No content-hash
                // check here (unlike the content-sync consumer): this handler operates on
                // editorState.sections, derived from DB blocks, with no comparable markdown
                // string at this call site to hash against -- the TTL (which exceeds the
                // poll interval) plus explicit invalidation on a genuinely new edit is the
                // staleness guard instead.
                if var token = editorState.reconcileSuppression, !token.isExpired, !token.consumedByHierarchy {
                    token.consumedByHierarchy = true
                    editorState.reconcileSuppression = token.isFullyConsumed ? nil : token
                    DebugLog.log(.sync, "[onSectionsUpdated] hierarchy re-enforcement suppressed (content just undone)")
                    return
                }
                Task { @MainActor in
                    await Self.enforceHierarchyAsync(
                        editorState: editorState,
                        syncService: sectionSyncService
                    )
                }
            }
        }
    }

    /// Sort-order normalization, image-block dedup, and word-count recompute.
    /// Must run before `startObserving*` -- see the sort-order comment below.
    private func runProjectMaintenance(db: ProjectDatabase, pid: String) {
        // Check and normalize duplicate sort orders BEFORE starting observation
        do {
            let existingBlocks = try db.fetchBlocks(projectId: pid)
            if !existingBlocks.isEmpty {
                let sortOrders = existingBlocks.map { $0.sortOrder }
                let uniqueCount = Set(sortOrders).count
                if uniqueCount < sortOrders.count {
                    let detail = "(\(sortOrders.count) blocks, \(uniqueCount) unique)"
                    DebugLog.log(.lifecycle, "[ContentView] Duplicate sortOrders detected \(detail). Normalizing...")
                    try db.normalizeSortOrders(projectId: pid)
                }
            }
        } catch {
            DebugLog.log(.lifecycle, "[ContentView] Error checking/normalizing sort orders: \(error)")
        }

        // Clean up duplicate adjacent image blocks (from content push race condition)
        do {
            try db.deduplicateAdjacentImageBlocks(projectId: pid)
        } catch {
            DebugLog.log(.lifecycle, "[ContentView] Error deduplicating image blocks: \(error)")
        }

        // Recompute stored block word counts under current rules. Bundled fixtures
        // (getting-started.ff) and any user project saved before the rules changed
        // have stale wordCount values on disk; this sweep brings them forward
        // without bumping `updatedAt`. Idempotent: no writes when counts match.
        do {
            let summary = try db.recomputeStoredBlockWordCounts(projectId: pid)
            // Unconditional print — the user needs to see this to verify the migration
            // ran, even when `DebugLog.enabled` is narrow or we ever ship a release build.
            let counts = "\(summary.totalBlocks) blocks, \(summary.changedBlocks) updated"
            let totals = "total \(summary.oldTotal) -> \(summary.newTotal)"
            DebugLog.always("[WordCount] recomputed \(counts), \(totals)")
        } catch {
            DebugLog.always("[WordCount] recompute failed: \(error)")
        }
    }

    /// Load document goal settings into editorState.
    private func applyDocumentGoalSettings() {
        if let goalSettings = try? documentManager.loadDocumentGoalSettings() {
            editorState.documentGoal = goalSettings.goal
            editorState.documentGoalType = goalSettings.goalType
            editorState.excludeBibliography = goalSettings.excludeBibliography
        }
    }

    /// Load content from blocks (or fall back to legacy content table).
    ///
    /// Internal (not private) so a test can pin the N2 Import path (t-94369a83 3a-1b round C8b): an imported project is
    /// created with its Markdown in the content table and NO blocks, and the NEW ContentView that Import from Getting
    /// Started builds finds it here, on mount, through the legacy-content branch below.
    func loadInitialContent(db: ProjectDatabase, pid: String) {
        do {
            // B10: this used to re-run `deleteOrphanedFootnoteDefinitions` on EVERY
            // project open. Demoted to a one-time migration (`v16_notes_orphan_sweep`,
            // ProjectDatabase.swift) -- B5 already made the sweep an allowlist rather
            // than a denylist, so there is no correctness reason left to keep re-running
            // it on every open rather than once, ever, per project.
            let existingBlocks = try db.fetchBlocks(projectId: pid)

            if !existingBlocks.isEmpty {
                // Blocks exist - assemble markdown from blocks. assembleMarkdownForEditor
                // (not plain assembleMarkdown): editorState.content must carry the
                // bibliography-end terminator when the doc ends in bibliography content —
                // see BlockParser.bibliographyEndMarker's doc comment.
                editorState.content = BlockParser.assembleMarkdownForEditor(from: existingBlocks)
                DebugLog.log(.lifecycle, "[LOAD] Assembled \(existingBlocks.count) blocks -> content length=\(editorState.content.count)")
                // INTENTIONAL REPLACEMENT: initial project load -- no prior local edits to
                // protect, and the freshly-opened editor must show the real document.
                updateSourceContentIfNeeded(intentionalReplacement: true)
            } else {
                // No blocks yet - load from legacy content table and parse into blocks
                let savedContent = try documentManager.loadContent()

                if let savedContent = savedContent, !savedContent.isEmpty {
                    // Parse content into blocks for the new system
                    // Preserve existing section metadata if available
                    let existingSections = try db.fetchSections(projectId: pid)
                    var metadata: [String: SectionMetadata] = [:]
                    for section in existingSections {
                        metadata[section.title] = SectionMetadata(from: section)
                    }

                    // Pass `savedContent` UNSTRIPPED so a genuine legacy
                    // `<!-- ::auto-bibliography:: -->` marker still fires BlockParser.parse's
                    // tier 1 -- with tier 3 deleted, a legacy document has no other evidence to
                    // select the bibliography heading on (it predates the terminator too, so
                    // tier 2 can't fire either). `strippingBibliographyMarkerFromBlocks: true`
                    // removes the marker literal from each resulting block's own
                    // markdownFragment, so it never leaks into the editor from here.
                    // C5: threads the DB-resolved Notes title (mirrors `bibliographyHeaderName`'s
                    // own default-`ExportSettings.load()` treatment) so an already-recognized,
                    // non-default-titled Notes heading survives this initial-load reparse too --
                    // see `fetchNotesHeadingTitle`'s doc comment.
                    let blocks = BlockParser.parse(
                        markdown: savedContent,
                        projectId: pid,
                        existingSectionMetadata: metadata.isEmpty ? nil : metadata,
                        strippingBibliographyMarkerFromBlocks: true,
                        notesHeaderName: try? db.fetchNotesHeadingTitle(projectId: pid)
                    )

                    // editorState.content MUST be the STRIPPED content -- assembleMarkdownForEditor
                    // is built from the parsed blocks' own (already marker-stripped)
                    // markdownFragments, so it never carries the raw marker literal into
                    // Milkdown/the editor. Only the parse() call above uses unstripped text.
                    //
                    // Assigned BEFORE the throwing `db.replaceBlocks` call below, deliberately:
                    // `assembleMarkdownForEditor(from: blocks)` only needs the already-computed
                    // `blocks` array, not a successful database write. If `replaceBlocks` throws,
                    // the catch block at the bottom of this function only logs -- so leaving this
                    // assignment on the far side of that call would show the user an EMPTY
                    // document instead of their actual (just-parsed) content.
                    editorState.content = BlockParser.assembleMarkdownForEditor(from: blocks)
                    // INTENTIONAL REPLACEMENT: initial project load (legacy content path).
                    updateSourceContentIfNeeded(intentionalReplacement: true)

                    try db.replaceBlocks(blocks, for: pid)
                } else {
                    editorState.content = ""
                    // INTENTIONAL REPLACEMENT: initial project load (empty-document path).
                    updateSourceContentIfNeeded(intentionalReplacement: true)
                }
            }
            // Phase 4a: the editor's text was just loaded from (or written to) the stored rows, in all three branches: the
            // Markdown per-block writer compares with the stored rows from here. (CodeMirror's `onWebViewReady` and every
            // later Swift push into it do the same; calling it more often than needed only costs one re-align.)
            editorState.markdownWriter.noteLoaded(text: editorState.content, pid: pid)
        } catch {
            DebugLog.log(.lifecycle, "[ContentView] Failed to load content: \(error.localizedDescription)")
        }
    }

    /// Connect to Zotero (via Better BibTeX) - just verifies availability
    /// Search happens on-demand via JSON-RPC when user types /cite
    func connectToZotero() async {
        let zotero = ZoteroService.shared

        do {
            try await zotero.connect()
            DebugLog.log(.zotero, "[ContentView] Zotero/BBT is available for citation search")
        } catch {
            DebugLog.log(.zotero, "[ContentView] Zotero connection failed: \(error.localizedDescription)")
            // Silent failure - Zotero is optional dependency
        }
    }

    /// The view-only middle of a project switch, between the sequence's two publishes. Returns as
    /// soon as the content push has been STARTED (as before the sequence existed: the push is a
    /// separate un-awaited task); `publishAfterContent` is called as that task's last step, or at
    /// the end of the Source-mode branch.
    ///
    /// Called by the lifecycle's open tail only (t-94369a83 3a-1b rounds C5b and C8b; the old `handleProjectOpened`
    /// is gone). The open tail RETIRES the old project's writer (P6), so in Markdown mode it must also give the
    /// block-sync service a writer for the new project (plan section 4.4 open-tail step 8: `reconfigure` runs in
    /// BOTH modes; only the content push and `startPolling` stay Rich-Text-only).
    func configureAndPushContentAfterProjectSwitch(
        publishAfterContent: @escaping @MainActor () -> Void
    ) async {
        await configureForCurrentProject()

        // editorState.suppressBibliographyRebuildsDuringSwitch is armed by the open tail
        // (`runOpenTail`) before this function runs (see that property's doc comment) -- these remaining resets
        // still belong here, discarding any OTHER pending-rebuild flag a mid-switch
        // notification may have set via handleBibliographySectionChanged's
        // zoomed/contentState-busy guards.
        editorState.pendingBibliographyRebuild = false
        editorState.pendingBibliographyRebuildAfterZoom = false
        editorState.pendingNotesRebuild = false
        editorState.pendingFootnoteLabels.reset()

        // Reconfigure BlockSyncService with new DB (weak WebView ref still valid). Markdown mode here (the old writer
        // was retired); Rich Text reconfigures in the branch below.
        if editorState.editorMode == .source,
           let db = documentManager.projectDatabase,
           let pid = documentManager.projectId {
            await blockSyncService.reconfigure(database: db, projectId: pid)
        }
        if editorState.editorMode == .wysiwyg,
           let db = documentManager.projectDatabase,
           let pid = documentManager.projectId {
            await blockSyncService.reconfigure(database: db, projectId: pid)
            Task {
                if let result = fetchBlocksWithIds() {
                    // Sync editorState.content to prevent polling from overwriting the atomic push
                    editorState.content = result.markdown
                    // INTENTIONAL REPLACEMENT: project (re)open/restore. (Guarded by
                    // editorMode == .wysiwyg above, so today this is a no-op --
                    // updateSourceContentIfNeeded itself only acts in Source mode -- but
                    // classified for correctness if that guard ever changes.)
                    updateSourceContentIfNeeded(intentionalReplacement: true)
                    await blockSyncService.setContentWithBlockIds(
                        markdown: result.markdown, blockIds: result.blockIds,
                        imageMeta: result.imageMeta, detectPausedEdits: false,
                        expectedBlocks: result.expectedBlocks,
                        managedBlockIds: result.managedBlockIds)
                }
                editorState.isResettingContent = false
                // End-of-switch point 1 of 3 (round 4): the WYSIWYG branch's own async
                // content-push settles here. See
                // EditorViewState.suppressBibliographyRebuildsDuringSwitch's doc comment for
                // why the window closes exactly where isResettingContent does, not on a
                // separate timer.
                editorState.suppressBibliographyRebuildsDuringSwitch = false
                blockSyncService.startPolling()
                // Scroll to top after content push settles
                try? await Task.sleep(for: .milliseconds(100))
                findBarState.activeWebView?.evaluateJavaScript(
                    "window.scrollTo({top: 0, behavior: 'instant'})"
                ) { _, _ in }
                // Last step: the new content is in, so tell the editors the final display state.
                publishAfterContent()
            }
            // Watchdog: ensure isResettingContent is cleared even if JS call hangs
            Task {
                try? await Task.sleep(for: .seconds(3))
                if editorState.isResettingContent {
                    DebugLog.log(.lifecycle, "[handleProjectOpened] WATCHDOG: isResettingContent stuck, forcing clear")
                    editorState.isResettingContent = false
                }
                // End-of-switch point 2 of 3 (round 4), hard backstop: unconditional, not
                // gated on the `if` above -- guarantees the suppression window is bounded to
                // at most ~3s even in the pathological case where point 1 above never ran
                // (e.g. the content-push Task itself never reached its own clear) and
                // isResettingContent was already false for some other reason by the time
                // this watchdog fires.
                editorState.suppressBibliographyRebuildsDuringSwitch = false
            }
        } else {
            editorState.isResettingContent = false
            // End-of-switch point 3 of 3 (round 4): the Source-mode branch settles
            // synchronously, right here -- no async content-push Task exists on this path.
            editorState.suppressBibliographyRebuildsDuringSwitch = false
            if editorState.editorMode == .source {
                // Mirrors the WYSIWYG branch's explicit window.scrollTo({top: 0}) reset above.
                // Before setContent()'s diff-based rewrite, Source Mode's whole-document
                // replace incidentally reset scroll to the top on every project switch, as a
                // side effect of CodeMirror mapping any selection inside a fully-replaced
                // range to position 0. The minimal-diff push no longer guarantees that when
                // the old and new project's content happen to share a leading prefix, so make
                // the reset explicit. Reuses the same editorState.scrollToOffset mechanism
                // already wired for annotation/footnote jump-to-offset requests --
                // CodeMirrorEditor.swift's updateNSView applies it right after the content
                // push, in the same pass, once isResettingContent flips back to false above.
                editorState.scrollToOffset = 0
            }
            publishAfterContent()  // no asynchronous push on this branch
        }
    }

    /// The `.projectDidClose` post of the GETTING STARTED close (`LifecycleEntry.gettingStartedCloseUserInfo`; every
    /// other close is a managed lifecycle whose keyed post `LegacyProjectNotifications` ignores). See
    /// `closeGettingStartedProject()`.
    func handleProjectClosed() {
        Task { await closeGettingStartedProject() }
    }

    /// Closing Getting Started (t-94369a83 3a-1b round C8b). It is an ephemeral playground, re-copied from the app
    /// bundle each time it opens, so there is nothing to save, no automatic version and no lifecycle: no flush, no
    /// fetch, no token, no barrier. `ProjectCommands.close` has already closed it in `DocumentManager`; what is left
    /// is this view's own state. That is exactly the managed close tail without its automatic version (the throwaway
    /// token says Getting Started, which the tail reads to skip it, N1) -- stop observing, cancel and reset the
    /// sync services, retire the writer, reset the editor state, then `onProjectClosed` (the picker) -- plus
    /// stopping the poll timer, which a managed lifecycle stops at arm. Nothing here reads `DocumentManager` for the
    /// closing project (N7): by now it holds none.
    ///
    /// This replaces the old `performProjectClose` (flush, fetch, bibliography flush, backup, reset), which had no
    /// other caller once Close Project, Open, Open Recent, Save As, Finder open, New Project, Import, Repair and
    /// Help > Getting Started all went through `LifecycleEntry.run`. Getting Started to Getting Started is not a
    /// close at all (`ProjectCommands.openGettingStarted`).
    func closeGettingStartedProject() async {
        blockSyncService.stopPolling()
        let token = LifecycleToken(kind: .close, wasGettingStarted: true)
        await runCloseTail(token: token, callOnProjectClosed: true)
    }

    // handleSaveVersion() -- Save Version handling -- lives in ContentView+VersionHistory.swift, moved there to
    // keep this file under SwiftLint's file_length limit.
}
