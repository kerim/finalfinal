//
//  AnnotationPanel.swift
//  final final
//

import SwiftUI

/// Main annotation panel view with filter bar and grouped annotation list
struct AnnotationPanel: View {
    @Bindable var editorState: EditorViewState
    let onScrollToAnnotation: (Int, Int) -> Void  // (annotationIndex, charOffset)
    let onToggleCompletion: (AnnotationViewModel) -> Void
    let onUpdateAnnotationText: ((AnnotationViewModel, String) -> Void)?

    @Environment(ThemeManager.self) private var themeManager
    var body: some View {
        VStack(spacing: 0) {
            // Header
            panelHeader

            Divider()

            // Filter bar
            AnnotationFilterBar(
                typeFilters: $editorState.annotationTypeFilters,
                displayModes: $editorState.annotationDisplayModes,
                isPanelOnlyMode: $editorState.isPanelOnlyMode,
                hideCompletedTasks: $editorState.hideCompletedTasks
            )

            Divider()

            // Annotation list
            if editorState.displayAnnotations.isEmpty {
                emptyState
            } else {
                annotationList
            }
        }
        .frame(minWidth: 200, idealWidth: 260, maxWidth: 320)
        .background(themeManager.currentTheme.sidebarBackground)
    }

    private var panelHeader: some View {
        HStack {
            Text("Annotations")
                .font(.system(size: TypeScale.annotationBody, weight: .semibold))
                .foregroundStyle(themeManager.currentTheme.sidebarText)

            Spacer()

            // Task count badge
            if editorState.incompleteTaskCount > 0 {
                Text("\(editorState.incompleteTaskCount)")
                    .font(.system(size: TypeScale.annotationSmall, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(themeManager.currentTheme.statusColors.next)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()

            Text("No annotations")
                .font(.system(size: TypeScale.annotationBody))
                .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.5))

            Text("Use /task, /comment, or /reference\nto add annotations")
                .font(.system(size: TypeScale.annotationSmall))
                .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.4))
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding()
    }

    private var annotationList: some View {
        let annotations = editorState.displayAnnotations
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(annotations) { annotation in
                    AnnotationCardView(
                        annotation: annotation,
                        onTap: {
                            if let index = editorState.annotations.firstIndex(where: { $0.id == annotation.id }) {
                                onScrollToAnnotation(index, annotation.charOffset)
                            }
                        },
                        onToggleCompletion: {
                            onToggleCompletion(annotation)
                        },
                        onUpdateText: onUpdateAnnotationText
                    )
                    if annotation.id != annotations.last?.id {
                        Divider().padding(.leading, 30)
                    }
                }
            }
        }
    }
}

#Preview {
    let editorState = EditorViewState()

    // Add sample annotations in document order (mixed types)
    editorState.annotations = [
        AnnotationViewModel(from: Annotation(
            contentId: "test",
            type: .task,
            text: "Add citation needed",
            isCompleted: false,
            charOffset: 100
        )),
        AnnotationViewModel(from: Annotation(
            contentId: "test",
            type: .comment,
            text: "Revisit this phrasing later",
            charOffset: 150
        )),
        AnnotationViewModel(from: Annotation(
            contentId: "test",
            type: .task,
            text: "Fact-checked",
            isCompleted: true,
            charOffset: 200
        )),
        AnnotationViewModel(from: Annotation(
            contentId: "test",
            type: .reference,
            text: "Smith et al. (2023) study on memory consolidation during sleep found that participants showed a 15% improvement in recall when using spaced repetition techniques combined with adequate rest periods",
            charOffset: 400
        ))
    ]

    return AnnotationPanel(
        editorState: editorState,
        onScrollToAnnotation: { index, charOffset in print("Scroll to index \(index) offset \(charOffset)") },
        onToggleCompletion: { annotation in print("Toggle \(annotation.id)") },
        onUpdateAnnotationText: { annotation, newText in print("Update \(annotation.id): \(newText)") }
    )
    .frame(height: 400)
    .environment(ThemeManager.shared)
}
