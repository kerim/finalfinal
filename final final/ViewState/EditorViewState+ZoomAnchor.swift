//
//  EditorViewState+ZoomAnchor.swift
//  final final
//
//  t-75d20927: the zoom's block range as a value that follows a re-spacing of the `sortOrder` numbers.
//
//  A zoom keeps the rows it shows as a `[start, end)` range of raw `sortOrder` numbers for as long as it lasts. A re-spacing of the
//  numbers (a long paste in Rich Text, a run of Enters: `ProjectDatabase.renumberSortOrdersIfCrowded`) would make those numbers pick
//  other rows, so the range is stored as an `AnchoredSortOrderRange`: the numbers plus the length of
//  `ProjectDatabase.sortOrderRenumberLog` when they were taken, carried through every re-spacing since when read.
//
//  The stored property `zoomedBlockRangeAnchor` stays in the class body (EditorViewState.swift: a stored property cannot live in an
//  extension). Everything else reads and writes `zoomedBlockRange`, below. The anchor itself is read only where a range is captured to be
//  used later and must still see the re-spacings committed in between: the lifecycle save's step 2 (`captureForLifecycle`) and
//  `applyZoomedRangeWrite`, which hand it to the write so it is translated inside the write's own transaction.
//

import Foundation

extension EditorViewState {
    /// Sort order boundaries for the zoomed block range: always the numbers the rows have NOW. Assigning one stamps it at the log's
    /// current length, so assign numbers just read from the database (a range from an older read would miss a re-spacing that
    /// committed in between).
    var zoomedBlockRange: (start: Double, end: Double?)? {
        get { zoomedBlockRangeAnchor?.current }
        set {
            zoomedBlockRangeAnchor = newValue.map { AnchoredSortOrderRange(range: $0, log: projectDatabase?.sortOrderRenumberLog) }
        }
    }
}
