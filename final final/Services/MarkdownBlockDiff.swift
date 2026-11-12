//
//  MarkdownBlockDiff.swift
//  final final
//
//  t-94369a83 Phase 4a, plan v2 section 1(a)/(c): the PURE half of saving Markdown typing block by block.
//  No database, no MainActor, no editor, no writer. The caller (`MarkdownBlockWriter`, from the debounced Markdown
//  re-parse and the bibliography flush) parses the editor's text with `BlockParser.parse`, hands this file the parse
//  and a baseline, and gets back the `BlockChanges` to send through `DocumentWriter`
//  (`BlockSyncService.applyMarkdownTurn`), plus the baseline to keep afterwards.
//
//  WHAT IT DECIDES
//
//    1. ALIGNMENT. Which parsed block is which stored block. `CollectionDifference` over hashed keys finds the
//       blocks whose text did not change; inside each changed region, removed and inserted blocks are PAIRED in
//       order only when their `BlockType` is equal (same-type gap pairing). A pair becomes an update that keeps
//       the row's id (so a paragraph keeps its id while edited, and a heading keeps its id, status, tags and
//       goals when renamed or when its level changes). Everything else is a delete or an insert. A block whose
//       type changes is therefore a delete plus an insert, and a MOVED block gets a new id. Never a full LCS
//       table (review M21): `CollectionDifference` is Myers' O((N+M)*D).
//
//    2. DIFF. From the alignment, `BlockChanges`: updates, inserts with CHAINED temp-id anchors, deletes.
//
//    3. PRE-FILTER (review M9). The changes the database would refuse are never sent: updates and deletes of
//       bibliography rows, deletes of Notes rows, updates of a Notes row that change its footnote label.
//       The flags come from the ALIGNED rows (what the database holds), not from the new parse. Inserts the
//       parse flags `isBibliography` are dropped too (the bibliography is machine-managed; the database would
//       put a block inside it into the bibliography and refuse its later edits and deletes).
//
//    4. MOVED NOTES DEFINITIONS (t-4a8fd8af). A footnote definition the editor shows in a different place than the
//       database holds it is NOT a new definition. The editor's `renumberFootnotes` relabels the definitions in
//       place and never re-sorts them, while the database keeps its Notes rows sorted by footnote number
//       (`reconcileNotesBlocks`), so after a renumber whose map swaps runs of numbers (46..54 before 37..45) the
//       alignment sees each moved definition as a removed row in one region and an inserted block in another and
//       never pairs them. Sending that insert saves a second row with the same label on every fire. So a Notes
//       paragraph the alignment calls new (an insert, or paired with a Notes row of ANOTHER slot, which the
//       pre-filter drops anyway or which would write another footnote's text into the row) is PAIRED with the
//       baseline Notes row in the same SLOT that nothing else claims (an unmatched row, or one in such a pairing).
//       The slot of a definition is its footnote label; the slot of a continuation paragraph (the second, third ...
//       paragraph of a footnote, each its own row, no label of its own) is its owner's label plus its ordinal
//       under that owner. Same text, no change; different text, an update on that row's id (the label is
//       unchanged, so the database accepts it, and an edit made inside the moved run is saved, not dropped). The
//       row leaves the removed set, so it no longer counts as a filtered Notes delete. Each row is paired once, and
//       a row the alignment matched by text is never paired: a definition with a NEW label, a second hand-typed
//       copy of a label that is already matched, a continuation of a NEW footnote and an extra continuation (an
//       ordinal no baseline row of that owner has) stay inserts (N3 below). See `pairMovedNotes`.
//
//  THE KEY. (BlockType, headingLevel for headings only, trimmed fragment), hashed once. Whitespace around a
//  fragment and blank lines between blocks do not matter (a whitespace-only change is an empty diff); a
//  change anywhere inside a fragment does.
//
//  N3 (judge verdict 2): A NEW PARAGRAPH TYPED INSIDE THE NOTES SECTION IS SENT, not pre-filtered. Reasons:
//    - Rich Text sends the same insert, and the database's own placement rules
//      (`resolveInsertPlacement`, `buildInsertedBlock`) flag it `isNotes` by containment (anchored on a
//      non-heading Notes row) or by its `[^N]:` shape; nothing in the database ever refuses an insert.
//      `processEditorDeletes` and `applyUpdateToExistingBlock` are the only refusals, and they are exactly
//      what the pre-filter above mirrors.
//    - Dropping it would leave typed text unsaved until the next switch or close for no safety benefit.
//    - Notes TEXT edits are sent for the same reason (the footnote-sync pipeline depends on them); only a
//      change of the footnote label, and deletes, are dropped.
//  The one Notes shape that stays unflagged in the database is a paragraph typed directly under the Notes
//  HEADING (the containment rule excludes a heading anchor); the next `.rows` fire re-reads the real flags
//  and the footnote sync adopts it (`adoptUnflaggedNotesContinuations`).
//
//  C4 (judge verdict 2): a diff that is empty ONLY because the filter dropped everything it found reports
//  that fact (`Result.emptyOnlyBecauseFiltered`), so the caller keeps the baseline in rows mode and schedules
//  nothing. A write that carried any filtered change likewise leaves the baseline in rows mode
//  (`Result.baselineAfterWriteMustBeRows`): the baseline never claims text the database lacks. A moved Notes
//  definition counts as filtered (`Filtered.notesMoves`): the database keeps its Notes rows in number order and the
//  editor does not, so the two differ in order after the write and the baseline must be re-read from the rows.
//

