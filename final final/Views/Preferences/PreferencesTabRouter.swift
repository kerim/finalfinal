//
//  PreferencesTabRouter.swift
//  final final
//
//  Which Settings tab to show when a caller asks for a specific one ("Export Preferences..."
//  in the File menu, the auto-backup warning toast's "Open Diagnostics" action).
//
//  The request is STORED here rather than only broadcast, because a broadcast reaches a live
//  view only: on a cold launch the Settings window's view does not exist yet when the request
//  is made (the request is what opens the window), so a notification-only route would be
//  missed and the window would open on its default tab instead. A stored value works both
//  ways: a view that is created afterwards reads it on appear, and a view that is already
//  open sees it change and applies it.
//
//  The request is cleared as soon as the view applies it, so a later plain open of Settings
//  (the app menu's Settings item, Cmd-,) is never redirected by a stale request.
//

import SwiftUI

@MainActor
@Observable
final class PreferencesTabRouter {
    static let shared = PreferencesTabRouter()

    /// The tab a plain open of Settings shows.
    static let defaultTab: PreferencesTab = .export

    /// A tab a caller asked for that the Settings view has not applied yet.
    private(set) var pendingTab: PreferencesTab?

    /// Not `private` -- `.shared` is the one production instance, but tests construct their
    /// own isolated routers rather than mutating the shared singleton.
    init() {}

    /// Ask for a specific tab. Call BEFORE opening the Settings window, so a view created by
    /// that open finds the request already waiting.
    func request(_ tab: PreferencesTab) {
        pendingTab = tab
    }

    /// The tab a newly created Settings view should start on: the pending request if there is
    /// one, the default otherwise. Reading it does NOT clear the request (SwiftUI may build a
    /// view value more than once; only the view's `onAppear` consumes it).
    var initialTab: PreferencesTab {
        pendingTab ?? Self.defaultTab
    }

    /// Take the pending request: returns it and clears it, so it is applied exactly once.
    /// `nil` when nothing was requested.
    func consumePendingTab() -> PreferencesTab? {
        defer { pendingTab = nil }
        return pendingTab
    }
}
