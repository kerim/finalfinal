//
//  RemovedHeadingMemory.swift
//  final final
//
//  t-b097670d: what the Markdown per-block writer remembers of the headings it deleted, so that a heading that comes back in a LATER
//  save takes its status, tags and goals again. One value per `MarkdownBlockWriter` (one per open project).
//
//  Why it exists. In Markdown mode a heading the user cuts and pastes elsewhere, drags selected text inside the editor, or deletes
//  and brings back with Cmd-Z is, to the writer, a delete of the old row and an insert of a new one (the write cannot move a row). (The
//  Outline sidebar drag is another thing: the queued structural reorder keeps ids and never reaches this diff. Only dragging selected
//  text inside the editor is a same-save move.) When the delete and the insert are in ONE save the diff pairs them and the new row
//  copies the old row's six fields inside the same transaction (`pairMovedHeadings`). But the save runs about a second after the last
//  keystroke: a cut, a click elsewhere and a paste usually fall in two saves, and a deleted line that is saved and then undone always
//  does. By the time the insert is written the old row is gone, so the writer keeps the six fields of every heading row it deletes
//  (`MarkdownBlockWriter.complete` records them, from `EditorApplyResult.deletedHeadings`, the rows as they were just before the
//  delete) and the next save's inserted heading with the identical line takes them by value (`pairRememberedHeadings`).
//
//  The zoomed Markdown save shares the same memory (`ZoomedHeadingCarry`, `Database+BlocksReplace.swift`; `EditorViewState+
//  ZoomedRangeWrite.swift` hands it over after the write): a heading it deletes without a same-title partner is recorded, and a new
//  heading with the identical line takes the fields back, so a cut zoomed can be pasted unzoomed and the other way round.
//
//  Which item a heading takes. Items are kept oldest first, each with a token that only grows. When k inserted headings of one line
//  are candidates in a save they take the k most recently recorded items of that line; those items are then handed out by the `sortOrder`
//  the deleted rows had (the order they sat in the document), not by when they were deleted. A single cut and paste takes the
//  latest removal and not an older stale one; two equal titles both removed and both put back get their own fields in document order.
//
//  An item leaves the memory only when a write that used it was applied and minted that insert (`consume`); a failed or refused write
//  keeps it for the retry. Writes are serialized, so two saves never take the same item.
//
//  Lifetime and size. Kept across `markdownWriter.reset()` (a zoom, a mode switch: the document is the same, so a heading deleted, a
//  switch to Rich Text and back, then Cmd-Z still carries); forgotten by `EditorViewState.resetForProjectSwitch()` (close and project
//  switch), and a record under another project id clears it first, so one project's items never reach another project's diff
//  (`items(for:)`). About `capacity` items, the oldest dropped first: an item that is never put back ages out, at the cost of a few
//  small values. The cap never evicts items recorded by the SAME call, so a select-all delete of 300 headings keeps all 300 (a later
//  small call trims back to `capacity`).
//
//  A heading typed fresh with the same line as one deleted earlier in the open session takes the old fields. Accepted: an identical line
//  (same level, same text) reappearing in the same document is almost always the same section coming back, the opposite mistake loses
//  the user's own data silently, and this one shows a status or goal on a card the user can see and change.
//
//  NOT COVERED: section breaks. A section break can have section metadata too (`BlockType.canHaveSectionMetadata`), but every section-
//  break marker is the same line, so matching by line would hand a status, tags and goals to the wrong section; only headings are
//  remembered. Rich Text's own editing never reads or writes this memory (a heading cut or pasted in Rich Text is not covered). Rich Text
//  zoom can reach it through the old zoom path (`flushContentToDatabase` calls `applyZoomedRangeWrite`, the zoom transition's fallback),
//  and so can the bibliography flush's fallback; that is harmless: it only puts fields back on a heading with an identical line.
//  In zoomed Markdown a sub-heading RENAME is still a delete plus an insert (until t-47694cc4): it records the old line's fields, and if the
//  new line equals the line of a heading deleted earlier it takes that heading's fields. A stated limit. A heading cut and a different
//  heading's whole selected line pasted over it in the same pause also stays as it is (the region pairing makes it a rename in place).
//
//  Pure and main-actor free: no database, no editor.
//

