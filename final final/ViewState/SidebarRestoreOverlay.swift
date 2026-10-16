//
//  SidebarRestoreOverlay.swift
//  final final
//
//  t-94369a83 Phase 4b, slice 2b (quick undo of an editor-first section delete): where a restored section's leaders go in the sidebar
//  while the database does not hold their rows yet.
//
//  THE BUG THIS FIXES (first VM runs, testQuickUndoTiming_article). The overlay used to place each restored leader by comparing its OLD
//  pre-delete `sortOrder` with the CURRENT outline's sort orders. After the delete the rows that followed the deleted section had been
//  renumbered to close the gap, so for the last body section before Notes the old number of its sub-heading (about 82) was larger than
//  the new number of "# Notes" (about 78): the level-3 heading landed right after the level-1 "Notes", the hierarchy check
//  (`ContentView.hasHierarchyViolations`: level <= predecessor + 1) fired, and hierarchy enforcement patched the heading to level 2 in
//  the database and the editor and wiped the redo stack.
//
//  THE RULE NOW. A restore is placed by DOCUMENT ANCHOR, never by a stale number: the id of the nearest outline block (heading or
//  section break) that stood before the first restored leader in the pre-delete document and is not itself restored. The leaders go
//  right after it, in their own (document) order; with no outline block before them they go first. Only when no anchor was recorded
//  (the delete job had not applied yet, so there was no pre-delete payload and the database still holds the rows under their old
//  numbers) or the anchor is not in the list any more does the old sort-order rule apply.
//
//  Everything here is pure (no editor state, no database) so a unit test can drive it with plain values.
//

import Foundation

/// Where a pending restore goes in the outline.
enum RestoreAnchor: Equatable, Sendable {
    /// Nothing outline-level stood before the restored leaders: they go first.
    case documentStart
    /// They go right after the outline block with this id.
    case after(String)
}

/// What the overlay needs to know about an outline entry; `Block` (outline results) and `SectionViewModel` (the sidebar's own list) both
/// have it.
protocol RestoreOverlayItem {
    var id: String { get }
    var sortOrder: Double { get }
    var isBibliography: Bool { get }
}

extension Block: RestoreOverlayItem {}
extension SectionViewModel: RestoreOverlayItem {}

/// One quick-undone section whose rows the database has not got back yet: its leaders in document order, and where they go.
struct PendingRestore<Item: RestoreOverlayItem> {
    let leaders: [Item]
    /// nil: no anchor was recorded; the leaders are placed by their old sort orders (the rule before anchors existed).
    let anchor: RestoreAnchor?
}

enum SidebarRestoreOverlay {

    /// The anchor for `leaders` (the section's heading and section-break rows, as the delete job recorded them) in the document as it
    /// was before the delete (`preDeleteRows`, in document order). nil when the pre-delete rows are not known (the delete job has not
    /// applied yet) or do not hold the leaders.
    static func anchor(for leaders: [Block], inPreDeleteRows rows: [Block]) -> RestoreAnchor? {
        let restoredIds = Set(leaders.map(\.id))
        guard !restoredIds.isEmpty, let first = rows.firstIndex(where: { restoredIds.contains($0.id) }) else { return nil }
        let previous = rows[..<first].last { row in
            (row.blockType == .heading || row.isPseudoSection) && !row.isBibliography && !restoredIds.contains(row.id)
        }
        return previous.map { .after($0.id) } ?? .documentStart
    }

    /// `list` (an outline in its own order: sections by sort order, the bibliography last) with every restore's leaders merged in. A
    /// leader already in `list` is not added twice. Restores are applied in the order of their first leader's old sort order, so a
    /// later restore may be anchored on a leader an earlier one has just put in.
    static func merging<Item: RestoreOverlayItem>(_ restores: [PendingRestore<Item>], into list: [Item]) -> [Item] {
        guard !restores.isEmpty else { return list }
        var result = list
        var present = Set(list.map(\.id))
        let ordered = restores.sorted { firstSortOrder($0) < firstSortOrder($1) }
        for restore in ordered {
            let missing = restore.leaders.filter { !present.contains($0.id) }
            guard !missing.isEmpty else { continue }
            if let start = insertionIndex(after: restore.anchor, in: result) {
                result.insert(contentsOf: missing, at: start)
            } else {
                for leader in missing.sorted(by: { $0.sortOrder < $1.sortOrder }) {
                    result.insert(leader, at: indexBySortOrder(of: leader, in: result))
                }
            }
            present.formUnion(missing.map(\.id))
        }
        return result
    }

    private static func firstSortOrder<Item: RestoreOverlayItem>(_ restore: PendingRestore<Item>) -> Double {
        restore.leaders.map(\.sortOrder).min() ?? 0
    }

    /// The index right after the anchor, or nil when there is no anchor, it is not in `list`, or it is the bibliography (which the
    /// outline keeps last whatever its position in the document).
    private static func insertionIndex<Item: RestoreOverlayItem>(after anchor: RestoreAnchor?, in list: [Item]) -> Int? {
        switch anchor {
        case nil:
            return nil
        case .documentStart?:
            return 0
        case .after(let id)?:
            guard let index = list.firstIndex(where: { $0.id == id }), !list[index].isBibliography else { return nil }
            return index + 1
        }
    }

    /// The rule before anchors: before the first non-bibliography entry with a larger sort order, else before the bibliography, else last.
    private static func indexBySortOrder<Item: RestoreOverlayItem>(of leader: Item, in list: [Item]) -> Int {
        list.firstIndex { !$0.isBibliography && $0.sortOrder > leader.sortOrder }
            ?? list.firstIndex { $0.isBibliography }
            ?? list.count
    }
}
