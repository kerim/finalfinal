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
    /// The same seam for Duplicate Section (2026-11-09, the two Duplicate-at-once tests): same `userInfo`, runs `duplicateSectionFromSidebar`.
    nonisolated static let duplicateNotificationName = Notification.Name("com.kerim.final-final.uitest.duplicateSection")
    nonisolated static let titleKey = "title"
    /// Optional `userInfo` number (seconds, default 0): when no section has the title YET, look again every 10 ms for this long and
    /// run the command the moment one does. A test posts the second command right after the first click, before the first command's
    /// copy has reached the sidebar, and the app runs it as soon as the copy is there (no UI walk to the copy's card).
    nonisolated static let waitSecondsKey = "waitSeconds"
    static let shared = UITestingDeleteTrigger()

    private enum Kind {
        case delete, duplicate
        var word: String { self == .delete ? "deleteSection" : "duplicateSection" }
    }

    private weak var editorState: EditorViewState?
    private var perform: (@MainActor (String) -> Void)?
    private var performDuplicate: (@MainActor (String) -> Void)?
    private var isObserving = false

    /// Points the trigger at `editorState` and the actions to run, and starts listening (once), but only when UI testing: outside it
    /// nothing is registered with the distributed notification center (a unit test drives `handle(title:)` directly).
    func install(
        editorState: EditorViewState, perform: @escaping @MainActor (String) -> Void,
        performDuplicate: (@MainActor (String) -> Void)? = nil
    ) {
        self.editorState = editorState
        self.perform = perform
        self.performDuplicate = performDuplicate
        guard TestMode.isUITesting, !isObserving else { return }
        isObserving = true
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(receivedNotification(_:)), name: Self.notificationName, object: nil,
            suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(receivedDuplicateNotification(_:)), name: Self.duplicateNotificationName, object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    /// Stops listening when the view that installed it goes away (only that view's: another window must not remove it).
    func remove(for editorState: EditorViewState) {
        guard self.editorState === editorState else { return }
        DistributedNotificationCenter.default().removeObserver(self, name: Self.notificationName, object: nil)
        DistributedNotificationCenter.default().removeObserver(self, name: Self.duplicateNotificationName, object: nil)
        isObserving = false
        self.editorState = nil
        perform = nil
        performDuplicate = nil
    }

    @objc nonisolated private func receivedNotification(_ notification: Notification) {
        let title = notification.userInfo?[Self.titleKey] as? String
        let wait = (notification.userInfo?[Self.waitSecondsKey] as? NSNumber)?.doubleValue ?? 0
        MainActor.assumeIsolated { handle(title: title, waitSeconds: wait) }
    }

    @objc nonisolated private func receivedDuplicateNotification(_ notification: Notification) {
        let title = notification.userInfo?[Self.titleKey] as? String
        let wait = (notification.userInfo?[Self.waitSecondsKey] as? NSNumber)?.doubleValue ?? 0
        MainActor.assumeIsolated { handleDuplicate(title: title, waitSeconds: wait) }
    }

    /// One delete request. Internal so a unit test can drive it without the distributed notification center.
    func handle(title: String?, waitSeconds: Double = 0) { run(.delete, title: title, waitSeconds: waitSeconds) }

    /// One duplicate request, the same way.
    func handleDuplicate(title: String?, waitSeconds: Double = 0) { run(.duplicate, title: title, waitSeconds: waitSeconds) }

    private func action(for kind: Kind) -> (@MainActor (String) -> Void)? { kind == .delete ? perform : performDuplicate }

    private func run(_ kind: Kind, title: String?, waitSeconds: Double) {
        DebugLog.log(
            .undo, "[UITEST-TRIGGER] t=\(StructuralTrace.nowMs())ms \(kind.word) received title=\(title ?? "(none)")")
        guard editorState != nil, action(for: kind) != nil else {
            DebugLog.alwaysPersisted("[UITestingDeleteTrigger] \(kind.word): no editor is installed -- nothing done")
            return
        }
        guard let title else {
            DebugLog.alwaysPersisted("[UITestingDeleteTrigger] \(kind.word): no title -- nothing done")
            return
        }
        if tryRun(kind, title: title) { return }
        guard waitSeconds > 0 else {
            DebugLog.alwaysPersisted("[UITestingDeleteTrigger] \(kind.word): no section titled \"\(title)\" -- nothing done")
            return
        }
        // Not there yet: the first command's copy reaches the sidebar a few tens of milliseconds after its click.
        Task { @MainActor [weak self] in
            let deadline = ContinuousClock.now + .seconds(waitSeconds)
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
                guard let self else { return }
                if self.tryRun(kind, title: title) { return }
            }
            DebugLog.alwaysPersisted(
                "[UITestingDeleteTrigger] \(kind.word): no section titled \"\(title)\" after \(waitSeconds) s -- nothing done")
        }
    }

    /// Runs the command for the first section titled `title`. False when there is none (yet).
    private func tryRun(_ kind: Kind, title: String) -> Bool {
        guard let editorState, let perform = action(for: kind),
              let sectionId = Self.sectionId(forTitle: title, in: editorState.sections) else { return false }
        // There is no click behind this trigger: tell the trace not to read `NSApp.currentEvent` (the last event the run loop
        // handled, seconds old) as one. The click note is written synchronously inside `perform`, before its Task hop. The flag
        // is cleared again afterwards so that an early return in `perform` (the zoom-locked guard, before the click note is
        // reached) never leaves it set for a later real menu click.
        StructuralTrace.nextClickHasNoEvent.withLock { $0 = true }
        perform(sectionId)
        StructuralTrace.nextClickHasNoEvent.withLock { $0 = false }
        return true
    }

    /// The id of the first section whose title is exactly `title`.
    static func sectionId(forTitle title: String, in sections: [SectionViewModel]) -> String? {
        sections.first { $0.title == title }?.id
    }
}

#endif
