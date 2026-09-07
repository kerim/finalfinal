//
//  ContentView+ContentRebuilding.swift
//  final final
//
//  Content rebuilding, zoom filtering, and annotation handlers. Detail/editor view
//  presentation lives in ContentView+EditorPresentation.swift.
//

import SwiftUI

extension ContentView {
    /// Image metadata for passing to JS setContentWithBlockIds
    struct ImageBlockMeta {
        let id: String
        let width: Int?
        let caption: String?
        let alt: String?
        let src: String?
    }

    /// Assembled content for an atomic content+ID push: the markdown plus everything the
    /// editor needs to stay aligned with it. Every call site reads these by label, so this
    /// replaced the original five-member return tuple without touching any of them.
    struct BlockFetchResult {
        let markdown: String
        let blockIds: [String]
        let imageMeta: [ImageBlockMeta]
        let bibBoundaryIndex: Int?
        /// Node index one PAST the last bibliography block (nil iff `bibBoundaryIndex` is nil).
        /// Companion end bound for `bibBoundaryIndex`: together they mark the bibliography
        /// section's [start, end) range, so the JS-side cursor clamp can tell "inside the
        /// section" apart from "in real trailing content after it" — see
        /// `BlockParser.lastBibliographyNodeIndex`'s doc comment.
        let bibBoundaryEndIndex: Int?
        let expectedBlocks: [BlockParser.BlockAlignmentMeta]
    }

    /// Fetch blocks from DB and return assembled markdown + ordered block IDs + image metadata
    /// Used for atomic content+ID pushes (bibliography rebuild, etc.)
    func fetchBlocksWithIds() -> BlockFetchResult? {
        guard let db = documentManager.projectDatabase,
              let pid = documentManager.projectId else { return nil }

        do {
            let allBlocks: [Block]
            if let zoomedIds = editorState.zoomedSectionIds {
                let blocks = try db.fetchBlocks(projectId: pid)
                allBlocks = filterBlocksForZoom(blocks, zoomedIds: zoomedIds, zoomedBlockRange: editorState.zoomedBlockRange)
            } else {
                allBlocks = try db.fetchBlocks(projectId: pid)
            }

            let sorted = allBlocks.sorted { a, b in
                let aKey = (a.sortOrder, a.blockType == .heading ? 0 : 1)
                let bKey = (b.sortOrder, b.blockType == .heading ? 0 : 1)
                return aKey < bKey
            }
            // assembleMarkdownForEditor (not plain assembleMarkdown): this markdown becomes
            // editorState.content, which flushContentToDatabase() reparses before every PDF
            // export — it must carry the bibliography-end terminator when the doc ends in
            // bibliography content, or trailing user text silently gets flagged and dropped.
            let markdown = BlockParser.assembleMarkdownForEditor(from: sorted)
            // Single call produces both the id array and its expected-metadata array from the
            // SAME iteration, so the two cannot drift apart in count/order (see alignmentPairs).
            let pairs = BlockParser.alignmentPairs(sorted)
            let ids = pairs.map { $0.id }
            let expectedBlocks = pairs.map { $0.meta }

            // Collect image metadata for figure nodes (width/caption/alt persistence)
            let imageMeta = sorted
                .filter { $0.blockType == .image }
                .map { ImageBlockMeta(id: $0.id, width: $0.imageWidth, caption: $0.imageCaption, alt: $0.imageAlt, src: $0.imageSrc) }

            let bibBoundaryIndex = BlockParser.firstBibliographyNodeIndex(sorted)
            let bibBoundaryEndIndex = BlockParser.lastBibliographyNodeIndex(sorted)

            DebugLog.log(.bib, "[fetchBlocksWithIds] bibBoundaryIndex=\(String(describing: bibBoundaryIndex)) "
                + "bibBoundaryEndIndex=\(String(describing: bibBoundaryEndIndex)) "
                + "blockCount=\(sorted.count) idCount=\(ids.count)")

            return BlockFetchResult(
                markdown: markdown, blockIds: ids, imageMeta: imageMeta,
                bibBoundaryIndex: bibBoundaryIndex, bibBoundaryEndIndex: bibBoundaryEndIndex,
                expectedBlocks: expectedBlocks)
        } catch {
            return nil
        }
    }

