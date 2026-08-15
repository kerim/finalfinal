//
//  ContentView+NotificationHandlers.swift
//  final final
//
//  Notification handlers extracted from body's modifier-chain closures to keep
//  type-checking fast: bibliography/notes rebuilds, content-state transitions,
//  footnote insertion, and zoom-out resync.
//

import SwiftUI

extension ContentView {
    /// Bibliography section was updated in the database - rebuild editor content
    @MainActor
    func handleBibliographySectionChanged() {
        DebugLog.log(.bib, {
            let contentIsEmpty = editorState.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return "[CV:bibNotif] contentState=\(editorState.contentState) suppress=\(suppressNextBibliographyRebuild) "
                + "pendingBib=\(pendingBibliographyRebuild) content.isEmpty=\(contentIsEmpty)"
        }())
        // Skip if zoomed into a section (bibliography update only affects full document view)
        guard editorState.zoomedSectionId == nil else { return }
        // Skip during any content transition (including editor switch)
        guard editorState.contentState == .idle else {
            pendingBibliographyRebuild = true
            return
        }
        // Skip the first bibliography notification after a project switch
        // (it fires from the old project's debounced citekey check)
        // Skip rebuild when editor content is empty - no citations exist,
        // so rebuilding from blocks would restore stale content
        guard !editorState.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !suppressNextBibliographyRebuild else {
            suppressNextBibliographyRebuild = false
            DebugLog.log(.bib, "[ContentView] bibliographySectionChanged suppressed (post-project-switch)")
            return
        }

        // Atomic content+IDs push to prevent temp ID race condition.
        // Without this, setContent() triggers assignBlockIds() which creates temp IDs,
        // and the 100ms-delayed pushBlockIds() arrives too late — block-sync reports
        // changes with temp IDs, Swift creates new blocks at maxSortOrder+1.
        editorState.contentState = .bibliographyUpdate
        editorState.isResettingContent = true  // prevent updateNSView → setContent()

        Task {
            // Force-flush pending JS changes to DB before reading blocks
            if let db = documentManager.projectDatabase, let pid = documentManager.projectId {
                DebugLog.log(.bib, "[CV:bibRebuild] BEFORE poll: \((try? db.fetchBlockCount(projectId: pid)) ?? -1) blocks in DB")
            }
            await blockSyncService.pollBlockChangesNow()
            if let db = documentManager.projectDatabase, let pid = documentManager.projectId {
                DebugLog.log(.bib, "[CV:bibRebuild] AFTER poll: \((try? db.fetchBlockCount(projectId: pid)) ?? -1) blocks in DB")
            }

            guard let result = fetchBlocksWithIds() else {
                editorState.isResettingContent = false
                editorState.contentState = .idle
                return
            }

            editorState.content = result.markdown  // sidebar sync (won't trigger WKWebView push)
            updateSourceContentIfNeeded()

            await blockSyncService.setContentWithBlockIds(
                markdown: result.markdown, blockIds: result.blockIds,
                imageMeta: result.imageMeta,
                cursorBoundary: result.bibBoundaryIndex,
                cursorBoundaryEnd: result.bibBoundaryEndIndex,
                expectedBlocks: result.expectedBlocks)
            editorState.isResettingContent = false
            editorState.contentState = .idle
        }
    }

    /// Notes section was updated in the database - rebuild editor content
    @MainActor
    func handleNotesSectionChanged() {
        guard editorState.zoomedSectionId == nil else { return }
        guard editorState.contentState == .idle else {
            pendingNotesRebuild = true
            return
        }
        guard !editorState.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Atomic content+IDs push (same pattern as bibliography)
        editorState.contentState = .bibliographyUpdate  // Reuse same state
        editorState.isResettingContent = true

        Task {
            // Force-flush pending JS changes to DB before reading blocks
            await blockSyncService.pollBlockChangesNow()

            guard let result = fetchBlocksWithIds() else {
                editorState.isResettingContent = false
                editorState.contentState = .idle
                return
            }

            editorState.content = result.markdown
            updateSourceContentIfNeeded()

            await blockSyncService.setContentWithBlockIds(
                markdown: result.markdown, blockIds: result.blockIds,
                imageMeta: result.imageMeta,
                cursorBoundary: result.bibBoundaryIndex,
                cursorBoundaryEnd: result.bibBoundaryEndIndex,
                expectedBlocks: result.expectedBlocks)
            editorState.isResettingContent = false
            editorState.contentState = .idle
        }
    }

