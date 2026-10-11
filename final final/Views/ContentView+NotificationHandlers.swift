//
//  ContentView+NotificationHandlers.swift
//  final final
//
//  Notification handlers extracted from body's modifier-chain closures to keep
//  type-checking fast: bibliography/notes rebuilds, content-state transitions,
//  and zoom-out resync. The footnote-insertion handlers live in
//  ContentView+FootnoteHandlers.swift.
//

import SwiftUI

extension ContentView {
    /// UI-test-only: widens a rebuild handler's flush window (the gap between
    /// `fetchBlocksWithIds()` reading the rebuilt content and that content being pushed back
    /// to the editor) by `TestMode.uiTestingRebuildPushDelayMilliseconds`, so an e2e test can
    /// type into the window deterministically -- proving a rebuild's own push can overwrite
    /// words typed during it (t-6a0d195d). A no-op whenever that value is 0, which is always
    /// true outside a UI test that explicitly sets `FF_UI_TESTING_REBUILD_PUSH_DELAY_MS`; see
    /// that property's doc comment.
    @MainActor
    func holdRebuildFlushWindowForUITesting() async {
        let delayMs = TestMode.uiTestingRebuildPushDelayMilliseconds
        guard delayMs > 0 else { return }
        // Round-3 review (#20): a log marker with real wall-clock bounds, proving the held-open
        // window actually spans the time an e2e test types into it -- not merely trusting that a
        // fixed typing cadence PROBABLY lands inside a fixed delay. NSLog (not DebugLog, whose
        // `.sync` category is disabled by default -- see DebugLog.enabled) so this always reaches
        // the unified log stream the XCUITest run captures, right alongside the matching
        // "typed chunk" markers RebuildFlushTypingRaceE2ETests.swift logs from its own process.
        NSLog("[RebuildFlushRace] hold-window START delayMs=\(delayMs)")
        try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
        NSLog("[RebuildFlushRace] hold-window END")
    }

