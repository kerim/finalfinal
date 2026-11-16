//
//  EditorViewState+ZoomTargets.swift
//  final final
//
//  Phase 5 job A7: the text a zoom puts into the editor, assembled from the rows. Pulled out of `zoomToSection` and
//  `restoreFullDocumentAndClearZoom` (EditorViewState+Zoom.swift) so today's path and the carried path
//  (EditorViewState+ZoomTransition.swift) assemble exactly the same document. A pure extraction of those functions' assembly lines.
//

import Foundation

/// A document as a zoom hands it to the editor: the markdown and the ids, expected types, image metadata and managed ids that go with it.
struct ZoomTargetDocument {
    let markdown: String
    let blockIds: [String]
    let expected: [BlockParser.BlockAlignmentMeta]
    let imageMeta: [ContentView.ImageBlockMeta]
    let managedBlockIds: Set<String>
}

/// What a zoom IN reads from the rows: the zoomed chapter's document (with its mini-Notes when it has footnote references), the section
/// ids it covers, its sort-order range, the largest footnote label of the whole body, and the zoomed rows themselves.
struct ZoomInTarget {
    let document: ZoomTargetDocument
    let descendantIds: Set<String>
    let range: (start: Double, end: Double?)
    let maxLabel: Int
    let zoomedBlocks: [Block]
}

extension EditorViewState {
    /// The whole document as a zoom out (and the lost-root recovery) pushes it: every row, Bibliography and Notes flagged managed.
    static func fullDocumentTarget(from allBlocks: [Block]) -> ZoomTargetDocument {
        // assembleMarkdownForEditor (not plain assembleMarkdown): this merged content becomes editorState.content again, unlike
        // zoomToSection's zoomedContent (which already excludes bibliography blocks and stays on assembleMarkdown) -- see
        // BlockParser.bibliographyEndMarker's doc comment.
        let mergedContent = BlockParser.assembleMarkdownForEditor(from: allBlocks)
        let allImageMeta = allBlocks
            .filter { $0.blockType == .image }
            .map { ContentView.ImageBlockMeta(id: $0.id, width: $0.imageWidth, caption: $0.imageCaption, alt: $0.imageAlt, src: $0.imageSrc) }
        let allPairs = BlockParser.alignmentPairs(allBlocks)
        // Restored (unzoomed) document includes Bibliography/Notes headings again -- flag them managed so the Cmd-hover zoom hint
        // excludes them (see BlockSyncService.setContentWithBlockIds's managedBlockIds doc comment).
        let managed = Set(allBlocks.filter { $0.isBibliography || $0.isNotes }.map { $0.id })
        return ZoomTargetDocument(
            markdown: mergedContent, blockIds: allPairs.map { $0.id }, expected: allPairs.map { $0.meta }, imageMeta: allImageMeta,
            managedBlockIds: managed)
    }

    /// The zoomed chapter `sectionId` as a zoom in pushes it. Nil (logged) when the block is missing or not a heading. Throws when the rows
    /// cannot be read. Reads `sections` for the descendant ids; changes nothing.
    func buildZoomInTarget(sectionId: String, mode: ZoomMode, db: ProjectDatabase, pid: String) throws -> ZoomInTarget? {
        // Find the heading block BEFORE computing descendant IDs
        guard let headingBlock = try db.fetchBlock(id: sectionId), let headingLevel = headingBlock.headingLevel else {
            DebugLog.log(.zoom, "[Zoom] zoomToSection(\(sectionId)) aborted: block missing or not a heading (headingLevel nil)")
            return nil
        }
        let descendantIds = mode == .shallow ? getShallowDescendantIds(of: sectionId) : getDescendantIds(of: sectionId)

        // Find the range boundary (next heading that ends this zoom scope)
        let sorted = try db.fetchBlocks(projectId: pid).sorted { $0.sortOrder < $1.sortOrder }
        let endSortOrder = zoomEndSortOrder(after: headingBlock, headingLevel: headingLevel, mode: mode, in: sorted)

        // The blocks in the range (the heading included), Bibliography and Notes (managed sections) excluded
        let zoomedBlocks = sorted.filter { block in
            block.sortOrder >= headingBlock.sortOrder && !block.isBibliography && !block.isNotes
                && (endSortOrder == nil || block.sortOrder < endSortOrder!)
        }

        let headingLogMessage = "[Zoom] Heading: id=\(headingBlock.id), sort=\(headingBlock.sortOrder), " +
            "level=\(headingLevel), fragment=\"\(String(headingBlock.markdownFragment.prefix(80)))\""
        DebugLog.log(.zoom, headingLogMessage)
        DebugLog.log(.zoom, "[Zoom] endSortOrder=\(String(describing: endSortOrder)), zoomedBlocks=\(zoomedBlocks.count)")
        if let first = zoomedBlocks.first {
            DebugLog.log(.zoom, "[Zoom] First block: id=\(first.id), sort=\(first.sortOrder), type=\(first.blockType)")
        }

        let zoomedImageMeta = zoomedBlocks
            .filter { $0.blockType == .image }
            .map { ContentView.ImageBlockMeta(id: $0.id, width: $0.imageWidth, caption: $0.imageCaption, alt: $0.imageAlt, src: $0.imageSrc) }
        let zoomedPairs = BlockParser.alignmentPairs(zoomedBlocks)
        var zoomedContent = BlockParser.assembleMarkdown(from: zoomedBlocks)

        // Append mini #Notes section if zoomed content contains footnote references
        let footnoteRefs = FootnoteSyncService.extractFootnoteRefs(from: zoomedContent)
        if !footnoteRefs.isEmpty {
            // Get ALL notes blocks from the full document (heading + definition blocks)
            let notesBlocks = sorted.filter { $0.isNotes }
            if !notesBlocks.isEmpty {
                let notesMd = BlockParser.assembleMarkdown(from: notesBlocks)
                let defs = FootnoteSyncService.extractFootnoteDefinitions(from: notesMd)
                var miniNotes = "\n\n<!-- ::zoom-notes:: -->\n# Notes\n"
                for ref in footnoteRefs {
                    if let def = defs[ref], !def.isEmpty {
                        miniNotes += "\n[^\(ref)]: \(def)\n"
                    } else {
                        miniNotes += "\n[^\(ref)]: \n"
                    }
                }
                zoomedContent += miniNotes
            }
        }

        // Compute max footnote label across full document body
        let bodyBlocks = sorted.filter { !$0.isNotes && !$0.isBibliography }
        let fullBodyContent = BlockParser.assembleMarkdown(from: bodyBlocks)
        let allDocRefs = FootnoteSyncService.extractFootnoteRefs(from: fullBodyContent)
        let maxLabel = allDocRefs.compactMap { Int($0) }.max() ?? 0

        let document = ZoomTargetDocument(
            markdown: zoomedContent, blockIds: zoomedPairs.map { $0.id }, expected: zoomedPairs.map { $0.meta },
            imageMeta: zoomedImageMeta, managedBlockIds: [])
        return ZoomInTarget(
            document: document, descendantIds: descendantIds, range: (start: headingBlock.sortOrder, end: endSortOrder),
            maxLabel: maxLabel, zoomedBlocks: zoomedBlocks)
    }

