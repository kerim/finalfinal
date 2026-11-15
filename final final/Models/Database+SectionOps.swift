//
//  Database+SectionOps.swift
//  final final
//
//  Forward DB ops for sidebar section delete/duplicate (right-click/control-click context
//  menu on a sidebar card). Ported from the parked `sidebar-section-delete-dup` worktree
//  for Phase 4 of the unified chronological undo system
//  (docs/architecture/unified-undo.md).
//
//  Unlike that worktree's original single-slot verbatim-inverse design, these are FORWARD
//  ops only -- there is no `restoreDeletedBlocks`/`deleteBlocks`/`canUndoSectionOperation`/
//  `SectionOperationRecord` here. Undo of `.sectionDelete`/`.sectionDuplicate` is handled the
//  same way as every other structural op: `StructuralUndoController` captures a forced
//  undo-point snapshot BEFORE calling into this file, and undoes by restoring that snapshot
//  wholesale (see docs/architecture/unified-undo.md's audited-sequences section, "one
//  implementation used by all six ops" / snapshot-inverse design). See
//  `StructuralUndoController.performSectionDelete`/
//  `performSectionDuplicate`.
//
//  Duplicate = a verbatim deep copy of every Block row in the section's subtree, fresh UUIDs,
//  placed via fractional sortOrder midpoints so no OTHER row's sortOrder is ever touched.
//  Bibliography/notes sections refuse both operations entirely -- they're machine-managed by
//  BibliographySyncService/FootnoteSyncService, not the user.
//
//  Known limitation (by design, not a bug): both operations refuse while zoomed into a
//  section (`StructuralUndoController`'s `.refuseIfZoomed` policy) -- the zoom range is
//  itself a DB structural concept (`zoomedBlockRange`); reconciling it against a concurrent
//  delete/duplicate is out of scope for this feature.
//

import Foundation
import GRDB

// MARK: - Section Subtree Resolution

extension ProjectDatabase {

    /// Resolve the ordered block ids making up a section's full subtree: the leader block
    /// (heading or section-break/pseudo-section) itself, its own body blocks, and every
    /// deeper-level descendant leader (+ its own body blocks) that immediately follows it in
    /// document order -- stopping at the first sibling-or-shallower leader, or at the first
    /// Notes/Bibliography row (see the stop in `resolveSectionSubtree`'s leader loop).
    ///
    /// Mirrors two existing pieces of the codebase rather than inventing a third: the
    /// leader/body grouping `reorderAllBlocks` uses (`groupBlocksBySections` in
    /// Database+BlocksReorder.swift), and the level-based parent/child rule
    /// `EditorViewState.findParentByLevel`/`filterToSubtree` use to build `SectionViewModel`
    /// parent chains for zoom. A pseudo-section's effective level is `headingLevel ?? 1`, the
    /// same convention `SectionCardView.SectionViewModel.init(from block:)` uses -- kept
    /// consistent here so "the section's children" means the same thing in the sidebar and in
    /// this delete/duplicate path.
    ///
    /// Returns `nil` when `rootId` isn't a leader block, or is a bibliography/notes section --
    /// both refuse delete/duplicate entirely.
    func sectionBlockIds(rootId: String, projectId: String) throws -> [String]? {
        try read { db in
            try Self.resolveSectionSubtree(db: db, rootId: rootId, projectId: projectId)?.blockIds
        }
    }

    /// Whether `rootId` is a block `sectionBlockIds` would resolve a subtree for, decided from that ONE row: it exists in this
    /// project, is a heading or a section break (`isPseudoSection`), and is neither the Notes nor the Bibliography row. Those are
    /// exactly the cases where `resolveSectionSubtree` returns nil, so `isDeletableSectionRoot == (sectionBlockIds != nil)` for every
    /// id. Exists because the editor-first delete only needs the yes or no before it calls the editor, and `resolveSectionSubtree`
    /// answers it by fetching and decoding every block row of the project (about 1,100 on the twelve-chapter book) on the main thread.
    func isDeletableSectionRoot(rootId: String, projectId: String) throws -> Bool {
        try read { db in
            try Self.isDeletableSectionRoot(db: db, rootId: rootId, projectId: projectId)
        }
    }