    /// Bibliography section was updated in the database - rebuild editor content
    @MainActor
    func handleBibliographySectionChanged() {
        DebugLog.log(.bib, {
            let contentIsEmpty = editorState.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return "[CV:bibNotif] contentState=\(editorState.contentState) suppress=\(editorState.suppressBibliographyRebuildsDuringSwitch) "
                + "pendingBib=\(editorState.pendingBibliographyRebuild) content.isEmpty=\(contentIsEmpty)"
        }())
        // Skip if zoomed into a section (bibliography update only affects full document view).
        // Deferred, not dropped: a rename's retitle already landed in the block table before
        // this notification fired (see ContentView's `.bibliographyHeaderNameChanged`
        // observer), so the zoomed editor is now showing a stale heading until this rebuild
        // actually runs. Drained on zoom-exit by `handleZoomStateCleared()` (must-fix 7, judge
        // round) -- a SEPARATE flag from `editorState.pendingBibliographyRebuild` below, which is
        // only drained by the shared idle-transition chain in `handleContentStateChange` and
        // would starve the notes/footnote-label queues that already share that chain if reused
        // here.
        guard editorState.zoomedSectionId == nil else {
            editorState.pendingBibliographyRebuildAfterZoom = true
            return
        }
        // Skip during any content transition (including editor switch). Also while a close / project switch /
        // quit holds the editor (t-94369a83 3a-1b, round C4, item 23): nothing may START a rebuild inside its
        // window, so the request is deferred, not dropped (a rebuild that already runs is awaited by the
        // lifecycle's step 3). A cancelled lifecycle re-posts it (round C5a); a completed one drops it (C5b).
        guard editorState.contentState == .idle, editorState.activeLifecycle == nil else {
            editorState.pendingBibliographyRebuild = true
            return
        }
        // Skip rebuild when editor content is empty - no citations exist,
        // so rebuilding from blocks would restore stale content
        guard !editorState.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Skip every bibliography notification for the duration of a project switch (it
        // may fire from the old project's debounced citekey check; before 3a-1b it could also come
        // from the explicit pending-flush call the old `handleProjectOpened()` made). CHECKED, not consumed --
        // round 4 (doc-open-blank-regression): a one-shot flag that resets itself here
        // protects only the FIRST of possibly two mid-switch posts, leaving a second one
        // free to run this handler's own Task below and reopen the blank-pane publish
        // window. See `EditorViewState.suppressBibliographyRebuildsDuringSwitch`'s doc
        // comment for the window's arm/clear points.
        guard !editorState.suppressBibliographyRebuildsDuringSwitch else {
            DebugLog.log(.bib, "[ContentView] bibliographySectionChanged suppressed (project switch in progress)")
            return
        }
        // Atomic content+IDs push to prevent temp ID race condition.
        // Without this, setContent() triggers assignBlockIds() which creates temp IDs,
        // and the 100ms-delayed pushBlockIds() arrives too late — block-sync reports
        // changes with temp IDs, Swift creates new blocks at maxSortOrder+1.
        editorState.contentState = .bibliographyUpdate
        // Finding #1 (Calm_Bibliography, t-7c1d3fd8): mark the instant this bump lands,
        // synchronously and before any Task is spawned, so a routine poll cycle parked
        // mid-flight can keep (not discard) a batch that predates this rebuild by exactly
        // this one transition — see BlockSyncService.checkGenerationGuard's doc comment.
        blockSyncService.beginDatabaseRebuild()
        // This is a synthetic content rebuild, not a mode switch — any cursor position
        // already sitting in cursorPositionToRestore was computed against the
        // pre-rebuild document and is stale by construction. Drop it so the stale
        // mode-switch restore mechanism can't fire later and overwrite whatever
        // cursor placement this rebuild (or a subsequent one) actually wants.
        cursorPositionToRestore = nil
        editorState.isResettingContent = true  // prevent updateNSView → setContent()

        // Registered so the lifecycle save sequence (step 3) can await this rebuild, push included (item 21).
        let rebuildTask: Task<Void, Never> = Task {
            // Force-flush pending JS changes to DB before reading blocks
            if let db = documentManager.projectDatabase, let pid = documentManager.projectId {
                DebugLog.log(.bib, "[CV:bibRebuild] BEFORE poll: \((try? db.fetchBlockCount(projectId: pid)) ?? -1) blocks in DB")
            }
            await blockSyncService.pollBlockChangesNowForDatabaseRebuild()
            if let db = documentManager.projectDatabase, let pid = documentManager.projectId {
                DebugLog.log(.bib, "[CV:bibRebuild] AFTER poll: \((try? db.fetchBlockCount(projectId: pid)) ?? -1) blocks in DB")
            }

            guard let result = fetchBlocksWithIds() else {
                editorState.isResettingContent = false
                editorState.contentState = .idle
                return
            }

            editorState.content = result.markdown  // sidebar sync (won't trigger WKWebView push)
            // DERIVED REFRESH (default): notification-driven bibliography resync -- can fire
            // at arbitrary moments, including mid-typing (the undo-mode-switch-focus root
            // cause scenario). Must go through the settle-window guard, never force through.
            updateSourceContentIfNeeded()

            await holdRebuildFlushWindowForUITesting()

            let merged = await blockSyncService.setContentWithBlockIds(
                markdown: result.markdown, blockIds: result.blockIds,
                imageMeta: result.imageMeta,
                cursorBoundary: result.bibBoundaryIndex,
                cursorBoundaryEnd: result.bibBoundaryEndIndex,
                expectedBlocks: result.expectedBlocks,
                managedBlockIds: result.managedBlockIds,
                preserveUserBlocks: true)
            // t-6a0d195d: the push merges the rebuild's content with whatever the live editor
            // held for user blocks, so the markdown actually pushed can differ from
            // result.markdown (typing in the window between the DB read above and this push
            // landing survives instead of being overwritten). Reflect that back into
            // editorState.content now, while still inside this same notification's handling --
            // NOT the stale, pre-merge value assigned before the push.
            if let merged, merged != result.markdown {
                editorState.content = merged
                // #12 (round-3 review): keep the Markdown-mode source copy from going stale --
                // it was already updated once above from the PRE-merge `result.markdown`; the
                // merge can change what's actually on screen (an in-window edit surviving), so
                // it must run again against the value editorState.content holds now.
                updateSourceContentIfNeeded()
            }
            editorState.isResettingContent = false
            editorState.contentState = .idle

            // The `editorState.content = result.markdown` assignment above happened while
            // contentState == .bibliographyUpdate, so ViewNotificationModifiers.handleContentChange's
            // `guard editorState.contentState == .idle else { return }` silently dropped the
            // onChange(of: editorState.content) firing for it -- neither sectionSyncService nor
            // annotationSyncService ever saw this content. Force both syncs explicitly now that
            // we're back to .idle, rather than leaving the `section` table and annotation
            // positions stale until the user's next keystroke re-triggers onChange.
            // sectionSyncService.syncNow correctly omits `fromEditorChange` (defaults to false)
            // here -- same reasoning as the pre-round-trip programmatic sync in
            // ContentView+ProjectLifecycle.swift:51 (configureForCurrentProject): a
            // notification-driven bibliography regeneration is not a genuine editor edit, so it
            // must not trip Getting-Started edit-detection.
            await sectionSyncService.syncNow(editorState.content)
            await annotationSyncService.syncNow(editorState.content)
        }
        editorState.registerRebuildTask(rebuildTask)
    }

    /// Bibliography heading name preference changed (Export preferences) -- retitle the open
    /// document's own bibliography heading in place, then let the existing
    /// `.bibliographySectionChanged` notification refresh both editors from the updated
    /// block table (`handleBibliographySectionChanged` above already observes it).
    ///
    /// `oldNames` is `[old name from the notification] + the current grace list`: by the time
    /// this notification arrives, `ExportSettingsManager.setBibliographyHeaderName` has
    /// already appended the outgoing name to the grace list in the SAME atomic write that
    /// changed the setting, so the old name below is technically already present in
    /// `previousBibliographyHeaderNames` too -- listing it explicitly is harmless (candidate
    /// matching is a simple `.contains`) and keeps this call correct even if that atomicity
    /// detail ever changes.
    @MainActor
    func handleBibliographyHeaderNameChanged(_ notification: Notification) {
        guard let projectId = documentManager.projectId,
              let database = documentManager.projectDatabase,
              let oldName = notification.userInfo?["oldName"] as? String,
              let newName = notification.userInfo?["newName"] as? String else { return }

        let oldNames = [oldName] + ExportSettingsManager.shared.previousBibliographyHeaderNames
        // See `.bibliographyHeaderNameChanged`'s doc comment (EditorViewState+Types.swift):
        // absent means a genuine settings change, not a reconciliation retry.
        let isReconciliationOnly = notification.userInfo?["isReconciliationOnly"] as? Bool ?? false

        Task {
            await performBibliographyHeaderNameChange(
                database: database, projectId: projectId, oldNames: oldNames, newName: newName,
                isReconciliationOnly: isReconciliationOnly
            )
        }
    }

    /// Must-fix 1 (judge round): the actual rename work, extracted from
    /// `handleBibliographyHeaderNameChanged`'s `Task { ... }` body so it can be awaited
    /// directly by `BibliographyHeaderNameWiringTests` -- same "internal, not private, for
    /// direct testability" shape as `BibliographySyncService.performBibliographyUpdate`.
    ///
    /// Flushes the live editor's text into the block table BEFORE writing the rename, using
    /// the SAME project-id-scoped closure `BibliographySyncService.performBibliographyUpdate`
    /// awaits before its own writes (`bibliographySyncService.flushLiveEditorContentToBlocks`,
    /// wired by `ContentView+ProjectLifecycle.swift`'s `makeBibliographyFlushHandler`) --
    /// without this, a rename landing while Source Mode has a pending, not-yet-flushed edit
    /// races `ViewNotificationModifiers.scheduleFullDocumentReparse`'s 1000ms debounced
    /// re-parse two ways: (a) if the reparse's own `guard contentState == .idle` fires while
    /// this rename's own `handleBibliographySectionChanged` rebuild has set `contentState =
    /// .bibliographyUpdate`, the reparse is silently dropped -- losing that pending edit
    /// outright; (b) even without that race, the reparse's STALE captured content would
    /// overwrite the just-renamed row with pre-rename text once it does fire. Calling the
    /// flush closure first closes both: its write (`MarkdownBlockWriter.writeNow`, or
    /// `flushContentToDatabase()` on its fallback) cancels `blockReparseTask` first, which is
    /// exactly what removes the stale-content write that would otherwise revert the rename.
    /// (Since Phase 4a the per-block fire reads the CURRENT `editorState.content` at fire time,
    /// never the text captured at schedule time, so a surviving schedule can no longer write
    /// pre-rename text; the cancel remains so the fire does not also run a second, needless
    /// compare.)
    ///
    /// `isReconciliationOnly` (default `false`): set when this call was triggered by
    /// `ExportSettingsManager.setBibliographyHeaderName`'s no-op path -- the SETTING isn't
    /// actually changing, this is a self-healing retry against a document that might still be
    /// stuck on an old name after an earlier failed rename (see that method's doc comment).
    /// Controls whether a `.noCandidate` outcome is worth telling the user about:
    /// - On a genuine rename attempt (`isReconciliationOnly == false`), zero matching
    ///   candidates is real, actionable information -- "I looked for a heading to rename and
    ///   found none" -- so it's surfaced via `.bibliographyHeadingRenameFailed`.
    /// - On a reconciliation-only retry, `.noCandidate` and `.alreadyCorrect` are instead the
    ///   EXPECTED, healthy steady state: `.alreadyCorrect` in particular fires on essentially
    ///   EVERY reconciliation-only call against a healthy document (see
    ///   `BibliographyHeadingRenamer.NoOpReason.alreadyCorrect`'s doc comment --
    ///   `newName` is always present in `oldNames` on this path, so the one matching candidate
    ///   is routinely the document's own already-correct heading), which now includes every
    ///   `ExportPreferencesPane` appearance (see that view's `.onAppear`, which explicitly
    ///   re-commits the draft on every appearance, not only the first). Surfacing either there
    ///   would flash a wrong, alarming error on nearly every ordinary visit to that pane.
    ///
    /// Every OTHER `.noOp` reason (ambiguous candidates, a collision, a database error) is
    /// surfaced regardless of `isReconciliationOnly`: those mean a real problem is still
    /// blocking the document from matching the configured name, which is exactly the
    /// information a retry exists to (re-)report -- see the verification requirement that a
    /// repeated resubmission against an unresolved collision shows the SAME informative error
    /// again, never silence.
    @MainActor
    func performBibliographyHeaderNameChange(
        database: ProjectDatabase, projectId: String, oldNames: [String], newName: String,
        isReconciliationOnly: Bool = false
    ) async {
        if let flush = bibliographySyncService.flushLiveEditorContentToBlocks {
            // No project switch in progress here -- editorState.content is live, so no
            // override is needed (see makeBibliographyFlushHandler's doc comment).
            await flush(projectId, nil)
        }

        // Phase 2 (t-94369a83), §2.2: reserve AFTER the flush above, not before -- so
        // this write's turn in the ordered queue reflects when the flush (which can
        // itself take a beat) actually finished, not when this function was first
        // called.
        let outcome: BibliographyHeadingRenamer.RenameOutcome
        if let systemWriter = bibliographySyncService.systemWriter {
            let identity = SystemWriteIdentity(projectId: projectId, database: database)
            let result = await systemWriter.perform(
                identity: identity, kind: .bibliographyRename,
                stillWanted: { bibliographySyncService.database === identity.database },
                body: { db in
                    // Re-read the effective header name from INSIDE the transaction, NOT
                    // this function's own captured `newName` -- so a rename that reserves
                    // its turn after a concurrent one still converges on whichever name is
                    // actually current in settings at the moment ITS write commits,
                    // regardless of scheduling order (mirrors
                    // `BibliographySyncService.writeBibliographyRows`'s own re-read of the
                    // same setting, for the same reason).
                    let effectiveName = ExportSettings.load().effectiveBibliographyHeaderName
                    return SystemWriteBody(value: BibliographyHeadingRenamer.renameInTransaction(
                        db: db, projectId: projectId, from: oldNames, to: effectiveName))
                }
            )
            switch result.outcome {
            case .applied(let renameOutcome):
                // A `.noOp` here is a normal outcome of a completed write (see
                // `renameInTransaction`'s own doc comment) -- handled by the shared
                // switch below exactly like the pre-Phase-2 direct-write result was.
                outcome = renameOutcome
            case .refused(let reason):
                // Review fix (finding #13): this used to post the SAME "database
                // error" notification for every refusal reason. Most refusals here are
                // completely benign -- the project switched away, the writer was
                // replaced/retired, or this call nested inside another system write --
                // exactly what `BibliographySyncService`'s own
                // `.refused(.identityMismatch)/.refused(.writerRetired)/.refused(.notWanted)`
                // handling already treats as "superseded or project changed -- nothing
                // to do", with no user-facing error. Telling the user "database error"
                // for a rename that simply no longer applies (they've moved to a
                // different project) is actively misleading.
                switch reason {
                case .notWanted, .identityMismatch, .writerRetired, .nested,
                     .skipped(.projectSwitch), .skipped(.writerReplaced), .skipped(.editorReplaced),
                     .skipped(.lifecycleDrain), .skipped(.drainTimeout), .skipped(.close):
                    // `.skipped(.close)` is reachable once 3a-1b calls `retire(.close)`;
                    // nothing produces it today.
                    DebugLog.log(.bib, "[ContentView] performBibliographyHeaderNameChange: rename refused " +
                        "(\(reason)) -- benign supersession, no user-facing error")
                case .outOfTurn, .noWriter, .skipped(.systemStalled):
                    // A genuine problem -- the write never got its turn, no writer is
                    // configured, or the I-SYS stall backstop fired because something
                    // else blocked the queue. Still surfaced via the existing message
                    // (not literally "the database threw", but the user-facing outcome
                    // is the same: the rename did not happen and won't retry itself).
                    NotificationCenter.default.post(
                        name: .bibliographyHeadingRenameFailed, object: nil,
                        userInfo: ["reason": BibliographyHeadingRenamer.NoOpReason.databaseError.message]
                    )
                }
                return
            case .failed:
                // A write that actually threw -- this IS a real database error.
                NotificationCenter.default.post(
                    name: .bibliographyHeadingRenameFailed, object: nil,
                    userInfo: ["reason": BibliographyHeadingRenamer.NoOpReason.databaseError.message]
                )
                return
            }
        } else {
            // §2.0's `.noWriter` fallback -- no writer configured at all (defensive
            // only; should not happen once `configureSyncServices` wires it).
            outcome = BibliographyHeadingRenamer.rename(
                in: database, projectId: projectId, from: oldNames, to: newName
            )
        }

        switch outcome {
        case .renamed:
            NotificationCenter.default.post(name: .bibliographySectionChanged, object: nil)
        case .noOp(let reason):
            let isBenignReconciliation = isReconciliationOnly && (reason == .noCandidate || reason == .alreadyCorrect)
            if !isBenignReconciliation {
                NotificationCenter.default.post(
                    name: .bibliographyHeadingRenameFailed, object: nil, userInfo: ["reason": reason.message]
                )
            }
        }
    }

    /// Notes section was updated in the database - rebuild editor content
    @MainActor
    func handleNotesSectionChanged() {
        guard editorState.zoomedSectionId == nil else {
            FootnoteDiag.log("notesSectionChanged handler: skipped while zoomed")
            return
        }
        // Also deferred while a close / switch / quit holds the editor -- see `handleBibliographySectionChanged`
        // (t-94369a83 3a-1b, round C4, item 23).
        guard editorState.contentState == .idle, editorState.activeLifecycle == nil else {
            FootnoteDiag.log("notesSectionChanged handler: DEFERRED (re-posted when idle) contentState=\(editorState.contentState) " +
                "lifecycle=\(editorState.activeLifecycle != nil)")
            editorState.pendingNotesRebuild = true
            return
        }
        guard !editorState.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            FootnoteDiag.log("notesSectionChanged handler: skipped, the document is empty")
            return
        }
        let diagStart = FootnoteDiag.nowMs()
        FootnoteDiag.log("notes rebuild: starts")

        // Atomic content+IDs push (same pattern as bibliography)
        editorState.contentState = .bibliographyUpdate  // Reuse same state
        // Finding #1 (Calm_Bibliography, t-7c1d3fd8): mark the instant this bump lands,
        // synchronously and before any Task is spawned — see
        // handleBibliographySectionChanged above and
        // BlockSyncService.checkGenerationGuard's doc comment.
        blockSyncService.beginDatabaseRebuild()
        // This is a synthetic content rebuild, not a mode switch — any cursor position
        // already sitting in cursorPositionToRestore was computed against the
        // pre-rebuild document and is stale by construction. Drop it so the stale
        // mode-switch restore mechanism can't fire later and overwrite whatever
        // cursor placement this rebuild (or a subsequent one) actually wants.
        cursorPositionToRestore = nil
        editorState.isResettingContent = true

        // Registered for the lifecycle save sequence's step 3, as in `handleBibliographySectionChanged`.
        let rebuildTask: Task<Void, Never> = Task {
            defer { FootnoteDiag.log("notes rebuild: finished duration=\(FootnoteDiag.nowMs() - diagStart)ms") }
            // Force-flush pending JS changes to DB before reading blocks
            await blockSyncService.pollBlockChangesNowForDatabaseRebuild()
            FootnoteDiag.log("notes rebuild: forced poll done after \(FootnoteDiag.nowMs() - diagStart)ms")

            guard let result = fetchBlocksWithIds() else {
                editorState.isResettingContent = false
                editorState.contentState = .idle
                return
            }

            editorState.content = result.markdown
            // DERIVED REFRESH (default): notification-driven Notes/footnote-definitions
            // resync -- same reasoning as handleBibliographySectionChanged above.
            updateSourceContentIfNeeded()

            await holdRebuildFlushWindowForUITesting()

            let pushStart = FootnoteDiag.nowMs()
            let merged = await blockSyncService.setContentWithBlockIds(
                markdown: result.markdown, blockIds: result.blockIds,
                imageMeta: result.imageMeta,
                cursorBoundary: result.bibBoundaryIndex,
                cursorBoundaryEnd: result.bibBoundaryEndIndex,
                expectedBlocks: result.expectedBlocks,
                managedBlockIds: result.managedBlockIds,
                preserveUserBlocks: true)
            FootnoteDiag.log("notes rebuild: editor push done pushDuration=\(FootnoteDiag.nowMs() - pushStart)ms blocks=\(result.blockIds.count)")
            // t-6a0d195d: see handleBibliographySectionChanged's matching comment above -- the
            // merged push's actual markdown can differ from result.markdown.
            if let merged, merged != result.markdown {
                editorState.content = merged
                updateSourceContentIfNeeded() // #12: keep the Markdown-mode source copy in sync
            }
            editorState.isResettingContent = false
            editorState.contentState = .idle

            // The `editorState.content = result.markdown` assignment above happened while
            // contentState == .bibliographyUpdate (reused for Notes rebuilds too), so
            // ViewNotificationModifiers.handleContentChange's
            // `guard editorState.contentState == .idle else { return }` silently dropped the
            // onChange(of: editorState.content) firing for it -- neither sectionSyncService nor
            // annotationSyncService ever saw this content. Force both syncs explicitly now that
            // we're back to .idle, rather than leaving the `section` table and annotation
            // positions stale until the user's next keystroke re-triggers onChange.
            // sectionSyncService.syncNow correctly omits `fromEditorChange` (defaults to false)
            // here -- same reasoning as handleBibliographySectionChanged above.
            await sectionSyncService.syncNow(editorState.content)
            await annotationSyncService.syncNow(editorState.content)
        }
        editorState.registerRebuildTask(rebuildTask)
    }