    /// Rebuild document content from block database
    /// For zoom state, fetches only the zoomed range; otherwise fetches all blocks
    func rebuildDocumentContent() {
        // Guard against rebuilding during editor transition
        guard editorState.contentState != .editorTransition else { return }
        guard let result = fetchBlocksWithIds() else { return }

        editorState.isResettingContent = true
        editorState.content = result.markdown
        editorState.pendingImageMeta = result.imageMeta

        // Update sourceContent for CodeMirror (when in source mode)
        // DERIVED REFRESH (default): general DB-driven rebuild, not a deliberate
        // replacement event. (This function has no current callers -- dead code -- but
        // classified for whoever revives it.)
        updateSourceContentIfNeeded()

        Task {
            await blockSyncService.setContentWithBlockIds(
                markdown: result.markdown,
                blockIds: result.blockIds,
                imageMeta: result.imageMeta,
                cursorBoundary: result.bibBoundaryIndex,
                cursorBoundaryEnd: result.bibBoundaryEndIndex,
                expectedBlocks: result.expectedBlocks,
                zoomMode: editorState.zoomedSectionIds != nil)
            editorState.isResettingContent = false
        }
    }

    /// Filter blocks to only those within zoomed heading ranges
    func filterBlocksForZoom(
        _ blocks: [Block],
        zoomedIds: Set<String>,
        zoomedBlockRange: (start: Double, end: Double?)? = nil
    ) -> [Block] {
        Self.filterBlocksForZoomStatic(blocks, zoomedIds: zoomedIds, zoomedBlockRange: zoomedBlockRange)
    }

    /// Range-based zoom filtering: keep the non-bibliography blocks whose sortOrder falls inside
    /// the zoomed range. Split out of `filterBlocksForZoomStatic` so that function's branch count
    /// stays under the complexity limit; behaviour is unchanged.
    private static func blocksInZoomRange(
        _ blocks: [Block],
        range: (start: Double, end: Double?)
    ) -> [Block] {
        blocks.sorted { $0.sortOrder < $1.sortOrder }.filter { block in
            guard !block.isBibliography else { return false }
            guard block.sortOrder >= range.start else { return false }
            if let end = range.end { guard block.sortOrder < end else { return false } }
            return true
        }
    }

    /// Static version of filterBlocksForZoom for use from static methods.
    /// Prefers range-based filtering when available (handles new sections created during zoom).
    /// Falls back to ID-based filtering when range is not available.
    static func filterBlocksForZoomStatic(
        _ blocks: [Block],
        zoomedIds: Set<String>,
        zoomedBlockRange: (start: Double, end: Double?)? = nil
    ) -> [Block] {
        // Prefer range-based filtering when available (handles new sections during zoom)
        if let range = zoomedBlockRange {
            return blocksInZoomRange(blocks, range: range)
        }

        // Fall back to ID-based filtering
        let sortedBlocks = blocks.sorted { $0.sortOrder < $1.sortOrder }
        var includeBlocks: [Block] = []
        var inZoomedRange = false
        var currentZoomedLevel: Int?

        for block in sortedBlocks {
            if block.isOutlineHeading || block.isPseudoSection {
                if zoomedIds.contains(block.id) {
                    inZoomedRange = true
                    currentZoomedLevel = block.headingLevel
                    includeBlocks.append(block)
                    continue
                } else if inZoomedRange {
                    if let level = currentZoomedLevel, let blockLevel = block.headingLevel, blockLevel <= level {
                        inZoomedRange = false
                        currentZoomedLevel = nil
                        continue
                    }
                }
            }

            if inZoomedRange && !block.isBibliography {
                includeBlocks.append(block)
            }
        }

        return includeBlocks
    }

