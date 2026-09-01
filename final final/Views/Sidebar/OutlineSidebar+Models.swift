//
//  OutlineSidebar+Models.swift
//  final final
//
//  Data types for outline sidebar: transfer, drop position, reorder request, level info.
//

import SwiftUI
import UniformTypeIdentifiers

/// Transferable wrapper for drag-and-drop
struct SectionTransfer: Codable, Transferable {
    let id: String
    let sortOrder: Double
    let headerLevel: Int
    let isSubtreeDrag: Bool      // True when Option-drag includes descendants
    let childIds: [String]       // Ordered descendant IDs for subtree drag

    init(id: String, sortOrder: Double, headerLevel: Int, isSubtreeDrag: Bool = false, childIds: [String] = []) {
        self.id = id
        self.sortOrder = sortOrder
        self.headerLevel = headerLevel
        self.isSubtreeDrag = isSubtreeDrag
        self.childIds = childIds
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .sectionTransfer)
    }
}

extension UTType {
    static var sectionTransfer: UTType {
        UTType(exportedAs: "com.kerim.final-final.section")
    }
}

// MARK: - Drop Position Types

/// Represents where a drop will occur relative to a section card
/// Now includes level information for horizontal zone-based level selection
enum DropPosition: Equatable {
    case insertBefore(index: Int, level: Int)   // Insert before card at index with specified level
    case insertAfter(index: Int, level: Int)    // Insert after card at index with specified level

    var targetIndex: Int {
        switch self {
        case .insertBefore(let idx, _), .insertAfter(let idx, _):
            return idx
        }
    }

    var level: Int {
        switch self {
        case .insertBefore(_, let lvl), .insertAfter(_, let lvl):
            return lvl
        }
    }
}

// MARK: - Level Calculation

/// Calculate target header level from horizontal drop position using zone-based selection
/// Returns a level from 1 to predecessorLevel+1 based on x position within the sidebar
/// - Parameters:
///   - x: Horizontal position of the drop
///   - sidebarWidth: Total width of the sidebar for zone calculation
///   - predecessorLevel: Header level of the section above the drop position (0 if dropping at top)
/// - Returns: Target header level (1+, no upper limit for deep headers)
func calculateZoneLevel(x: CGFloat, sidebarWidth: CGFloat, predecessorLevel: Int) -> Int {
    // Special case: first position (no predecessor) only allows level 1
    if predecessorLevel == 0 {
        return 1
    }

    let minLevel = 1
    let maxLevel = predecessorLevel + 1

    // All available levels from H1 to one deeper than predecessor
    let levels = Array(minLevel...maxLevel)

    // Divide sidebar width evenly among levels
    let zoneWidth = sidebarWidth / CGFloat(levels.count)
    let zoneIndex = min(Int(x / zoneWidth), levels.count - 1)
    return levels[max(0, zoneIndex)]
}

/// Structured request for section reordering with full context
struct SectionReorderRequest {
    let sectionId: String
    let targetSectionId: String?  // Insert AFTER this section (nil = insert at beginning)
    let newLevel: Int
    let newParentId: String?
    let isSubtreeDrag: Bool       // True when Option-drag moves parent with children
    let childIds: [String]        // Ordered descendant IDs for subtree drag

    init(
        sectionId: String,
        targetSectionId: String?,
        newLevel: Int,
        newParentId: String?,
        isSubtreeDrag: Bool = false,
        childIds: [String] = []
    ) {
        self.sectionId = sectionId
        self.targetSectionId = targetSectionId
        self.newLevel = newLevel
        self.newParentId = newParentId
        self.isSubtreeDrag = isSubtreeDrag
        self.childIds = childIds
    }
}

/// Lightweight struct for level constraint calculation (thread-safe)
/// Used to pass section level info to drop delegates without @Observable
struct SectionLevelInfo: Sendable {
    let id: String
    let headerLevel: Int
    let index: Int
}

// MARK: - Render Key (bt t-ef411da3 root-cause fix)

