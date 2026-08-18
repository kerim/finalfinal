//
//  ContentView+ContentRebuilding.swift
//  final final
//
//  Content rebuilding, zoom filtering, detail/editor views, and annotation handlers.
//

import SwiftUI
import WebKit

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
    func updateSourceContentIfNeeded() {
        guard editorState.editorMode == .source else { return }

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

    @ViewBuilder
    var detailView: some View {
        HSplitView {
            // Main editor area
            VStack(spacing: 0) {
                // Find bar (shown above editor)
                if findBarState.isVisible {
                    FindBarView(state: findBarState)
                }

                editorView
                // Hide status bar in focus mode for distraction-free writing
                if !editorState.focusModeHidesStatusBar {
                    StatusBar(editorState: editorState)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(themeManager.currentTheme.editorBackground)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("editor-area")

            // Annotation panel (conditionally shown)
            if editorState.isAnnotationPanelVisible {
                AnnotationPanel(
                    editorState: editorState,
                    onScrollToAnnotation: { index, _ in
                        editorState.scrollToAnnotationIndex = index
                    },
                    onToggleCompletion: { annotation in
                        toggleAnnotationCompletion(annotation)
                    },
                    onUpdateAnnotationText: { annotation, newText in
                        handleAnnotationTextUpdate(annotation, newText: newText)
                    },
                    onCreateDocumentAnnotation: { type in
                        createDocumentAnnotation(type: type)
                    },
                    onDeleteDocumentAnnotation: { id in
                        deleteDocumentAnnotation(id: id)
                    }
                )
            }
        }
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

        // Barrier (docs/plans/patient-rewinding-clockwork.md §4.5, plan §7 Phase 4): this
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

        // Barrier (docs/plans/patient-rewinding-clockwork.md §4.5, plan §7 Phase 4): this
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

    /// Builds the JSON payload for `window.FinalFinal.setAnnotationDisplayModes()`, matching
    /// the shape `MilkdownCoordinator+Content.swift`'s `setAnnotationDisplayModes()` sends.
    ///
    /// Needed because a freshly-created WKWebView (WYSIWYG/Source mode switch, or a fresh
    /// instance claimed from `EditorPreloader`) starts its JS module state at the hardcoded
    /// defaults (all types "inline") — `annotationDisplayModesChanged` is only posted on
    /// `.onChange` of the preference, so an editor that already matches the current
    /// preference (nothing "changed" from SwiftUI's perspective) never receives it. Without
    /// this catch-up push, annotations created in that editor render inline until the user
    /// happens to toggle the setting again.
    private func annotationDisplayModesJSON(_ editorState: EditorViewState) -> String? {
        var modeDict: [String: String] = [:]
        for (type, mode) in editorState.annotationDisplayModes {
            modeDict[type.rawValue] = mode.rawValue
        }
        modeDict["__panelOnly"] = editorState.isPanelOnlyMode ? "true" : "false"
        modeDict["__hideCompletedTasks"] = editorState.hideCompletedTasks ? "true" : "false"
        guard let jsonData = try? JSONSerialization.data(withJSONObject: modeDict),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return nil }
        return jsonString
    }

    /// Gives a freshly claimed/created WebView native macOS keyboard focus, so
    /// Cmd-Z/Cmd-Shift-Z route through `UndoRedoCommands`'s `focusedWebView()` check
    /// (via `NSApp.keyWindow?.firstResponder`) as soon as the WebView is ready --
    /// without this, switching editor mode (WYSIWYG<->Source) via its keyboard
    /// shortcut leaves undo silently no-op'ing until the user clicks into the
    /// document, since the mode switch never otherwise hands the new WebView
    /// first-responder status. Same underlying gap the Find-bar fix closed
    /// (`FindBarState.swift`), different trigger.
    ///
    /// `onWebViewReady` can fire synchronously from `makeNSView` -- the preloaded-
    /// WebView path SwiftUI takes both on first editor creation and on every mode
    /// switch -- BEFORE SwiftUI has actually attached the returned view to the
    /// window, so `webView.window` is nil at that point and `makeFirstResponder`
    /// would silently fail if called inline. Defer to the next run-loop turn,
    /// where attachment has normally completed; if it still hasn't (window still
    /// nil), retry once more a turn later. Mirrors `EquationDialog`'s
    /// makeFirstResponder retry pattern ("can silently fail... retrying once on
    /// the next run-loop turn... is a standard, safe defensive pattern").
    @MainActor
    private func restoreEditorFocus(_ webView: WKWebView) {
        DispatchQueue.main.async { [weak webView] in
            guard let webView else { return }
            if let window = webView.window {
                window.makeFirstResponder(webView)
            } else {
                DispatchQueue.main.async { [weak webView] in
                    guard let webView, let window = webView.window else { return }
                    window.makeFirstResponder(webView)
                }
            }
        }
    }

    @ViewBuilder
    var editorView: some View {
        // Wait for preload to complete before showing editor
        if !isEditorPreloadReady {
            // Minimal loading state - just a blank area with theme background
            Color.clear
                .task {
                    // Wait for preload with 2 second timeout
                    _ = await EditorPreloader.shared.waitUntilReady(timeout: 2.0)
                    isEditorPreloadReady = true
                }
        } else {
            // Toggle between MilkdownEditor (WYSIWYG) and CodeMirrorEditor (source)
            // Anchors are injected when switching to source, extracted when switching back
            if editorState.editorMode == .wysiwyg {
                MilkdownEditor(
                    content: $editorState.content,
                    focusModeEnabled: $editorState.focusModeEnabled,
                    cursorPositionToRestore: $cursorPositionToRestore,
                    scrollToOffset: $editorState.scrollToOffset,
                    scrollToBlockId: $editorState.scrollToBlockId,
                    scrollToAnnotationIndex: $editorState.scrollToAnnotationIndex,
                    isResettingContent: $editorState.isResettingContent,
                    contentState: editorState.contentState,
                    isZoomingContent: editorState.isZoomingContent,
                    contentGeneration: editorState.contentGeneration,
                    pollCacheResetGeneration: editorState.pollCacheResetGeneration,
                    themeCSS: currentThemeCSS,
                    onContentChange: { _ in
                        // Content change handling - could trigger outline parsing here
                    },
                    onStatsChange: { words, characters in
                        editorState.updateStats(words: words, characters: characters)
                    },
                    onSectionChange: { title in
                        editorState.currentSectionName = title
                    },
                    onCursorPositionSaved: { position in
                        cursorPositionToRestore = position
                    },
                    onSectionIdChange: { blockId, title in
                        editorState.currentSectionId = editorState.resolveSectionId(blockId: blockId, title: title)
                    },
                    onSelectionChange: { text in
                        editorState.updateSelection(text)
                    },
                    onContentAcknowledged: {
                        // Called when WebView confirms content was set
                        // Used for acknowledgement-based synchronization during zoom
                        editorState.acknowledgeContent()
                    },
                    onWebViewReady: { webView in
                        findBarState.activeWebView = webView
                        structuralUndoController.activeWebView = webView
                        restoreEditorFocus(webView)
                        // Sync current annotation display state - see annotationDisplayModesJSON's
                        // doc comment for why this fresh WebView wouldn't otherwise learn it.
                        if let json = annotationDisplayModesJSON(editorState) {
                            webView.evaluateJavaScript("window.FinalFinal.setAnnotationDisplayModes(\(json))") { _, _ in }
                        }
                        // Configure BlockSyncService with the WebView
                        if let db = documentManager.projectDatabase,
                           let pid = documentManager.projectId {
                            blockSyncService.configure(database: db, projectId: pid, webView: webView)
                            blockSyncService.editorState = editorState
                            // Prevent updateNSView race during initial content push
                            editorState.isResettingContent = true
                            // Atomic push: content + block IDs in one JS call (no temp ID warnings)
                            Task {
                                if let result = fetchBlocksWithIds() {
                                    await blockSyncService.setContentWithBlockIds(
                                        markdown: result.markdown, blockIds: result.blockIds,
                                        imageMeta: result.imageMeta,
                                        cursorBoundary: result.bibBoundaryIndex,
                                        cursorBoundaryEnd: result.bibBoundaryEndIndex,
                                        expectedBlocks: result.expectedBlocks,
                                        zoomMode: editorState.zoomedSectionIds != nil)
                                    // Always sync editorState.content to DB-assembled markdown.
                                    // Without this, updateNSView sees editorState.content (e.g. 1748 chars)
                                    // ≠ lastPushedContent (1747 chars) and re-pushes WITHOUT block IDs,
                                    // destroying all real UUIDs (causing mass deletes).
                                    editorState.content = result.markdown
                                }
                                editorState.isResettingContent = false
                                blockSyncService.startPolling()
                            }
                        }
                    }
                )
            } else {
                CodeMirrorEditor(
                    content: $editorState.sourceContent,
                    focusModeEnabled: $editorState.focusModeEnabled,
                    cursorPositionToRestore: $cursorPositionToRestore,
                    scrollToOffset: $editorState.scrollToOffset,
                    scrollToAnnotationIndex: $editorState.scrollToAnnotationIndex,
                    isResettingContent: $editorState.isResettingContent,
                    pendingImageMeta: $editorState.pendingImageMeta,
                    contentState: editorState.contentState,
                    isZoomingContent: editorState.isZoomingContent,
                    contentGeneration: editorState.contentGeneration,
                    pollCacheResetGeneration: editorState.pollCacheResetGeneration,
                    themeCSS: currentThemeCSS,
                    onContentChange: { newContent in
                        // Update sourceContent with raw content (including anchors)
                        // This keeps anchors in sync for mode switch
                        editorState.sourceContent = newContent

                        // Strip anchors and bibliography marker, then update content for sync/sidebar
                        let cleanContent = sectionSyncService.stripSectionAnchors(from: newContent)
                        editorState.content = SectionSyncService.stripBibliographyMarker(from: cleanContent)
                    },
                    onStatsChange: { words, characters in
                        editorState.updateStats(words: words, characters: characters)
                    },
                    onSectionChange: { title in
                        editorState.currentSectionName = title
                    },
                    onCursorPositionSaved: { position in
                        cursorPositionToRestore = position
                    },
                    onSectionIdChange: { blockId, title in
                        editorState.currentSectionId = editorState.resolveSectionId(blockId: blockId, title: title)
                    },
                    onSelectionChange: { text in
                        editorState.updateSelection(text)
                    },
                    onContentAcknowledged: {
                        editorState.acknowledgeContent()
                    },
                    onWebViewReady: { webView in
                        findBarState.activeWebView = webView
                        structuralUndoController.activeWebView = webView
                        restoreEditorFocus(webView)
                        // Sync current annotation display state - see annotationDisplayModesJSON's
                        // doc comment for why this fresh WebView wouldn't otherwise learn it.
                        if let json = annotationDisplayModesJSON(editorState) {
                            webView.evaluateJavaScript("window.FinalFinal.setAnnotationDisplayModes(\(json))") { _, _ in }
                        }
                        // Push image metadata for width display in CodeMirror previews
                        if let result = fetchBlocksWithIds() {
                            let metaArray = result.imageMeta.compactMap { meta -> [String: Any]? in
                                guard let width = meta.width, let src = meta.src else { return nil }
                                return ["src": src, "width": width]
                            }
                            if !metaArray.isEmpty,
                               let data = try? JSONSerialization.data(withJSONObject: metaArray),
                               let json = String(data: data, encoding: .utf8) {
                                webView.evaluateJavaScript("window.FinalFinal.setImageMeta(\(json))")
                            }
                        }
                    }
                )
            }
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

        // Create definition in DB (reuses existing logic)
        footnoteSyncService.handleImmediateInsertion(label: label, projectId: projectId)

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
            NotificationCenter.default.post(
                name: .scrollToFootnoteDefinition,
                object: nil,
                userInfo: ["label": label]
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
        let bodyBlocks = BlockParser.parse(markdown: body, projectId: projectId)
        let newEnd = newStart + Double(bodyBlocks.count)

        let allBlocks = (try? db.fetchBlocks(projectId: projectId)) ?? []
        let blockAtEnd = allBlocks.first { $0.sortOrder >= newEnd }

        editorState.zoomedBlockRange = (start: newStart, end: blockAtEnd?.sortOrder)
    }
}
