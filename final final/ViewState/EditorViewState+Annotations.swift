//
//  EditorViewState+Annotations.swift
//  final final
//

import SwiftUI

// MARK: - Annotation Filtering

extension EditorViewState {

    /// Document-level annotations (not anchored to markdown)
    var documentAnnotations: [AnnotationViewModel] {
        annotations.filter { $0.isDocumentLevel }
    }

    /// Document-level annotations filtered by type and completion status
    var displayDocumentAnnotations: [AnnotationViewModel] {
        documentAnnotations.filter { annotation in
            guard annotationTypeFilters.contains(annotation.type) else { return false }
            if hideCompletedTasks && annotation.type == .task && annotation.isCompleted {
                return false
            }
            return true
        }
    }

    /// Inline annotations to display in panel (filtered by type and completion status)
    var displayAnnotations: [AnnotationViewModel] {
        annotations.filter { annotation in
            // Exclude document-level (shown separately)
            guard !annotation.isDocumentLevel else { return false }

            // Must match type filter
            guard annotationTypeFilters.contains(annotation.type) else { return false }

            // Hide completed tasks if filter is on
            if hideCompletedTasks && annotation.type == .task && annotation.isCompleted {
                return false
            }

            return true
        }
    }

    /// Toggle visibility of an annotation type in the panel
    func toggleAnnotationTypeFilter(_ type: AnnotationType) {
        if annotationTypeFilters.contains(type) {
            annotationTypeFilters.remove(type)
        } else {
            annotationTypeFilters.insert(type)
        }
    }

    /// Set display mode for an annotation type
    func setAnnotationDisplayMode(_ mode: AnnotationDisplayMode, for type: AnnotationType) {
        annotationDisplayModes[type] = mode
    }

    /// Get display mode for an annotation type
    func displayMode(for type: AnnotationType) -> AnnotationDisplayMode {
        annotationDisplayModes[type] ?? .inline
    }

    /// Toggle annotation panel visibility
    func toggleAnnotationPanel() {
        isAnnotationPanelVisible.toggle()
    }

    /// Toggle outline sidebar visibility
    func toggleOutlineSidebar() {
        isOutlineSidebarVisible.toggle()
    }

    /// Get annotation counts by type (single-pass)
    var annotationCounts: [AnnotationType: Int] {
        annotations.reduce(into: [:]) { counts, annotation in
            counts[annotation.type, default: 0] += 1
        }
    }

    /// Get incomplete task count
    var incompleteTaskCount: Int {
        annotations.filter { $0.type == .task && !$0.isCompleted }.count
    }

}
