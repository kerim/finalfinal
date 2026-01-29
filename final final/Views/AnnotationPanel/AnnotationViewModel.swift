//
//  AnnotationViewModel.swift
//  final final
//

import SwiftUI

/// ViewModel for binding Annotation data to UI
@MainActor
@Observable
class AnnotationViewModel: Identifiable {
    let id: String
    var contentId: String
    var sectionId: String?
    var type: AnnotationType
    var text: String
    var isCompleted: Bool
    var charOffset: Int
    var highlightStart: Int?
    var highlightEnd: Int?

    init(from annotation: Annotation) {
        self.id = annotation.id
        self.contentId = annotation.contentId
        self.sectionId = annotation.sectionId
        self.type = annotation.type
        self.text = annotation.text
        self.isCompleted = annotation.isCompleted
        self.charOffset = annotation.charOffset
        self.highlightStart = annotation.highlightStart
        self.highlightEnd = annotation.highlightEnd
    }

    /// Whether this annotation has an associated highlight span
    var hasHighlight: Bool {
        highlightStart != nil && highlightEnd != nil
    }

    /// Display marker for this annotation
    var marker: String {
        if type == .task {
            return isCompleted ? type.completedMarker : type.collapsedMarker
        }
        return type.collapsedMarker
    }

    /// Preview text for display (truncated)
    var previewText: String {
        let maxLength = 50
        if text.count <= maxLength {
            return text
        }
        return String(text.prefix(maxLength)) + "…"
    }

    /// Full text for tooltips or expanded view
    var fullText: String {
        text
    }

    /// Convert back to Annotation model
    func toAnnotation(createdAt: Date, updatedAt: Date) -> Annotation {
        Annotation(
            id: id,
            contentId: contentId,
            sectionId: sectionId,
            type: type,
            text: text,
            isCompleted: isCompleted,
            charOffset: charOffset,
            highlightStart: highlightStart,
            highlightEnd: highlightEnd,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// Create a modified copy
    func withUpdates(
        text: String? = nil,
        isCompleted: Bool? = nil,
        charOffset: Int? = nil,
        highlightStart: Int?? = nil,
        highlightEnd: Int?? = nil,
        sectionId: String?? = nil
    ) -> AnnotationViewModel {
        let annotation = Annotation(
            id: self.id,
            contentId: self.contentId,
            sectionId: sectionId ?? self.sectionId,
            type: self.type,
            text: text ?? self.text,
            isCompleted: isCompleted ?? self.isCompleted,
            charOffset: charOffset ?? self.charOffset,
            highlightStart: highlightStart ?? self.highlightStart,
            highlightEnd: highlightEnd ?? self.highlightEnd
        )
        return AnnotationViewModel(from: annotation)
    }
}