/// Precomputed comparison key backing `OutlineSidebar`'s `Equatable` conformance (see that
/// type's `==` in OutlineSidebar.swift). `ContentView` reconstructs `OutlineSidebar` fresh on
/// every keystroke -- it's a plain `View` value, rebuilt every time `ContentView.body` runs --
/// so without `Equatable` plus `.equatable()` at that call site, SwiftUI has no way to tell that
/// reconstruction apart from a genuine content change: `OutlineSidebar.body` re-ran on every
/// keystroke regardless of whether anything the sidebar actually displays had changed.
///
/// What's folded in, and why:
///  - `sectionsSignature`: `OutlineSidebar.renderSignature(of:)` over the RAW, unfiltered
///    `sections` array -- see that function's own doc comment for exactly which per-section
///    fields it covers, and which it deliberately excludes. Its effectiveness rests on a
///    precondition this file does not itself enforce: `SectionViewModel` object identity must
///    stay stable across an ordinary keystroke (the SAME instances get mutated in place, never
///    replaced), which is `EditorViewState+ObservableListDiff.swift`'s `mergeById`/
///    `mergeSections` doing its job correctly -- a change to that merge logic that started
///    replacing instances instead of mutating them would silently defeat `ObjectIdentifier`-based
///    hashing here, in a file this diff never touches.
///  - `statusFilter` / `headerLevelFilter` / `zoomedSectionId` / `documentGoal` /
///    `documentGoalType` / `excludeBibliography`: six of `OutlineSidebar`'s SEVEN other
///    `@Binding`s -- each read directly inside `body` (`filteredSections`, `OutlineFilterBar`'s
///    own bindings, the empty-state branch, `isZoomed:` per card, ...), so a change to any one of
///    them can change what `body` would produce.
///
/// NOT folded in, deliberately: `OutlineSidebar`'s EIGHTH `@Binding`, `sectionDropInFlight`, is
/// never read inside `body` -- it is only ever forwarded downstream as `$sectionDropInFlight` to
/// the drop delegates (`SectionDropDelegate`/`EndDropDelegate`). A `Binding`'s get/set closures
/// stay live against their true underlying storage regardless of whether `OutlineSidebar.body`
/// re-runs, so a drop delegate built in an earlier body pass keeps reading/writing the CURRENT
/// value even while `body` is being skipped -- there is nothing here for a skipped `body` to make
/// stale. Also not folded in: the two NON-optional closures, `onScrollToSection` and
/// `onSectionUpdated` (compare `DraggableCardView`'s own doc comment, same file family, which
/// enumerates every closure IT carries for the identical reason) -- closures aren't `Equatable`
/// at all, and every closure `OutlineSidebar` holds captures only reference-backed `@State`/
/// `@Observable` storage via `self`, never a by-value local, so a "stale" retained closure from a
/// skipped `body` pass behaves identically to a freshly-built one when it's eventually invoked. A
/// future closure that captured a plain by-value local instead would need to revisit this.
///
/// EXPLICIT INVARIANT: any `@Binding` added to `OutlineSidebar` in the future that is READ
/// INSIDE `body` (a `.wrappedValue` read, not just forwarded onward as `$x`) must ALSO be added
/// here -- both as a stored field and as a constructor parameter folded into the comparison -- or
/// its updates will silently stop reaching the sidebar the moment `ContentView`'s `.equatable()`
/// call decides nothing changed. A binding only ever forwarded downstream as `$x` (like
/// `sectionDropInFlight` above) does not need to be added. There is no compiler check for this
/// distinction; it is purely a discipline this doc comment exists to name.
///
/// EXPLICIT INVARIANT: excluding `title`/`wordCount` here (via `renderSignature`'s own
/// exclusions) is safe ONLY because `SectionCardView`, `FilteredWordCountLabel`, and
/// `SectionTitleTooltip` all read those properties LIVE off the `@Observable` `SectionViewModel`
/// object itself, rather than receiving them as plain values `OutlineSidebar`'s own body passes
/// down. If any of those three leaves is ever changed to receive title/word count as a plain
/// `String`/`Int` parameter instead of reading the object directly, this whole design breaks
/// silently -- the leaf would keep showing whatever value was captured the last time
/// `OutlineSidebar.body` happened to run, with no further updates reaching it.
///
/// ACCEPTED RISK: `sectionsSignature` is a 64-bit hash, so a collision (~2^-64) would make two
/// genuinely different section lists compare equal here and get silently skipped. Same
/// precedent/risk already accepted by `OutlineSidebar.structuralSignature(of:)`.
struct OutlineSidebarRenderKey: Equatable {
    let sectionsSignature: Int
    let statusFilter: SectionStatus?
    let headerLevelFilter: Int?
    let zoomedSectionId: String?
    let documentGoal: Int?
    let documentGoalType: GoalType
    let excludeBibliography: Bool