import Foundation

enum MarkdownBlockDiff {

    // MARK: - Shared assembly order

    /// The stored rows in the order the editor shows them: `assemblySorted` (by `sortOrder`, a heading before a
    /// non-heading at the same `sortOrder`), with empty fragments dropped (they produce no editor node).
    ///
    /// ONE implementation, two callers (plan step 2): this file's alignment of the stored rows against a parse
    /// (rows mode), and `ContentView.updateSourceContentIfNeeded`'s block-offset map. They MUST agree with each
    /// other and with `BlockParser.assembleMarkdown`, or an anchor lands in the wrong place or a block is
    /// aligned to the wrong row; sharing the function is what keeps them from drifting.
    static func assemblyOrderedNonEmpty(_ blocks: [Block]) -> [Block] {
        BlockParser.assemblySorted(blocks).filter { !BlockParser.isEmptyFragment($0.markdownFragment) }
    }

    // MARK: - Key

    /// A block's identity for alignment. Equal keys mean "the same block text": same type, same heading level
    /// (headings only), same trimmed fragment. The hash is computed once at construction, so comparing two
    /// different blocks is one integer compare, and a full string compare only happens for genuine matches.
    struct Key: Hashable, Sendable {
        let blockType: BlockType
        let headingLevel: Int?
        let fragment: String
        private let hashCode: Int

        init(blockType: BlockType, headingLevel: Int?, markdownFragment: String) {
            let level = blockType == .heading ? headingLevel : nil
            let trimmed = markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines)
            self.blockType = blockType
            self.headingLevel = level
            self.fragment = trimmed
            var hasher = Hasher()
            hasher.combine(blockType)
            hasher.combine(level)
            hasher.combine(trimmed)
            self.hashCode = hasher.finalize()
        }

        init(_ block: Block) {
            self.init(blockType: block.blockType, headingLevel: block.headingLevel, markdownFragment: block.markdownFragment)
        }

