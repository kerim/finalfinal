//
//  AnnotationCardView.swift
//  final final
//

import SwiftUI

/// Individual annotation card for the annotation panel
struct AnnotationCardView: View {
    @Bindable var annotation: AnnotationViewModel
    let onTap: () -> Void
    let onToggleCompletion: () -> Void
    let onUpdateText: ((AnnotationViewModel, String) -> Void)?

    @Environment(ThemeManager.self) private var themeManager
    @State private var isHovering = false
    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var isTextEditorFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Type marker / checkbox
            markerView

            // Content
            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    // Edit mode: TextEditor for multi-line support
                    VStack(alignment: .leading, spacing: 4) {
                        TextEditor(text: $editText)
                            .font(.system(size: 12))
                            .frame(minHeight: 60, maxHeight: 120)
                            .padding(4)
                            .background(themeManager.currentTheme.editorBackground.opacity(0.5))
                            .cornerRadius(4)
                            .focused($isTextEditorFocused)

                        HStack {
                            Button("Save") {
                                commitEdit()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .keyboardShortcut(.return, modifiers: .command)

                            Button("Cancel") {
                                cancelEdit()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .keyboardShortcut(.escape, modifiers: [])
                        }
                    }
                } else {
                    // Display mode
                    Text(annotation.previewText)
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .lineLimit(2)
                        .strikethrough(annotation.type == .task && annotation.isCompleted)

                    if annotation.hasHighlight {
                        Text("Has highlight")
                            .font(.system(size: 10))
                            .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.5))
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(backgroundColor)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isEditing {
                onTap()
            }
        }
        .onTapGesture(count: 2) {
            startEditing()
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }

    // MARK: - Edit Mode

    private func startEditing() {
        guard onUpdateText != nil else { return }
        editText = annotation.text  // Copy full text (not preview)
        isEditing = true
        isTextEditorFocused = true
    }

    private func commitEdit() {
        let trimmedText = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, trimmedText != annotation.text else {
            cancelEdit()
            return
        }
        onUpdateText?(annotation, trimmedText)
        isEditing = false
        editText = ""
    }

    private func cancelEdit() {
        isEditing = false
        editText = ""
    }

    @ViewBuilder
    private var markerView: some View {
        if annotation.type == .task {
            // Clickable checkbox for tasks
            Button(action: onToggleCompletion) {
                Text(annotation.marker)
                    .font(.system(size: 14))
                    .foregroundColor(markerColor)
            }
            .buttonStyle(.plain)
            .help(annotation.isCompleted ? "Mark as incomplete" : "Mark as complete")
        } else {
            // Static marker for comments/references
            Text(annotation.marker)
                .font(.system(size: 14))
                .foregroundColor(markerColor)
        }
    }

    private var markerColor: Color {
        switch annotation.type {
        case .task:
            return annotation.isCompleted
                ? themeManager.currentTheme.statusColors.final_
                : themeManager.currentTheme.statusColors.next
        case .comment:
            return themeManager.currentTheme.statusColors.writing
        case .reference:
            return themeManager.currentTheme.statusColors.review
        }
    }

    private var textColor: Color {
        if annotation.type == .task && annotation.isCompleted {
            return themeManager.currentTheme.sidebarText.opacity(0.5)
        }
        return themeManager.currentTheme.sidebarText
    }

    private var backgroundColor: Color {
        if isHovering {
            return themeManager.currentTheme.sidebarSelectedBackground.opacity(0.5)
        }
        return .clear
    }
}

/// Grouped section header for annotations panel
struct AnnotationGroupHeader: View {
    let type: AnnotationType
    let count: Int
    let isExpanded: Bool
    let onToggle: () -> Void

    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        Button(action: onToggle) {
            HStack {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.6))
                    .frame(width: 12)

                Text(type.collapsedMarker)
                    .font(.system(size: 12))

                Text(type.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.sidebarText)

                Text("(\(count))")
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.6))

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(themeManager.currentTheme.sidebarBackground.opacity(0.5))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    let taskAnnotation = AnnotationViewModel(from: Annotation(
        contentId: "test",
        type: .task,
        text: "Add citation for this claim about cognitive load theory",
        isCompleted: false,
        charOffset: 100
    ))

    let completedTask = AnnotationViewModel(from: Annotation(
        contentId: "test",
        type: .task,
        text: "Fact-checked this statistic",
        isCompleted: true,
        charOffset: 200
    ))

    let comment = AnnotationViewModel(from: Annotation(
        contentId: "test",
        type: .comment,
        text: "I'm not sure about this phrasing - revisit later",
        charOffset: 300,
        highlightStart: 280,
        highlightEnd: 300
    ))

    let reference = AnnotationViewModel(from: Annotation(
        contentId: "test",
        type: .reference,
        text: "Smith et al. (2023) found that participants showed a 15% improvement in recall when using spaced repetition techniques.",
        charOffset: 400
    ))

    VStack(spacing: 0) {
        AnnotationGroupHeader(
            type: .task,
            count: 2,
            isExpanded: true,
            onToggle: {}
        )

        AnnotationCardView(
            annotation: taskAnnotation,
            onTap: { print("Tapped task") },
            onToggleCompletion: { print("Toggle task") },
            onUpdateText: { annotation, newText in print("Update \(annotation.id): \(newText)") }
        )

        Divider()

        AnnotationCardView(
            annotation: completedTask,
            onTap: { print("Tapped completed") },
            onToggleCompletion: { print("Toggle completed") },
            onUpdateText: nil
        )

        AnnotationGroupHeader(
            type: .comment,
            count: 1,
            isExpanded: true,
            onToggle: {}
        )

        AnnotationCardView(
            annotation: comment,
            onTap: { print("Tapped comment") },
            onToggleCompletion: {},
            onUpdateText: { annotation, newText in print("Update \(annotation.id): \(newText)") }
        )

        AnnotationGroupHeader(
            type: .reference,
            count: 1,
            isExpanded: true,
            onToggle: {}
        )

        AnnotationCardView(
            annotation: reference,
            onTap: { print("Tapped reference") },
            onToggleCompletion: {},
            onUpdateText: nil
        )
    }
    .frame(width: 280)
    .background(Color(nsColor: .windowBackgroundColor))
    .environment(ThemeManager.shared)
}
