//
//  LifecycleWholeDocumentWrite+Check.swift
//  final final
//
//  t-94369a83 Phase 3a-2, Step 3 ("checked FB", Option A per the user's decision; plan-v2 section 0):
//  the comparison the queued whole-document write (FB) makes BEFORE it writes. Split out of
//  LifecycleWholeDocumentWrite.swift, whose `body` calls `matchingRowCount`.
//
//  The question it answers: are the rows already stored the rows FB would write? If so FB writes nothing
//  and bumps no epoch. It compares what a REOPEN reads, row by row, in the order a reopen reads them, plus the
//  text the sidebar's word counts come from:
//    - `blockType`;
//    - `headingLevel`, for headings only;
//    - `markdownFragment`, trimmed of whitespace and newlines on BOTH sides (the parser trims both ends;
//      per-edit fragments are untrimmed);
//    - `textContent`, trimmed on both sides exactly like the fragment (code review X1: `wordCount` and the
//      section goal progress are derived from it, see below);
//    - `isBibliography`, `isNotes`, `isPseudoSection`.
//  Rows whose fragment is empty after trimming are dropped on both sides (the parser never emits one and
//  a reopen skips them). Ids and the `sortOrder` NUMBERS are not compared, with one exception that is a
//  separate rule, not a field: `hasNearTie`.
//
//  The stored side is sorted with `BlockParser.assemblySorted`, the ordering a reopen uses. The would-write
//  side is `ProjectDatabase.preparedRowsForWholeReplace`, the very code `replaceBlocks` runs (heading
//  id/metadata and bibliography-flag restoration, carry-forward, image metadata), so the comparison and the
//  write cannot drift apart (plan-v2 D6, amendment A3).
//
//  Honest scope (plan-v2 D1, D5): the editor's per-block serializer (what the per-edit path stores) and its
//  whole-document serializer (what FB's fresh fetch carries) write some blocks differently (list markers,
//  tight vs loose list items, rules, `_x_` emphasis, characters remark escapes, possibly tables, multi-paragraph
//  quotes and citeproc bibliography text). After a session that touched any of those, the rows differ and FB
//  runs exactly as before. The check must NOT be loosened to tolerate them.
//
//  Why `textContent` is compared (code review X1; it replaces plan-v2 D8's "a skip leaves textContent and
//  wordCount as the editor wrote them"): the per-edit path stores ProseMirror's `node.textContent`, which
//  drops inline atoms (citations, footnote references, inline math) and joins table and quote child text with
//  no separator, while FB re-derives the text from the whole-document parse (`BlockParser.extractTextContent`).
//  A skip that ignored it would leave LOWER section word counts and goal progress for anyone who cites or
//  uses tables. Comparing it means FB runs whenever the editor's text differs from what FB would write, so
//  the counts stay what they were before this phase; `wordCount` is derived from `textContent`
//  (`Block.recalculateWordCount`), so it is covered too. The open-time maintenance pass
//  (`recomputeStoredBlockWordCounts`) recomputes counts from the STORED `textContent`, so it would not repair
//  what a skip left. The narrowed scope, stated plainly: a paragraph containing a citation, footnote
//  reference or inline math still rebuilds at close, as today. Plain-text paragraphs and headings are the
//  ones that skip.
//

import Foundation
import GRDB

extension LifecycleWholeDocumentWrite {

    /// Two adjacent stored rows (in reopen order) whose `sortOrder` values are closer than this, or equal,
    /// are a near tie: the check reports "different" so FB runs and renumbers (plan-v2 D2). FB is the only
    /// thing that renumbers `sortOrder`; the per-edit insert path halves the gap between neighbours
    /// (`Database+BlocksInsert`: the midpoint), so a long run of paragraphs added just before the Notes or
    /// bibliography heading squeezes the gap to the heading toward zero. The rule protects ACROSS closes:
    /// FB at close renumbers, so the squeeze cannot accumulate over sessions. WITHIN one session about 47
    /// such paragraphs can still tie before the close (a double has no room left for another midpoint), and
    /// a mid-session export, Save Version or crash would then see the tie (parked, t-746279b2).
    static let nearTieThreshold: Double = 1e-6

    /// One row as a reopen reads it: exactly the fields the check compares.
    struct ComparableRow: Equatable, Sendable, CustomStringConvertible {
        let blockType: BlockType
        let headingLevel: Int?
        let markdownFragment: String
        /// The text the word counts derive from (code review X1), trimmed like the fragment.
        let textContent: String
        let isBibliography: Bool
        let isNotes: Bool
        let isPseudoSection: Bool