        static func == (lhs: Key, rhs: Key) -> Bool {
            lhs.hashCode == rhs.hashCode && lhs.blockType == rhs.blockType
                && lhs.headingLevel == rhs.headingLevel && lhs.fragment == rhs.fragment
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(hashCode)
        }
    }

    // MARK: - Baseline entry

    /// One block of a baseline: the stored row's id (nil when it is not known), its key, and the flags the
    /// pre-filter needs (read from the ALIGNED ROW, so they are what the database holds).
    struct Entry: Sendable, Equatable {
        var id: String?
        let key: Key
        let isBibliography: Bool
        let isNotes: Bool
        /// The footnote label of a Notes row's fragment (`[^3]:` gives "3"); nil for a Notes row without one and
        /// for every non-Notes row. The label-change refusal compares this with the new fragment's label.
        let notesLabel: String?

        init(id: String?, key: Key, isBibliography: Bool, isNotes: Bool, notesLabel: String?) {
            self.id = id
            self.key = key
            self.isBibliography = isBibliography
            self.isNotes = isNotes
            self.notesLabel = notesLabel
        }

        /// A stored row.
        init(row: Block) {
            self.init(
                id: row.id, key: Key(row), isBibliography: row.isBibliography, isNotes: row.isNotes,
                notesLabel: row.isNotes ? MarkdownBlockDiff.notesLabel(of: row.markdownFragment) : nil)
        }

        /// A block of a parse that was just written, carrying the id the write gave it.
        init(parsed block: Block, id: String?) {
            self.init(
                id: id, key: Key(block), isBibliography: block.isBibliography, isNotes: block.isNotes,
                notesLabel: block.isNotes ? MarkdownBlockDiff.notesLabel(of: block.markdownFragment) : nil)
        }
    }

    /// The footnote label of a Notes fragment, by the same test the database refusal uses
    /// (`ProjectDatabase.applyUpdateToExistingBlock`).
    static func notesLabel(of fragment: String) -> String? {
        FootnoteSyncService.parseNotesLabel(from: fragment)?.label
    }

    /// The baseline for rows mode: the stored rows in assembly order, empty fragments dropped.
    static func baselineEntries(rows: [Block]) -> [Entry] {
        assemblyOrderedNonEmpty(rows).map { Entry(row: $0) }
    }

    // MARK: - Alignment

    enum AlignmentMatch: Sendable, Equatable {
        /// The same block text as baseline entry `Int`.
        case same(Int)
        /// A changed block, paired with baseline entry `Int` (same `BlockType`): an update that keeps the id.
        case changed(Int)
        /// Matches nothing: an insert.
        case inserted
    }

    struct Alignment: Sendable, Equatable {
        /// One per new block, in order.
        var matches: [AlignmentMatch]
        /// Baseline indices matched by nothing, ascending: deletes.
        var removed: [Int]
    }

    /// Aligns `new` against `baseline` by key. `CollectionDifference` finds the unchanged blocks; each region
    /// between two unchanged blocks (the removed run and the inserted run that sit there) is then paired in
    /// order by `BlockType`.
    ///
    /// `rules` (t-e3c7105f): a stored Notes HEADING row is not paired by type alone. See `PairingRules`.
    static func align(baseline: [Key], new: [Key], rules: PairingRules = .none) -> Alignment {
        var builder = AlignmentBuilder(baseline: baseline, new: new)
        let difference = new.difference(from: baseline)
        var removedBaseline = Set<Int>()
        var insertedNew = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removedBaseline.insert(offset)
            case .insert(let offset, _, _): insertedNew.insert(offset)
            }
        }

        var baselineIndex = 0
        var newIndex = 0
        while baselineIndex < baseline.count || newIndex < new.count {
            let startBaseline = baselineIndex
            let startNew = newIndex
            var removedRun: [Int] = []
            var insertedRun: [Int] = []
            while baselineIndex < baseline.count, removedBaseline.contains(baselineIndex) {
                removedRun.append(baselineIndex)
                baselineIndex += 1
            }
            while newIndex < new.count, insertedNew.contains(newIndex) {
                insertedRun.append(newIndex)
                newIndex += 1
            }
            builder.pair(removedRun: removedRun, insertedRun: insertedRun, rules: rules)
            // Both sides now stand on an unchanged block (the same element, by construction of the difference).
            if baselineIndex < baseline.count, newIndex < new.count {
                builder.matches[newIndex] = .same(baselineIndex)
                baselineIndex += 1
                newIndex += 1
            }
            if baselineIndex == startBaseline && newIndex == startNew { break }   // cannot happen; never loop forever
        }
        return Alignment(matches: builder.matches, removed: builder.removed)
    }

    /// Working state of one `align` call: pairs the removed baseline blocks with the inserted new blocks of ONE changed
    /// region, in order, only where the `BlockType` is equal.
    private struct AlignmentBuilder {
        let baseline: [Key]
        let new: [Key]
        var matches: [AlignmentMatch]
        var removed: [Int] = []

        init(baseline: [Key], new: [Key]) {
            self.baseline = baseline
            self.new = new
            self.matches = [AlignmentMatch](repeating: .inserted, count: new.count)
        }

        /// Greedy and in order: each removed block, from the first, takes the EARLIEST not-yet-passed inserted block of
        /// its type; a removed block with none left is a delete; an inserted block nobody took stays `.inserted`.
        /// Deterministic by construction (a split pairs the original with the FIRST half, a merge keeps the first
        /// block's id), linear, and a pairing never crosses another pairing, so every update keeps its row's place.
        /// It does not maximise the number of pairs (a removed `[heading, paragraph]` against an inserted
        /// `[paragraph, heading]` pairs one, not two): the cost of a missed pair is one new id, never lost text.
        ///
        /// A stored Notes HEADING row (`rules.restricted`, t-e3c7105f) goes first and takes only a heading `rules.allows`
        /// calls its own (the same section, renamed or at another level); with no such heading in the region it is removed
        /// (the writer never deletes a Notes row, so it stays). The other rows then pair as above, but only with the blocks
        /// before the next claimed one, so no two pairings cross.
        mutating func pair(removedRun: [Int], insertedRun: [Int], rules: PairingRules) {
            let result = MarkdownBlockDiff.pairRegion(
                baseline: baseline, new: new, removedRun: removedRun, insertedRun: insertedRun, rules: rules)
            for (newIndex, baselineIndex) in result.pairs { matches[newIndex] = .changed(baselineIndex) }
            removed.append(contentsOf: result.removed)
        }
    }

    /// The id of the stored row each parsed block lines up with (an unchanged block's row, or the row a changed
    /// block is paired with), nil for a block that matches no row. Rows mode, as a plain function of the stored
    /// rows: the round trip `assemble(rows) -> parse -> align` must give an id for every block.
    static func align(parsed: [Block], rows: [Block]) -> [String?] {
        let baseline = baselineEntries(rows: rows)
        let alignment = align(baseline: baseline.map(\.key), new: parsed.map { Key($0) })
        return alignment.matches.map { match in
            switch match {
            case .same(let index), .changed(let index): return baseline[index].id
            case .inserted: return nil
            }
        }
    }

    // MARK: - Diff

    /// What the pre-filter dropped, by reason.
    struct Filtered: Sendable, Equatable {
        var bibliographyUpdates = 0
        var bibliographyDeletes = 0
        var bibliographyInserts = 0
        var notesDeletes = 0
        var notesLabelChanges = 0
        /// Notes paragraphs (definitions and continuation paragraphs) the editor shows in a different place than the
        /// database holds them, paired with their row by slot (see "MOVED NOTES DEFINITIONS" above). Not a dropped
        /// change: a text edit inside a moved paragraph is still sent as an update. Counted so the baseline stays in
        /// rows mode.
        var notesMoves = 0

        var total: Int {
            bibliographyUpdates + bibliographyDeletes + bibliographyInserts + notesDeletes + notesLabelChanges + notesMoves
        }
    }

    struct Result: Sendable {
        /// What to send. Already pre-filtered.
        var changes: BlockChanges
        /// One entry per new block, in order: the baseline after a CLEAN write. An inserted block carries its
        /// temp id until `resolvingTempIds` swaps in the permanent one; a dropped (filtered) insert has no id.
        var entries: [Entry]
        var filtered: Filtered
        /// Changes the diff could not address because the baseline did not know the row's id (a baseline entry
        /// with a nil id was removed or changed, or an insert had to be anchored past one).
        var unaddressable: Int

        var isEmpty: Bool { changes.isEmpty }

        /// C4: nothing to send ONLY because the filter dropped everything the diff found (or the rest could not be
        /// addressed). The caller keeps rows mode and schedules nothing: the editor and the database differ on text
        /// the writer must not write.
        var emptyOnlyBecauseFiltered: Bool { changes.isEmpty && (filtered.total > 0 || unaddressable > 0) }

        /// After a write that carried any filtered or unaddressable change the baseline must be rows mode, never
        /// `entries`: the entries describe text the database does not hold.
        var baselineAfterWriteMustBeRows: Bool { filtered.total > 0 || unaddressable > 0 }

        /// `entries` with each temp id replaced by the permanent id the write minted (`EditorApplyResult.idMapping`).
        /// A temp id the write did not mint (a rejected or deduplicated insert) becomes nil.
        func resolvingTempIds(_ idMapping: [String: String]) -> [Entry] {
            entries.map { entry in
                guard let id = entry.id, id.hasPrefix(MarkdownBlockDiff.tempIdPrefix) else { return entry }
                var resolved = entry
                resolved.id = idMapping[id]
                return resolved
            }
        }
    }

    /// Every temp id this file mints starts with this (the writer treats any `temp-` prefix as an unminted id).
    static let tempIdPrefix = "temp-md-"

    static func makeTempId() -> String { tempIdPrefix + UUID().uuidString }

    /// The diff of `new` (a parse of the editor's text) against `baseline`, pre-filtered.
    ///
    /// ANCHORS (review M10). An insert is anchored on the nearest EARLIER block of the new sequence that has an
    /// id: a kept or updated block's permanent id, or the temp id of an insert earlier in the same batch (the
    /// writer resolves a chained temp anchor within the batch: `processEditorInserts` reads `idMapping`). With no
    /// earlier id-bearing block the insert is `atDocumentStart`. A nil anchor is never sent: it would land at
    /// the END of the document.
    ///
    /// A dropped insert (bibliography-flagged) has no id, so it is never used as an anchor: a later insert
    /// chained onto a temp id that never mints would fall through to the end of the document too.
    ///
    /// MOVED NOTES DEFINITIONS (t-4a8fd8af). Before anything is added, a Notes paragraph the alignment calls new is
    /// paired with the baseline Notes row in the same slot (`pairMovedNotes`). The paired row is not a delete and
    /// the paired block is not an insert.
    ///
    /// - Parameter makeTempId: injectable so a test can assert the exact `BlockChanges`.
    static func diff(baseline: [Entry], new: [Block], makeTempId: () -> String = MarkdownBlockDiff.makeTempId) -> Result {
        let (alignment, movedNotes) = pairMovedNotes(
            alignment: align(
                baseline: baseline.map(\.key), new: new.map { Key($0) }, rules: notesHeadingRules(baseline: baseline, new: new)),
            baseline: baseline, new: new)
        var builder = DiffBuilder()
        for index in alignment.removed {
            builder.addRemoved(baseline[index])
        }
        for (index, block) in new.enumerated() {
            switch alignment.matches[index] {
            case .same(let baselineIndex):
                builder.addUnchanged(baseline[baselineIndex])
            case .changed(let baselineIndex):
                builder.addChanged(block, row: baseline[baselineIndex], makeTempId: makeTempId)
            case .inserted:
                if let rowIndex = movedNotes[index] {
                    builder.addMovedNotes(block, row: baseline[rowIndex])
                } else {
                    builder.addInserted(block, makeTempId: makeTempId)
                }
            }
        }
        return Result(
            changes: BlockChanges(updates: builder.updates, inserts: builder.inserts, deletes: builder.deletes),
            entries: builder.entries, filtered: builder.filtered, unaddressable: builder.unaddressable)
    }

    /// Rows mode: the diff of `new` against the stored `rows`.
    static func diff(rows: [Block], new: [Block], makeTempId: () -> String = MarkdownBlockDiff.makeTempId) -> Result {
        diff(baseline: baselineEntries(rows: rows), new: new, makeTempId: makeTempId)
    }

    /// Working state of one `diff` call, fed in this order: every removed baseline block, then the new blocks in
    /// order (the order the anchors depend on).
    private struct DiffBuilder {
        var updates: [BlockUpdate] = []
        var inserts: [BlockInsert] = []
        var deletes: [String] = []
        var entries: [Entry] = []
        var filtered = Filtered()
        var unaddressable = 0
        /// The nearest earlier id-bearing block of the new sequence (a permanent id or an earlier insert's temp id).
        private var anchorId: String?
        /// A block with no known id lies between `anchorId` and the block being added.
        private var passedAnUnknownBlock = false

        /// A baseline block that matches nothing: a delete, unless the database would refuse it.
        mutating func addRemoved(_ row: Entry) {
            guard let id = row.id else {
                unaddressable += 1
                return
            }
            if row.isBibliography {
                filtered.bibliographyDeletes += 1
            } else if row.isNotes {
                filtered.notesDeletes += 1
            } else {
                deletes.append(id)
            }
        }

        mutating func addUnchanged(_ row: Entry) {
            entries.append(row)
            if let id = row.id {
                anchorId = id
                passedAnUnknownBlock = false
            } else {
                passedAnUnknownBlock = true
            }
        }

        /// A new block paired with a baseline block of the same type: an update that keeps the id, unless the database
        /// would refuse it (a bibliography row; a Notes row whose footnote label changes).
        mutating func addChanged(_ block: Block, row: Entry, makeTempId: () -> String) {
            guard let id = row.id else {
                // The row's id is unknown, so it can be neither updated nor deleted: insert the new text (the caller
                // leaves the baseline in rows mode, where the stale row is found and deleted).
                unaddressable += 1
                addInserted(block, makeTempId: makeTempId)
                return
            }
            anchorId = id
            passedAnUnknownBlock = false
            if row.isBibliography {
                filtered.bibliographyUpdates += 1
                entries.append(row)
            } else if row.isNotes, MarkdownBlockDiff.notesLabel(of: block.markdownFragment) != row.notesLabel {
                filtered.notesLabelChanges += 1
                entries.append(row)
            } else {
                updates.append(BlockUpdate(
                    id: id, textContent: block.textContent, markdownFragment: block.markdownFragment,
                    headingLevel: block.headingLevel, blockType: block.blockType.rawValue))
                entries.append(Entry(
                    id: id, key: Key(block), isBibliography: false, isNotes: row.isNotes,
                    notesLabel: row.isNotes ? MarkdownBlockDiff.notesLabel(of: block.markdownFragment) : nil))
            }
        }

        /// A new Notes paragraph (a definition or a continuation) paired by slot with a baseline Notes row
        /// (`pairMovedNotes`): the editor shows it elsewhere than the database holds it. Like `addChanged` without the
        /// label-change branch (a definition's label is equal by construction): the same text is no change, different
        /// text is an update on the row's id (the database accepts a Notes text edit with an unchanged label). Never
        /// an insert.
        mutating func addMovedNotes(_ block: Block, row: Entry) {
            filtered.notesMoves += 1
            guard let id = row.id else {
                // The row's id is unknown, so it cannot be updated, but a row in this slot exists: sending an insert
                // would save a second row (a Notes row is never deleted by the writer). Say so, so the caller re-reads
                // the rows (rows mode) and the next fire has the id.
                unaddressable += 1
                passedAnUnknownBlock = true
                entries.append(Entry(parsed: block, id: nil))
                return
            }
            anchorId = id
            passedAnUnknownBlock = false
            if row.key == Key(block) {
                entries.append(row)
            } else {
                updates.append(BlockUpdate(
                    id: id, textContent: block.textContent, markdownFragment: block.markdownFragment,
                    headingLevel: block.headingLevel, blockType: block.blockType.rawValue))
                entries.append(Entry(
                    id: id, key: Key(block), isBibliography: false, isNotes: true, notesLabel: row.notesLabel))
            }
        }

        /// A new block that matches nothing: an insert anchored on the nearest earlier id, dropped when the parse flags
        /// it bibliography.
        mutating func addInserted(_ block: Block, makeTempId: () -> String) {
            if block.isBibliography {
                filtered.bibliographyInserts += 1
                entries.append(Entry(parsed: block, id: nil))
                return
            }
            if passedAnUnknownBlock {
                // The new block follows a block whose id the baseline does not know; anchoring on the nearest earlier
                // KNOWN id puts it before that block in the database. Say so, so the caller re-reads the stored order
                // (rows mode) after this write.
                unaddressable += 1
                passedAnUnknownBlock = false
            }
            let tempId = makeTempId()
            inserts.append(BlockInsert(
                tempId: tempId, blockType: block.blockType.rawValue, textContent: block.textContent,
                markdownFragment: block.markdownFragment, headingLevel: block.headingLevel,
                afterBlockId: anchorId, atDocumentStart: anchorId == nil ? true : nil))
            entries.append(Entry(parsed: block, id: tempId))
            anchorId = tempId
        }
    }
}

