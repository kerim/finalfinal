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
/// Returns one of 2-3 valid level options based on x position relative to predecessor
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

    // Allow levels beyond H6 (deep headers from subtree drags)
    let minLevel = max(1, predecessorLevel - 1)
    let maxLevel = predecessorLevel + 1  // No cap - allow H7+

    // Determine how many unique levels are available
    let uniqueLevels = Set([minLevel, predecessorLevel, maxLevel]).sorted()

    if uniqueLevels.count == 2 {
        // Only 2 options (e.g., predecessor at level 1 gives [1, 2])
        let zoneWidth = sidebarWidth / 2
        return x < zoneWidth ? uniqueLevels[0] : uniqueLevels[1]
    } else {
        // 3 options: minLevel, same level, maxLevel
        let zoneWidth = sidebarWidth / 3
        if x < zoneWidth {
            return minLevel
        } else if x < zoneWidth * 2 {
            return predecessorLevel
        } else {
            return maxLevel
        }
    }
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
