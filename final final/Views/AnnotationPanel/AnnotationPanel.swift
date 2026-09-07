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

    /// Drives `idealWidth` below -- seeded from the persisted width (or the shared default,
    /// see `AnnotationPanelWidth`), then kept in sync with genuine user drag-resizes by
    /// `widthObserver`, and driven through the show/hide animation by `animateToggle`.
    @State private var panelWidth: CGFloat = AnnotationPanelWidth.load(from: .standard)

    /// True only while the show/hide width animation (`.panelToggle`) is in flight. Gates
    /// `widthObserver`'s write-back (must-fix 1): without this, the animation's own pass
    /// through every width between the stored value and zero would each get sampled by the
    /// GeometryReader below and persisted as if the user had dragged there, permanently
    /// corrupting the saved width (down to 0, the worst case) the moment anyone toggles the
    /// panel. Also temporarily relaxes `minWidth` to 0 in `.frame(...)` below so the animation
    /// can actually reach zero -- the panel's real drag-resize floor stays `minWidth` from
    /// `AnnotationPanelWidth` (must-fix 2) whenever this is false.
    @State private var isAnimatingToggle = false

    /// Identifies the most recently started toggle animation, so a stale completion callback
    /// from an EARLIER toggle (rapid show/hide/show clicks) can't clear `isAnimatingToggle`
    /// while a NEWER toggle's animation is still actually in flight.
    @State private var toggleAnimationToken = UUID()

    /// Debounces `widthObserver`'s UserDefaults write during a live divider drag (should-fix
    /// 6, review round 2): `geo.size.width` changes on every frame while the mouse moves, and
    /// without this, every one of those frames was a separate UserDefaults write. The width
    /// used for layout (`panelWidth`) still updates synchronously on every frame; only the
    /// persistence is coalesced until the drag pauses.
    @State private var widthSaveTask: Task<Void, Never>?

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
        .frame(
            // Floors at AnnotationPanelWidth.minWidth ONLY in the steady visible state (real
            // drag-resize needs that floor, must-fix 2). Both while animating AND in the
            // steady HIDDEN state, the floor must be 0 -- if it snapped back to minWidth the
            // instant a close animation's completion callback clears isAnimatingToggle, the
            // panel would immediately re-expand to 200pt right after finishing its collapse
            // to 0, since idealWidth (0) would then be fighting a 200pt floor every frame.
            minWidth: (editorState.isAnnotationPanelVisible && !isAnimatingToggle) ? AnnotationPanelWidth.minWidth : 0,
            idealWidth: panelWidth,
            // Ceiling pinned to 0 in the steady HIDDEN state (review round 2, must-fix 1):
            // previously this stayed at AnnotationPanelWidth.maxWidth (320) even while hidden,
            // so the "hidden" panel was really just a 0-width panel whose HSplitView divider
            // still had 320pt of slack to be dragged into -- exactly the parity violation the
            // task exists to prevent, since a resulting drag-open never updated
            // isAnnotationPanelVisible. Pinning min AND max to 0 together gives the pane a
            // fixed 0pt size while hidden, so there is no slack left for the divider to move
            // through at all. Relaxed back to the real ceiling whenever visible OR animating
            // (both directions need room for `panelWidth` to travel between 0 and the real
            // width), matching the floor's own animating-relaxation above.
            maxWidth: (editorState.isAnnotationPanelVisible || isAnimatingToggle) ? AnnotationPanelWidth.maxWidth : 0
        )
        .clipped()
        .accessibilityHidden(!editorState.isAnnotationPanelVisible)
        .allowsHitTesting(editorState.isAnnotationPanelVisible)
        .background(themeManager.currentTheme.sidebarBackground)
        .background(widthObserver)
        .onAppear {
            // must-fix 2 (review round 2): `panelWidth` is seeded once, at construction, from
            // the persisted width -- but this view can be constructed while
            // isAnnotationPanelVisible is ALREADY false (e.g. a window rebuilt mid Focus Mode,
            // where EditorViewState+FocusMode.swift sets isAnnotationPanelVisible = false
            // before this view exists). Nothing fires an onChange for a property that was
            // already false at seed time, so without this the panel would render at its last
            // saved width (e.g. ~260pt) with only the (now pinned-to-0) max width silently
            // clipping it -- reconcile the state itself instead of relying on that side effect.
            if !editorState.isAnnotationPanelVisible {
                panelWidth = 0
            }
        }
        .onChange(of: editorState.isAnnotationPanelVisible) { _, newValue in
            animateToggle(becomingVisible: newValue)
        }
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

    /// Samples the panel's actual rendered width -- the only way to observe a divider drag,
    /// since HSplitView resizes the view's frame directly rather than through any SwiftUI
    /// binding this view owns. Persists that width so it survives a toggle and a relaunch
    /// (must-fix 2: drag-resize keeps working exactly as before).
    ///
    /// Gated to fire ONLY on a genuine user drag (must-fix 1): while `isAnimatingToggle` is
    /// true, every width the show/hide animation passes through -- including 0 -- would
    /// otherwise look identical to a drag and get persisted, which is worse than today's bug
    /// (today the width is simply never persisted; this would actively corrupt it to 0).
    private var widthObserver: some View {
        GeometryReader { geo in
            Color.clear
                .onChange(of: geo.size.width) { _, newWidth in
                    guard !isAnimatingToggle else { return }
                    guard editorState.isAnnotationPanelVisible else {
                        // Defense in depth for must-fix 1 (review round 2): the `.frame` above
                        // pins BOTH minWidth and maxWidth to exactly 0 in this steady hidden
                        // state, specifically so the HSplitView divider has no slack left to
                        // drag through -- that is the primary fix. This branch is the backstop
                        // in case some HSplitView edge case still lets the pane grow anyway: a
                        // meaningfully non-zero observed width while `isAnnotationPanelVisible`
                        // is false can only mean a genuine drag got through, and the one thing
                        // that must never happen is treating that drag as if it didn't occur
                        // (discarding it, as the write-back guard alone used to do) -- so make
                        // the visibility flag catch up to what the user actually did, the same
                        // way `withSidebarSync` (ViewNotificationModifiers.swift) already does
                        // for the Outline sidebar's own native-chevron drag.
                        guard newWidth > 1 else { return }
                        let clamped = AnnotationPanelWidth.clamp(newWidth)
                        panelWidth = clamped
                        AnnotationPanelWidth.save(clamped, to: .standard)
                        editorState.isAnnotationPanelVisible = true
                        return
                    }
                    guard newWidth > 0 else { return }
                    let clamped = AnnotationPanelWidth.clamp(newWidth)
                    panelWidth = clamped
                    // Debounced write-back (should-fix 6, review round 2): `panelWidth` above
                    // still updates synchronously every frame so the divider tracks the mouse
                    // with no lag; only the UserDefaults write is coalesced, since a live drag
                    // fires this onChange on every pixel of mouse movement and persisting on
                    // every one of those is needless disk I/O for a value nobody reads until
                    // the next launch or panel toggle.
                    widthSaveTask?.cancel()
                    widthSaveTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled else { return }
                        AnnotationPanelWidth.save(clamped, to: .standard)
                    }
                }
        }
    }

    /// Width-animation fallback for the Annotations panel's show/hide (plan step 4 /
    /// must-fix 1). HSplitView does not honor a SwiftUI insertion `.transition` on a
    /// conditionally-mounted child -- it snaps the arrangement instantly with no animation
    /// hook -- so this panel stays mounted at all times (see `ContentView+EditorPresentation
    /// .swift`'s `detailView`, which no longer conditions its inclusion on
    /// `isAnnotationPanelVisible`) and animates its OWN `idealWidth` down to, or up from, zero
    /// instead. `.panelToggle` (Theme/Animations.swift) approximates the AppKit divider
    /// animation the Outline sidebar gets for free from NavigationSplitView -- it is NOT
    /// shared code between the two panels; matching their look is a by-eye call, not a
    /// guarantee this animation curve provides on its own.
    private func animateToggle(becomingVisible: Bool) {
        isAnimatingToggle = true
        let token = UUID()
        toggleAnimationToken = token
        // `completion:` ties clearing isAnimatingToggle to the animation SwiftUI actually ran,
        // rather than a `DispatchQueue.main.asyncAfter` guess at its wall-clock duration
        // (should-fix 5, review round 2) -- under main-thread load the old timer could fire
        // before the animation had visually finished, re-opening the width-observer's
        // write-back guard mid-transition and persisting a wrong intermediate width.
        withAnimation(.panelToggle, completionCriteria: .logicallyComplete) {
            panelWidth = becomingVisible ? AnnotationPanelWidth.load(from: .standard) : 0
        } completion: {
            // A newer toggle (rapid show/hide/show) already superseded this one -- let ITS
            // own completion callback be the one that clears isAnimatingToggle.
            guard toggleAnimationToken == token else { return }
            isAnimatingToggle = false
            if becomingVisible {
                panelWidth = AnnotationPanelWidth.clamp(panelWidth)
            }
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