// MARK: - A Notes heading row follows its heading (t-e3c7105f)
// In an extension so the enum body stays under the project's type-body-length limit.

extension MarkdownBlockDiff {

    /// Which new blocks a stored Notes HEADING row may take the text of.
    ///
    /// The bug this closes: select all in Markdown mode, delete, type a replacement document. The first save (editor empty) deletes
    /// every row the writer may delete and leaves the Notes rows, so the next save compares a first heading and a paragraph with a
    /// baseline of just the Notes heading and its definition. Pairing by type alone gave the Notes heading row to the first typed
    /// heading ("# Chapter One"): the update was accepted (a heading has no footnote label to differ) and the row kept its Notes
    /// flag, so the document's first heading was a Notes heading beside the real one.
    ///
    /// A Notes heading row now pairs only with a heading that is still the Notes heading: the parse flags it Notes, or it opens a
    /// run with a `[^N]:` definition under it before the next heading (`NotesOpeningSelector`, so a renamed Notes heading with its
    /// definitions still counts), or its title is the row's own title (at any level: the H1 to H2 flip, before any definition is
    /// typed). Any other heading becomes an insert and the row stays. Notes heading rows pair first, so an ordinary row that sits
    /// before them (a half-typed "## No") cannot take the heading they are waiting for.
    struct PairingRules: Sendable {
        /// Baseline indices of the stored Notes heading rows.
        var restricted: Set<Int> = []
        /// Whether the new block at the second index may take the text of the restricted row at the first.
        var allows: @Sendable (_ baselineIndex: Int, _ newIndex: Int) -> Bool = { _, _ in true }