    /// Processes pending rebuilds when contentState returns to idle
    @MainActor
    func handleContentStateChange(from oldValue: EditorContentState, to newValue: EditorContentState) {
        DebugLog.log(
            .bib,
            "[CV:stateChange] \(oldValue)→\(newValue) pendingBib=\(editorState.pendingBibliographyRebuild) "
                + "pendingNotes=\(editorState.pendingNotesRebuild)")
        guard newValue == .idle else { return }
        // Process ONE pending item per idle transition (if/else if chain).
        // Each rebuild sets contentState to non-idle; the next idle transition
        // picks up the next pending item.
        // Defer re-posts using DispatchQueue.main.async to give SwiftUI one
        // runloop frame to render refreshSections() results from
        // withContentStateRecovery (which fires on the same idle transition).
        // Without this, the synchronous notification immediately sets
        // contentState back to non-idle, and the sidebar never renders.
        if editorState.pendingBibliographyRebuild {
            editorState.pendingBibliographyRebuild = false
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .bibliographySectionChanged, object: nil)
            }
        } else if editorState.pendingNotesRebuild {
            FootnoteDiag.log("pending notes rebuild re-posted: contentState is idle again (was \(oldValue))")
            editorState.pendingNotesRebuild = false
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .notesSectionChanged, object: nil)
            }
        } else if !editorState.pendingFootnoteLabels.isEmpty {
            drainNextPendingFootnoteIfPossible()
        }
    }

    /// Re-syncs annotations, hierarchy, bibliography, and footnotes after zoom-out
    @MainActor
    func handleDidZoomOut() {
        // Drain a bibliography rebuild deferred while zoomed (see
        // handleBibliographySectionChanged's zoomed-into-a-section guard above). By the time
        // `.didZoomOut` fires here, `zoomOut()` has already nilled `zoomedSectionId`, which
        // means `handleZoomStateCleared()` (must-fix 7, judge round) has normally already run
        // this same drain via `.zoomStateCleared` -- called again here regardless, since
        // NotificationCenter delivery order across two independently-registered observers
        // isn't a contract either handler should depend on. Idempotent either way: draining an
        // already-false flag is a no-op.
        drainPendingBibliographyRebuildAfterZoom()

        // Re-sync annotations with full document content after zoom-out.
        // During zoom, annotation reconciliation deletes annotations outside the zoomed
        // subset. Milkdown restores them via content normalization triggering onChange,
        // but CodeMirror returns content verbatim so onChange never fires.
        annotationSyncService.contentChanged(editorState.content)

        // Catch hierarchy violations accumulated during zoom (Fix 1 skips enforcement
        // while zoomed). If onSectionsUpdated fires first, its enforcement pass finds
        // no violations and exits immediately.
        if editorState.contentState == .idle,
           ContentView.hasHierarchyViolations(in: editorState.sections) {
            Task { @MainActor in
                await ContentView.enforceHierarchyAsync(
                    editorState: editorState,
                    syncService: sectionSyncService
                )
                // INTENTIONAL REPLACEMENT (flagged -- genuinely nested/ambiguous): part of
                // handleDidZoomOut()'s own zoom-TRANSITION handling (hierarchy violations
                // accumulated while zoomed get cleaned up as this transition completes), so
                // classified with the other zoom-transition sites rather than as an
                // independent background enforcement pass.
                updateSourceContentIfNeeded(intentionalReplacement: true)
            }
        }

        // Zoom-out completed - trigger bibliography sync with full document content
        // Citations added during zoom need to be processed now
        guard let projectId = documentManager.projectId else { return }
        let citekeys = BibliographySyncService.extractCitekeys(from: editorState.content)
        bibliographySyncService.checkAndUpdateBibliography(
            currentCitekeys: citekeys,
            projectId: projectId
        )

        // Sync footnotes with full document content
        // Updates lastKnownRefs to prevent debounce from deleting definitions
        let footnoteRefs = FootnoteSyncService.extractFootnoteRefs(from: editorState.content)
        footnoteSyncService.checkAndUpdateFootnotes(
            footnoteRefs: footnoteRefs,
            projectId: projectId,
            fullContent: editorState.content
        )
    }

    /// Must-fix 7 (judge round): fires on `.zoomStateCleared`, posted by
    /// `EditorViewState.zoomedSectionId`'s own `didSet` from EVERY code path that clears zoom
    /// state -- not only `zoomOut()`'s own successful completion (`.didZoomOut` /
    /// `handleDidZoomOut()` above). See that notification's doc comment
    /// (EditorViewState+Types.swift) for the full list of other exit paths this closes; a
    /// rename that defers `pendingBibliographyRebuildAfterZoom` while zoomed must not be
    /// stranded for the rest of the session just because the zoom then exited through one of
    /// those instead of the normal path.
    @MainActor
    func handleZoomStateCleared() {
        drainPendingBibliographyRebuildAfterZoom()
    }

    /// Shared by `handleDidZoomOut()` and `handleZoomStateCleared()` above -- see
    /// `pendingBibliographyRebuildAfterZoom`'s own doc comment (EditorViewState.swift).
    @MainActor
    private func drainPendingBibliographyRebuildAfterZoom() {
        guard editorState.pendingBibliographyRebuildAfterZoom else { return }
        editorState.pendingBibliographyRebuildAfterZoom = false
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .bibliographySectionChanged, object: nil)
        }
    }

    // MARK: - Shared zoom-in/zoom-out tails (heading Cmd-click + sidebar + breadcrumb)

    /// Single implementation of the user-initiated zoom-IN tail -- byte-for-byte the same
    /// sequence the sidebar's `onZoomToSection` callback used to inline directly (see
    /// `sidebarView` in ContentView.swift). Factored out so heading Cmd-click (always-on,
    /// no Focus Mode gate) shares this instead of risking a second, drifting copy.
    @MainActor
    func performUserZoomIn(_ sectionId: String, mode: ZoomMode, reason: String) {
        // Barrier (see docs/architecture/unified-undo.md's Barriers section): a USER-initiated
        // zoom in, hooked at the call site rather than inside EditorViewState+Zoom.swift's
        // zoomToSection() itself -- matches the zoom-out barrier's placement below.
        unifiedUndoService.invalidateAll(reason: reason)
        findBarState.clearSearch()
        editorState.contentState = .zoomTransition
        Task {
            await editorState.zoomToSection(sectionId, mode: mode)
            await blockSyncService.pushBlockIds(for: editorState.zoomedBlockRange)
            await annotationSyncService.syncNow(editorState.content)
            editorState.contentState = .idle
        }
    }

    /// Single implementation of the user-initiated zoom-OUT tail -- byte-for-byte the same
    /// sequence both the breadcrumb's and the sidebar's `onZoomOut` callbacks used to inline
    /// separately (see `sidebarView` in ContentView.swift). Factored out so heading Cmd-click
    /// (always-on, no Focus Mode gate) shares this instead of risking a third, drifting copy --
    /// the `.didZoomOut` post and `scrollToSection` call below trigger bibliography/citation
    /// resync and were the easiest pieces to silently drop when this was duplicated by hand.
    ///
    /// Feedback-round fix (zoom-out redraw/scroll perf): the inherited pre-Cmd-click version of
    /// this sequence (present verbatim in main's old sidebar/breadcrumb `onZoomOut` closures)
    /// followed `editorState.zoomOut()` with an UNRANGED `blockSyncService.pushBlockIds()` --
    /// i.e. `range: nil`, which re-fetches EVERY block from the DB and re-syncs block IDs for
    /// the WHOLE document a second time. That work is already done: `zoomOut()`'s own
    /// `setContentWithBlockIds(...)` call (EditorViewState+Zoom.swift) already pushes the
    /// full, post-flush block-ID mapping for the restored document -- assigning IDs
    /// (`setBlockIdsForTopLevel`), redecorating, AND scheduling the post-RAF snapshot
    /// (`deferredSnapshotAndUnpause` -> `resetAndSnapshot`, web/milkdown/src/api-content.ts) --
    /// as part of the SAME content push. The follow-up `pushBlockIds()` repeated every step of
    /// that (a second full-document DB fetch, a second `setBlockIdsForTopLevel` pass, a second
    /// `redecorateBlockIds` ProseMirror dispatch, a second `resetAndSnapshot`) via ANOTHER full
    /// `webView.evaluateJavaScript` round trip -- pure duplicated work whose cost scales with
    /// the FULL document size, sitting directly in front of the `scrollToSection` call below.
    /// That's why zoom-out visibly paused far longer than zoom-in: zoom-in's matching call
    /// (`performUserZoomIn`, just above) passes `pushBlockIds(for: editorState.zoomedBlockRange)`
    /// -- scoped to the small zoomed range, so the same redundancy there is cheap. Deleted here
    /// rather than scoped to a range, since `zoomOut()` always restores the ENTIRE document and
    /// its own `setContentWithBlockIds` call already covers exactly that. `performUserZoomIn`
    /// above is left untouched (zoom-in behavior/perf is explicitly out of scope for this
    /// round). `zoomOut()`'s other caller family, StructuralUndoController's `.autoZoomOut`
    /// step -- used only by the three Version-History restore actions (`restoreSectionReplace`,
    /// `restoreEntireProject`, `restoreSectionAsDuplicate`); `deleteSections` and
    /// `duplicateSections` are `.refuseIfZoomed` and never reach this step, and
    /// `reorderAllBlocks` is `.allowWhileZoomed` and never auto-zooms out at all -- had this
    /// same redundant follow-up `pushBlockIds()` call after its own `zoomOut()`. That has now
    /// been fixed there too; see that call site's own comment in StructuralUndoController.swift.
    @MainActor
    func performUserZoomOut(reason: String) {
        unifiedUndoService.invalidateAll(reason: reason)
        let savedSectionId = editorState.zoomedSectionId
        findBarState.clearSearch()
        editorState.contentState = .zoomTransition
        let zoomOutStart = Date()
        Task {
            await editorState.zoomOut(restoreScrollToSectionId: savedSectionId)
            DebugLog.log(.zoom, "[ZoomClick] zoomOut() settled in \(Date().timeIntervalSince(zoomOutStart))s")
            editorState.contentState = .idle
            NotificationCenter.default.post(name: .didZoomOut, object: nil)
            if let sectionId = savedSectionId {
                // KEPT even though zoomOut() above already resolved and landed on this same
                // target in WYSIWYG -- via BlockSyncService.setContentWithBlockIds's
                // scrollToBlockId option (in-push, synchronous), same blockScrollTargetTop math
                // as scrollToSection() below reaches through a DIFFERENT, same-named mechanism:
                // it sets EditorViewState.scrollToBlockId (the deferred @Binding MilkdownEditor
                // consumes to call window.FinalFinal.scrollToBlock -- see that property's doc
                // comment in EditorViewState.swift for the two mechanisms sharing this name).
                // scrollToSection() is the ONLY mechanism for Source (CodeMirror) mode, a
                // separate offset-based path (ContentView+SectionManagement.swift:11) this
                // JS-side fix doesn't reach. In WYSIWYG it recomputes the identical position and
                // produces no visible movement, so keeping it unconditionally is harmless there
                // and necessary here.
                scrollToSection(sectionId)
            }
            DebugLog.log(.zoom, "[ZoomClick] performUserZoomOut tail complete in \(Date().timeIntervalSince(zoomOutStart))s")
        }
    }

    /// Handles a Cmd-click on a heading in the editor (heading-zoom-click-handler.ts, via the
    /// `zoomHeadingClicked` message and `.zoomHeadingClicked` notification). Always-on -- no
    /// Focus Mode gate anywhere in this path; the only gate is `contentState == .idle`, applied
    /// inside `HeadingZoomClickRouter.decide`.
    @MainActor
    func handleZoomHeadingClicked(_ notification: Notification) {
        guard let blockId = notification.userInfo?["blockId"] as? String else {
            DebugLog.log(.zoom, "[ZoomClick] .zoomHeadingClicked notification missing blockId — ignoring")
            return
        }
        let action = HeadingZoomClickRouter.decide(
            blockId: blockId,
            zoomedSectionId: editorState.zoomedSectionId,
            contentState: editorState.contentState,
            sections: editorState.sections.map {
                HeadingZoomClickSectionInfo(
                    id: $0.id,
                    isBibliography: $0.isBibliography,
                    isNotes: $0.isNotes,
                    isPseudoSection: $0.isPseudoSection
                )
            }
        )
        switch action {
        case .drop(let reason):
            DebugLog.log(.zoom, "[ZoomClick] ignored Cmd-click on \(blockId): \(reason)")
        case .zoomIn(let id, let mode):
            performUserZoomIn(id, mode: mode, reason: "user zoomed in (heading Cmd-click)")
        case .zoomOut:
            performUserZoomOut(reason: "user zoomed out (heading Cmd-click)")
        }
    }
}