    static func isDeletableSectionRoot(db: Database, rootId: String, projectId: String) throws -> Bool {
        guard let root = try Block.fetchOne(db, key: rootId), root.projectId == projectId else { return false }
        return (root.blockType == .heading || root.isPseudoSection) && !root.isBibliography && !root.isNotes
    }

    /// Ordered block ids of a section's subtree, plus the root leader's display title.
    struct SectionSubtree {
        let blockIds: [String]
        let rootTitle: String
    }

    static func resolveSectionSubtree(db: Database, rootId: String, projectId: String) throws -> SectionSubtree? {
        let allBlocks = try Block
            .filter(Block.Columns.projectId == projectId)
            .order(Block.Columns.sortOrder)
            .fetchAll(db)

        // Same leader predicate as fetchOutlineBlocks (Database+Blocks.swift): heading OR
        // pseudo-section. Order is preserved by filtering the already-sortOrder-sorted array.
        let leaders = allBlocks.filter { $0.blockType == .heading || $0.isPseudoSection }
        guard let rootIndex = leaders.firstIndex(where: { $0.id == rootId }) else { return nil }
        let root = leaders[rootIndex]
        guard !root.isBibliography, !root.isNotes else { return nil }
        let rootLevel = root.headingLevel ?? 1

        var subtreeLeaders = [root]
        for leader in leaders[(rootIndex + 1)...] {
            // Never reaches a Notes or Bibliography row, whatever its level (t-94369a83 Phase 4b, D1.0):
            // those regions are machine-managed, so the section ends before the first one. Without
            // this stop, a final top-level chapter followed by a Notes heading one level below it (a
            // Notes H2 after an H1 chapter) took the Notes heading too. BEHAVIOUR CHANGE, named: Delete and
            // Duplicate of such a final chapter no longer take or copy the Notes heading row and the
            // footnote rows grouped under it (they hang under the Notes heading as its body). The
            // editor's own range rule (`deleteSectionEditorFirst`, web/milkdown) uses the same stop,
            // so the two paths agree. A section break is a leader at effective level 1
            // (`headingLevel ?? 1`, as below); an `hr` is never a leader (it is not in `leaders`).
            if leader.isNotes || leader.isBibliography { break }
            let level = leader.headingLevel ?? 1
            guard level > rootLevel else { break }
            subtreeLeaders.append(leader)
        }

        // Group non-leader blocks under whichever leader precedes them -- identical shape to
        // `groupBlocksBySections`, just scoped to this file so we don't have to widen that
        // helper's `private` visibility for a one-call reuse.
        let leaderIds = Set(leaders.map(\.id))
        var bodyByLeader: [String: [Block]] = [:]
        var currentLeaderId: String?
        for block in allBlocks {
            if leaderIds.contains(block.id) {
                currentLeaderId = block.id
            } else if block.isBibliography || block.isNotes {
                // t-94369a83 Phase 4b fix round 2a, item 10: a Notes or Bibliography row that is NOT a leader (the bibliography's
                // opening marker, `BlockParser` keeps it as its own `.bibliography` row, or a headingless bibliography run) ends
                // body grouping. Without this it was filed under the last user chapter before it, so deleting the LAST chapter of
                // a document with a bibliography deleted that marker row in the database while the editor (whose range rule stops
                // at the first managed row) kept it, and Duplicate copied it.
                currentLeaderId = nil
            } else if let leaderId = currentLeaderId {
                bodyByLeader[leaderId, default: []].append(block)
            }
        }

        var result: [String] = []
        for leader in subtreeLeaders {
            result.append(leader.id)
            result.append(contentsOf: (bodyByLeader[leader.id] ?? []).map(\.id))
        }
        return SectionSubtree(blockIds: result, rootTitle: root.outlineTitle)
    }