        static let none = PairingRules()
    }

    /// The pairing of ONE changed region (`AlignmentBuilder.pair` calls it; kept here so the enum body stays under the length
    /// limit). Returns the pairs as (new index, baseline index) and the removed rows that took no block, in removed order.
    static func pairRegion(
        baseline: [Key], new: [Key], removedRun: [Int], insertedRun: [Int], rules: PairingRules
    ) -> (pairs: [(Int, Int)], removed: [Int]) {
        let claims = claimNotesHeadings(
            baseline: baseline, new: new, removedRun: removedRun, insertedRun: insertedRun, rules: rules)
        // For each removed row: the first inserted position it must stay below (the next claim after it).
        var limits = [Int](repeating: insertedRun.count, count: removedRun.count)
        var nextClaim = insertedRun.count
        for position in removedRun.indices.reversed() {
            limits[position] = nextClaim
            if let claim = claims[removedRun[position]] { nextClaim = claim }
        }
        var pairs: [(Int, Int)] = []
        var removed: [Int] = []
        var cursor = 0
        for (position, removedIndex) in removedRun.enumerated() {
            if let claim = claims[removedIndex] {
                pairs.append((insertedRun[claim], removedIndex))
                cursor = claim + 1
                continue
            }
            if rules.restricted.contains(removedIndex) {
                removed.append(removedIndex)
                continue
            }
            let type = baseline[removedIndex].blockType
            var candidate = cursor
            while candidate < limits[position], new[insertedRun[candidate]].blockType != type {
                candidate += 1
            }
            if candidate < limits[position] {
                pairs.append((insertedRun[candidate], removedIndex))
                cursor = candidate + 1
            } else {
                removed.append(removedIndex)
            }
        }
        return (pairs, removed)
    }

