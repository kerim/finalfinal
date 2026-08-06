//
//  Database+BlocksReorder.swift
//  final final
//
//  Block reorder, replace, and normalize operations.
//

import Foundation
import GRDB

// MARK: - Heading Update Info

/// Information about heading changes during reorder/hierarchy enforcement
/// Passed from ContentView to reorderAllBlocks so heading markdownFragment and level
/// can be updated atomically alongside sort order changes.
struct HeadingUpdate: Sendable {
    let markdownFragment: String?
    let headingLevel: Int?
}

// MARK: - Block Heading Metadata

/// Preserved heading metadata during block replacement (avoids large tuple)
private struct HeadingMetadata {
    let status: SectionStatus?
    let tags: [String]?
    let wordGoal: Int?
    let goalType: GoalType
    let aggregateGoal: Int?
    let aggregateGoalType: GoalType
    let isBibliography: Bool
    let isNotes: Bool
}

/// Preserved image metadata during block replacement
private struct ImageMeta {
    let imageCaption: String?
    let imageWidth: Int?
}

/// A single existing heading's id + metadata, queued by title so duplicate-titled headings
/// are matched by occurrence index (1st old "Notes" -> 1st new "Notes", 2nd -> 2nd, ...)
/// instead of every same-titled heading colliding on one scalar slot. See the FIFO-queue
/// usage below for why: absolute position would churn every downstream id when a paragraph
/// is inserted above a heading, so occurrence-within-title is the stable key instead.
private struct PreservedHeading {
    let id: String
    let metadata: HeadingMetadata
}

// MARK: - ProjectDatabase Block Reorder/Replace

extension ProjectDatabase {

