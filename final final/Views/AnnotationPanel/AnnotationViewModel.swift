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

    /// True while `AnnotationCardView` is showing this annotation's inline edit `TextEditor`.
    /// Lives here (a reference type persistently identified by `id`, not on the View's own
    /// `@State`) so the Esc ladder's registered cancel closure (UX contract §6, see
    /// `AnnotationCardView.startEditing`) can capture THIS model directly instead of the View
    /// struct: capturing the View struct would (a) create a retain cycle -- the struct holds
    /// `escapeLadder`, which would then hold the closure, which holds the struct, which holds
    /// `escapeLadder` again -- and (b) risk acting on a stale `@State` box if SwiftUI ever
    /// recycles the row (these cards live in a `LazyVStack` inside `AnnotationPanel`'s
    /// `ScrollView`). Capturing this model instead has neither problem: it never references
    /// `escapeLadder`, and it's the same object for this annotation regardless of which View
    /// struct instance is currently rendering it.
    var isEditing = false
    /// Scratch buffer for the in-progress edit, separate from `text` until `commitEdit()`
    /// saves it. Lives alongside `isEditing` for the same reason.
    var editText = ""

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

    /// Update this view model in place from a re-fetched `Annotation`, preserving object
    /// identity so SwiftUI's per-row `@Observable` dependency tracking doesn't tear down and
    /// reinstall on every database tick (see `EditorViewState.mergeAnnotations`). Mirrors
    /// `init(from:)` fully -- unlike `SectionViewModel.apply`, there are no caller-patched
    /// placeholder fields here. Every assignment is equality-guarded because `@Observable`
    /// fires on any write, including one that writes back the same value.
    func apply(_ annotation: Annotation) {
        if contentId != annotation.contentId { contentId = annotation.contentId }
        if sectionId != annotation.sectionId { sectionId = annotation.sectionId }
        if type != annotation.type { type = annotation.type }
        if text != annotation.text { text = annotation.text }
        if isCompleted != annotation.isCompleted { isCompleted = annotation.isCompleted }
        if charOffset != annotation.charOffset { charOffset = annotation.charOffset }
        if highlightStart != annotation.highlightStart { highlightStart = annotation.highlightStart }
        if highlightEnd != annotation.highlightEnd { highlightEnd = annotation.highlightEnd }
    }

    /// Whether this annotation applies to the document as a whole
    var isDocumentLevel: Bool { charOffset < 0 }

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