    /// removed baseline index -> position in `insertedRun` of the heading it takes: each Notes heading row, in order, takes the
    /// earliest heading after the previous claim that `rules.allows`.
    private static func claimNotesHeadings(
        baseline: [Key], new: [Key], removedRun: [Int], insertedRun: [Int], rules: PairingRules
    ) -> [Int: Int] {
        var claims: [Int: Int] = [:]
        var floor = 0
        for removedIndex in removedRun where rules.restricted.contains(removedIndex) {
            var candidate = floor
            while candidate < insertedRun.count,
                  !(new[insertedRun[candidate]].blockType == baseline[removedIndex].blockType
                    && rules.allows(removedIndex, insertedRun[candidate])) {
                candidate += 1
            }
            if candidate < insertedRun.count {
                claims[removedIndex] = candidate
                floor = candidate + 1
            }
        }
        return claims
    }

    static func notesHeadingRules(baseline: [Entry], new: [Block]) -> PairingRules {
        let restricted = Set(baseline.indices.filter {
            baseline[$0].isNotes && !baseline[$0].isBibliography && baseline[$0].key.blockType == .heading
        })
        guard !restricted.isEmpty else { return .none }
        let units = new.map {
            NotesOpeningSelector.Unit(
                isCandidateHeading: false, isAnyHeading: $0.blockType == .heading,
                isEvidence: FootnoteSyncService.parseNotesLabel(from: $0.markdownFragment) != nil)
        }
        let fragments = new.map { $0.markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines) }
        var titles: [Int: String] = [:]
        for index in restricted {
            titles[index] = BlockParser.extractTextContent(from: baseline[index].key.fragment, blockType: .heading)
        }
        let rowTitles = titles
        return PairingRules(restricted: restricted) { baselineIndex, newIndex in
            guard new[newIndex].blockType == .heading else { return false }
            if new[newIndex].isNotes { return true }
            if NotesOpeningSelector.hasEvidence(in: units, after: newIndex + 1) { return true }
            return BlockParser.isNotesHeading(fragments[newIndex], notesHeaderName: rowTitles[baselineIndex] ?? "Notes")
        }
    }
}

