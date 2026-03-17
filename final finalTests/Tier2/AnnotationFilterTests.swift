//
//  AnnotationFilterTests.swift
//  final finalTests
//
//  Tier 2: Visible Breakage
//  Tests for EditorViewState annotation filtering: type filters,
//  hide completed tasks, displayAnnotations, incompleteTaskCount.
//

import Testing
import Foundation
@testable import final_final

@Suite("Annotation Filter — Tier 2: Visible Breakage")
struct AnnotationFilterTests {

    // MARK: - Helpers

    /// Creates test annotation view models with positive charOffset (inline, not document-level)
    @MainActor
    private func makeAnnotation(
        type: AnnotationType,
        text: String = "test",
        isCompleted: Bool = false,
        charOffset: Int = 10
    ) -> AnnotationViewModel {
        let annotation = Annotation(
            contentId: "test-content",
            type: type,
            text: text,
            isCompleted: isCompleted,
            charOffset: charOffset
        )
        return AnnotationViewModel(from: annotation)
    }

    // MARK: - Type Filters

    @Test("toggleAnnotationTypeFilter removes type from set, toggle again restores")
    @MainActor
    func toggleAnnotationTypeFilter() {
        let state = EditorViewState()

        #expect(state.annotationTypeFilters.contains(.task))

        state.toggleAnnotationTypeFilter(.task)
        #expect(!state.annotationTypeFilters.contains(.task))

        state.toggleAnnotationTypeFilter(.task)
        #expect(state.annotationTypeFilters.contains(.task))
    }

    @Test("All annotation types are initially in annotationTypeFilters")
    @MainActor
    func allTypesInitiallyPresent() {
        let state = EditorViewState()

        for type in AnnotationType.allCases {
            #expect(state.annotationTypeFilters.contains(type),
                    "\(type) should be in initial filter set")
        }
    }

    // MARK: - Display Annotations

    @Test("displayAnnotations with hideCompletedTasks excludes completed tasks")
    @MainActor
    func hideCompletedTasksFiltering() {
        let state = EditorViewState()
        state.annotations = [
            makeAnnotation(type: .task, text: "incomplete", isCompleted: false),
            makeAnnotation(type: .task, text: "completed", isCompleted: true, charOffset: 20),
            makeAnnotation(type: .comment, text: "a comment", charOffset: 30)
        ]

        // Without filter
        state.hideCompletedTasks = false
        #expect(state.displayAnnotations.count == 3)

        // With filter
        state.hideCompletedTasks = true
        let filtered = state.displayAnnotations
        #expect(filtered.count == 2)
        #expect(!filtered.contains { $0.text == "completed" })
    }

    @Test("Filter with empty type set → empty displayAnnotations")
    @MainActor
    func emptyTypeSetEmptyDisplay() {
        let state = EditorViewState()
        state.annotations = [
            makeAnnotation(type: .task),
            makeAnnotation(type: .comment, charOffset: 20),
            makeAnnotation(type: .reference, charOffset: 30)
        ]

        // Remove all types
        state.annotationTypeFilters = []

        #expect(state.displayAnnotations.isEmpty)
    }

    // MARK: - Incomplete Task Count

    @Test("incompleteTaskCount counts only non-completed task annotations")
    @MainActor
    func incompleteTaskCount() {
        let state = EditorViewState()
        state.annotations = [
            makeAnnotation(type: .task, text: "todo 1", isCompleted: false),
            makeAnnotation(type: .task, text: "todo 2", isCompleted: false, charOffset: 20),
            makeAnnotation(type: .task, text: "done", isCompleted: true, charOffset: 30),
            makeAnnotation(type: .comment, text: "comment", charOffset: 40)
        ]

        #expect(state.incompleteTaskCount == 2)
    }

    // MARK: - Document-Level vs Inline

    @Test("Document-level annotations (charOffset < 0) excluded from displayAnnotations")
    @MainActor
    func documentLevelExcludedFromInline() {
        let state = EditorViewState()
        state.annotations = [
            makeAnnotation(type: .task, charOffset: 10),           // inline
            makeAnnotation(type: .comment, charOffset: -1),        // document-level
            makeAnnotation(type: .reference, charOffset: 20)       // inline
        ]

        let inline = state.displayAnnotations
        #expect(inline.count == 2)
        #expect(!inline.contains { $0.charOffset < 0 })

        let docLevel = state.displayDocumentAnnotations
        #expect(docLevel.count == 1)
        #expect(docLevel.first?.type == .comment)
    }
}
