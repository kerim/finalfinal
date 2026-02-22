//
//  EditorViewState+Zoom.swift
//  final final
//

import SwiftUI

// MARK: - Zoom & Content Acknowledgement

extension EditorViewState {

    /// Wait for content acknowledgement from the editor with timeout fallback
    /// Call this AFTER setting content to wait for WebView to confirm it was set
    /// Timeout of 1 second ensures contentState returns to .idle even if callback fails
    func waitForContentAcknowledgement() async {
        isAcknowledged = false

        // Race between acknowledgement and timeout
        // Use a simple timeout approach with Task.sleep and cancellation
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            // If we reach here without being cancelled, the acknowledgement timed out
            // Resume the continuation to prevent deadlock (only if not already acknowledged)
            guard !isAcknowledged else { return }
            isAcknowledged = true
            contentAckContinuation?.resume()
            contentAckContinuation = nil
        }

        // Wait for acknowledgement (or timeout to resume it)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            contentAckContinuation = continuation
        }

        // Cancel timeout if acknowledgement came first
        timeoutTask.cancel()
    }

    /// Called by the editor when content has been confirmed set
    /// Resumes the waiting continuation to allow zoom transition to complete
    func acknowledgeContent() {
        guard !isAcknowledged else { return }
        isAcknowledged = true
        contentAckContinuation?.resume()
        contentAckContinuation = nil
    }

    // MARK: - Subtree Filtering

    func filterToSubtree(sections: [SectionViewModel], rootId: String) -> [SectionViewModel] {
        var idsToInclude = Set<String>([rootId])

        // Build set of all descendants
        var changed = true
        while changed {
            changed = false
            for section in sections where section.parentId != nil && idsToInclude.contains(section.parentId!) {
                if !idsToInclude.contains(section.id) {
                    idsToInclude.insert(section.id)
                    changed = true
                }
            }
        }

        return sections.filter { idsToInclude.contains($0.id) }
    }

    // MARK: - Zoom Operations

    /// Zoom into a section, filtering the editor to show only that section and its descendants
    /// This is async because it needs to coordinate content transitions safely
    /// - Parameters:
    ///   - sectionId: The ID of the section to zoom into
    ///   - mode: Zoom mode (.full for all descendants, .shallow for direct pseudo-children only)
    func zoomToSection(_ sectionId: String, mode: ZoomMode = .full) async {
        // Guard against re-entry during transitions
        guard contentState == .idle else { return }

        guard let db = projectDatabase, let pid = currentProjectId else { return }

        // SET CONTENTSTATE FIRST - before flush to prevent observation race conditions
        contentState = .zoomTransition

        // Flush any pending editor edits before zooming
        flushContentToDatabase()

        // If already zoomed to a different section, unzoom first
        if zoomedSectionId != nil && zoomedSectionId != sectionId {
            await zoomOut()
        }

        guard sections.first(where: { $0.id == sectionId }) != nil else {
            zoomedSectionIds = nil
            zoomedSectionId = nil
            zoomedBlockRange = nil
            contentState = .idle
            return
        }

        do {
            // Find the heading block BEFORE computing descendant IDs
            guard let headingBlock = try db.fetchBlock(id: sectionId),
                  let headingLevel = headingBlock.headingLevel else {
                zoomedSectionIds = nil
                zoomedSectionId = nil
                zoomedBlockRange = nil
                contentState = .idle
                return
            }

            // Calculate zoomed section IDs AFTER confirming block exists
            let descendantIds = mode == .shallow
                ? getShallowDescendantIds(of: sectionId)
                : getDescendantIds(of: sectionId)
            zoomedSectionIds = descendantIds

            // Find the range boundary (next heading that ends this zoom scope)
            let allBlocks = try db.fetchBlocks(projectId: pid)
            let sorted = allBlocks.sorted { $0.sortOrder < $1.sortOrder }
            let endSortOrder = findEndSortOrder(
                after: headingBlock, headingLevel: headingLevel, mode: mode, in: sorted
            )

            // Store range for later use
            zoomedBlockRange = (start: headingBlock.sortOrder, end: endSortOrder)

            // Fetch blocks in the range (including the heading itself)
            // Exclude bibliography and notes blocks (managed sections)
            var zoomedBlocks = sorted.filter { block in
                block.sortOrder >= headingBlock.sortOrder &&
                !block.isBibliography &&
                !block.isNotes &&
                (endSortOrder == nil || block.sortOrder < endSortOrder!)
            }

            #if DEBUG
            print("[Zoom] Heading: id=\(headingBlock.id), sort=\(headingBlock.sortOrder), " +
                "level=\(headingLevel), fragment=\"\(String(headingBlock.markdownFragment.prefix(80)))\"")
            print("[Zoom] endSortOrder=\(String(describing: endSortOrder)), zoomedBlocks=\(zoomedBlocks.count)")
            if let first = zoomedBlocks.first {
                print("[Zoom] First block: id=\(first.id), sort=\(first.sortOrder), type=\(first.blockType)")
            }
            #endif

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

            // Push zoom footnote state to JS BEFORE setting content (prevents timing gap)
            NotificationCenter.default.post(
                name: .setZoomFootnoteState,
                object: nil,
                userInfo: ["zoomed": true, "maxLabel": maxLabel]
            )

            #if DEBUG
            print("[Zoom] Content preview (\(zoomedContent.count) chars): \(String(zoomedContent.prefix(200)))")
            #endif

            // Set zoomed state
            zoomedSectionId = sectionId
            isZoomingContent = true
            content = zoomedContent

            // Update sourceContent for CodeMirror
            if editorMode == .source, let syncService = sectionSyncService {
                // Compute offsets from zoomedBlocks (same data that produced zoomedContent)
                let sortedBlocks = zoomedBlocks.sorted { a, b in
                    let aKey = (a.sortOrder, a.blockType == .heading ? 0 : 1)
                    let bKey = (b.sortOrder, b.blockType == .heading ? 0 : 1)
                    return aKey < bKey
                }
                var blockOffset: [String: Int] = [:]
                var offset = 0
                for (i, block) in sortedBlocks.enumerated() {
                    if i > 0 { offset += 2 }
                    blockOffset[block.id] = offset
                    offset += block.markdownFragment.count
                }

                let zoomedSections = sections
                    .filter { descendantIds.contains($0.id) && !$0.isBibliography }
                    .sorted { $0.sortOrder < $1.sortOrder }
                var adjustedSections: [SectionViewModel] = []
                for section in zoomedSections {
                    if let off = blockOffset[section.id] {
                        adjustedSections.append(section.withUpdates(startOffset: off))
                    }
                }
                sourceContent = syncService.injectSectionAnchors(
                    markdown: zoomedContent,
                    sections: adjustedSections
                )
            } else {
                sourceContent = zoomedContent
            }

            await waitForContentAcknowledgement()

            isZoomingContent = false
            contentState = .idle
        } catch {
            print("[EditorViewState] Zoom error: \(error)")
            zoomedSectionIds = nil
            zoomedSectionId = nil
            zoomedBlockRange = nil
            isZoomingContent = false
            contentState = .idle
        }
    }

    /// Zoom out from current section - fetch ALL blocks from DB and restore full document
    func zoomOut() async {
        guard zoomedSectionId != nil else { return }
        guard let db = projectDatabase, let pid = currentProjectId else {
            zoomedSectionId = nil
            return
        }

        // Caller manages state if already in transition (called from zoomToSection)
        let callerManagedState = (contentState == .zoomTransition)
        if !callerManagedState {
            contentState = .zoomTransition
        }

        // Flush any pending editor edits before reading from DB
        flushContentToDatabase()

        do {
            // Fetch ALL blocks from DB - database is always complete
            let allBlocks = try db.fetchBlocks(projectId: pid)
            let mergedContent = BlockParser.assembleMarkdown(from: allBlocks)

            // Clear zoom footnote state BEFORE pushing full document content
            NotificationCenter.default.post(
                name: .setZoomFootnoteState,
                object: nil,
                userInfo: ["zoomed": false, "maxLabel": 0]
            )

            isZoomingContent = true
            content = mergedContent

            // Update sourceContent for CodeMirror
            if editorMode == .source, let syncService = sectionSyncService {
                // Compute offsets from allBlocks (same data that produced mergedContent)
                let sortedBlocks = allBlocks.sorted { a, b in
                    let aKey = (a.sortOrder, a.blockType == .heading ? 0 : 1)
                    let bKey = (b.sortOrder, b.blockType == .heading ? 0 : 1)
                    return aKey < bKey
                }
                var blockOffset: [String: Int] = [:]
                var offset = 0
                for (i, block) in sortedBlocks.enumerated() {
                    if i > 0 { offset += 2 }
                    blockOffset[block.id] = offset
                    offset += block.markdownFragment.count
                }

                let allSectionsList = sections.filter { !$0.isBibliography }.sorted { $0.sortOrder < $1.sortOrder }
                var adjustedSections: [SectionViewModel] = []
                for section in allSectionsList {
                    if let off = blockOffset[section.id] {
                        adjustedSections.append(section.withUpdates(startOffset: off))
                    }
                }
                let withAnchors = syncService.injectSectionAnchors(
                    markdown: mergedContent,
                    sections: adjustedSections
                )
                sourceContent = syncService.injectBibliographyMarker(
                    markdown: withAnchors,
                    sections: sections
                )
            } else {
                sourceContent = mergedContent
            }

            // Clear zoom state
            zoomedSectionIds = nil
            zoomedSectionId = nil
            zoomedBlockRange = nil

            await waitForContentAcknowledgement()

            isZoomingContent = false

            if !callerManagedState {
                contentState = .idle
                NotificationCenter.default.post(name: .didZoomOut, object: nil)
            }
        } catch {
            print("[EditorViewState] Zoom out error: \(error)")
            zoomedSectionId = nil
            zoomedSectionIds = nil
            zoomedBlockRange = nil
            isZoomingContent = false
            if !callerManagedState {
                contentState = .idle
            }
        }
    }

    /// Simple zoom out without async - for use in synchronous contexts like breadcrumb click
    func zoomOutSync() {
        Task {
            await zoomOut()
        }
    }

    // MARK: - CodeMirror Flush

    /// Immediately persist editor content to the block database (no debounce).
    /// Called before zoom-out, zoom-to, and editor switch to ensure edits are saved.
    /// Handles both zoomed (range replace) and non-zoomed (full replace) cases.
    /// Works for both Milkdown and CodeMirror — content is always available in editorState.content.
    func flushContentToDatabase() {
        guard !content.isEmpty else { return }
        guard let db = projectDatabase, let pid = currentProjectId else { return }

        // Cancel any pending debounced re-parse
        blockReparseTask?.cancel()
        blockReparseTask = nil

        do {
            // Preserve existing heading metadata
            let existing = try db.fetchBlocks(projectId: pid)
            var metadata: [String: SectionMetadata] = [:]
            for block in existing where block.blockType == .heading {
                metadata[block.textContent] = SectionMetadata(
                    status: block.status,
                    tags: block.tags?.isEmpty == false ? block.tags : nil,
                    wordGoal: block.wordGoal
                )
            }

            // Strip mini #Notes marker before parsing (only present when zoomed)
            let contentToParse = SectionSyncService.stripZoomNotes(from: content).stripped

            let blocks = BlockParser.parse(
                markdown: contentToParse,
                projectId: pid,
                existingSectionMetadata: metadata.isEmpty ? nil : metadata
            )

            if let range = zoomedBlockRange {
                // Zoomed: only replace blocks within the zoom range
                try db.replaceBlocksInRange(
                    blocks,
                    for: pid,
                    startSortOrder: range.start,
                    endSortOrder: range.end
                )

                // Recalculate zoomedBlockRange after normalization shifted sort orders.
                // Uses count-based end boundary (not level-based) to prevent higher-level
                // headings (e.g., h1 inside h2 zoom) from shrinking the range and causing
                // content duplication.
                if let zoomedId = zoomedSectionId {
                    var headingBlock = try db.fetchBlock(id: zoomedId)

                    // Fallback: heading renamed → ID not preserved → find first heading in parsed blocks
                    if headingBlock == nil || headingBlock?.blockType != .heading {
                        if let fallback = blocks.first(where: { $0.blockType == .heading }) {
                            headingBlock = try db.fetchBlock(id: fallback.id)
                            zoomedSectionId = fallback.id
                        } else {
                            // Heading deleted entirely → clear zoom state
                            zoomedBlockRange = nil
                            zoomedSectionId = nil
                            zoomedSectionIds = nil
                            return
                        }
                    }

                    if let headingBlock = headingBlock {
                        let newStart = headingBlock.sortOrder
                        // End = first block after all inserted blocks (count-based, not level-based)
                        let newEnd = newStart + Double(blocks.count)
                        let allBlocks = try db.fetchBlocks(projectId: pid)
                        let blockAtEnd = allBlocks.first { $0.sortOrder >= newEnd }
                        zoomedBlockRange = (start: newStart, end: blockAtEnd?.sortOrder)
                    }
                }
            } else {
                // Not zoomed: full document replace (existing behavior)
                try db.replaceBlocks(blocks, for: pid)
            }
        } catch {
            print("[EditorViewState] flushCodeMirrorSyncIfNeeded error: \(error)")
        }
    }

    // MARK: - Block Range Helpers

    /// Find the sortOrder of the first heading that ends a zoom scope.
    /// - Full zoom: stops at the next heading with level <= the zoomed heading's level
    /// - Shallow zoom: stops at the very next heading of any level
    private func findEndSortOrder(
        after headingBlock: Block, headingLevel: Int, mode: ZoomMode, in sorted: [Block]
    ) -> Double? {
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

    // MARK: - Descendant Helpers

    /// Get all descendant section IDs for a given section
    /// Uses document order to find pseudo-sections that belong to the zoomed section
    func getDescendantIds(of sectionId: String) -> Set<String> {
        var ids = Set<String>([sectionId])

        // Ensure sections are sorted by document order
        let sortedSections = sections.sorted { $0.sortOrder < $1.sortOrder }

        // Find the zoomed section's index and level
        guard let rootIndex = sortedSections.firstIndex(where: { $0.id == sectionId }),
              let rootSection = sortedSections.first(where: { $0.id == sectionId }) else {
            return ids
        }
        let rootLevel = rootSection.headerLevel

        // First: Add pseudo-sections that follow in document order
        // Continue until we hit a regular (non-pseudo) section at same or shallower level
        for i in (rootIndex + 1)..<sortedSections.count {
            let section = sortedSections[i]

            // Stop at a regular (non-pseudo) section at same or shallower level
            if !section.isPseudoSection && section.headerLevel <= rootLevel {
                break
            }

            // Include pseudo-sections (they visually belong to the preceding section)
            if section.isPseudoSection {
                ids.insert(section.id)
            }
        }

        // Second: Add all transitive children by parentId
        // This loop handles both regular children AND children of pseudo-sections
        var changed = true
        while changed {
            changed = false
            for section in sortedSections where section.parentId != nil && ids.contains(section.parentId!) {
                if !ids.contains(section.id) {
                    ids.insert(section.id)
                    changed = true
                }
            }
        }

        return ids
    }

    /// Get section ID plus only its direct pseudo-section children
    /// Used for shallow zoom (Option+double-click)
    /// Uses document order to find pseudo-sections that belong to the zoomed section
    func getShallowDescendantIds(of sectionId: String) -> Set<String> {
        var ids = Set<String>([sectionId])

        // Ensure sections are sorted by document order
        let sortedSections = sections.sorted { $0.sortOrder < $1.sortOrder }

        // Find the section's index and level
        guard let rootIndex = sortedSections.firstIndex(where: { $0.id == sectionId }),
              let rootSection = sortedSections.first(where: { $0.id == sectionId }) else {
            return ids
        }
        let rootLevel = rootSection.headerLevel

        // Add only pseudo-sections that immediately follow in document order
        // Stop at any regular section at same or shallower level
        for i in (rootIndex + 1)..<sortedSections.count {
            let section = sortedSections[i]

            // Stop at a regular (non-pseudo) section at same or shallower level
            if !section.isPseudoSection && section.headerLevel <= rootLevel {
                break
            }

            // Include pseudo-sections only (shallow = no children, just pseudo-sections)
            if section.isPseudoSection {
                ids.insert(section.id)
            }
        }

        return ids
    }

}