// MARK: - Moved Notes definitions (t-4a8fd8af)
// In an extension so the enum body stays under the project's type-body-length limit.

extension MarkdownBlockDiff {

    /// Pairs each Notes paragraph of the new text that the alignment calls new with the baseline Notes row in the same
    /// SLOT (`notesSlots`: a definition is its footnote label, a continuation paragraph is its owner's label plus its
    /// ordinal under that owner). Returns the alignment with the paired rows taken out of the removed set, and new-block
    /// index -> baseline index for the pairs.
    ///
    /// A paragraph is a candidate when the alignment made it an insert, or paired it with a Notes row of ANOTHER slot.
    /// That second pairing is one the pre-filter would drop anyway (a definition: `addChanged`'s label change) or one
    /// that would write another footnote's text into the row (a continuation: label-less, so `addChanged` cannot tell
    /// them apart), and it happens whenever a removed row and an inserted block of different slots sit in the same
    /// region (two neighbouring swaps; a swap next to a new footnote): the same-type pairing then eats the row a moved
    /// paragraph needs. A row is a candidate when the alignment left it unmatched, or when it sits in such a pairing.
    /// Rows are taken once each, in order, by the first candidate paragraph with their slot (a baseline that holds a
    /// slot twice offers its rows in order). Rows and blocks the alignment matched by text (`.same`) or by a
    /// slot-preserving `.changed` are never candidates: a second copy of a definition (typed by hand), a continuation
    /// of a NEW footnote and an extra continuation (an ordinal no baseline row of that owner has) find no row and
    /// stay inserts.
    ///
    /// A pairing of another slot with one side taken is dissolved: its block becomes an insert (or the pair), its row a
    /// removed row (a filtered Notes delete) unless another paragraph took it. One with neither side taken stays as it
    /// is (a filtered label change, or the update `addChanged` sends). A bibliography row never pairs, and neither does
    /// a row or block without a slot.
    private static func pairMovedNotes(
        alignment: Alignment, baseline: [Entry], new: [Block]
    ) -> (alignment: Alignment, moved: [Int: Int]) {
        let rowSlots = notesSlots(baseline.map {
            NotesItem(isNotes: $0.isNotes && !$0.isBibliography, isHeading: $0.key.blockType == .heading, label: $0.notesLabel)
        })
        guard rowSlots.contains(where: { $0 != nil }) else { return (alignment, [:]) }
        let blockSlots = notesSlots(new.map {
            NotesItem(
                isNotes: $0.isNotes && !$0.isBibliography, isHeading: $0.blockType == .heading,
                label: $0.isNotes ? notesLabel(of: $0.markdownFragment) : nil)
        })
        let otherSlotPairs = pairsInAnotherSlot(alignment: alignment, rowSlots: rowSlots, blockSlots: blockSlots)
        var rowsBySlot: [String: [Int]] = [:]
        for rowIndex in (alignment.removed + otherSlotPairs.keys).sorted() {
            if let slot = rowSlots[rowIndex] { rowsBySlot[slot, default: []].append(rowIndex) }
        }
        let moved = claimRows(&rowsBySlot, alignment: alignment, blockSlots: blockSlots, otherSlotPairs: otherSlotPairs)
        guard !moved.isEmpty else { return (alignment, [:]) }
        var adjusted = alignment
        let takenRows = Set(moved.values)
        for (rowIndex, index) in otherSlotPairs where takenRows.contains(rowIndex) || moved[index] != nil {
            adjusted.matches[index] = .inserted
            if !takenRows.contains(rowIndex) { adjusted.removed.append(rowIndex) }
        }
        adjusted.removed = adjusted.removed.filter { !takenRows.contains($0) }.sorted()
        return (adjusted, moved)
    }

