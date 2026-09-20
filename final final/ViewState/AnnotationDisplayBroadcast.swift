//
//  AnnotationDisplayBroadcast.swift
//  final final
//
//  Window-scoped delivery of the annotation display state (per-type modes, Panel Only, Hide
//  Completed) to the web editors.
//
//  Why scoped: `NotificationCenter.default.post` is global, and the app can have more than one
//  window's editors alive at once (Finder-open makes AppKit spawn a second WindowGroup window with
//  its own ContentView and EditorViewState, see AppDelegate.closeSpuriousFinderOpenWindows). An
//  unscoped post from one window's state re-decorated EVERY window's editors, so whichever window
//  posted last decided what a document rendered. Each `EditorViewState` therefore has a
//  `windowToken`; a post carries the poster's token, and an editor observes with the token of the
//  state it was created for, receiving only posts that carry it.
//
//  The notification name is PRIVATE to this type on purpose: nothing else can post it (a direct
//  `NotificationCenter.default.post` would not compile, and would be ignored by every editor
//  anyway) and nothing can observe it without going through `addObserver(for:)`, which applies the
//  token guard itself -- an editor cannot forget it.
//
//  The other route to an editor -- the catch-up push in ContentView's `onWebViewReady`
//  (ContentView+EditorPresentation.swift) -- is not a notification at all: it evaluates JavaScript
//  on that window's own WebView, so it is already scoped.
//

import Foundation

enum AnnotationDisplayBroadcast {
    /// What a post carries: the state to show.
    struct Payload: Sendable {
        let modes: [AnnotationType: AnnotationDisplayMode]
        let isPanelOnly: Bool
        let hideCompletedTasks: Bool
    }

    private static let name = Notification.Name("annotationDisplayModesChanged")
    private static let windowTokenKey = "windowToken"

    /// Post the display state for the editors of the window that owns `windowToken`.
    @MainActor
    static func post(
        modes: [AnnotationType: AnnotationDisplayMode],
        isPanelOnly: Bool,
        hideCompletedTasks: Bool,
        windowToken: UUID
    ) {
        NotificationCenter.default.post(
            name: name,
            object: nil,
            userInfo: [
                "modes": modes,
                "isPanelOnly": isPanelOnly,
                "hideCompletedTasks": hideCompletedTasks,
                windowTokenKey: windowToken
            ]
        )
    }

    /// Observe the display state posted for the window that owns `windowToken`, and only that
    /// window's: a post carrying another token, or none, never reaches `handler`. `queue` is as
    /// for `NotificationCenter.addObserver(forName:object:queue:using:)` (`nil` delivers
    /// synchronously on the poster's thread). Keep the returned token and remove it on teardown.
    static func addObserver(
        for windowToken: UUID,
        queue: OperationQueue?,
        using handler: @escaping @Sendable (Payload) -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: queue) { notification in
            guard let postedToken = notification.userInfo?[windowTokenKey] as? UUID, postedToken == windowToken,
                  let modes = notification.userInfo?["modes"] as? [AnnotationType: AnnotationDisplayMode] else { return }
            handler(Payload(
                modes: modes,
                isPanelOnly: notification.userInfo?["isPanelOnly"] as? Bool ?? false,
                hideCompletedTasks: notification.userInfo?["hideCompletedTasks"] as? Bool ?? false
            ))
        }
    }
}