    /// Updates sourceContent from current content when in source mode
    /// Recalculates section offsets and injects anchors/bibliography markers
    ///
    /// - Parameter intentionalReplacement: pass `true` when this call is a deliberate,
    ///   one-time content replacement the CodeMirror coordinator's settle-window guard
    ///   must apply unconditionally (zoom transitions, project switch/open, structural
    ///   undo/redo restores) rather than treat as a derived/background refresh that could
    ///   land mid-typing and silently take a user's undo history with it (undo-mode-
    ///   switch-focus root cause -- see CodeMirrorCoordinator.shouldPushContent). Defaults
    ///   to `false` (DERIVED REFRESH) -- every call site below is classified in its own
    ///   one-line comment; when genuinely unsure, this default is the safe choice, since a
    ///   wrongly-guarded intentional push only delays (via the deferred-recompute retry),
    ///   never drops, the content.
    func updateSourceContentIfNeeded(intentionalReplacement: Bool = false) {
        guard editorState.editorMode == .source else { return }
        if intentionalReplacement {
            editorState.forcedPushGeneration += 1
        }

        // Get non-bibliography sections in sort order
        let sectionsForAnchors = editorState.sections
            .filter { !$0.isBibliography }
            .sorted { $0.sortOrder < $1.sortOrder }

        // Compute offsets from blocks (same data that produced editorState.content)
        var adjustedSections: [SectionViewModel] = []
        if let db = documentManager.projectDatabase,
           let pid = documentManager.projectId {
            do {
                let fetchedBlocks: [Block]
                if let zoomedIds = editorState.zoomedSectionIds {
                    let allBlocks = try db.fetchBlocks(projectId: pid)
                    fetchedBlocks = filterBlocksForZoom(
                        allBlocks, zoomedIds: zoomedIds,
                        zoomedBlockRange: editorState.zoomedBlockRange)
                } else {
                    fetchedBlocks = try db.fetchBlocks(projectId: pid)
                }

                // Sort with same tie-breaking as assembleMarkdown
                let sorted = fetchedBlocks.sorted { a, b in
                    let aKey = (a.sortOrder, a.blockType == .heading ? 0 : 1)
                    let bKey = (b.sortOrder, b.blockType == .heading ? 0 : 1)
                    return aKey < bKey
                }

                // Build block-ID → Character offset map
                // MUST stay in sync with BlockParser.assembleMarkdown filtering
                let nonEmpty = sorted.filter { !BlockParser.isEmptyFragment($0.markdownFragment) }
                var blockOffset: [String: Int] = [:]
                var offset = 0
                for (i, block) in nonEmpty.enumerated() {
                    if i > 0 { offset += 2 }  // "\n\n" separator
                    blockOffset[block.id] = offset
                    offset += block.markdownFragment.count
                }

                for section in sectionsForAnchors {
                    if let off = blockOffset[section.id] {
                        adjustedSections.append(section.withUpdates(startOffset: off))
                    }
                }
            } catch { }
        }

        let withAnchors = sectionSyncService.injectSectionAnchors(
            markdown: editorState.content,
            sections: adjustedSections
        )
        editorState.sourceContent = sectionSyncService.injectBibliographyMarker(
            markdown: withAnchors,
            sections: editorState.sections
        )
    }

    /// Toggle annotation completion and update both markdown and database
    func toggleAnnotationCompletion(_ annotation: AnnotationViewModel) {
        // Toggle local state
        annotation.isCompleted.toggle()

        // Document-level: DB-only update (no markdown to modify) -- NOT a barrier (plan §2's
        // hazard table): it never touches editor content, so it's invisible to both the doc
        // and outside the timeline's concern entirely.
        if annotation.isDocumentLevel {
            if let db = documentManager.projectDatabase {
                try? db.updateAnnotationCompletion(id: annotation.id, isCompleted: annotation.isCompleted)
            }
            return
        }

        // Barrier (see docs/architecture/unified-undo.md's Barriers section): this
        // inline (content-mutating) branch rewrites editorState.content directly, outside the
        // structural-op checkpoint machinery -- a structural undo landing after this could
        // revert the toggle along with whatever it's actually undoing.
        unifiedUndoService.invalidateAll(reason: "inline annotation completion toggled")

        // Update markdown content
        editorState.content = annotationSyncService.updateTaskCompletion(
            in: editorState.content,
            at: annotation.charOffset,
            isCompleted: annotation.isCompleted
        )

        // Database will be updated via sync service when content changes
    }

