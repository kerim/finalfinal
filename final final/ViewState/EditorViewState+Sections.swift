//
//  EditorViewState+Sections.swift
//  final final
//

import SwiftUI

// MARK: - Sections

extension EditorViewState {

    /// Sections to display (filtered by status and zoom)
    var displaySections: [SectionViewModel] {
        var result = sections

        // Apply status filter
        if let filter = statusFilter {
            result = result.filter { $0.status == filter }
        }

        // Apply zoom (show subtree only)
        if let zoomId = zoomedSectionId {
            result = filterToSubtree(sections: result, rootId: zoomId)
        }

        return result
    }

    /// Sections for outline navigation popover (zoom-filtered only, no status filter)
    var outlineSections: [SectionViewModel] {
        if let zoomId = zoomedSectionId {
            return filterToSubtree(sections: sections, rootId: zoomId)
        }
        return sections
    }

    /// Find zoomed section for breadcrumb display
    var zoomedSection: SectionViewModel? {
        guard let zoomId = zoomedSectionId else { return nil }
        return sections.first { $0.id == zoomId }
    }

}