    init(
        sections: [SectionViewModel],
        statusFilter: SectionStatus?,
        headerLevelFilter: Int?,
        zoomedSectionId: String?,
        documentGoal: Int?,
        documentGoalType: GoalType,
        excludeBibliography: Bool
    ) {
        self.sectionsSignature = OutlineSidebar.renderSignature(of: sections)
        self.statusFilter = statusFilter
        self.headerLevelFilter = headerLevelFilter
        self.zoomedSectionId = zoomedSectionId
        self.documentGoal = documentGoal
        self.documentGoalType = documentGoalType
        self.excludeBibliography = excludeBibliography
    }
}

/// `Equatable` conformance backing `OutlineSidebar`'s `.equatable()` call site
/// (ContentView.swift). Kept HERE rather than in OutlineSidebar.swift purely to stay clear of
/// that file's SwiftLint `file_length` warning threshold (800 lines) -- no other reason; this is
/// exactly as much a part of `OutlineSidebar`'s own contract as if it lived in the primary file.
///
/// `ContentView` reconstructs `OutlineSidebar` fresh on every keystroke -- it's a plain `View`
/// value, rebuilt every time `ContentView.body` runs -- so pairing this with `.equatable()` at
/// that call site is what lets SwiftUI recognize a keystroke that touched neither the section
/// list's render-relevant fields nor the filter/zoom/goal state as producing an EQUAL
/// `OutlineSidebar` value, and skip re-invoking `OutlineSidebar.body` entirely. This is the
/// actual root-cause fix for bt t-ef411da3 -- rounds 1-2 fixed leaf-level over-invalidation
/// (word-count/tooltip extraction, `cardHeight`); this fixes body-level over-invalidation, the
/// thing those leaf fixes could never reach on their own because `ContentView` forced `body` to
/// re-run regardless.
extension OutlineSidebar: Equatable {
    static func == (lhs: OutlineSidebar, rhs: OutlineSidebar) -> Bool {
        lhs.renderKey == rhs.renderKey
            // `zoomedSectionIds` and `currentSectionId` are compared HERE, directly, rather than
            // folded into `renderKey` -- and deliberately NOT alongside `zoomedSectionId`
            // (singular, the zoom `@Binding`, which IS inside `renderKey`). These are genuinely
            // different kinds of property: `zoomedSectionIds`/`currentSectionId` are a plain
            // `let`/`var` on this struct -- real snapshots of THIS instance's own value, safe and
            // meaningful to compare directly. `zoomedSectionId` is a `@Binding`; comparing
            // `lhs.zoomedSectionId`/`rhs.zoomedSectionId` here would just re-read the SAME live
            // storage through two different binding wrappers and always report equal -- which is
            // exactly why its VALUE is captured into `renderKey` at construction time instead
            // (see that type's doc comment). Do not "simplify" by merging these two lines into
            // one -- that was rejected in round-1 review for exactly this reason: it would
            // silently turn `zoomedSectionIds`/`currentSectionId` into tautological
            // (always-true) comparisons, reintroducing the original bug for those two fields.
            && lhs.zoomedSectionIds == rhs.zoomedSectionIds
            && lhs.currentSectionId == rhs.currentSectionId
            && (lhs.onSectionReorder == nil) == (rhs.onSectionReorder == nil)
            && (lhs.onZoomToSection == nil) == (rhs.onZoomToSection == nil)
            && (lhs.onZoomOut == nil) == (rhs.onZoomOut == nil)
            && (lhs.onDragStarted == nil) == (rhs.onDragStarted == nil)
            && (lhs.onDragEnded == nil) == (rhs.onDragEnded == nil)
            && (lhs.onDuplicateSection == nil) == (rhs.onDuplicateSection == nil)
            && (lhs.onDeleteSection == nil) == (rhs.onDeleteSection == nil)
    }
}