    /// The slot of each paragraph of a sequence (a baseline or a parse), nil where there is none. Mirrors the ownership
    /// walk of `FootnoteSyncService.notesOwnershipMap`, which is how the database sorts the Notes group: a Notes
    /// definition (`[^N]:`) is slot `def:N`; a label-less Notes paragraph after it is a continuation of that footnote,
    /// slot `cont:N:k` (k = 1, 2, ... under that owner; the footnote editor stores each paragraph of a multi-paragraph
    /// footnote as its own row); a heading or a non-Notes block ends the run, and a label-less Notes paragraph before
    /// any definition is the user's own prose (no slot).
    private static func notesSlots(_ items: [NotesItem]) -> [String?] {
        var owner: String?
        var ordinal = 0
        return items.map { item in
            guard item.isNotes, !item.isHeading else {
                owner = nil
                return nil
            }
            if let label = item.label {
                owner = label
                ordinal = 0
                return "def:\(label)"
            }
            guard let current = owner else { return nil }
            ordinal += 1
            return "cont:\(current):\(ordinal)"
        }
    }

    /// What `notesSlots` needs to know about one paragraph.
    private struct NotesItem {
        let isNotes: Bool       // a Notes paragraph that is not bibliography
        let isHeading: Bool
        let label: String?      // the footnote label of its fragment (`[^N]:`), if it has one
    }

    /// The `.changed` pairs between a slotted Notes row and a block of ANOTHER slot (or none). Baseline index -> index
    /// of the new block.
    private static func pairsInAnotherSlot(alignment: Alignment, rowSlots: [String?], blockSlots: [String?]) -> [Int: Int] {
        var pairs: [Int: Int] = [:]
        for (index, match) in alignment.matches.enumerated() {
            guard case .changed(let rowIndex) = match, let slot = rowSlots[rowIndex], blockSlots[index] != slot else { continue }
            pairs[rowIndex] = index
        }
        return pairs
    }

    /// New-block index -> baseline index: each candidate Notes paragraph, in order, takes the first row of its slot.
    private static func claimRows(
        _ rowsBySlot: inout [String: [Int]], alignment: Alignment, blockSlots: [String?], otherSlotPairs: [Int: Int]
    ) -> [Int: Int] {
        var moved: [Int: Int] = [:]
        for (index, blockSlot) in blockSlots.enumerated() {
            switch alignment.matches[index] {
            case .same: continue
            case .changed(let rowIndex): if otherSlotPairs[rowIndex] != index { continue }
            case .inserted: break
            }
            guard let slot = blockSlot, var rows = rowsBySlot[slot], !rows.isEmpty else { continue }
            moved[index] = rows.removeFirst()
            rowsBySlot[slot] = rows
        }
        return moved
    }
}
