//
//  HeadingZoomClickRouter.swift
//  final final
//
//  Pure decision logic for Cmd-click-a-heading-to-zoom (always-on editor
//  interaction -- no Focus Mode gate, no preference gate; the only gate is
//  `contentState == .idle`). Kept separate from ContentView so the branching
//  is unit-testable without spinning up the view hierarchy -- see
//  HeadingZoomClickRouterTests.swift.
//

enum HeadingZoomClickAction: Equatable {
    case zoomIn(id: String, mode: ZoomMode)
    case zoomOut
    case drop(reason: String)
}

/// Minimal per-section metadata `decide` needs -- deliberately NOT `SectionViewModel`
/// itself, so this file (and its tests) don't need to import/construct the full
/// view-model type. `ContentView+NotificationHandlers.swift` maps `editorState.sections`
/// into these at the call site.
struct HeadingZoomClickSectionInfo: Equatable {
    let id: String
    let isBibliography: Bool
    let isNotes: Bool
    let isPseudoSection: Bool
}

enum HeadingZoomClickRouter {
    /// Decides what a Cmd-click on a heading's `blockId` should do, given the
    /// current zoom/content state. `sections` is the known outline sections -- a
    /// block id not among them can't be zoomed into, and a bibliography/Notes
    /// section is always dropped: `zoomToSection` (EditorViewState+Zoom.swift)
    /// filters those managed sections' blocks out of the zoomed content, so
    /// zooming into one and later flushing would destroy it (mirrors the guard
    /// at OutlineSidebar.swift's onDoubleClick).
    static func decide(
        blockId: String,
        zoomedSectionId: String?,
        contentState: EditorContentState,
        sections: [HeadingZoomClickSectionInfo]
    ) -> HeadingZoomClickAction {
        if contentState != .idle {
            return .drop(reason: "content state is \(contentState), not idle")
        }
        if blockId.hasPrefix("temp-") {
            // Defense-in-depth only -- the JS side (heading-zoom-click-handler.ts)
            // already retries for 8s before ever sending a still-temporary id, so
            // reaching this branch means that retry didn't resolve it.
            return .drop(reason: "block id still temporary — JS retry did not resolve it")
        }
        if blockId == zoomedSectionId {
            return .zoomOut
        }
        guard let section = sections.first(where: { $0.id == blockId }) else {
            return .drop(reason: "no outline section for block id")
        }
        if section.isBibliography || section.isNotes {
            return .drop(reason: "managed section — zoom would destroy it")
        }
        return .zoomIn(id: blockId, mode: .full)
    }
}
