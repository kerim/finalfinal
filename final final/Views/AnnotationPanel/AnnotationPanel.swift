//
//  AnnotationPanel.swift
//  final final
//

import SwiftUI

/// Main annotation panel view with filter bar and grouped annotation list
struct AnnotationPanel: View {
    @Bindable var editorState: EditorViewState
    let onScrollToAnnotation: (Int) -> Void
    let onToggleCompletion: (AnnotationViewModel) -> Void
    let onUpdateAnnotationText: ((AnnotationViewModel, String) -> Void)?

    @Environment(ThemeManager.self) private var themeManager
    @State private var expandedTypes: Set<AnnotationType> = Set(AnnotationType.allCases)

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
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(themeManager.currentTheme.sidebarText)

            Spacer()

            // Task count badge
            if editorState.incompleteTaskCount > 0 {
                Text("\(editorState.incompleteTaskCount)")
                    .font(.system(size: TypeScale.smallUI, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(themeManager.currentTheme.statusColors.next)
                    .cornerRadius(8)
            }

            // Close button
            Button {
                editorState.toggleAnnotationPanel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: TypeScale.smallUI, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Close panel")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()

            Text("No annotations")
                .font(.system(size: 12))
                .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.5))

            Text("Use /task, /comment, or /reference\nto add annotations")
                .font(.system(size: 11))
                .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.4))
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding()
    }

    private var annotationList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach([AnnotationType.task, .comment, .reference], id: \.self) { type in
                    annotationSection(for: type)
                }
            }
        }
    }

    @ViewBuilder
    private func annotationSection(for type: AnnotationType) -> some View {
        let annotations = annotationsForType(type)

        if !annotations.isEmpty && editorState.annotationTypeFilters.contains(type) {
            SwiftUI.Section {
                if expandedTypes.contains(type) {
                    ForEach(annotations) { annotation in
                        AnnotationCardView(
                            annotation: annotation,
                            onTap: {
                                onScrollToAnnotation(annotation.charOffset)
                            },
                            onToggleCompletion: {
                                onToggleCompletion(annotation)
                            },
                            onUpdateText: onUpdateAnnotationText
                        )

                        if annotation.id != annotations.last?.id {
                            Divider()
                                .padding(.leading, 30)
                        }
                    }
                }
            } header: {
                AnnotationGroupHeader(
                    type: type,
                    count: annotations.count,
                    isExpanded: expandedTypes.contains(type),
                    onToggle: {
                        toggleExpanded(type)
                    }
                )
            }
        }
    }

    private func annotationsForType(_ type: AnnotationType) -> [AnnotationViewModel] {
        editorState.displayAnnotations.filter { $0.type == type }
    }

    private func toggleExpanded(_ type: AnnotationType) {
        if expandedTypes.contains(type) {
            expandedTypes.remove(type)
        } else {
            expandedTypes.insert(type)
        }
    }
}

#Preview {
    let editorState = EditorViewState()

    // Add sample annotations
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
            type: .task,
            text: "Fact-checked",
            isCompleted: true,
            charOffset: 200
        )),
        AnnotationViewModel(from: Annotation(
            contentId: "test",
            type: .comment,
            text: "Revisit this phrasing later",
            charOffset: 300
        )),
        AnnotationViewModel(from: Annotation(
            contentId: "test",
            type: .reference,
            text: "Smith et al. (2023) study on memory",
            charOffset: 400
        ))
    ]

    return AnnotationPanel(
        editorState: editorState,
        onScrollToAnnotation: { offset in print("Scroll to \(offset)") },
        onToggleCompletion: { annotation in print("Toggle \(annotation.id)") },
        onUpdateAnnotationText: { annotation, newText in print("Update \(annotation.id): \(newText)") }
    )
    .frame(height: 400)
    .environment(ThemeManager.shared)
}
