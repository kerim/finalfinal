//
//  MarkdownBlockDiff+MovedHeadings.swift
//  final final
//
//  t-b097670d: a heading moved (cut and pasted, or selected text dragged inside the editor) or put back in Markdown mode keeps its
//  status, tags and goals. The PURE half: which inserted heading takes the six section-metadata fields of which deleted heading row (see
//  "5. MOVED HEADINGS" in MarkdownBlockDiff.swift). In Markdown the Outline sidebar drag is the queued structural reorder: it keeps ids and
//  never reaches this diff; only dragging selected text inside the editor is a same-save move. In an extension in its own file so
//  MarkdownBlockDiff.swift stays under the project's file-length limit.
//
//  Why a move is a delete plus an insert. The alignment pairs a removed row with an inserted block only inside one changed region
//  and only for equal `BlockType`; a heading cut from one place and pasted in another sits in two regions, so it is a delete of the
//  old row and an insert of a new one. `BlockUpdate` has no `sortOrder`, so a write cannot move a row, and a deleted id is never
//  reused. The new row therefore has a new id, and it must take the old row's six fields (`SectionMetadataCarry`) or the user's
//  status, tags and goals are lost. Notes rows keep their id across a move in `pairMovedNotes` only because the database keeps
//  them sorted by footnote number; headings have no such rule.
//
//  The match is the key: same type, same level, same trimmed line. A renamed heading (a different line) is not a move: it is the
//  existing `.changed` update that keeps the id, and a level change is another key. A heading moved in the same save as another
//  heading edit in the same spot (the removed row already paired `.changed` with another heading) is not a candidate either.
//
//  NOT COVERED: section breaks. `BlockType.canHaveSectionMetadata` is true for `.heading` and `.sectionBreak`, but every
//  section-break marker is the same line, so matching by line would hand the fields to the wrong section; only `.heading` blocks
//  are candidates here, and `RemovedHeadingMemory` never holds a section break. Notes and bibliography headings are machine-managed
//  and never candidates.
//

import Foundation

extension MarkdownBlockDiff {

    /// A heading row this diff deletes: what the writer needs to remember its fields once the write has deleted it
    /// (`RemovedHeadingMemory`). `carriedByTempId` is the temp id of the insert of the same save that takes the row's fields directly
    /// (`pairMovedHeadings`), nil for a row nothing takes: the writer remembers a carried row only when that insert was NOT minted
    /// (a refused or dropped insert would otherwise lose the fields).
    struct RemovedHeadingRef: Sendable, Equatable {
        let id: String
        let key: Key
        var carriedByTempId: String?
    }

    /// A remembered item an inserted heading takes (`Result.usedRemembered`): the insert's temp id and the item's token.
    struct UsedRemembered: Sendable, Equatable {
        let tempId: String
        let token: Int
    }

    /// Whether a block or row of this shape may take part in a heading carry: a plain heading, neither Notes nor bibliography.
    private static func isCarryingHeading(blockType: BlockType, isNotes: Bool, isBibliography: Bool) -> Bool {
        blockType == .heading && !isNotes && !isBibliography
    }

    /// SAME SAVE. New-block index -> baseline index of the removed heading row whose six fields that block takes.
    ///
    /// Each removed heading row (the alignment left it unmatched; not Notes, not bibliography; its id known) is paired with the inserted
    /// heading block (the alignment calls it new and `pairMovedNotes` did not claim it; not Notes, not bibliography) of the SAME key,
    /// in document order per key: the first such block takes the first such row, the next block the next row, and so on. With two
    /// equal titles both moved, the first moved copy therefore takes the earlier row. A key with more rows than blocks leaves the
    /// extra rows deleted (they are not paired; `removedHeadings` still lists them); more blocks than rows leaves the later blocks to
    /// the remembered items.
    static func pairMovedHeadings(
        alignment: Alignment, baseline: [Entry], new: [Block], movedNotes: [Int: Int]
    ) -> [Int: Int] {
        var rowsByKey: [Key: [Int]] = [:]
        for index in alignment.removed.sorted() {
            let row = baseline[index]
            guard row.id != nil,
                  isCarryingHeading(blockType: row.key.blockType, isNotes: row.isNotes, isBibliography: row.isBibliography) else { continue }
            rowsByKey[row.key, default: []].append(index)
        }
        guard !rowsByKey.isEmpty else { return [:] }
        var paired: [Int: Int] = [:]
        var used: [Key: Int] = [:]
        for (index, match) in alignment.matches.enumerated() {
            guard case .inserted = match, movedNotes[index] == nil,
                  isCarryingHeading(blockType: new[index].blockType, isNotes: new[index].isNotes, isBibliography: new[index].isBibliography)
            else { continue }
            let key = Key(new[index])
            let taken = used[key, default: 0]
            guard let rows = rowsByKey[key], taken < rows.count else { continue }
            paired[index] = rows[taken]
            used[key] = taken + 1
        }
        return paired
    }

    /// ACROSS SAVES. New-block index -> the remembered item (`RemovedHeadingMemory.items`, oldest first) whose six fields that block takes.
    ///
    /// A candidate is an inserted heading block (not Notes, not bibliography; not claimed by `pairMovedNotes`) with no twin in this
    /// save (`sameSave`). For each key, when k blocks of that key are candidates in this save they take the k MOST RECENTLY recorded
    /// items of that key, so a single cut and paste takes the latest removal and not an older stale one. Those k items are then
    /// handed to the k blocks in the order the rows sat in the document (the items' `sortOrder`, ties by token), not in the order
    /// they were deleted: with two headings of one line deleted later-one-first and put back by one Cmd-Z pair, the earlier
    /// heading gets the earlier row's fields. A key with fewer items than blocks leaves the later blocks with nothing. The rule itself is
    /// `RemovedHeadingMemory.assign`, which the zoomed save uses too.
    static func pairRememberedHeadings(
        alignment: Alignment, new: [Block], movedNotes: [Int: Int], sameSave: [Int: Int], remembered: [RemovedHeadingMemory.Item]
    ) -> [Int: RemovedHeadingMemory.Item] {
        guard !remembered.isEmpty else { return [:] }
        var candidates: [(index: Int, key: Key)] = []
        for (index, match) in alignment.matches.enumerated() {
            guard case .inserted = match, movedNotes[index] == nil, sameSave[index] == nil,
                  isCarryingHeading(blockType: new[index].blockType, isNotes: new[index].isNotes, isBibliography: new[index].isBibliography)
            else { continue }
            candidates.append((index, Key(new[index])))
        }
        return RemovedHeadingMemory.assign(candidates: candidates, items: remembered)
    }
}
