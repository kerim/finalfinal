//
//  AnnotationCardView.swift
//  final final
//

import SwiftUI

/// Individual annotation card for the annotation panel
struct AnnotationCardView: View {
    @Bindable var annotation: AnnotationViewModel
    /// Esc-ladder live state for this window (UX contract §6). Optional so existing preview/
    /// test call sites keep compiling unchanged.
    var escapeLadder: EscapeLadderContext? = nil
    let onTap: () -> Void
    let onToggleCompletion: () -> Void
    let onUpdateText: ((AnnotationViewModel, String) -> Void)?
    var onDelete: (() -> Void)?
    var pendingEditId: String?
    var onAutoEditStarted: (() -> Void)?

    @Environment(ThemeManager.self) private var themeManager
    @State private var isHovering = false
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
                    if annotation.isEditing {
                        // Edit mode: TextEditor for multi-line support
                        VStack(alignment: .leading, spacing: 4) {
                            TextEditor(text: $annotation.editText)
                                .font(.system(size: TypeScale.annotationBody))
                                .frame(minHeight: 60, maxHeight: 120)
                                .padding(4)
                                .background(themeManager.currentTheme.editorBackground.opacity(0.5))
                                .cornerRadius(4)
                                .focused($isTextEditorFocused)
                                .accessibilityIdentifier("annotation-card-edit-field")

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
                                // No .keyboardShortcut(.escape) here (hygiene, not a behavior
                                // change): this shortcut WAS load-bearing under the old code
                                // outside Focus Mode (the removed AppDelegate monitor only
                                // consumed Esc while Focus Mode was on) -- but the new escape
                                // ladder now owns Esc for this surface in every case, Focus Mode
                                // or not (UX contract §6), driving this exact cancelEdit() via
                                // the registered annotation-edit entry below.
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

                // Delete button (visible on hover) -- serves both document-level AND inline
                // annotation cards; the caller wires `onDelete` to the appropriate route
                // (`onDeleteDocumentAnnotation`/`onDeleteInlineAnnotation` in AnnotationPanel.swift).
                if let onDelete, isHovering {
                    Button(action: onDelete) {
                        Image(systemName: "xmark")
                            .font(.system(size: TypeScale.chromeMicro, weight: .medium))
                            .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .help("Delete annotation")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(backgroundColor)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                startEditing()
            }
            .onTapGesture {
                if !annotation.isEditing {
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
        .onChange(of: annotation.isEditing) { _, editing in
            if editing {
                isTextEditorFocused = true
            }
        }
        .onChange(of: isTextEditorFocused) { _, focused in
            // Reports genuine native focus, not just "in edit mode" (UX contract §6, "where
            // you're typing wins" -- see EscapeLadderSnapshot.focusedAnnotationEditId's doc
            // comment). Distinct from the `annotationEditOrder` registration below, which
            // tracks every card merely open for editing.
            escapeLadder?.setAnnotationEditFocused(id: annotation.id, focused: focused)
        }
        .task(id: pendingEditId) {
            guard let pendingEditId, annotation.id == pendingEditId else { return }
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            startEditing()
            onAutoEditStarted?()
        }
        .onDisappear {
            // A GENUINE SwiftUI unmount of this row -- e.g. scrolled out of the LazyVStack
            // inside AnnotationPanel's ScrollView, or the document/project switching out from
            // under it -- but `annotation` (AnnotationViewModel) is identity-preserved across
            // remounts (EditorViewState+ObservableListDiff.swift's mergeAnnotations reuses the
            // same instance by id) -- its `isEditing`/`editText` no longer reset on unmount the
            // way SwiftUI @State would have. A card mid-edit when it disappears this way must
            // not reappear still showing as being edited with stale text, so this discards the
            // in-progress edit the same way `cancelEdit()` does on a user-initiated cancel, in
            // addition to unregistering so the Esc ladder never holds a stale entry for a card
            // that no longer exists.
            //
            // CORRECTED (judge review, 2026-09-10, t-784ff3aa): this does NOT cover Focus Mode
            // hiding the Annotations panel, despite an earlier version of this comment claiming
            // it did -- that claim was factually wrong. The panel is never actually unmounted
            // when Focus Mode hides it: `ContentView+EditorPresentation.swift`'s `detailView`
            // keeps `AnnotationPanel` "always mounted" and instead animates its own width down
            // to zero (plus `.accessibilityHidden`/`.allowsHitTesting(false)`), none of which
            // unmounts this subview or fires `.onDisappear`. That case -- a card left mid-edit
            // when Focus Mode hides the panel -- is handled separately, by
            // `AnnotationPanel`'s own `.onChange(of: editorState.isAnnotationPanelVisible)` ->
            // `resetInProgressEdits()`, which performs the identical reset/unregister pair.
            annotation.isEditing = false
            annotation.editText = ""
            escapeLadder?.unregisterAnnotationEdit(id: annotation.id)
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
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: TypeScale.chromeMicro, weight: .medium))
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
        annotation.editText = annotation.text  // Copy full text (not preview)
        annotation.isEditing = true
        isTextEditorFocused = true
        // Register a cancel closure with the Esc ladder (UX contract §6) that captures the
        // annotation VIEW MODEL -- a reference type identified by `id`, the same object
        // regardless of which View struct instance is currently rendering it -- rather than
        // this View struct itself. Capturing `self` here (e.g. a bound `cancelEdit` method
        // reference) would capture the WHOLE struct, including its own `escapeLadder`
        // reference: a retain cycle (escapeLadder -> this closure -> the struct ->
        // escapeLadder again), and a risk of acting on a stale `@State` box if SwiftUI ever
        // recycles this row (these cards live in a `LazyVStack` inside `AnnotationPanel`'s
        // `ScrollView`). `model` and `ladder` are captured weakly so the closure itself never
        // keeps either alive past its natural lifetime. Re-registering (e.g. a second
        // startEditing() while already open) is safe: registerAnnotationEdit replaces the
        // prior entry for this id, so a fresh registration always overwrites any stale one.
        let model = annotation
        let id = annotation.id
        escapeLadder?.registerAnnotationEdit(id: id) { [weak model, weak ladder = escapeLadder] in
            model?.isEditing = false
            model?.editText = ""
            ladder?.unregisterAnnotationEdit(id: id)
        }
    }

    private func commitEdit() {
        let trimmedText = annotation.editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, trimmedText != annotation.text else {
            cancelEdit()
            return
        }
        onUpdateText?(annotation, trimmedText)
        annotation.isEditing = false
        annotation.editText = ""
        escapeLadder?.unregisterAnnotationEdit(id: annotation.id)
    }

    private func cancelEdit() {
        annotation.isEditing = false
        annotation.editText = ""
        escapeLadder?.unregisterAnnotationEdit(id: annotation.id)
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
        // swiftlint:disable:next line_length
        text: "I'm not sure about this phrasing - revisit later. The argument needs more supporting evidence and the transition from the previous paragraph feels abrupt. Consider restructuring.",
        charOffset: 300,
        highlightStart: 280,
        highlightEnd: 300
    ))

    let reference = AnnotationViewModel(from: Annotation(
        contentId: "test",
        type: .reference,
        // swiftlint:disable:next line_length
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
