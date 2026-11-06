//
//  ViewNotificationModifiers+LegacySwitch.swift
//  final final
//
//  Today's switch between Rich Text and Markdown (both directions), moved out of ViewNotificationModifiers.swift unchanged in Phase 5 jobs
//  A9 and A10 (docs/architecture/write-queue-plan/phase5/a9-notes.md): it is now the fallback of the carried switch
//  (EditorViewState+SwitchTransition*.swift) and the whole switch under `FF_UI_TESTING_LEGACY_TRANSITION=switch` or while zoomed.
//

import SwiftUI

extension View {
    /// Today's switch from Markdown to Rich Text: the fallback of the carried switch, and the whole switch under
    /// `FF_UI_TESTING_LEGACY_TRANSITION=switch` or while zoomed (Phase 5 job A10). Synchronous.
    @MainActor
    func performLegacySwitchToRichText(editorState: EditorViewState, sectionSyncService: SectionSyncService) {
        // Switching FROM source mode TO WYSIWYG - set state BEFORE flush
        editorState.contentState = .editorTransition
        DebugLog.log(.editor, "[SWITCH→MW] Starting. sourceContent length=\(editorState.sourceContent.count)")
        // Extract the anchors and the bibliography marker from the text the Markdown editor holds NOW, save that text and hand it
        // to Rich Text. (It used to save `editorState.content`, which lags the page by its 50 ms push timer, so keys typed just
        // before the switch were not saved.)
        editorState.commitMarkdownTextForRichTextSwitch(sectionSyncService: sectionSyncService)
        editorState.toggleEditorMode()

        // No fixed wait here. contentState stays .editorTransition until the new Rich Text editor has been handed its
        // content: onWebViewReady (ContentView+EditorPresentation.swift) sets .idle right after setContentWithBlockIds
        // returns and before block polling starts. Backstop: the 5 s contentState watchdog (EditorViewState).
        // History: a 1.5 s Task.sleep stood here (added 2026-02-04 for a "missing # from headers" claim, no
        // reproduction on file); removed in the faster-switch work after VM runs showed headings survive without it.
    }

    /// Today's switch from Rich Text to Markdown: the fallback of the carried switch, and the whole switch under
    /// `FF_UI_TESTING_LEGACY_TRANSITION=switch` or while zoomed (Phase 5 job A9). Synchronous.
    @MainActor
    func performLegacySwitchToMarkdown(editorState: EditorViewState, sectionSyncService: SectionSyncService) {
        // Switching TO source mode - inject anchors
        editorState.contentState = .editorTransition
        DebugLog.log(.editor, "[SWITCH→CM] Starting. content length=\(editorState.content.count)")

        // When zoomed, only inject anchors for zoomed sections
        let sectionsToInject: [SectionViewModel]
        if let zoomedIds = editorState.zoomedSectionIds {
            sectionsToInject = editorState.sections.filter { zoomedIds.contains($0.id) }
        } else {
            sectionsToInject = editorState.sections
        }

        // Flush editor content to blocks DB before computing offsets.
        // Without this, recently-inserted nodes (e.g. images via editor-first
        // approach) may not be in the blocks table yet, causing wrong offsets
        // and anchor injection corruption.
        // `skipUnchangedWrite`: when the stored rows already are what this flush would store (no edit since
        // the last save), nothing is written, so every row keeps its id. A zoomed flush ignores the flag.
        editorState.flushContentToDatabase(overrideContent: editorState.content, skipUnchangedWrite: true)
        DebugLog.log(.editor, "[SWITCH→CM] After flush")

        // Compute offsets from blocks (same data that produced editorState.content)
        var adjustedSections: [SectionViewModel] = []
        if let db = editorState.projectDatabase,
           let pid = editorState.currentProjectId {
            do {
                let fetchedBlocks: [Block]
                if let zoomedIds = editorState.zoomedSectionIds {
                    let allBlocks = try db.fetchBlocks(projectId: pid)
                    fetchedBlocks = ContentView.filterBlocksForZoomStatic(
                        allBlocks, zoomedIds: zoomedIds,
                        zoomedBlockRange: editorState.zoomedBlockRange)
                } else {
                    fetchedBlocks = try db.fetchBlocks(projectId: pid)
                }
                DebugLog.log(.editor, "[SWITCH→CM] Fetched \(fetchedBlocks.count) blocks")
                let sorted = fetchedBlocks.sorted { a, b in
                    let aKey = (a.sortOrder, a.blockType == .heading ? 0 : 1)
                    let bKey = (b.sortOrder, b.blockType == .heading ? 0 : 1)
                    return aKey < bKey
                }
                // MUST stay in sync with BlockParser.assembleMarkdown filtering
                let nonEmpty = sorted.filter { !BlockParser.isEmptyFragment($0.markdownFragment) }
                var blockOffset: [String: Int] = [:]
                var offset = 0
                for (i, block) in nonEmpty.enumerated() {
                    if i > 0 { offset += 2 }
                    blockOffset[block.id] = offset
                    offset += block.markdownFragment.count
                }
                for section in sectionsToInject.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                    if let off = blockOffset[section.id] {
                        adjustedSections.append(section.withUpdates(startOffset: off))
                    }
                }
                DebugLog.log(.editor, "[SWITCH→CM] Sections with offsets: \(adjustedSections.count)")
            } catch {
                DebugLog.log(.editor, "[SWITCH→CM] ERROR fetching blocks: \(error)")
            }
        }

        let withAnchors = sectionSyncService.injectSectionAnchors(
            markdown: editorState.content,
            sections: adjustedSections
        )
        DebugLog.log(.editor, "[SWITCH→CM] After anchors: length=\(withAnchors.count)")
        // Also inject bibliography marker for source mode
        let withBibMarker = sectionSyncService.injectBibliographyMarker(
            markdown: withAnchors,
            sections: sectionsToInject
        )
        // DERIVED REFRESH (default) -- but not a gap: this writes the freshly-mounted
        // CodeMirror instance's OWN mount content, composed just before
        // toggleEditorMode() below actually mounts it. That new instance's
        // `lastLocalEditAt` starts (and is defensively reset to) `.distantPast` on its
        // own mount (CodeMirrorCoordinator.shouldPushContent's undo-mode-switch-focus
        // fix), so the settle-window guard can never suppress THIS push -- no
        // `forcedPushGeneration` bump needed here.
        editorState.sourceContent = withBibMarker
        editorState.toggleEditorMode()
        // Phase 4a: Swift just handed the Markdown editor its text, assembled from the stored rows (the flush above wrote
        // them, or found them unchanged): the per-block writer compares with the stored rows from here. The editorMode
        // `onChange` resets it too at the next render; both leave the baseline on the rows, so their order does not matter.
        editorState.markdownWriter.noteLoaded(text: withBibMarker, pid: editorState.currentProjectId)
        editorState.contentState = .idle
    }
}
