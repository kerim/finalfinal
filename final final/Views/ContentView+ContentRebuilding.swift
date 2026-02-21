//
//  ContentView+ContentRebuilding.swift
//  final final
//
//  Content rebuilding, zoom filtering, detail/editor views, and annotation handlers.
//

import SwiftUI

extension ContentView {
    /// Fetch blocks from DB and return assembled markdown + ordered block IDs
    /// Used for atomic content+ID pushes (bibliography rebuild, etc.)
    func fetchBlocksWithIds() -> (markdown: String, blockIds: [String])? {
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

            let sorted = allBlocks.sorted { $0.sortOrder < $1.sortOrder }
            let markdown = BlockParser.assembleMarkdown(from: sorted)
            let ids = sorted.map { $0.id }
            return (markdown, ids)
        } catch {
            print("[ContentView] Error fetching blocks with IDs: \(error)")
            return nil
        }
    }

    /// Rebuild document content from block database
    /// For zoom state, fetches only the zoomed range; otherwise fetches all blocks
    func rebuildDocumentContent() {
        #if DEBUG
        print("[rebuildDocumentContent] Called. zoomed=\(editorState.zoomedSectionIds != nil), contentState=\(editorState.contentState)")
        #endif
        // Guard against rebuilding during editor transition
        guard editorState.contentState != .editorTransition else {
            return
        }
        guard let db = documentManager.projectDatabase,
              let pid = documentManager.projectId else { return }

        do {
            let allBlocks: [Block]
            if let zoomedIds = editorState.zoomedSectionIds {
                // When zoomed, only include blocks in the zoomed range
                let blocks = try db.fetchBlocks(projectId: pid)
                // Filter to blocks that fall within zoomed heading ranges
                allBlocks = filterBlocksForZoom(blocks, zoomedIds: zoomedIds, zoomedBlockRange: editorState.zoomedBlockRange)
            } else {
                allBlocks = try db.fetchBlocks(projectId: pid)
            }

            editorState.content = BlockParser.assembleMarkdown(from: allBlocks)

            // Update sourceContent for CodeMirror (when in source mode)
            updateSourceContentIfNeeded()
        } catch {
            print("[ContentView] Error rebuilding content from blocks: \(error)")
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
            return blocks.sorted { $0.sortOrder < $1.sortOrder }.filter { block in
                guard !block.isBibliography else { return false }
                guard block.sortOrder >= range.start else { return false }
                if let end = range.end { guard block.sortOrder < end else { return false } }
                return true
            }
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
                var blockOffset: [String: Int] = [:]
                var offset = 0
                for (i, block) in sorted.enumerated() {
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
                if !editorState.focusModeEnabled {
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
                    onScrollToAnnotation: { offset in
                        editorState.scrollTo(offset: offset)
                    },
                    onToggleCompletion: { annotation in
                        toggleAnnotationCompletion(annotation)
                    },
                    onUpdateAnnotationText: { annotation, newText in
                        handleAnnotationTextUpdate(annotation, newText: newText)
                    }
                )
            }
        }
    }

    /// Toggle annotation completion and update both markdown and database
    func toggleAnnotationCompletion(_ annotation: AnnotationViewModel) {
        // Toggle local state
        annotation.isCompleted.toggle()

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
        // 1. Suppress sync to prevent feedback loop
        annotationSyncService.isSyncSuppressed = true

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
                print("[ContentView] Error updating annotation: \(error.localizedDescription)")
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
            annotationSyncService.isSyncSuppressed = false
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
                    isResettingContent: $editorState.isResettingContent,
                    contentState: editorState.contentState,
                    isZoomingContent: editorState.isZoomingContent,
                    themeCSS: currentThemeCSS,
                    onContentChange: { _ in
                        // Content change handling - could trigger outline parsing here
                    },
                    onStatsChange: { words, characters in
                        editorState.updateStats(words: words, characters: characters)
                    },
                    onCursorPositionSaved: { position in
                        cursorPositionToRestore = position
                    },
                    onContentAcknowledged: {
                        // Called when WebView confirms content was set
                        // Used for acknowledgement-based synchronization during zoom
                        editorState.acknowledgeContent()
                    },
                    onWebViewReady: { webView in
                        findBarState.activeWebView = webView
                        // Configure BlockSyncService with the WebView
                        if let db = documentManager.projectDatabase,
                           let pid = documentManager.projectId {
                            blockSyncService.configure(database: db, projectId: pid, webView: webView)
                            // Prevent updateNSView race during initial content push
                            editorState.isResettingContent = true
                            // Atomic push: content + block IDs in one JS call (no temp ID warnings)
                            Task {
                                if let result = fetchBlocksWithIds() {
                                    await blockSyncService.setContentWithBlockIds(
                                        markdown: result.markdown, blockIds: result.blockIds)
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
                    isResettingContent: $editorState.isResettingContent,
                    contentState: editorState.contentState,
                    isZoomingContent: editorState.isZoomingContent,
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
                    onCursorPositionSaved: { position in
                        cursorPositionToRestore = position
                    },
                    onWebViewReady: { webView in
                        findBarState.activeWebView = webView
                    }
                )
            }
        }
    }
}
