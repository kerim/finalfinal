//
//  UITestingDeleteTrigger.swift
//  final final
//
//  Phase 4b slice 2a, fix round 12 (speed). UI-TEST-ONLY seam, DEBUG builds only: starts Delete Section without a menu click.
//
//  Why: an XCUITest menu click is followed by the test's own accessibility queries ("find the section-delete-button MenuItem"),
//  which wait on this process's web content and block the app's main thread for as long as the JavaScript call runs. A timing
//  taken with that interference in it cannot tell the app's own stall from the test's. The test posts this distributed
//  notification instead and reads the app's own trace lines.
//
//    name      com.kerim.final-final.uitest.deleteSection
//    userInfo  ["title": "<the section's exact title as the sidebar shows it>"]
//
//  The section is found by title in `editorState.sections` and the SAME entry point the sidebar's context-menu action calls is run
//  (`ContentView.deleteSectionFromSidebar`), so everything after is the real path, including its `click-start type=none` trace line,
//  which is the zero of the op's timeline. A title no section has is logged `alwaysPersisted` and nothing is done. Receipt is
//  logged under `.undo` (the trace's category) as `[UITEST-TRIGGER] t=<ms>ms deleteSection received title=<title>`, on the same
//  clock as the `[STRUCT-TRACE]` lines, so the op's `start` line follows within a few milliseconds.
//
//  Installed only when `TestMode.isUITesting` (the `FF_UI_TESTING=1` launch environment), from `ContentView`'s `.task`; nothing of
//  this file exists in a Release build.
//

#if DEBUG

import Foundation

@MainActor
final class UITestingDeleteTrigger: NSObject {

    nonisolated static let notificationName = Notification.Name("com.kerim.final-final.uitest.deleteSection")
    nonisolated static let titleKey = "title"
    static let shared = UITestingDeleteTrigger()

    private weak var editorState: EditorViewState?
    private var perform: (@MainActor (String) -> Void)?
    private var isObserving = false

    /// Points the trigger at `editorState` and the action to run, and starts listening (once), but only when UI testing: outside it
    /// nothing is registered with the distributed notification center (a unit test drives `handle(title:)` directly).
    func install(editorState: EditorViewState, perform: @escaping @MainActor (String) -> Void) {
        self.editorState = editorState
        self.perform = perform
        guard TestMode.isUITesting, !isObserving else { return }
        isObserving = true
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(receivedNotification(_:)), name: Self.notificationName, object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    /// Stops listening when the view that installed it goes away (only that view's: another window must not remove it).
    func remove(for editorState: EditorViewState) {
        guard self.editorState === editorState else { return }
        DistributedNotificationCenter.default().removeObserver(self, name: Self.notificationName, object: nil)
        isObserving = false
        self.editorState = nil
        perform = nil
    }

    @objc nonisolated private func receivedNotification(_ notification: Notification) {
        let title = notification.userInfo?[Self.titleKey] as? String
        MainActor.assumeIsolated { handle(title: title) }
    }

    /// One delete request. Internal so a unit test can drive it without the distributed notification center.
    func handle(title: String?) {
        DebugLog.log(
            .undo, "[UITEST-TRIGGER] t=\(StructuralTrace.nowMs())ms deleteSection received title=\(title ?? "(none)")")
        guard let editorState, let perform else {
            DebugLog.alwaysPersisted("[UITestingDeleteTrigger] deleteSection: no editor is installed -- nothing deleted")
            return
        }
        guard let title, let sectionId = Self.sectionId(forTitle: title, in: editorState.sections) else {
            DebugLog.alwaysPersisted(
                "[UITestingDeleteTrigger] deleteSection: no section titled \"\(title ?? "(none)")\" -- nothing deleted")
            return
        }
        // There is no click behind this trigger: tell the trace not to read `NSApp.currentEvent` (the last event the run loop
        // handled, seconds old) as one. The click note is written synchronously inside `perform`, before its Task hop. The flag
        // is cleared again afterwards so that an early return in `perform` (the zoom-locked guard, before the click note is
        // reached) never leaves it set for a later real menu click.
        StructuralTrace.nextClickHasNoEvent.withLock { $0 = true }
        perform(sectionId)
        StructuralTrace.nextClickHasNoEvent.withLock { $0 = false }
    }

    /// The id of the first section whose title is exactly `title`.
    static func sectionId(forTitle title: String, in sections: [SectionViewModel]) -> String? {
        sections.first { $0.title == title }?.id
    }
}

#endif