    /// The ordered block ids of a section's FLAT range (t-18b7fa48 Phase 4b, slice 2, plan D3): the leader `headingId` (a heading or a
    /// section break) and its OWN body only, up to but not including the next heading of ANY level, the next section break, the first
    /// Notes / Bibliography row (the auto-bibliography marker row included), or the end of the document. A deeper heading below it is
    /// NOT part of the range, which is what separates this from `resolveSectionSubtree` (the delete / duplicate rule, where a section
    /// owns every deeper heading under it).
    ///
    /// Why a second rule exists. A Version History section is the text between two headings of any level, the way
    /// `SectionSyncService` cuts a document into `section` rows (`buildParsedHeaders`: a section ends at the next boundary, whatever its
    /// level, or at the first managed section). A restore that replaces "the section" must therefore replace exactly that text, so a
    /// level-1 chapter keeps its level-2 children when its own text is replaced. The editor-side twin is `findFlatSectionRange`
    /// (web/milkdown, round 2c); the queued job removes by this rule what the editor already replaced by its own, so the two must pick
    /// the same rows for the same document.
    ///
    /// Returns `nil` when `headingId` is not a row of the project, is not a heading or a section break, or is a Notes / Bibliography
    /// row (those are machine-managed and never restored by hand). A one-row range (a heading with no body) is `[headingId]`.
    ///
    /// Reads only the columns it needs, in assembly order (`sortOrder`, a heading before a non-heading at the same value): the caller
    /// is the click, which must not decode every row of a book on the main thread.
    static func flatSectionBlockIds(db: Database, headingId: String, projectId: String) throws -> [String]? {
        let headingRaw = BlockType.heading.rawValue
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, blockType, isPseudoSection, isNotes, isBibliography FROM block WHERE projectId = ? \
            ORDER BY sortOrder, CASE WHEN blockType = ? THEN 0 ELSE 1 END, rowid
            """, arguments: [projectId, headingRaw])

        var range: [String] = []
        for row in rows {
            let id: String = row["id"]
            let isManaged = (row["isNotes"] as Bool) || (row["isBibliography"] as Bool)
                || (row["blockType"] as String) == BlockType.bibliography.rawValue
            let isLeader = (row["blockType"] as String) == headingRaw || (row["isPseudoSection"] as Bool)
            if range.isEmpty {
                guard id == headingId else { continue }
                guard isLeader, !isManaged else { return nil }
                range.append(id)
            } else {
                if isLeader || isManaged { break }
                range.append(id)
            }
        }
        return range.isEmpty ? nil : range
    }
}

// MARK: - Delete / Duplicate (forward ops only -- see file header)

extension ProjectDatabase {

    /// Delete a section's full subtree (heading + descendants). Refuses (`nil`) for
    /// bibliography/notes sections or an unresolvable root id. All-or-nothing in a single
    /// write transaction. Returns the deleted root section's display title on success, for use
    /// as a `StructuralEntry` title.
    ///
    /// Does NOT touch the legacy `section` table (a real production bug, found and fixed
    /// 2026-08-22 via Phase D's e2e suite -- this file's own header comment above previously,
    /// wrongly, claimed this function "also removes the legacy `section` table row"). `section`
    /// is a SEPARATE table from `block`, keyed by its own independently-generated UUID
    /// (`SectionReconciler.reconcile()`'s `Section(...)` construction, `Section.swift`'s
    /// `id: String = UUID().uuidString` default) -- there is no shared ID space and no DB
    /// cascade between them. A `Section.filter(keys: blockIds).deleteAll(db)` here (the removed
    /// code) matched zero rows every single time, silently -- the stale `section` row for the
    /// deleted heading survived every sidebar delete, and `Snapshot.swift`'s direct
    /// `section.sortOrder` reads (Version History) were reading a table that didn't actually
    /// reflect the delete. `section`-table convergence is `SectionReconciler`'s job, driven by
    /// `SectionSyncService`, reconciling parsed headers against existing rows by content/position
    /// -- never by a caller passing a `block` id directly. `StructuralUndoController.performStructuralOp`
    /// now forces that resync after this DB mutation lands (see its own "Step 7c" comment).
    @discardableResult
    func deleteSections(rootId: String, projectId: String) throws -> String? {
        try write { db in
            try Self.deleteSections(db: db, rootId: rootId, projectId: projectId)?.rootTitle
        }
    }

    /// The body of `deleteSections(rootId:projectId:)` on an open `Database`, for a caller already inside a write
    /// transaction (t-94369a83 Phase 4b, slice 2a: `SectionDeleteJob` deletes the rows in the same transaction that wrote the
    /// Version History snapshot). Returns the deleted subtree (its ordered row ids and the root's title), or `nil` -- with
    /// nothing deleted -- when the root is not a deletable leader, exactly as `deleteSections(rootId:projectId:)` returns nil.
    static func deleteSections(db: Database, rootId: String, projectId: String) throws -> SectionSubtree? {
        guard let subtree = try Self.resolveSectionSubtree(db: db, rootId: rootId, projectId: projectId) else {
            return nil
        }
        let orderedIds = subtree.blockIds
        guard !orderedIds.isEmpty else { return nil }

        let fetched = try Block.filter(keys: orderedIds).fetchAll(db)
        guard fetched.count == orderedIds.count else { return nil }

        try Block.filter(keys: orderedIds).deleteAll(db)

        // Deleting a section's subtree can change which heading precedes which --
        // re-persist sectionParentId to match. See Database+BlockParents.swift.
        try Self.recomputeSectionParents(db: db, projectId: projectId)

        return subtree
    }

    /// Duplicate a section's full subtree: every Block row in it is deep-copied verbatim with a
    /// fresh UUID, placed immediately after the original via fractional sortOrder midpoints
    /// between the subtree's last block and whatever follows it -- so no other row's sortOrder
    /// changes, unless the room after the section is used up (a copy's step would fall below `crowdedSortOrderGap`, after a few
    /// duplicates of a long section in one spot). Then every row is first re-spaced 1, 2, 3 ... in order, in the same write, and
    /// the old numbers are logged (`renumberLog`, t-bf66e4ee). The `" copy"` suffix is applied to the top heading's title/fragment only;
    /// descendant headings and body content are copied unchanged. Refuses (`nil`) for
    /// bibliography/notes sections or an unresolvable root id. Returns the new (suffixed) title
    /// on success, for use as a `StructuralEntry` title.
    ///
    /// Does NOT touch the legacy `section` table (a real production bug, found and fixed
    /// 2026-08-22 via Phase D's e2e suite -- see `deleteSections`'s doc comment for the shared
    /// root cause). The removed code inserted a `Section(id: copy.id, ...)` row keyed by the
    /// COPY's fresh `block` id -- since `block` and `section` share no ID space, and every real
    /// `section` row is minted with its OWN independently-generated UUID
    /// (`SectionReconciler.reconcile()`), that insert created a PERMANENT ORPHAN row no
    /// reconciler pass could ever find or prune by that id -- active, ongoing data corruption on
    /// every sidebar duplicate, not just a dead no-op like the delete side's bug. Section-table
    /// convergence is `SectionReconciler`'s job now; see `deleteSections`'s doc comment and
    /// `StructuralUndoController.performStructuralOp`'s "Step 7c" comment for the fix.
    @discardableResult
    func duplicateSections(rootId: String, projectId: String) throws -> String? {
        try write { db in
            try Self.duplicateSections(
                db: db, rootId: rootId, projectId: projectId, copies: nil, renumberLog: sortOrderRenumberLog)?.newTitle
        }
    }

    /// What `duplicateSections(db:rootId:projectId:copies:)` made.
    struct DuplicatedSubtree: Sendable, Equatable {
        /// The copy's display title (the root heading with " copy" when the root is a heading), for a `StructuralEntry` title.
        let newTitle: String
        /// The ids of EVERY row the copy inserted, in document order (a row the editor has no node for, a list item, is in it too).
        let copiedBlockIds: [String]
        /// How the editor's copies and the rows differ, when they did (t-18b7fa48 `duplicateCopiesMismatch`). Logged by the caller,
        /// never thrown: the copy is made either way, the rows that got no editor id get fresh ones.
        let copiesMismatch: String?
    }

    /// The body of `duplicateSections(rootId:projectId:)` on an open `Database`, for a caller already inside a write transaction
    /// (t-18b7fa48 Phase 4b slice 3, `SectionDuplicateJob`: the rows are copied in the same transaction that wrote the Version
    /// History snapshot). Returns `nil`, with nothing written, when the root is not a duplicable leader, exactly as the instance
    /// method does.
    ///
    /// `copies` (nil: every copy gets a fresh UUID, today's behaviour, which the instance method keeps): the ids the EDITOR gave the
    /// copies it inserted, one per copied top-level node in document order, each with the id the source node had in the editor
    /// (`source`, already resolved through the writer's temp-id map). They are matched against `BlockParser.alignmentPairs` of the
    /// subtree's rows by the source id, for EVERY row (an empty paragraph the editor shows is a row `BlockParser.alignmentPairs` skips,
    /// and it takes the editor's id for its copy too), then by position where the ids do not match but the counts of copies and
    /// aligned nodes agree (`alignmentPairs` lists one pair per top-level editor node: list rows of the same type AND marker merged, so a
    /// list directly after another with the other bullet or delimiter is a node of its own (t-4eb7bfa9), empty fragments and
    /// the bibliography marker skipped). A row the editor has no node for (a list's later items) gets a fresh UUID. A new id that is
    /// already a row of the table is never reused (it would break the primary key): that copy gets a fresh UUID too. Every difference
    /// that remains is reported in `copiesMismatch`; the caller then pushes the database's ids to the editor, so both sides agree.
    static func duplicateSections(
        db: Database, rootId: String, projectId: String, copies: [(source: String, new: String)]?,
        renumberLog: SortOrderRenumberLog? = nil
    ) throws -> DuplicatedSubtree? {
        guard let subtree = try Self.resolveSectionSubtree(db: db, rootId: rootId, projectId: projectId) else {
            return nil
        }
        let orderedIds = subtree.blockIds
        guard !orderedIds.isEmpty else { return nil }

        guard var placement = try Self.duplicatePlacement(db: db, orderedIds: orderedIds, projectId: projectId) else { return nil }
        if placement.step < Self.crowdedSortOrderGap {
            // t-bf66e4ee: the room after the section is used up (earlier copies were squeezed into it). Spread every saved position out
            // again first, in this same write, and log it for a zoom range; then work the placement out AGAIN from the table, because
            // every number the first reading holds is an old one now.
            let old = try Self.renumberAllSortOrders(db: db, projectId: projectId)
            Self.logSortOrderRenumbersOnCommit([old], to: renumberLog, db: db)
            DebugLog.log(.data, "[SectionOps] duplicate would crowd sort orders - renumbered \(old.count) rows first")
            guard let respaced = try Self.duplicatePlacement(db: db, orderedIds: orderedIds, projectId: projectId) else { return nil }
            placement = respaced
        }
        let orderedBlocks = placement.orderedBlocks
        let lastSortOrder = placement.lastSortOrder
        let step = placement.step

        var idMap: [String: String] = [:]
        var mismatch: String?
        if let copies {
            let match = try Self.matchEditorCopies(db: db, copies: copies, orderedBlocks: orderedBlocks)
            idMap = match.matched
            mismatch = match.mismatch
        }
        for block in orderedBlocks where idMap[block.id] == nil { idMap[block.id] = UUID().uuidString }

        var newTitle = subtree.rootTitle + " copy"
        for (index, original) in orderedBlocks.enumerated() {
            var copy = original
            copy.id = idMap[original.id] ?? UUID().uuidString
            // Remap intra-subtree parentId (list_item -> its containing list block, etc.)
            // to the COPY's parent, not the original's -- a block whose parent falls
            // outside the subtree (shouldn't happen structurally) drops the reference
            // rather than pointing at a block that was never duplicated.
            copy.parentId = original.parentId.flatMap { idMap[$0] }
            copy.sortOrder = lastSortOrder + step * Double(index + 1)
            copy.createdAt = Date()
            copy.updatedAt = Date()
            if index == 0, original.blockType == .heading {
                copy.textContent += " copy"
                copy.markdownFragment = Self.appendCopySuffix(toHeadingFragment: original.markdownFragment)
                // `copy = original` above carries over the ORIGINAL's stored wordCount
                // verbatim; appending " copy" to textContent without this call would persist
                // a one-word-short count forever (wordCount is a stored column, not computed
                // on read). Must run before `copy.insert(db)` below.
                copy.recalculateWordCount()
                newTitle = copy.outlineTitle
            }
            try copy.insert(db)
        }

        // The duplicated subtree inserts new heading rows -- re-persist sectionParentId
        // to match. See Database+BlockParents.swift.
        try Self.recomputeSectionParents(db: db, projectId: projectId)

        return DuplicatedSubtree(
            newTitle: newTitle, copiedBlockIds: orderedBlocks.compactMap { idMap[$0.id] }, copiesMismatch: mismatch)
    }

    /// Where `duplicateSections(db:...)` puts the copies, read from the table as it stands NOW: the subtree's rows in document order,
    /// the highest `sortOrder` among them, and the step between one copy and the next.
    private struct DuplicatePlacement {
        let orderedBlocks: [Block]
        let lastSortOrder: Double
        let step: Double
    }

    /// nil when a row of the subtree is gone, exactly as `duplicateSections(db:...)` refuses. The copies fill the room between the
    /// subtree's last row and the row after it, at `room / (rows + 1)` apart; with nothing after it the room is made up
    /// (`rows + 1`), so the step is 1.
    private static func duplicatePlacement(db: Database, orderedIds: [String], projectId: String) throws -> DuplicatePlacement? {
        let fetched = try Block.filter(keys: orderedIds).fetchAll(db)
        guard fetched.count == orderedIds.count else { return nil }
        let idOrder = Dictionary(uniqueKeysWithValues: orderedIds.enumerated().map { ($1, $0) })
        let orderedBlocks = fetched.sorted { (idOrder[$0.id] ?? 0) < (idOrder[$1.id] ?? 0) }

        guard let lastSortOrder = orderedBlocks.map(\.sortOrder).max() else { return nil }
        let nextBlock = try Block
            .filter(Block.Columns.projectId == projectId)
            .filter(Block.Columns.sortOrder > lastSortOrder)
            .order(Block.Columns.sortOrder)
            .fetchOne(db)
        // No following block (subtree is the last thing in the document): fabricate an
        // upper bound far enough past lastSortOrder to give every copy its own fractional
        // slot; there's nothing after it to collide with.
        let upperBound = nextBlock?.sortOrder ?? (lastSortOrder + Double(orderedBlocks.count) + 1.0)
        let step = (upperBound - lastSortOrder) / Double(orderedBlocks.count + 1)
        return DuplicatePlacement(orderedBlocks: orderedBlocks, lastSortOrder: lastSortOrder, step: step)
    }

    /// Matches the editor's copies against the subtree's rows (see `duplicateSections(db:rootId:projectId:copies:)`). Returns the copy
    /// id for every row the editor has a node for (original row id -> copy id) and a short description of every difference, nil when
    /// there was none. Never throws on a difference.
    ///
    /// Two passes (round 1g-C, review A2). First EVERY row of the subtree, not only the rows `BlockParser.alignmentPairs` lists, is
    /// matched by its id against the `source` of an editor copy: the editor mints a copy for every top-level node it has, an empty
    /// paragraph included, while `alignmentPairs` skips the rows with an empty fragment, so a blank paragraph's row used to be left
    /// with a fresh id the editor never held and typing into that copy was silently not saved. Then, only when the counts of copies
    /// and aligned nodes agree, a node the first pass found no source for takes the copy at its position. A row the editor has no
    /// copy for (a list's later items, a row the editor does not show) gets a fresh id and is not a difference.
    ///
    /// What is reported (and makes the caller push the database's ids to the editor): a node of the editor's that got a fresh id, an
    /// editor copy that matched no row, a match by position, and an id that was already a row or repeated.
    private static func matchEditorCopies(
        db: Database, copies: [(source: String, new: String)], orderedBlocks: [Block]
    ) throws -> (matched: [String: String], mismatch: String?) {
        let pairs = BlockParser.alignmentPairs(orderedBlocks)
        // A new id that is already a row cannot be used; one repeated in the list is used once.
        var matcher = EditorCopyMatcher(taken: Set(try Block.filter(keys: copies.map(\.new)).select(Column("id"), as: String.self).fetchAll(db)))
        var newBySource: [String: String] = [:]
        for copy in copies where !copy.source.isEmpty && newBySource[copy.source] == nil { newBySource[copy.source] = copy.new }
        for row in orderedBlocks {
            guard let candidate = newBySource[row.id] else { continue }
            if !matcher.claim(candidate, for: row.id) {
                matcher.notes.append("copy id \(candidate.prefix(8)) is already a row or repeated: a fresh id was minted")
            }
        }
        matcher.fillByPosition(pairs: pairs.map(\.id), copies: copies.map(\.new))
        matcher.describeDifferences(pairs: pairs.map(\.id), copies: copies.map(\.new), rowCount: orderedBlocks.count)
        return (matcher.matched, matcher.notes.isEmpty ? nil : matcher.notes.joined(separator: "; "))
    }

    /// The state of `matchEditorCopies`: which copy ids are spent, which rows have theirs, what to report.
    private struct EditorCopyMatcher {
        let taken: Set<String>
        var used = Set<String>()
        var matched: [String: String] = [:]
        var notes: [String] = []

        /// A node of the editor's that the source pass found no copy for takes the copy at its position, when the counts agree.
        mutating func fillByPosition(pairs: [String], copies: [String]) {
            guard pairs.count == copies.count else { return }
            var byPosition = 0
            for (index, pairId) in pairs.enumerated() where matched[pairId] == nil {
                if claim(copies[index], for: pairId) { byPosition += 1 }
            }
            if byPosition > 0 { notes.append("\(byPosition) copy(ies) matched by position, not by source id") }
        }

        /// What is left after both passes: nodes without a copy, copies without a row. Adds the counts when anything is reported.
        mutating func describeDifferences(pairs: [String], copies: [String], rowCount: Int) {
            let freshNodes = pairs.filter { matched[$0] == nil }.count
            if freshNodes > 0 { notes.append("\(freshNodes) node(s) got a fresh id") }
            let unmatchedCopies = copies.filter { !used.contains($0) && !taken.contains($0) }.count
            if unmatchedCopies > 0 { notes.append("\(unmatchedCopies) editor copy(ies) matched no row of the section") }
            guard !notes.isEmpty else { return }
            notes.append("the editor copied \(copies.count) top-level block(s); the section has \(pairs.count) node(s) in \(rowCount) row(s)")
        }

        /// Gives `rowId` the copy id `candidate` when it is usable (not empty, not already a row of the table, not spent). False
        /// otherwise, and then nothing changed.
        mutating func claim(_ candidate: String, for rowId: String) -> Bool {
            guard !candidate.isEmpty, !taken.contains(candidate), !used.contains(candidate) else { return false }
            matched[rowId] = candidate
            used.insert(candidate)
            return true
        }
    }

    /// Append " copy" to a heading's markdown fragment (single line: "#{1,6} title"),
    /// preserving anything after a literal newline defensively even though headings are not
    /// expected to contain one.
    private static func appendCopySuffix(toHeadingFragment fragment: String) -> String {
        if let newlineIndex = fragment.firstIndex(of: "\n") {
            return fragment[..<newlineIndex] + " copy" + fragment[newlineIndex...]
        }
        return fragment + " copy"
    }
}
