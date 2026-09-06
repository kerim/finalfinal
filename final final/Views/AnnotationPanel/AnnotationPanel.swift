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
    let onCreateDocumentAnnotation: ((AnnotationType) -> Void)?
    let onDeleteDocumentAnnotation: ((String) -> Void)?

    @Environment(ThemeManager.self) private var themeManager
    @State private var showDeleteConfirmation: String?  // annotation ID to delete

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

            // Annotation list (document-level + inline)
            if editorState.displayAnnotations.isEmpty && editorState.displayDocumentAnnotations.isEmpty {
                emptyState
            } else {
                annotationList
            }
        }
        .frame(minWidth: 200, idealWidth: 260, maxWidth: 320)
        .background(themeManager.currentTheme.sidebarBackground)
        .alert("Delete Annotation", isPresented: Binding(
            get: { showDeleteConfirmation != nil },
            set: { if !$0 { showDeleteConfirmation = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let id = showDeleteConfirmation {
                    onDeleteDocumentAnnotation?(id)
                }
                showDeleteConfirmation = nil
            }
            Button("Cancel", role: .cancel) {
                showDeleteConfirmation = nil
            }
        } message: {
            Text("This document note will be permanently deleted. This action cannot be undone.")
        }
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

            Text("Use /task, /comment, or /reference\nto add inline annotations,\nor use the + button for document notes")
                .font(.system(size: TypeScale.annotationSmall))
                .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.4))
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding()
    }

    private var annotationList: some View {
        let inlineAnnotations = editorState.displayAnnotations
        let docAnnotations = editorState.displayDocumentAnnotations
        return ScrollView {
            LazyVStack(spacing: 0) {
                // Document Notes section
                if !docAnnotations.isEmpty || !editorState.isDocumentNotesCollapsed {
                    documentNotesSection(docAnnotations)
                }

                // Inline Notes header (when both sections have content)
                if !docAnnotations.isEmpty || !editorState.isDocumentNotesCollapsed,
                   !inlineAnnotations.isEmpty {
                    Text("Inline Notes")
                        .font(.system(size: TypeScale.annotationSmall, weight: .medium))
                        .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }

                // Inline annotations
                ForEach(inlineAnnotations) { annotation in
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
                    if annotation.id != inlineAnnotations.last?.id {
                        Divider().padding(.leading, 30)
                    }
                }
            }
        }
    }

    // MARK: - Document Notes Section

    @ViewBuilder
    private func documentNotesSection(_ docAnnotations: [AnnotationViewModel]) -> some View {
        // Section header
        HStack(spacing: 4) {
            // Chevron button (left-aligned)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    editorState.isDocumentNotesCollapsed.toggle()
                }
            } label: {
                Image(systemName: editorState.isDocumentNotesCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.6))
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Document Notes")
                .font(.system(size: TypeScale.annotationSmall, weight: .medium))
                .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.6))

            Spacer()

            // "+" button with type picker
            Menu {
                Button("Task") { onCreateDocumentAnnotation?(.task) }
                Button("Comment") { onCreateDocumentAnnotation?(.comment) }
                Button("Reference") { onCreateDocumentAnnotation?(.reference) }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.5))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)

        // Document annotation cards (when expanded)
        if !editorState.isDocumentNotesCollapsed {
            ForEach(docAnnotations) { annotation in
                AnnotationCardView(
                    annotation: annotation,
                    onTap: { /* No-op for document-level annotations */ },
                    onToggleCompletion: {
                        onToggleCompletion(annotation)
                    },
                    onUpdateText: onUpdateAnnotationText,
                    onDelete: {
                        showDeleteConfirmation = annotation.id
                    },
                    pendingEditId: editorState.pendingEditAnnotationId,
                    onAutoEditStarted: {
                        editorState.pendingEditAnnotationId = nil
                    }
                )
                if annotation.id != docAnnotations.last?.id {
                    Divider().padding(.leading, 30)
                }
            }
        }

        Divider()
    }
}

#Preview {
    let editorState = EditorViewState()

    // Add sample annotations in document order (mixed types)
    editorState.annotations = [
        // Document-level annotations
        AnnotationViewModel(from: Annotation(
            contentId: "test",
            type: .task,
            text: "Needs peer review",
            isCompleted: false,
            charOffset: Annotation.documentLevelOffset
        )),
        AnnotationViewModel(from: Annotation(
            contentId: "test",
            type: .comment,
            text: "Check with editor",
            charOffset: Annotation.documentLevelOffset
        )),
        // Inline annotations
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
            // swiftlint:disable:next line_length
            text: "Smith et al. (2023) study on memory consolidation during sleep found that participants showed a 15% improvement in recall when using spaced repetition techniques combined with adequate rest periods",
            charOffset: 400
        ))
    ]

    return AnnotationPanel(
        editorState: editorState,
        onScrollToAnnotation: { index, charOffset in print("Scroll to index \(index) offset \(charOffset)") },
        onToggleCompletion: { annotation in print("Toggle \(annotation.id)") },
        onUpdateAnnotationText: { annotation, newText in print("Update \(annotation.id): \(newText)") },
        onCreateDocumentAnnotation: { type in print("Create document annotation: \(type)") },
        onDeleteDocumentAnnotation: { id in print("Delete document annotation: \(id)") }
    )
    .frame(height: 400)
    .environment(ThemeManager.shared)
}
