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
    @State private var isExpanded = false
    @State private var isTruncated = false
    @State private var constrainedTextHeight: CGFloat = 0
    @State private var fullTextHeight: CGFloat = 0
    @State private var isMoreHovered = false
    @FocusState private var isTextEditorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Card content — has card hover background
            HStack(alignment: .top, spacing: 8) {
                // Type marker / checkbox
                markerView

                // Content
                VStack(alignment: .leading, spacing: 2) {
                    if isEditing {
                        // Edit mode: TextEditor for multi-line support
                        VStack(alignment: .leading, spacing: 4) {
                            TextEditor(text: $editText)
                                .font(.system(size: TypeScale.annotationBody))
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
                        Text(annotation.text)
                            .font(.system(size: TypeScale.annotationBody))
                            .foregroundColor(textColor)
                            .lineLimit(isExpanded ? nil : 3)
                            .strikethrough(annotation.type == .task && annotation.isCompleted)
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.height
                            } action: { height in
                                constrainedTextHeight = height
                                updateTruncationState()
                            }
                            .background(
                                Text(annotation.text)
                                    .font(.system(size: TypeScale.annotationBody))
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .hidden()
                                    .onGeometryChange(for: CGFloat.self) { proxy in
                                        proxy.size.height
                                    } action: { height in
                                        fullTextHeight = height
                                        updateTruncationState()
                                    }
                            )

                        if annotation.hasHighlight {
                            Text("Has highlight")
                                .font(.system(size: TypeScale.annotationSmall))
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
            .onTapGesture(count: 2) {
                startEditing()
            }
            .onTapGesture {
                if !isEditing {
                    onTap()
                }
            }
            .onHover { hovering in
                isHovering = hovering
            }

            // More/less row — separate from card hover, full-width hit target
            if isTruncated || isExpanded {
                moreButton
            }
        }
        .onChange(of: annotation.text) { _, _ in
            isExpanded = false
        }
    }

    // MARK: - More/Less Button

    private var moreButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.toggle()
            }
        } label: {
            HStack {
                Spacer()
                HStack(spacing: 3) {
                    Text(isExpanded ? "less" : "more")
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                }
                .font(.system(size: TypeScale.annotationSmall, weight: .medium))
                .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.5))
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isMoreHovered
            ? themeManager.currentTheme.sidebarText.opacity(0.06)
            : Color.clear)
        .onHover { isMoreHovered = $0 }
    }

    // MARK: - Truncation Detection

    private func updateTruncationState() {
        // Don't re-evaluate when expanded — we already know it's truncatable
        guard !isExpanded else { return }
        let truncated = constrainedTextHeight > 0
            && fullTextHeight > 0
            && fullTextHeight > constrainedTextHeight + 1
        if truncated != isTruncated {
            isTruncated = truncated
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
                    .font(.system(size: TypeScale.annotationMarker))
                    .foregroundColor(markerColor)
            }
            .buttonStyle(.plain)
            .help(annotation.isCompleted ? "Mark as incomplete" : "Mark as complete")
        } else {
            // Static marker for comments/references
            Text(annotation.marker)
                .font(.system(size: TypeScale.annotationMarker))
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
        text: "I'm not sure about this phrasing - revisit later. The argument needs more supporting evidence and the transition from the previous paragraph feels abrupt. Consider restructuring.",
        charOffset: 300,
        highlightStart: 280,
        highlightEnd: 300
    ))

    let reference = AnnotationViewModel(from: Annotation(
        contentId: "test",
        type: .reference,
        text: "Smith et al. (2023) found that participants showed a 15% improvement in recall when using spaced repetition techniques combined with adequate rest periods between study sessions.",
        charOffset: 400
    ))

    VStack(spacing: 0) {
        AnnotationCardView(
            annotation: taskAnnotation,
            onTap: { print("Tapped task") },
            onToggleCompletion: { print("Toggle task") },
            onUpdateText: { annotation, newText in print("Update \(annotation.id): \(newText)") }
        )

        Divider().padding(.leading, 30)

        AnnotationCardView(
            annotation: completedTask,
            onTap: { print("Tapped completed") },
            onToggleCompletion: { print("Toggle completed") },
            onUpdateText: nil
        )

        Divider().padding(.leading, 30)

        AnnotationCardView(
            annotation: comment,
            onTap: { print("Tapped comment") },
            onToggleCompletion: {},
            onUpdateText: { annotation, newText in print("Update \(annotation.id): \(newText)") }
        )

        Divider().padding(.leading, 30)

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