    /// Handle annotation text update from sidebar editing
    func handleAnnotationTextUpdate(_ annotation: AnnotationViewModel, newText: String) {
        // Document-level: DB-only update (no markdown to modify) -- NOT a barrier, same
        // reasoning as toggleAnnotationCompletion's document-level branch above.
        if annotation.isDocumentLevel {
            if let db = documentManager.projectDatabase {
                try? db.updateAnnotationText(id: annotation.id, text: newText)
            }
            annotation.text = newText
            return
        }

        // Barrier (see docs/architecture/unified-undo.md's Barriers section): this
        // inline (content-mutating) branch rewrites editorState.content directly, outside the
        // structural-op checkpoint machinery -- same reasoning as
        // toggleAnnotationCompletion's inline branch above.
        unifiedUndoService.invalidateAll(reason: "inline annotation text edited")

        // 1. Suppress sync via content state to prevent feedback loop
        editorState.contentState = .annotationEdit

        // 2. Reconstruct markdown with new text
        let result = annotationSyncService.replaceAnnotationText(
            in: editorState.content,
            annotationId: annotation.id,
            oldCharOffset: annotation.charOffset,
            annotationType: annotation.type,
            oldText: annotation.text,
            newText: newText,
            isCompleted: annotation.isCompleted
        )

        // 3. Update database atomically (text + charOffset)
        if let db = documentManager.projectDatabase {
            do {
                try db.updateAnnotation(
                    id: annotation.id,
                    text: newText,
                    charOffset: result.newCharOffset
                )
            } catch {
                DebugLog.log(.bib, "[ContentView] Error updating annotation: \(error.localizedDescription)")
            }
        }

        // 4. Update local view model
        annotation.text = newText
        annotation.charOffset = result.newCharOffset

        // 5. Push to editor
        editorState.content = result.markdown

        // 6. Re-enable sync after delay
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            editorState.contentState = .idle
        }
    }

    // MARK: - Document-Level Annotations

    /// Create a document-level annotation (not anchored to markdown)
    func createDocumentAnnotation(type: AnnotationType) {
        guard let db = documentManager.projectDatabase,
              let cid = documentManager.contentId else { return }

        do {
            let annotation = try db.insertDocumentAnnotation(contentId: cid, type: type, text: "")
            editorState.pendingEditAnnotationId = annotation.id
            editorState.isDocumentNotesCollapsed = false
        } catch {
            DebugLog.log(.bib, "[ContentView] Error creating document annotation: \(error.localizedDescription)")
        }
    }

    /// Delete a document-level annotation (DB-only, no markdown rewrite)
    func deleteDocumentAnnotation(id: String) {
        guard let db = documentManager.projectDatabase else { return }
        do {
            try db.deleteAnnotation(id: id)
        } catch {
            DebugLog.log(.bib, "[ContentView] Error deleting document annotation: \(error.localizedDescription)")
        }
    }

    // MARK: - Zoomed Footnote Insertion

    func handleZoomedFootnoteInsertion(label: String, projectId: String) {
        editorState.contentState = .bibliographyUpdate

        // Flush current editor content to DB before modifying
        editorState.flushContentToDatabase()

        // Sync mini Notes definitions back to DB BEFORE creating new definition
        // (preserves user edits to existing definitions made during this zoom session)
        let (_, existingMiniNotes) = SectionSyncService.stripZoomNotes(from: editorState.content)
        if let miniNotes = existingMiniNotes {
            sectionSyncService.syncMiniNotesBackPublic(miniNotes, projectId: projectId)
        }

        // Create definition in DB (reuses existing logic). E4: capture the inserted row's id
        // for the `.scrollToFootnoteDefinition` post below, same as the non-zoomed path in
        // ContentView+NotificationHandlers.swift. NOTE: in zoom mode the mini-Notes tail is
        // NOT included in `pushBlockIds`'s array (isNotes blocks are excluded -- see the
        // KNOWN RESIDUAL RISK comment on the `pushBlockIds` call below), so this id will
        // typically be absent from the JS side's `getAllBlockIds()` map when zoomed; Milkdown's
        // `focusFootnoteDefinition` falls back to its node/text search in that case (loudly
        // logged), same as any other blockId-miss. Threading it through anyway costs nothing
        // and helps on the rare path where the id IS already present (e.g. zoom-out/back-in).
        let insertedBlockId = footnoteSyncService.handleImmediateInsertion(label: label, projectId: projectId)

        // Recalculate zoom range using count-based boundary
        recalculateZoomRangeCountBased(projectId: projectId)

        // Rebuild zoomed content with updated mini #Notes
        let (body, _) = SectionSyncService.stripZoomNotes(from: editorState.content)
        let refs = FootnoteSyncService.extractFootnoteRefs(from: body)

        // Get ALL definitions from DB
        let notesMd = footnoteSyncService.buildNotesSectionMarkdown(projectId: projectId) ?? ""
        let allDefs = FootnoteSyncService.extractFootnoteDefinitions(from: notesMd)

        var miniNotesSection = "\n\n<!-- ::zoom-notes:: -->\n# Notes\n"
        for ref in refs {
            let def = allDefs[ref] ?? ""
            miniNotesSection += "\n[^\(ref)]: \(def)\n"
        }

        let combined = body + miniNotesSection
        editorState.content = combined
        // Set pending image meta for CodeMirror (footnote insertion doesn't change figures)
        if let result = fetchBlocksWithIds() {
            editorState.pendingImageMeta = result.imageMeta
        }
        // DERIVED REFRESH (default, genuinely ambiguous -- flagged): a deliberate user
        // action (footnote insertion) synthesizes new content, arguably closer to an
        // intentional replacement, but this path is NOT a mode/zoom/project transition and
        // can plausibly land while the user keeps typing elsewhere in the zoomed body.
        // Left DERIVED so the settle-window guard can defer-and-retry rather than risk
        // taking a concurrent edit's undo history with it.
        updateSourceContentIfNeeded()

        // Push to editor via normal content path, then push block IDs for body only
        Task {
            guard let range = editorState.zoomedBlockRange else {
                editorState.contentState = .idle
                return
            }

            // Push block IDs for body blocks in zoom range
            // KNOWN RESIDUAL RISK (single-source-splice plan, Part 2): pushBlockIds applies
            // a DB-derived ID array positionally onto a doc built from an independently-
            // serialized body string. Footnote-definition (isNotes) blocks are excluded from
            // this array, so the footnote-blanking vector cannot occur here; a body-paragraph
            // mis-ID is theoretically possible but unobserved. Not fixed this pass to keep the
            // change surgical.
            await blockSyncService.pushBlockIds(for: range)

            editorState.contentState = .idle

            await Task.yield()

            // Scroll to new definition
            var scrollUserInfo: [String: Any] = ["label": label]
            if let insertedBlockId {
                scrollUserInfo["blockId"] = insertedBlockId
            }
            NotificationCenter.default.post(
                name: .scrollToFootnoteDefinition,
                object: nil,
                userInfo: scrollUserInfo
            )
        }
    }

    private func recalculateZoomRangeCountBased(projectId: String) {
        guard let db = documentManager.projectDatabase,
              let zoomedId = editorState.zoomedSectionId,
              let headingBlock = try? db.fetchBlock(id: zoomedId) else { return }

        let newStart = headingBlock.sortOrder

        // Count body blocks in zoom scope (same approach as flushContentToDatabase)
        let (body, _) = SectionSyncService.stripZoomNotes(from: editorState.content)
        // C5: threads the DB-resolved Notes title for consistency with every other production
        // `BlockParser.parse` site -- low-stakes here specifically (only `bodyBlocks.count` is
        // used, and `body` is already mini-Notes-stripped so Notes recognition rarely matters),
        // but `db`/`projectId` are already in scope so there is no reason to leave it defaulted.
        let bodyBlocks = BlockParser.parse(
            markdown: body,
            projectId: projectId,
            notesHeaderName: try? db.fetchNotesHeadingTitle(projectId: projectId)
        )
        let newEnd = newStart + Double(bodyBlocks.count)

        let allBlocks = (try? db.fetchBlocks(projectId: projectId)) ?? []
        let blockAtEnd = allBlocks.first { $0.sortOrder >= newEnd }

        editorState.zoomedBlockRange = (start: newStart, end: blockAtEnd?.sortOrder)
    }
}
