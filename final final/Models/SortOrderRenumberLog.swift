//
//  SortOrderRenumberLog.swift
//  final final
//
//  t-75d20927: a record of every re-spacing of the block table's `sortOrder` numbers in this session, and a value that keeps a
//  range of those numbers pointing at the same rows across them.
//
//  Why it exists. `ProjectDatabase.renumberSortOrdersIfCrowded` rewrites every row's `sortOrder` as 1, 2, 3 ... in assembly order
//  when a run of inserts in one spot has used up the room between two rows. It never changes the ORDER of the rows, only the
//  numbers. Almost nothing holds a number across a write (the editor holds ids). The one thing that does is a zoom: it stores the
//  rows it shows as a `[start, end)` range of raw `sortOrder` numbers for as long as the zoom lasts
//  (`EditorViewState.zoomedBlockRange`), and later reads (the close's whole-document write, the block-id push, the content
//  rebuild) pick "the rows with `start <= sortOrder < end`". After a re-spacing those numbers would pick other rows. So each
//  committed re-spacing logs the numbers it replaced, and a range stamped at an earlier point in the log is carried forward
//  through the entries it missed.
//

import Foundation
import Synchronization

/// The old `sortOrder` numbers of every committed re-spacing, in the order they committed. Lives on the `ProjectDatabase` (in memory
/// only: a zoom range never outlives the session, and a reopened project starts with a fresh log).
final class SortOrderRenumberLog: Sendable {
    /// One entry per committed renumber: the project's old `sortOrder`s in assembly order, so ascending. The row at position `i`
    /// became `i + 1` (`ProjectDatabase.rewriteSortOrders`).
    private let entries = Mutex<[[Double]]>([])

    /// Appends the renumbers one committed transaction made, in the order it made them. Called from that transaction's commit hook.
    func append(_ newEntries: [[Double]]) {
        guard !newEntries.isEmpty else { return }
        entries.withLock { $0.append(contentsOf: newEntries) }
    }

    /// How many renumbers have committed. A range stamped at this value has missed none of them.
    var generation: Int { entries.withLock { $0.count } }

    /// `range` carried through every renumber after the first `generation` entries, and the generation it is now current at.
    /// Both come from one lock hold, so they agree even while a renumber commits on another thread.
    func translate(
        _ range: (start: Double, end: Double?), from generation: Int
    ) -> (range: (start: Double, end: Double?), generation: Int) {
        entries.withLock { entries in
            var start = range.start
            var end = range.end
            for old in entries.dropFirst(generation) {
                start = Self.renumbered(start, old)
                end = end.map { Self.renumbered($0, old) }
            }
            return ((start: start, end: end), entries.count)
        }
    }

    /// The number a boundary `value` has after a renumber of rows whose old numbers were `oldAscending`: the new number of the
    /// first row at or after `value` (`index + 1`, exactly what `rewriteSortOrders` gives that row), or `count + 1` when no row
    /// is. The renumber keeps the rows' order, so "`sortOrder >= start` and `sortOrder < end`" picks the same rows before and
    /// after. A row that was deleted after the range was taken has no number any more; the next row's number stands in, as the
    /// raw comparison always did.
    static func renumbered(_ value: Double, _ oldAscending: [Double]) -> Double {
        var low = 0
        var high = oldAscending.count
        while low < high {
            let middle = (low + high) / 2
            if oldAscending[middle] >= value {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return Double(low + 1)
    }
}

/// A `[start, end)` range of `sortOrder` numbers that stays on the same rows when the numbers are re-spaced. `end == nil` is "to the
/// end of the document".
///
/// It remembers the log and the log's length at the moment it was taken; `current` carries the range through every renumber
/// committed since. The stored `range` is never rewritten, so the answer depends only on the log, not on how often it is read.
struct AnchoredSortOrderRange: Sendable {
    let range: (start: Double, end: Double?)
    private let log: SortOrderRenumberLog?
    private let generation: Int

    /// A range taken NOW, on the database's own log (`log` is nil only for an editor state that has no project database, where
    /// nothing can renumber).
    init(range: (start: Double, end: Double?), log: SortOrderRenumberLog?) {
        self.range = range
        self.log = log
        self.generation = log?.generation ?? 0
    }

    /// A range that never moves: for a caller that holds no log (a test that builds the range from rows it just read and renumbers nothing).
    init(unanchored range: (start: Double, end: Double?)) {
        self.range = range
        self.log = nil
        self.generation = 0
    }

    /// The range as the rows' numbers read today.
    var current: (start: Double, end: Double?) {
        log?.translate(range, from: generation).range ?? range
    }
}
