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
            await configureForCurrentProject()
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
        footnoteSyncService.configure(database: db, projectId: pid)
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
    private func makeBibliographyFlushHandler() -> (_ scheduledForProjectId: String) async -> Void {
        { [weak editorState] scheduledForProjectId in
            // Same three guards as the sibling debounced re-parse this flush stands in for
            // (ViewNotificationModifiers.swift's blockReparseTask, contentState/editorMode/
            // zoomedSectionId check): both do the same wholesale replaceBlocks() write, so
            // both must refuse to run mid-transition (drag reorder, zoom, project switch,
            // editor-mode switch) against stale or partial editorState.content.
            guard let editorState,
                  editorState.contentState == .idle,
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
            guard editorState.currentProjectId == scheduledForProjectId else { return }
            // editorState.content is already fresh here -- CodeMirror pushes via a 50ms
            // debounce and the bibliography debounce is scheduled from the same onChange
            // handler that sets editorState.content, so it can never be scheduled from
            // stale content. flushContentToDatabase() also cancels the pending debounced
            // re-parse task, closing the other half of the race.
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
            editorState.flushContentToDatabase()
        }
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
    private func loadInitialContent(db: ProjectDatabase, pid: String) {
        do {
            // Clean up orphaned footnote definitions from previous sessions before assembling
            try db.write { database in
                try FootnoteSyncService.deleteOrphanedFootnoteDefinitions(db: database, projectId: pid)
            }

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
                    let blocks = BlockParser.parse(
                        markdown: savedContent,
                        projectId: pid,
                        existingSectionMetadata: metadata.isEmpty ? nil : metadata,
                        strippingBibliographyMarkerFromBlocks: true
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

    /// Handle project opened notification
    ///
    /// N9 (Phase B remediation plan): the `isRestore` parameter this function used to take is
    /// gone -- every `.projectDidOpen` post site (grepped and confirmed) passes bare
    /// `object: nil`, so `notification.userInfo?["isRestore"]` was always `nil`/`false` at the
    /// one caller (`ViewNotificationModifiers.swift`'s `withFileNotifications`), meaning
    /// `isRestore` was already dead on arrival: version-history restores are routed entirely
    /// through `StructuralUndoController`'s own audited sequence today (plan §4.4), not through
    /// this notification at all.
    func handleProjectOpened() async {
        // Barrier (plan §4.5, Phase 5 backlog): a project switch must invalidate the unified
        // undo timeline -- it's per-project in-memory state (plan §4.1/§4.8), and
        // `unifiedUndoService` is a single `@State` instance owned by ContentView, so it
        // persists across a project switch within the SAME window rather than being recreated
        // per-project. Real justification (MF-6, Phase 5 review round -- corrected: an earlier
        // draft of this comment cited stale Undo/Redo MENU ENABLEMENT, which isn't actually the
        // hazard -- `UndoRedoCommands.canUndo`/`canRedo` are almost always `true` anyway via
        // `mayHaveTextUndo`, so the menu's enabled/disabled look barely changes either way):
        // this call is what makes `StructuralUndoController`'s in-flight generation/epoch check
        // (MF-2, `performStructuralOp`/`performUndo`/`performRedo`) actually fire. Without it, a
        // structural op already in flight when the user switches projects -- deliberately NOT
        // aborted here (`invalidateAll` is intentionally unguarded by `isPerforming`; do not
        // "fix" this by adding one -- see that epoch mechanism's doc comment for why skipping
        // the barrier instead would be worse) -- could still finish and record its entry,
        // re-seeding the NEW project's (now-current)
        // timeline with an entry that actually describes a mutation performed against the OLD
        // project's database. Runs first, before any of the flush/reset work below, so a late
        // in-flight structural op's epoch check has the earliest possible chance to catch this.
        unifiedUndoService.invalidateAll(reason: "project switch")

        // Stop block polling FIRST — prevents poll timer from firing during
        // the await suspension points in flushAllPendingContent() and writing
        // conflicting data to the database.
        blockSyncService.stopPolling()

        // Flush all pending content to OLD project's database before switching.
        await flushAllPendingContent()

        // Flush pending debounced bibliography/footnote updates before the reset()
        // calls below discard them. Runs independent of flushAllPendingContent()'s
        // editor-content state (pending sync lives in the services themselves,
        // captured at debounce-schedule time) and is bounded to ~3s via the same
        // helper the quit path uses, so a hung Zotero/BBT fetch can't stall a
        // project switch indefinitely.
        await editorState.flushPendingBibliographyAndFootnoteSync()

        // Stop remaining services
        editorState.stopObserving()
        blockSyncService.cancelPendingSync()
        sectionSyncService.cancelPendingSync()
        annotationSyncService.cancelPendingSync()
        bibliographySyncService.reset()
        footnoteSyncService.reset()

        // Create auto-backup of old project before switching
        await autoBackupService.projectWillSwitch()
        autoBackupService.reset()

        // Set flag to prevent polling from overwriting empty content during reset
        editorState.isResettingContent = true

        // REMOVED: isEditorPreloadReady = false — WebView stays alive to avoid blank screen

        // Reset JS-side transient state (undo history, CAYW, search, block IDs)
        findBarState.activeWebView?.evaluateJavaScript(
            "window.FinalFinal.resetForProjectSwitch()"
        ) { _, _ in }

        // Reset all project-specific state (content, sourceContent, zoom, tasks, etc.)
        editorState.resetForProjectSwitch()

        // Configure for new project
        await configureForCurrentProject()

        suppressNextBibliographyRebuild = true
        pendingBibliographyRebuild = false
        pendingNotesRebuild = false
        pendingFootnoteLabels.reset()

        // Reconfigure BlockSyncService with new DB (weak WebView ref still valid)
        if editorState.editorMode == .wysiwyg,
           let db = documentManager.projectDatabase,
           let pid = documentManager.projectId {
            blockSyncService.reconfigure(database: db, projectId: pid)
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
                        expectedBlocks: result.expectedBlocks)
                }
                editorState.isResettingContent = false
                blockSyncService.startPolling()
                // Scroll to top after content push settles
                try? await Task.sleep(for: .milliseconds(100))
                findBarState.activeWebView?.evaluateJavaScript(
                    "window.scrollTo({top: 0, behavior: 'instant'})"
                ) { _, _ in }
            }
            // Watchdog: ensure isResettingContent is cleared even if JS call hangs
            Task {
                try? await Task.sleep(for: .seconds(3))
                if editorState.isResettingContent {
                    DebugLog.log(.lifecycle, "[handleProjectOpened] WATCHDOG: isResettingContent stuck, forcing clear")
                    editorState.isResettingContent = false
                }
            }
        } else {
            editorState.isResettingContent = false
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
        }
    }

    /// Handle project closed notification
    func handleProjectClosed() {
        Task {
            await performProjectClose()
        }
    }

    /// Actually close the project and reset state
    func performProjectClose() async {
        // Flush pending content synchronously before closing.
        // editorState.content is current (JS 50ms debounce has fired by button click time).
        await editorState.flushAllSync()

        // Create auto-backup before closing if there are unsaved changes (not for Getting Started)
        if !documentManager.isGettingStartedProject {
            await autoBackupService.projectWillClose()
        }

        // Stop observation and services FIRST to prevent any further syncs
        editorState.stopObserving()
        blockSyncService.stopPolling()
        blockSyncService.cancelPendingSync()
        sectionSyncService.cancelPendingSync()
        annotationSyncService.cancelPendingSync()
        bibliographySyncService.reset()
        footnoteSyncService.reset()
        autoBackupService.reset()

        // Reset all project-specific state (content, sourceContent, zoom, tasks, etc.)
        editorState.resetForProjectSwitch()

        // Notify parent to show picker
        onProjectClosed?()
    }

    // MARK: - Version History Handlers

    /// Handle save version command (Cmd+Shift+S)
    func handleSaveVersion() async {
        guard let db = documentManager.projectDatabase,
              let pid = documentManager.projectId else {
            DebugLog.log(.lifecycle, "[ContentView] Cannot save version: no project open")
            return
        }

        // Flush the freshest possible WebView content into the block table before the
        // snapshot reads it -- the same staleness gap fixed for export (incremental
        // block-sync diff alone can silently drop a pure block move). See
        // EditorViewState+Zoom.swift's flushLiveContentToDatabase(currentContent:).
        await editorState.flushLiveContentToDatabase {
            await editorState.blockSyncService?.fetchContentFromWebView()
        }

        // Ensure sections are synced before snapshot (debounce may not have fired yet).
        // fromEditorChange: true — by the time this fires the content is definitionally the
        // user's real, settled state (not a pre-round-trip programmatic sync), so a real edit
        // immediately followed by Save Version must still reach Getting Started edit-detection.
        await sectionSyncService.syncNow(editorState.content, fromEditorChange: true)

        let name = saveVersionName.isEmpty ? nil : saveVersionName
        let service = SnapshotService(database: db, projectId: pid)

        do {
            if let versionName = name {
                let snapshot = try service.createManualSnapshot(name: versionName)
                DebugLog.log(.lifecycle, "[ContentView] Created manual snapshot: \(snapshot.displayName)")
            } else {
                if let snapshot = try service.createAutoSnapshot() {
                    DebugLog.log(.lifecycle, "[ContentView] Created auto snapshot: \(snapshot.id)")
                } else {
                    DebugLog.log(.lifecycle, "[ContentView] Auto snapshot skipped: content unchanged")
                }
            }
        } catch {
            DebugLog.log(.lifecycle, "[ContentView] Failed to create snapshot: \(error)")
        }

        saveVersionName = ""
    }

    // MARK: - Content Flush Helpers

    /// Fetch latest content directly from WebView, bypassing JS 50ms debounce.
    /// Returns nil if WebView is unavailable, JS call fails, or 2s timeout elapses.
    private func fetchContentFromWebView() async -> String? {
        guard let webView = findBarState.activeWebView else { return nil }
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async {
                        webView.evaluateJavaScript("window.FinalFinal.getContent()") { result, error in
                            if let error { DebugLog.log(.lifecycle, "[ContentView] fetchContentFromWebView JS error: \(error)") }
                            continuation.resume(returning: result as? String)
                        }
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Flush all pending content to DB before project switch/close.
    /// Must be called BEFORE resetForProjectSwitch() which clears editorState.content.
    private func flushAllPendingContent() async {
        // 1. Fetch fresh content from WebView (catches edits within JS 50ms debounce)
        if let freshContent = await fetchContentFromWebView(), !freshContent.isEmpty {
            editorState.content = freshContent
        }
        guard !editorState.content.isEmpty else { return }

        // 2. Flush blocks to DB (synchronous — re-parses content into blocks and writes)
        editorState.flushContentToDatabase()

        // 3. Flush section metadata (immediate write, bypasses 500ms debounce)
        await sectionSyncService.syncNow(editorState.content)

        // 4. Flush annotation positions (skip when zoomed — content is a subset)
        if editorState.zoomedSectionId == nil {
            await annotationSyncService.syncNow(editorState.content)
        }

        DebugLog.log(.lifecycle, "[ContentView] flushAllPendingContent completed")
    }
}