    /// Replace all blocks for a project, preserving heading IDs and metadata by title match.
    /// Used during initial parse, project open, and non-zoomed CodeMirror re-parse.
    func replaceBlocks(_ blocks: [Block], for projectId: String) throws {
        try write { db in
            let existingBlocks = try Block
                .filter(Block.Columns.projectId == projectId)
                .order(Block.Columns.sortOrder)
                .fetchAll(db)

            // Queue existing headings by title, in existing-document order. A duplicate title
            // (two headings both named "Notes", say) gets a queue of length > 1; consuming the
            // new parse in order pops the front of the matching title's queue, so the nth
            // heading titled T in the new parse inherits id+metadata from the nth heading
            // titled T in the old rows — not just the first (id) and last (metadata) as before,
            // which churned ids and cross-contaminated metadata on every duplicate title.
            var headingsByTitle: [String: [PreservedHeading]] = [:]
            for block in existingBlocks where block.blockType == .heading {
                headingsByTitle[block.textContent, default: []].append(
                    PreservedHeading(
                        id: block.id,
                        metadata: HeadingMetadata(
                            status: block.status, tags: block.tags,
                            wordGoal: block.wordGoal, goalType: block.goalType,
                            aggregateGoal: block.aggregateGoal, aggregateGoalType: block.aggregateGoalType,
                            isBibliography: block.isBibliography, isNotes: block.isNotes
                        )
                    )
                )
            }

            // Build image metadata lookup from existing blocks
            var imageMetaBySrc: [String: ImageMeta] = [:]
            for block in existingBlocks where block.blockType == .image {
                if let src = block.imageSrc, !src.isEmpty {
                    imageMetaBySrc[src] = ImageMeta(
                        imageCaption: block.imageCaption,
                        imageWidth: block.imageWidth
                    )
                }
            }

            if !imageMetaBySrc.isEmpty {
                DebugLog.log(.data, "[replaceBlocks] Image metadata to preserve: \(imageMetaBySrc.mapValues { "width=\($0.imageWidth ?? -1)" })")
            }

            try Block.filter(Block.Columns.projectId == projectId).deleteAll(db)

            for var block in blocks {
                // Preserve heading ID and metadata by occurrence-indexed title match: pop the
                // front of this title's queue and apply id + metadata from that SAME popped
                // entry in one branch (not two separate lookups), so they can never come from
                // two different existing occurrences of the same title. A unique title has a
                // one-element queue, which behaves exactly like the old first-match-wins.
                if block.blockType == .heading,
                   var queue = headingsByTitle[block.textContent], !queue.isEmpty {
                    let preserved = queue.removeFirst()
                    headingsByTitle[block.textContent] = queue
                    block.id = preserved.id
                    block.status = preserved.metadata.status
                    block.tags = preserved.metadata.tags
                    block.wordGoal = preserved.metadata.wordGoal
                    block.goalType = preserved.metadata.goalType
                    block.aggregateGoal = preserved.metadata.aggregateGoal
                    block.aggregateGoalType = preserved.metadata.aggregateGoalType
                    if preserved.metadata.isBibliography { block.isBibliography = true }
                    if preserved.metadata.isNotes { block.isNotes = true }
                }
                // Preserve image metadata by imageSrc match
                if block.blockType == .image, let src = block.imageSrc, !src.isEmpty {
                    // Legacy migration only: recover a caption from a leading
                    // <!-- caption: ... --> comment line, same guard as the gap-fill block
                    // below (only if the parser hasn't already set imageCaption — new-format
                    // fragments set it, even to "", via BlockParser.parseImageFragmentMeta) and
                    // anchored (`^`) so this can only match a comment immediately preceding the
                    // image, not one appearing anywhere else in the fragment.
                    let frag = block.markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines)
                    if block.imageCaption == nil,
                        let captionRange = frag.range(
                            of: #"^<!--\s*caption:\s*(.*?)\s*-->"#, options: .regularExpression
                        ) {
                        let fullMatch = String(frag[captionRange])
                        if let textRange = fullMatch.range(of: #"(?<=caption:\s).*?(?=\s*-->)"#, options: .regularExpression) {
                            block.imageCaption = String(fullMatch[textRange])
                        }
                    }
                    // Gap-fill only: don't overwrite parser-extracted values with stale DB cache
                    if let meta = imageMetaBySrc[src] {
                        if block.imageWidth == nil, let width = meta.imageWidth {
                            block.imageWidth = width
                        }
                        if block.imageCaption == nil, let caption = meta.imageCaption {
                            block.imageCaption = caption
                        }
                        imageMetaBySrc.removeValue(forKey: src)  // first-match-wins
                    }
                    DebugLog.log(.data, "[replaceBlocks] Image block src=\(block.imageSrc ?? "nil") width=\(block.imageWidth ?? -1)")
                }
                try block.insert(db)
            }

        }
    }

    /// Replace blocks within a sort order range (used during zoomed CodeMirror re-parse).
    /// Only deletes/inserts blocks in [startSortOrder, endSortOrder), preserving blocks outside the zoom.
    /// Restores heading metadata (status, tags, wordGoal, goalType) by title match.
    func replaceBlocksInRange(
        _ newBlocks: [Block],
        for projectId: String,
        startSortOrder: Double,
        endSortOrder: Double?
    ) throws {
        try write { db in
            // 1. Fetch existing blocks in range to preserve heading metadata and IDs
            var existingQuery = Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.sortOrder >= startSortOrder)
            if let end = endSortOrder {
                existingQuery = existingQuery.filter(Block.Columns.sortOrder < end)
            }
            let existingBlocks = try existingQuery.order(Block.Columns.sortOrder).fetchAll(db)

            // Count how many NEW headings share each title — this is how many old
            // occurrences of that title the pop queue below will actually reach (the 1st new
            // heading titled T claims the 1st old occurrence titled T, the 2nd new claims the
            // 2nd old, ...). Used below to decide, per OLD occurrence, whether its own slot
            // will ever be popped.
            var newHeadingCountByTitle: [String: Int] = [:]
            for block in newBlocks where block.blockType == .heading {
                newHeadingCountByTitle[block.textContent, default: 0] += 1
            }

            // Group existing headings by title, in existing-range order (preserves
            // zoomedSectionId across re-parses), then split each title's occurrences into
            // protectedHeadingIds (never deleted, never eligible to be popped) vs.
            // headingsByTitle (the pop queue consumed below). A duplicate title gets a queue
            // of length > 1; consuming the new parse in order pops the front of the matching
            // title's queue, so the nth heading titled T in the new parse inherits
            // id+metadata from the nth QUEUED heading titled T in the old rows —
            // occurrence-index matching, not absolute position (position would churn every
            // downstream id when a paragraph is inserted above a heading).
            //
            // Real invariant this provides: a machine-managed (isNotes/isBibliography) old
            // heading is protected specifically when ITS OWN occurrence slot — its position
            // among old headings sharing its title — falls at or beyond
            // newHeadingCountByTitle for that title, i.e. no new heading will ever reach it
            // to pop it. A title wholly absent from newBlocks has zero consumable slots, so
            // every occurrence of it is protected — the common case, unchanged from before.
            // The fix only changes behavior on a COUNT MISMATCH: e.g. a plain user heading
            // that collides in title with the machine "Notes" heading used to strip
            // protection from every "Notes"-titled occurrence (title-only check), including
            // the machine one, even when the machine heading's own queue slot was never
            // going to be reached by the single colliding new heading — silently deleting
            // the machine section with nothing to bring it back. Because protected
            // occurrences are excluded from headingsByTitle entirely, they are never
            // candidates to be popped in the first place; a still-protected heading's queue
            // slot can never be popped, but that was never the actual bug — the bug was
            // protection LAPSING (a title leaving the protected set) despite the specific
            // machine occurrence's slot remaining unreachable. See the must-fix tests below
            // (title-collision-with-protected-heading) for the exact scenario this guards.
            var existingHeadingsByTitle: [String: [Block]] = [:]
            for block in existingBlocks where block.blockType == .heading {
                existingHeadingsByTitle[block.textContent, default: []].append(block)
            }
            var protectedHeadingIds: Set<String> = []
            var headingsByTitle: [String: [PreservedHeading]] = [:]
            for (title, occurrences) in existingHeadingsByTitle {
                let consumable = newHeadingCountByTitle[title, default: 0]
                for (index, block) in occurrences.enumerated() {
                    if (block.isNotes || block.isBibliography) && index >= consumable {
                        protectedHeadingIds.insert(block.id)
                        continue
                    }
                    headingsByTitle[title, default: []].append(
                        PreservedHeading(
                            id: block.id,
                            metadata: HeadingMetadata(
                                status: block.status,
                                tags: block.tags,
                                wordGoal: block.wordGoal,
                                goalType: block.goalType,
                                aggregateGoal: block.aggregateGoal,
                                aggregateGoalType: block.aggregateGoalType,
                                isBibliography: block.isBibliography,
                                isNotes: block.isNotes
                            )
                        )
                    )
                }
            }

            // Safety net: Notes and Bibliography rows are machine-managed by their sync
            // services (FootnoteSyncService / BibliographySyncService), symmetric with the
            // guard in Database+Blocks.swift's applyBlockChangesFromEditor. A zoomed CodeMirror
            // re-parse must never silently delete them just because the current in-editor view
            // doesn't include them — flushContentToDatabase strips the mini-Notes text before
            // parsing for the footnote-insertion path, so newBlocks legitimately contains zero
            // isNotes rows on that call, which previously meant any real Notes row whose
            // sortOrder fell inside [start, end) was deleted with nothing to replace it.
            // Existing non-heading rows of these types are preserved untouched below (excluded
            // from the delete query); if newBlocks legitimately contains a matching (same-label)
            // Notes row, it is merged into the preserved row in place instead of inserted as a
            // duplicate alongside it.
            var notesRowByLabel: [String: Block] = [:]
            for block in existingBlocks where block.isNotes {
                if let label = FootnoteSyncService.parseNotesLabel(from: block.markdownFragment)?.label {
                    notesRowByLabel[label] = block
                }
            }

            // The "# Notes"/"# Bibliography" HEADING itself needs a different rule than the
            // paragraph rows above: it normally survives via the delete-then-reinsert-by-title-
            // match flow below (which already preserves its id/metadata safely), but that only
            // works if its own occurrence slot actually gets popped by a same-titled newBlocks
            // heading (see protectedHeadingIds, computed above alongside the queue). When it
            // doesn't — newBlocks omits the title entirely (the mini-Notes-stripped scenario),
            // or a colliding duplicate title consumes an earlier slot and leaves this
            // occurrence's slot unreached — protectedHeadingIds already excludes it from the
            // delete query below, so unconditionally deleting it here can no longer orphan it.

            // Every row the delete-then-reinsert logic below will NOT touch: preserved
            // (undeleted) non-heading isNotes/isBibliography rows, plus a protected
            // "# Notes"/"# Bibliography" heading (protectedHeadingIds, above). These keep
            // whatever DB row they already have — nothing below assigns them a fresh sortOrder,
            // so they'd otherwise be left at their stale original position. Collected here (in
            // original relative order, since existingBlocks is already sorted by sortOrder) so
            // step 3.5 below can re-anchor them immediately after the new content instead of
            // leaving them at a stale absolute position that can numerically collide with, or
            // fall inside, the freshly-sequenced new blocks — which previously let a newly-typed
            // paragraph land between the preserved Notes heading and its own footnote
            // definition, splitting the Notes section.
            let preservedRowIds: [String] = existingBlocks
                .filter { block in
                    protectedHeadingIds.contains(block.id) ||
                    ((block.isNotes || block.isBibliography) && block.blockType != .heading)
                }
                .map { $0.id }

            // Build image metadata lookup
            var imageMetaBySrc: [String: ImageMeta] = [:]
            for block in existingBlocks where block.blockType == .image {
                if let src = block.imageSrc, !src.isEmpty {
                    imageMetaBySrc[src] = ImageMeta(
                        imageCaption: block.imageCaption,
                        imageWidth: block.imageWidth
                    )
                }
            }

            // 2. Delete blocks in range — never delete non-heading isNotes/isBibliography rows
            // (machine-managed, see safety-net comment above), and never delete an
            // isNotes/isBibliography HEADING that has no matching replacement in newBlocks
            // (protectedHeadingIds, see comment above). Any other heading — including one of
            // these headings when newBlocks DOES contain a same-titled replacement — keeps
            // going through the existing delete-then-reinsert-by-title-match flow below.
            var deleteQuery = Block
                .filter(Block.Columns.projectId == projectId)
                .filter(Block.Columns.sortOrder >= startSortOrder)
                .filter(
                    Block.Columns.blockType == BlockType.heading.rawValue ||
                    (Block.Columns.isNotes == false && Block.Columns.isBibliography == false)
                )
            if !protectedHeadingIds.isEmpty {
                deleteQuery = deleteQuery.filter(!protectedHeadingIds.contains(Block.Columns.id))
            }
            if let end = endSortOrder {
                deleteQuery = deleteQuery.filter(Block.Columns.sortOrder < end)
            }
            try deleteQuery.deleteAll(db)

            // 2.5. Shift blocks after range to prevent sort order collisions when inserted
            // blocks — plus any preserved rows re-anchored in step 3.5 below — overflow the
            // original range. Reserving room for preservedRowIds.count here too (not just
            // newBlocks.count) is what keeps step 3.5's re-anchored positions from themselves
            // colliding with whatever comes after the range.
            if let end = endSortOrder {
                let insertEnd = startSortOrder + Double(newBlocks.count) + Double(preservedRowIds.count)
                if insertEnd > end {
                    let shift = insertEnd - end
                    try db.execute(
                        sql: """
                            UPDATE block SET sortOrder = sortOrder + ?, updatedAt = ?
                            WHERE projectId = ? AND sortOrder >= ?
                            """,
                        arguments: [shift, Date(), projectId, end]
                    )
                }
            }

            // Track footnote labels already claimed within this batch — whether by merging into
            // a preserved row or by falling through to a normal insert below — so a second
            // newBlocks entry with the same label (e.g. two "[^1]:" paragraphs from a
            // copy-paste slip or an interrupted renumbering) never produces a second DB row for
            // that label. First-occurrence-wins, matching the imageMetaBySrc dedup convention
            // used elsewhere in this file.
            var claimedNotesLabels: Set<String> = []

            // 3. Insert new blocks with sort orders starting at startSortOrder
            for (index, var block) in newBlocks.enumerated() {
                block.sortOrder = startSortOrder + Double(index)

                // Bibliography rows are 100% machine-generated (BibliographySyncService is the
                // sole writer); never insert a non-heading one through this path. The existing
                // (preserved, undeleted) row above remains authoritative. The "# Bibliography"
                // heading itself is excluded here (it goes through the normal
                // delete-then-reinsert-by-title-match flow below, which already handles it).
                if block.isBibliography && block.blockType != .heading {
                    DebugLog.log(.data, "[replaceBlocksInRange] Skipping insert of bibliography-shaped block (machine-managed)")
                    continue
                }

                // Notes rows: merge into the preserved existing row by label (same rule as the
                // applyBlockChangesFromEditor guard) instead of inserting a duplicate. A user's
                // legitimate label-preserving text edit reaching this path still lands (we copy
                // its content onto the existing row); a stale/mismatched label falls through to
                // a normal insert below rather than being silently dropped. (The "# Notes"
                // heading itself never matches parseNotesLabel's "[^N]:" pattern, so it always
                // falls through to the title-match flow below, same as any other heading.)
                if block.isNotes && block.blockType != .heading,
                   let label = FootnoteSyncService.parseNotesLabel(from: block.markdownFragment)?.label {
                    if claimedNotesLabels.contains(label) {
                        // Duplicate label within this same batch (e.g. two "[^1]:" paragraphs
                        // from a copy-paste slip) — the first occurrence above already claimed
                        // this label (merged or inserted); drop this one rather than producing a
                        // second DB row with the same footnote label.
                        DebugLog.log(.data, "[replaceBlocksInRange] Skipping duplicate notes label in batch: \(label)")
                        continue
                    }
                    claimedNotesLabels.insert(label)

                    if var existingNotesRow = notesRowByLabel[label] {
                        existingNotesRow.markdownFragment = block.markdownFragment
                        existingNotesRow.textContent = block.textContent
                        existingNotesRow.recalculateWordCount()
                        existingNotesRow.updatedAt = Date()
                        try existingNotesRow.update(db)
                        notesRowByLabel.removeValue(forKey: label)
                        continue
                    }
                }

                // 4 & 5. Preserve heading ID and metadata by occurrence-indexed title match: pop
                // the front of this title's queue and apply id + metadata from that SAME popped
                // entry in one branch, so they can never come from two different existing
                // occurrences of the same title. A unique title has a one-element queue, which
                // behaves exactly like the old first-match-wins.
                if block.blockType == .heading,
                   var queue = headingsByTitle[block.textContent], !queue.isEmpty {
                    let preserved = queue.removeFirst()
                    headingsByTitle[block.textContent] = queue
                    block.id = preserved.id
                    block.status = preserved.metadata.status
                    block.tags = preserved.metadata.tags
                    block.wordGoal = preserved.metadata.wordGoal
                    block.goalType = preserved.metadata.goalType
                    block.aggregateGoal = preserved.metadata.aggregateGoal
                    block.aggregateGoalType = preserved.metadata.aggregateGoalType
                    if preserved.metadata.isBibliography { block.isBibliography = true }
                    if preserved.metadata.isNotes { block.isNotes = true }
                }

                // 6. Preserve image metadata by imageSrc match
                if block.blockType == .image, let src = block.imageSrc, !src.isEmpty {
                    // Legacy migration only: recover a caption from a leading
                    // <!-- caption: ... --> comment line, same guard as the gap-fill block
                    // below (only if the parser hasn't already set imageCaption — new-format
                    // fragments set it, even to "", via BlockParser.parseImageFragmentMeta) and
                    // anchored (`^`) so this can only match a comment immediately preceding the
                    // image, not one appearing anywhere else in the fragment.
                    let frag = block.markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines)
                    if block.imageCaption == nil,
                        let captionRange = frag.range(
                            of: #"^<!--\s*caption:\s*(.*?)\s*-->"#, options: .regularExpression
                        ) {
                        let fullMatch = String(frag[captionRange])
                        if let textRange = fullMatch.range(of: #"(?<=caption:\s).*?(?=\s*-->)"#, options: .regularExpression) {
                            block.imageCaption = String(fullMatch[textRange])
                        }
                    }
                    // Gap-fill only: don't overwrite parser-extracted values with stale DB cache
                    if let meta = imageMetaBySrc[src] {
                        if block.imageWidth == nil, let width = meta.imageWidth {
                            block.imageWidth = width
                        }
                        if block.imageCaption == nil, let caption = meta.imageCaption {
                            block.imageCaption = caption
                        }
                        imageMetaBySrc.removeValue(forKey: src)
                    }
                }

                try block.insert(db)
            }

            // 3.5. Re-anchor preserved isNotes/isBibliography rows (and any protected heading,
            // see preservedRowIds above) immediately after all newly-inserted content. They kept
            // their original, stale sortOrder through the merge/skip logic above — left in
            // place, that stale value can numerically fall inside the range the new blocks now
            // occupy (most commonly when endSortOrder is nil, the normal case for zooming a
            // document's last section, which sits right before its own trailing footnotes). The
            // final renormalize step below only breaks sortOrder ties by heading-vs-non-heading,
            // so an actual collision there falls back to arbitrary DB/fetch order — which could
            // split a preserved Notes section from its own heading. Assigning fresh sequential
            // positions here — preserving relative order to each other, anchored right after the
            // last new block's slot — fixes that. Re-fetch each row fresh by id (rather than
            // reusing the pre-loop existingBlocks snapshot) so a content update already applied
            // by the merge logic above isn't clobbered by a stale copy.
            if !preservedRowIds.isEmpty {
                let anchorBase = startSortOrder + Double(newBlocks.count)
                let now = Date()
                for (offset, rowId) in preservedRowIds.enumerated() {
                    guard var row = try Block.fetchOne(db, key: rowId) else { continue }
                    let newSortOrder = anchorBase + Double(offset)
                    if row.sortOrder != newSortOrder {
                        row.sortOrder = newSortOrder
                        row.updatedAt = now
                        try row.update(db)
                    }
                }
            }

            // 6. Normalize sort orders inline (atomic with delete+insert above)
            let allProjectBlocks = try Block
                .filter(Block.Columns.projectId == projectId)
                .order(Block.Columns.sortOrder)
                .fetchAll(db)
            let sorted = allProjectBlocks.sorted { a, b in
                let aKey = (a.sortOrder, a.blockType == .heading ? 0 : 1)
                let bKey = (b.sortOrder, b.blockType == .heading ? 0 : 1)
                return aKey < bKey
            }
            let now = Date()
            for (index, var block) in sorted.enumerated() {
                let newSortOrder = Double(index + 1)
                if block.sortOrder != newSortOrder {
                    block.sortOrder = newSortOrder
                    block.updatedAt = now
                    try block.update(db)
                }
            }
        }
    }

    // MARK: - Reorder All Blocks (Atomic)

    /// Reorder ALL blocks (headings + body) to match a new section order.
    /// Body blocks follow their heading in the order they appeared before reorder.
    /// Executes in a single write transaction for atomicity.
    ///
    /// Algorithm:
    /// 1. Fetch all blocks sorted by current sortOrder
    /// 2. Group: for each heading/pseudo-section/bibliography, collect body blocks that follow
    ///    until the next group leader → those are its "body blocks"
    /// 3. Collect orphan body blocks before the first heading (preamble)
    /// 4. Re-assign sequential sort orders: preamble first, then for each heading in section
    ///    order → heading + its body blocks
    /// 5. Apply heading updates (markdownFragment, headingLevel) if provided
    func reorderAllBlocks(
        sections: [SectionViewModel],
        projectId: String,
        headingUpdates: [String: HeadingUpdate] = [:]
    ) throws {
        try write { db in
            // 1. Fetch all blocks in current sort order
            let allBlocks = try Block
                .filter(Block.Columns.projectId == projectId)
                .order(Block.Columns.sortOrder)
                .fetchAll(db)

            // 2. Group blocks: each "group leader" (heading, pseudo-section, bibliography)
            //    owns subsequent non-leader blocks until the next leader
            let sectionIds = Set(sections.map { $0.id })
            var groups: [String: [Block]] = [:]  // leaderId -> body blocks
            var preamble: [Block] = []           // body blocks before first leader
            var currentLeaderId: String?
            var leaderOrder: [String] = []       // preserves original leader order for lookup

            for block in allBlocks {
                let isLeader = sectionIds.contains(block.id)

                if isLeader {
                    currentLeaderId = block.id
                    groups[block.id] = []
                    leaderOrder.append(block.id)
                } else if let leaderId = currentLeaderId {
                    groups[leaderId, default: []].append(block)
                } else {
                    // Body block before any heading (preamble)
                    preamble.append(block)
                }
            }

            // 3. Build new order: preamble, then sections in new order with their body blocks
            var sortCounter: Double = 1.0
            let now = Date()

            // Preamble blocks first
            for var block in preamble {
                if block.sortOrder != sortCounter {
                    block.sortOrder = sortCounter
                    block.updatedAt = now
                    try block.update(db)
                }
                sortCounter += 1.0
            }

            // Sections in the order specified by the sections array
            for section in sections {
                // Update the heading/leader block
                if var headingBlock = try Block.fetchOne(db, key: section.id) {
                    headingBlock.sortOrder = sortCounter
                    headingBlock.updatedAt = now

                    // Apply heading updates if provided
                    if let update = headingUpdates[section.id] {
                        if let fragment = update.markdownFragment {
                            headingBlock.markdownFragment = fragment
                        }
                        if let level = update.headingLevel {
                            headingBlock.headingLevel = level
                        }
                    }

                    try headingBlock.update(db)
                    sortCounter += 1.0

                    // Body blocks follow in their original order
                    if let bodyBlocks = groups[section.id] {
                        for var bodyBlock in bodyBlocks {
                            if bodyBlock.sortOrder != sortCounter {
                                bodyBlock.sortOrder = sortCounter
                                bodyBlock.updatedAt = now
                                try bodyBlock.update(db)
                            }
                            sortCounter += 1.0
                        }
                    }
                }
            }
        }
    }

    // MARK: - Sort Order Operations

    /// Reorder a block (drag-and-drop handler)
    func reorderBlock(id: String, afterBlockId: String?) throws {
        try write { db in
            guard var block = try Block.fetchOne(db, key: id) else { return }

            let projectId = block.projectId
            var newSortOrder: Double

            if let afterId = afterBlockId {
                guard let afterBlock = try Block.fetchOne(db, key: afterId) else { return }

                // Find the next block after the target
                let nextBlock = try Block
                    .filter(Block.Columns.projectId == projectId)
                    .filter(Block.Columns.sortOrder > afterBlock.sortOrder)
                    .filter(Block.Columns.id != id)
                    .order(Block.Columns.sortOrder)
                    .fetchOne(db)

                if let next = nextBlock {
                    newSortOrder = (afterBlock.sortOrder + next.sortOrder) / 2.0
                } else {
                    newSortOrder = afterBlock.sortOrder + 1.0
                }
            } else {
                // Move to beginning
                let firstBlock = try Block
                    .filter(Block.Columns.projectId == projectId)
                    .filter(Block.Columns.id != id)
                    .order(Block.Columns.sortOrder)
                    .fetchOne(db)

                if let first = firstBlock {
                    newSortOrder = first.sortOrder / 2.0
                } else {
                    newSortOrder = 1.0
                }
            }

            block.sortOrder = newSortOrder
            block.updatedAt = Date()
            try block.update(db)
        }
    }

    /// Normalize sort orders (when fractional values get too small or duplicates exist)
    /// Uses tie-breaking: headings sort before non-headings at the same sortOrder
    func normalizeSortOrders(projectId: String) throws {
        try write { db in
            let blocks = try Block
                .filter(Block.Columns.projectId == projectId)
                .order(Block.Columns.sortOrder)
                .fetchAll(db)

            // Re-sort with tie-breaking: headings before non-headings at same sortOrder
            let sorted = blocks.sorted { a, b in
                let aKey = (a.sortOrder, a.blockType == .heading ? 0 : 1)
                let bKey = (b.sortOrder, b.blockType == .heading ? 0 : 1)
                return aKey < bKey
            }

            for (index, var block) in sorted.enumerated() {
                let newSortOrder = Double(index + 1)
                if block.sortOrder != newSortOrder {
                    block.sortOrder = newSortOrder
                    block.updatedAt = Date()
                    try block.update(db)
                }
            }
        }
    }

}