    /// Processes pending rebuilds when contentState returns to idle
    @MainActor
    func handleContentStateChange(from oldValue: EditorContentState, to newValue: EditorContentState) {
        DebugLog.log(.bib, "[CV:stateChange] \(oldValue)→\(newValue) pendingBib=\(pendingBibliographyRebuild) pendingNotes=\(pendingNotesRebuild)")
        guard newValue == .idle else { return }
        // Process ONE pending item per idle transition (if/else if chain).
        // Each rebuild sets contentState to non-idle; the next idle transition
        // picks up the next pending item.
        // Defer re-posts using DispatchQueue.main.async to give SwiftUI one
        // runloop frame to render refreshSections() results from
        // withContentStateRecovery (which fires on the same idle transition).
        // Without this, the synchronous notification immediately sets
        // contentState back to non-idle, and the sidebar never renders.
        if pendingBibliographyRebuild {
            pendingBibliographyRebuild = false
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .bibliographySectionChanged, object: nil)
            }
        } else if pendingNotesRebuild {
            pendingNotesRebuild = false
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .notesSectionChanged, object: nil)
            }
        } else if !pendingFootnoteLabels.isEmpty {
            drainNextPendingFootnoteIfPossible()
        }
    }

    /// Dequeues and re-posts exactly one pending footnote label, if contentState is
    /// idle and the queue is non-empty. Called both from the idle-transition branch
    /// above and from handleFootnoteInsertedImmediate's own early-return guard — the
    /// latter closes a gap where a drained item that turns out unprocessable (nil
    /// label/projectId) would otherwise never touch contentState, so no further idle
    /// transition would occur to pick up whatever is left in the queue.
    @MainActor
    private func drainNextPendingFootnoteIfPossible() {
        guard editorState.contentState == .idle,
              let next = pendingFootnoteLabels.dequeue() else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .footnoteInsertedImmediate, object: nil,
                userInfo: ["label": next])
        }
    }

    /// Inserts a footnote definition into the Notes section after a slash-command insertion
    @MainActor
    func handleFootnoteInsertedImmediate(_ notification: Notification) {
        guard let label = notification.userInfo?["label"] as? String,
              let projectId = documentManager.projectId else {
            drainNextPendingFootnoteIfPossible()
            return
        }
        // Zoom-aware handling: use zoom-specific insertion path
        if editorState.zoomedSectionId != nil {
            handleZoomedFootnoteInsertion(label: label, projectId: projectId)
            return
        }

        // Rapid double-insertion safety: queue label if busy
        guard editorState.contentState == .idle else {
            pendingFootnoteLabels.enqueue(label)
            return
        }

        // Set content state BEFORE DB write to suppress sync
        editorState.contentState = .bibliographyUpdate
        editorState.isResettingContent = true

        footnoteSyncService.handleImmediateInsertion(label: label, projectId: projectId)

        Task {
            // Force-flush pending JS changes to DB. This MUST complete before the
            // fetchBlocksWithIds() read below: editorState.content above only reflects what
            // the JS coordinator had already synced at notification-post time, but the
            // background block poller runs on its own ~2s interval, so a just-typed edit
            // to an existing footnote definition can still be sitting unflushed in JS when
            // we get here. fetchBlocksWithIds reads block text straight from the DB, so if
            // that read raced ahead of this flush it would silently rebuild the document
            // from stale (pre-edit) text and stomp the user's edit when the result is pushed
            // back to the editor below. Awaiting the flush first guarantees the read sees it.
            await blockSyncService.pollBlockChangesNow()
            DebugLog.log(.footnotes, "[ContentView] handleFootnoteInsertedImmediate: fresh flush guaranteed " +
                "complete for label=\(label), reading blocks from DB")

            // Single source of truth: one DB fetch produces markdown + IDs that are
            // guaranteed mutually aligned (BlockParser.assembleMarkdown /
            // idsForProseMirrorAlignment share filtering + list-merge logic). Previously
            // this function hand-spliced a separately-derived string and paired it with
            // this fetch's block IDs; when the two disagreed on top-level node arrangement,
            // the editor's positional ID-assignment could attach an existing footnote's
            // identity to the wrong (blank) node. Pushing result.markdown directly (the
            // same pattern rebuildDocumentContent already uses) eliminates that mismatch.
            guard let result = fetchBlocksWithIds() else {
                editorState.isResettingContent = false
                editorState.contentState = .idle
                resyncFootnotesAfterImmediateInsertion(projectId: projectId)
                return
            }

            editorState.content = result.markdown
            editorState.pendingImageMeta = result.imageMeta
            updateSourceContentIfNeeded()

            // Known residual limitation (left as-is, not fixed here): keystrokes typed in
            // the window between the flush above and setContentWithBlockIds below are still
            // lost the same way, since that push resets pending-change tracking. Narrower
            // window than before the reorder, but not eliminated.

            // Push fresh content with real block IDs atomically
            // (same pattern as bibliography — prevents temp ID race)
            await blockSyncService.setContentWithBlockIds(
                markdown: result.markdown, blockIds: result.blockIds,
                imageMeta: result.imageMeta,
                cursorBoundary: result.bibBoundaryIndex,
                cursorBoundaryEnd: result.bibBoundaryEndIndex,
                expectedBlocks: result.expectedBlocks)

            editorState.isResettingContent = false
            editorState.contentState = .idle
            resyncFootnotesAfterImmediateInsertion(projectId: projectId)

            await Task.yield()

            // Navigate cursor to new definition
            NotificationCenter.default.post(
                name: .scrollToFootnoteDefinition,
                object: nil,
                userInfo: ["label": label]
            )
        }
    }

    /// Guaranteed resync after an immediate footnote insertion returns `contentState` to
    /// `.idle`. `handleImmediateInsertion` unconditionally cancels any outstanding debounce,
    /// and `handleContentChange`'s `contentState == .idle` guard drops every `onChange` firing
    /// for the whole duration of this flow — including the flow's own final content push — so
    /// nothing else re-schedules a debounce for work that was dropped. Calling
    /// `checkAndUpdateFootnotes` here closes that gap. Cheap no-op in the common case: it
    /// early-exits when the live document's ref set already matches `lastKnownRefs`.
    @MainActor
    private func resyncFootnotesAfterImmediateInsertion(projectId: String) {
        let refreshedRefs = FootnoteSyncService.extractFootnoteRefs(from: editorState.content)
        footnoteSyncService.checkAndUpdateFootnotes(
            footnoteRefs: refreshedRefs,
            projectId: projectId,
            fullContent: editorState.content
        )
    }

    /// Re-syncs annotations, hierarchy, bibliography, and footnotes after zoom-out
    @MainActor
    func handleDidZoomOut() {
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
                updateSourceContentIfNeeded()
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
}
