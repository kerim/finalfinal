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

    /// `annotation`'s position within the INLINE-only ordering -- the numbering the JS bridge
    /// functions (`getAnnotations()`/`scrollToAnnotation()`/`deleteInlineAnnotation()`) use on
    /// both web editors. Document Notes are DB-only rows (`charOffset < 0`, sorted first in
    /// `annotations`) that are never written into the document's markdown/nodes, so those JS
    /// functions never see or count them; any index computed against the FULL `annotations`
    /// array is therefore off by however many Document Notes exist, landing on the wrong
    /// annotation. This filters them out before indexing so callers land on the annotation the
    /// user actually clicked.
    ///
    /// Panel-display filters (`annotationTypeFilters`, `hideCompletedTasks`) deliberately do
    /// NOT enter this index: they only hide cards from the panel's own list, they never remove
    /// the corresponding node from the document, so the bridge's inline ordering is unaffected
    /// by them. Only Document Notes -- which really are absent from the document -- are
    /// excluded here.
    ///
    /// Returns `nil` if `annotation` is itself document-level (it has no inline index) or is
    /// not present in `annotations` at all.
    func inlineAnnotationIndex(of annotation: AnnotationViewModel) -> Int? {
        guard !annotation.isDocumentLevel else { return nil }
        return annotations
            .filter { !$0.isDocumentLevel }
            .firstIndex(where: { $0.id == annotation.id })
    }

}
