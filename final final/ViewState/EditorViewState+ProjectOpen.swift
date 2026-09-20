//
//  EditorViewState+ProjectOpen.swift
//  final final
//
//  The steps of opening a project that decide what the editors show for the annotation display
//  settings, in ONE function that both ContentView and the unit tests call, so a test can no
//  longer drift from the app (the old tests re-assembled the steps by hand and stayed green with
//  the app's own wiring deleted).
//

import Foundation

extension EditorViewState {

    /// Which open this is.
    enum ProjectOpenKind {
        /// A window's first project (app launch, picker to editor, restore): nothing to reset.
        case launch
        /// Another project replacing the one on screen: everything project-specific is reset
        /// first.
        case projectSwitch
    }

    /// Delivers annotation display state (modes, Panel Only, Hide Completed) to the editors.
    typealias DisplayPublisher = @MainActor ([AnnotationType: AnnotationDisplayMode], Bool, Bool) -> Void

    /// Whether the open project has what `ContentView.configureForCurrentProject()` requires
    /// (database, id AND content id). Nothing is loaded or published for a project it would
    /// refuse to configure.
    static var openProjectIsConfigurable: Bool {
        let documentManager = DocumentManager.shared
        return documentManager.projectDatabase != nil
            && documentManager.projectId != nil
            && documentManager.contentId != nil
    }

    /// Open the current project's annotation display state, then hand the rest of the open to
    /// the view. The order is the point:
    ///
    /// 1. `.projectSwitch` only: reset everything project-specific (the annotation display
    ///    settings go back to the defaults, and the Focus Mode snapshot's captured fields are
    ///    cleared so the previous project's values can never be restored into this one).
    /// 2. Load the project's own saved settings and apply them; a project opened while Focus
    ///    Mode is on gets Focus Mode's inline override re-armed on top (capture only while a
    ///    snapshot field is nil, so this project's snapshot holds ITS values).
    /// 3. Cold relaunch into Focus Mode: re-enter it NOW, after the load, so the snapshot
    ///    captures the project's own values and the override applies before anything is
    ///    published -- the first thing the editors receive is already the overridden state.
    ///    (`reenterFocusModeIfRestored()` is a no-op unless Focus Mode is persisted on and no
    ///    snapshot exists yet, so ContentView's later call of it never captures a second time.)
    /// 4. Publish the state to the editors (`publish`).
    /// 5. `openProject`: what only the view can do -- configure services and start pushing the
    ///    new content into the editor. It is handed `publishAfterContent`, which it must call as
    ///    the LAST step of the content push (inside the push's own task, after its JS call has
    ///    returned) -- or at the end of its own work when there is no asynchronous push.
    ///
    ///    The sequence NEVER awaits the content push itself: the caller returns as soon as
    ///    `openProject` returns, exactly as before this sequence existed, because
    ///    ContentView's `.projectDidCreate` tail seeds content while `isResettingContent` is
    ///    still set and must not be reordered behind a push that can hang.
    /// 6. `publishAfterContent`, when it is called, publishes again -- now that the content is in
    ///    the editor (the push re-decorates it) -- unless another project has been opened in the
    ///    meantime, in which case it publishes nothing.
    ///
    /// Why publish explicitly at all: the editors otherwise hear about a change only from the
    /// `.onChange` observers, which compare before and after. A project opened while Focus Mode
    /// is on ends with every type collapsed exactly as it began, so the observers say nothing
    /// and the editors keep whatever they were last sent.
    ///
    /// Focus Mode's assignments stay direct and nothing here writes to the database.
    func runProjectOpenSequence(
        kind: ProjectOpenKind,
        publish: @escaping DisplayPublisher,
        openProject: @MainActor (_ publishAfterContent: @escaping @MainActor () -> Void) async -> Void
    ) async {
        let scheduledForProjectId = DocumentManager.shared.projectId
        let isConfigurable = Self.openProjectIsConfigurable

        if kind == .projectSwitch {
            resetForProjectSwitch()
        }
        if isConfigurable {
            loadAndApplyAnnotationDisplaySettings()
            reenterFocusModeIfRestored()
            publishAnnotationDisplayState(via: publish)
        } else {
            DebugLog.log(.lifecycle, "[ProjectOpen] Project is not fully open (database/id/content id); nothing loaded or published")
        }

        // Only if this project is still the open one: an open that was overtaken by a later one
        // (A then B then C in quick succession) must not push its state over the newer open's.
        let publishAfterContent: @MainActor () -> Void = { [weak self] in
            guard let self, isConfigurable, DocumentManager.shared.projectId == scheduledForProjectId else { return }
            self.publishAnnotationDisplayState(via: publish)
        }
        await openProject(publishAfterContent)
    }
}