    /// Phase 5 job A8: the zoomed chapter as the Markdown editor shows it, the section anchors injected at their offsets in the zoomed text
    /// (pulled out of `zoomToSection`, unchanged; the carried Markdown zoom in swaps exactly this text in). The plain text without a section
    /// service.
    func markdownZoomInText(_ target: ZoomInTarget) -> String {
        guard let syncService = sectionSyncService else { return target.document.markdown }
        let blockOffset = Self.markdownBlockOffsets(target.zoomedBlocks)
        let zoomedSections = sections
            .filter { target.descendantIds.contains($0.id) && !$0.isBibliography }
            .sorted { $0.sortOrder < $1.sortOrder }
        let adjustedSections = zoomedSections.compactMap { section in
            blockOffset[section.id].map { section.withUpdates(startOffset: $0) }
        }
        return syncService.injectSectionAnchors(markdown: target.document.markdown, sections: adjustedSections)
    }

    /// Phase 5 job A8: the whole document as the Markdown editor shows it, anchors and the bibliography marker injected (pulled out of
    /// `restoreFullDocumentAndClearZoom`, unchanged; the carried Markdown zoom out swaps exactly this text in).
    func markdownFullDocumentText(_ mergedContent: String, allBlocks: [Block]) -> String {
        guard let syncService = sectionSyncService else { return mergedContent }
        let blockOffset = Self.markdownBlockOffsets(allBlocks)
        let allSectionsList = sections.filter { !$0.isBibliography }.sorted { $0.sortOrder < $1.sortOrder }
        let adjustedSections = allSectionsList.compactMap { section in
            blockOffset[section.id].map { section.withUpdates(startOffset: $0) }
        }
        let withAnchors = syncService.injectSectionAnchors(markdown: mergedContent, sections: adjustedSections)
        return syncService.injectBibliographyMarker(markdown: withAnchors, sections: sections)
    }

    /// Each block's offset in the assembled text of `blocks` (the same data that produced it).
    private static func markdownBlockOffsets(_ blocks: [Block]) -> [String: Int] {
        let sortedBlocks = blocks.sorted { a, b in
            let aKey = (a.sortOrder, a.blockType == .heading ? 0 : 1)
            let bKey = (b.sortOrder, b.blockType == .heading ? 0 : 1)
            return aKey < bKey
        }
        // MUST stay in sync with BlockParser.assembleMarkdown filtering
        let nonEmptyBlocks = sortedBlocks.filter { !BlockParser.isEmptyFragment($0.markdownFragment) }
        var blockOffset: [String: Int] = [:]
        var offset = 0
        for (i, block) in nonEmptyBlocks.enumerated() {
            if i > 0 { offset += 2 }
            blockOffset[block.id] = offset
            offset += block.markdownFragment.count
        }
        return blockOffset
    }

    /// Find the sortOrder of the first heading that ends a zoom scope.
    /// - Full zoom: stops at the next heading with level <= the zoomed heading's level
    /// - Shallow zoom: stops at the very next heading of any level
    func zoomEndSortOrder(after headingBlock: Block, headingLevel: Int, mode: ZoomMode, in sorted: [Block]) -> Double? {
        for block in sorted where block.sortOrder > headingBlock.sortOrder {
            if block.blockType == .heading {
                if mode == .shallow {
                    return block.sortOrder
                } else if let level = block.headingLevel, level <= headingLevel {
                    return block.sortOrder
                }
            }
        }
        return nil
    }
}
