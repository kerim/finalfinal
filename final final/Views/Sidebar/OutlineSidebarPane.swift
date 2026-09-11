//
//  OutlineSidebarPane.swift
//  final final
//

import SwiftUI

/// Wraps the Outline sidebar (zoom breadcrumb + `OutlineSidebar` itself) in its own view so its
/// body only re-evaluates when something it actually reads changes -- not on every
/// `ContentView.body` pass (bt t-fecee361). `ContentView.body` previously built `OutlineSidebar`
/// inline inside `sidebarView`, which meant every property that construction read
/// (`editorState.sections`, `.zoomedSection`, `.currentSectionId`, the whole
/// `OutlineSidebarRenderKey`, etc.) was a dependency of `ContentView.body` itself.
/// `OutlineSidebar`'s own `.equatable()` protects `OutlineSidebar.body` from re-running on an
/// unchanged reconstruction, but does nothing for `ContentView.body`, which had already paid the
/// cost of re-evaluating and re-reading those `@Observable` properties before `.equatable()` ever
/// got a look -- every keystroke that moved the caret's section touched `currentSectionId`,
/// which `@Observable` treats as a dependency the instant it's read here, regardless of whether
/// the value actually changed.
///
/// **Invariant, compiler-enforced: a read added to this initializer as anything but a closure
/// defeats this extraction.** The only non-closure parameter is `editorState` -- the object
/// itself, nothing else (no `sections:`, no `currentSectionId:`, no theme param). Adding a
/// dedicated initializer parameter for any of those would make ITS read happen back in
/// `ContentView.sidebarView` at construction time, reintroducing the exact per-keystroke coupling
/// this file exists to remove. `ThemeManager` comes from `@Environment` here (already injected
/// app-wide via `.environment(ThemeManager.shared)` in `FinalFinalApp.swift`; `StatusBar.swift`
/// does the identical lookup), not a parameter, for the same reason.
struct OutlineSidebarPane: View {
    @Bindable var editorState: EditorViewState

    let onScrollToSection: (String) -> Void
    let onSectionUpdated: (SectionViewModel) -> Void
    let onSectionReorder: (SectionReorderRequest) -> Void
    let onZoomToSection: (String, ZoomMode) -> Void
    let onZoomOutFromSidebar: () -> Void
    let onZoomOutFromBreadcrumb: () -> Void
    let onDragStarted: () -> Void
    let onDragEnded: () -> Void
    let onDuplicateSection: (String) -> Void
    let onDeleteSection: (String) -> Void

    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        VStack(spacing: 0) {
            // Zoom breadcrumb when zoomed into a section
            if let zoomedSection = editorState.zoomedSection {
                ZoomBreadcrumb(
                    zoomedSection: zoomedSection,
                    onZoomOut: onZoomOutFromBreadcrumb
                )
                Divider()
            }

            OutlineSidebar(
                sections: $editorState.sections,
                statusFilter: $editorState.statusFilter,
                headerLevelFilter: $editorState.headerLevelFilter,
                zoomedSectionId: $editorState.zoomedSectionId,
                zoomedSectionIds: editorState.zoomedSectionIds,
                // Built fresh each body pass, by VALUE (not through the `$`-prefixed bindings
                // above) -- see `OutlineSidebarRenderKey`'s doc comment
                // (OutlineSidebar+Models.swift) for exactly why this exists: it's what lets
                // `OutlineSidebar`'s `.equatable()` below tell a keystroke that changed none of
                // these render-relevant values apart from one that did, instead of forcing
                // `OutlineSidebar.body` to re-run on every reconstruction regardless (bt
                // t-ef411da3).
                renderKey: OutlineSidebarRenderKey(
                    sections: editorState.sections,
                    statusFilter: editorState.statusFilter,
                    headerLevelFilter: editorState.headerLevelFilter,
                    zoomedSectionId: editorState.zoomedSectionId,
                    documentGoal: editorState.documentGoal,
                    documentGoalType: editorState.documentGoalType,
                    excludeBibliography: editorState.excludeBibliography
                ),
                documentGoal: $editorState.documentGoal,
                documentGoalType: $editorState.documentGoalType,
                excludeBibliography: $editorState.excludeBibliography,
                onScrollToSection: onScrollToSection,
                onSectionUpdated: onSectionUpdated,
                onSectionReorder: onSectionReorder,
                currentSectionId: editorState.currentSectionId,
                onZoomToSection: onZoomToSection,
                onZoomOut: onZoomOutFromSidebar,
                onDragStarted: onDragStarted,
                onDragEnded: onDragEnded,
                sectionDropInFlight: $editorState.sectionDropInFlight,
                onDuplicateSection: onDuplicateSection,
                onDeleteSection: onDeleteSection
            )
            // The actual root-cause fix for bt t-ef411da3: `sidebarView` reconstructs
            // `OutlineSidebar` fresh on every `ContentView.body` pass (every keystroke), and
            // without `.equatable()` here SwiftUI has no way to distinguish that reconstruction
            // from a genuine content change -- `OutlineSidebar.body` re-ran unconditionally.
            // Paired with `OutlineSidebar: Equatable` (OutlineSidebar+Models.swift), this lets
            // SwiftUI skip re-invoking `OutlineSidebar.body` when `renderKey` and the other
            // compared fields are unchanged. Must stay directly on `OutlineSidebar` itself, not
            // on the enclosing `VStack` -- `.equatable()` compares the view value it's attached
            // to, not its container.
            .equatable()
        }
        .frame(minWidth: 250)
        .background(themeManager.currentTheme.sidebarBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("outline-sidebar")
    }
}