        init(_ block: Block) {
            blockType = block.blockType
            headingLevel = block.blockType == .heading ? block.headingLevel : nil
            markdownFragment = block.markdownFragment.trimmingCharacters(in: .whitespacesAndNewlines)
            textContent = block.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            isBibliography = block.isBibliography
            isNotes = block.isNotes
            isPseudoSection = block.isPseudoSection
        }

        var description: String {
            "\(blockType.rawValue) level=\(headingLevel.map(String.init) ?? "nil") bibliography=\(isBibliography) "
                + "notes=\(isNotes) pseudoSection=\(isPseudoSection) fragment=\(markdownFragment.debugDescription) "
                + "text=\(textContent.debugDescription)"
        }

        /// The names of the compared fields in which the two rows differ (empty = identical).
        func differingFields(from other: ComparableRow) -> [String] {
            var fields: [String] = []
            if blockType != other.blockType { fields.append("blockType") }
            if headingLevel != other.headingLevel { fields.append("headingLevel") }
            if markdownFragment != other.markdownFragment { fields.append("markdownFragment") }
            if textContent != other.textContent { fields.append("textContent") }
            if isBibliography != other.isBibliography { fields.append("isBibliography") }
            if isNotes != other.isNotes { fields.append("isNotes") }
            if isPseudoSection != other.isPseudoSection { fields.append("isPseudoSection") }
            return fields
        }
    }

    /// The compared rows of `blocks`, in the order given, with empty-fragment rows dropped.
    static func comparableRows(_ blocks: [Block]) -> [ComparableRow] {
        blocks.filter { !BlockParser.isEmptyFragment($0.markdownFragment) }.map(ComparableRow.init)
    }

    /// Whether any two adjacent rows of `sortedStored` (already in reopen order) have equal `sortOrder`
    /// values or values less than `nearTieThreshold` apart. Every stored row counts, empty fragments
    /// included: a stale empty row can still be the neighbour a midpoint insert halves against, and the
    /// worst a spurious "tie" can do is one extra rebuild (which also deletes that empty row).
    static func hasNearTie(_ sortedStored: [Block]) -> Bool {
        zip(sortedStored, sortedStored.dropFirst()).contains { abs($1.sortOrder - $0.sortOrder) < nearTieThreshold }
    }

    /// The first way `stored` (sorted here with the reopen ordering) differs from `wouldWrite` (in the
    /// order FB would write it), described by row number and by the names of the differing fields with
    /// both values; nil when the compared rows are identical. The wording is what a failing test prints.
    static func firstDifference(stored: [Block], wouldWrite: [Block]) -> String? {
        let lhs = comparableRows(BlockParser.assemblySorted(stored))
        let rhs = comparableRows(wouldWrite)
        for (index, pair) in zip(lhs, rhs).enumerated() where pair.0 != pair.1 {
            return "row \(index + 1) differs in \(pair.0.differingFields(from: pair.1).joined(separator: ", ")): "
                + "stored [\(pair.0)] vs would write [\(pair.1)]"
        }
        guard lhs.count == rhs.count else {
            return "row count differs: stored \(lhs.count) vs would write \(rhs.count)"
        }
        return nil
    }

    /// True when the stored rows are identical, under the rule in this file's header, to the rows FB would
    /// write. Does not apply the near-tie rule: that is `hasNearTie`, a separate condition the body ANDs in.
    static func rowsMatch(stored: [Block], wouldWrite: [Block]) -> Bool {
        firstDifference(stored: stored, wouldWrite: wouldWrite) == nil
    }

    /// The check, inside FB's own transaction: the number of rows compared when the stored rows already
    /// match what FB would write and there is no near tie; nil when FB must write.
    static func matchingRowCount(db: Database, prepared: LifecycleWholeDocumentPrepared) throws -> Int? {
        let stored = BlockParser.assemblySorted(
            try Block.filter(Block.Columns.projectId == prepared.projectId).fetchAll(db))
        if hasNearTie(stored) {
            DebugLog.log(.lifecycle, "[LifecycleWholeDocumentWrite] check: near sortOrder tie among \(stored.count) rows -- rebuilding")
            return nil
        }
        let wouldWrite = ProjectDatabase.preparedRowsForWholeReplace(existing: stored, parsed: prepared.blocks)
        if let difference = firstDifference(stored: stored, wouldWrite: wouldWrite) {
            // Only the row number and field names go to the log, never the document's text.
            DebugLog.log(.lifecycle, "[LifecycleWholeDocumentWrite] check: rows differ -- rebuilding (\(difference.prefix(60)))")
            return nil
        }
        return comparableRows(wouldWrite).count
    }
}