import Foundation

struct RemovedHeadingMemory: Sendable {

    /// One remembered heading row.
    struct Item: Sendable, Equatable {
        /// Grows with every item recorded; the order items were recorded in, and what the diff reports back when it takes one.
        let token: Int
        /// The deleted row's line (type, level, trimmed fragment): an inserted heading takes the item only with an equal key.
        let key: MarkdownBlockDiff.Key
        let metadata: SectionMetadataCarry
        /// Where the deleted row sat, as stored when it was deleted. Hands several items of one line out in document order.
        let sortOrder: Double
    }

    /// What `record` is given for one deleted heading row.
    struct Removal: Sendable {
        let key: MarkdownBlockDiff.Key
        let metadata: SectionMetadataCarry
        let sortOrder: Double
    }

    /// The most items kept; the oldest go first.
    static let capacity = 200

    /// The project the items belong to; nil while there are none.
    private(set) var projectId: String?
    /// Oldest first.
    private(set) var items: [Item] = []
    private var nextToken = 1

    /// Appends one item per removal, in the given order, under `projectId`. Another project's items are dropped first. Past `capacity` the
    /// oldest items are dropped, but never one recorded by THIS call: the limit is the larger of `capacity` and this call's own count, so
    /// a select-all delete of 300 headings keeps all 300. Nothing happens for an empty list.
    mutating func record(_ removals: [Removal], projectId: String) {
        guard !removals.isEmpty else { return }
        if self.projectId != projectId {
            items = []
            self.projectId = projectId
        }
        for removal in removals {
            items.append(Item(token: nextToken, key: removal.key, metadata: removal.metadata, sortOrder: removal.sortOrder))
            nextToken += 1
        }
        let limit = max(Self.capacity, removals.count)
        if items.count > limit { items.removeFirst(items.count - limit) }
    }

    /// The rule that decides which remembered item a heading that comes back takes, as a pure function, shared by the per-block save
    /// (`MarkdownBlockDiff.pairRememberedHeadings`) and the zoomed save (`replaceBlocksInRangeCarrying`). `candidates` are the headings
    /// that came back (`index` is whatever the caller numbers them by; `key` is their line). For each key, when k candidates of that
    /// key are present they take the k MOST RECENTLY recorded items of that key (a single cut and paste takes the latest removal, not an
    /// older stale one); those items are then handed to the candidates in index order sorted by the `sortOrder` the deleted rows had (ties
    /// by token), not by when they were deleted. A key with fewer items than candidates leaves the later candidates with nothing.
    /// `items` are oldest first, as `items(for:)` returns them. Returns candidate index -> item.
    static func assign(candidates: [(index: Int, key: MarkdownBlockDiff.Key)], items: [Item]) -> [Int: Item] {
        guard !items.isEmpty, !candidates.isEmpty else { return [:] }
        var indicesByKey: [MarkdownBlockDiff.Key: [Int]] = [:]
        for candidate in candidates.sorted(by: { $0.index < $1.index }) {
            indicesByKey[candidate.key, default: []].append(candidate.index)
        }
        var itemsByKey: [MarkdownBlockDiff.Key: [Item]] = [:]
        for item in items { itemsByKey[item.key, default: []].append(item) }
        var assigned: [Int: Item] = [:]
        for (key, indices) in indicesByKey {
            guard let keyItems = itemsByKey[key] else { continue }
            let chosen = keyItems.suffix(indices.count).sorted { ($0.sortOrder, $0.token) < ($1.sortOrder, $1.token) }
            for (index, item) in zip(indices, chosen) { assigned[index] = item }
        }
        return assigned
    }

    /// Takes the items with these tokens out (a write that used them was applied).
    mutating func consume(tokens: Set<Int>) {
        guard !tokens.isEmpty else { return }
        items.removeAll { tokens.contains($0.token) }
    }

    /// The items a diff for `projectId` may take: all of them when they belong to that project, none otherwise.
    func items(for projectId: String) -> [Item] {
        self.projectId == projectId ? items : []
    }

    /// Forgets everything (the project is being closed or switched).
    mutating func forget() {
        items = []
        projectId = nil
    }
}
