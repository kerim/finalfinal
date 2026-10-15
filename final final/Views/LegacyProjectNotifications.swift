//
//  LegacyProjectNotifications.swift
//  final final
//
//  t-94369a83 Phase 3a-1b, rounds C5b and C8b (slice-3a-1b-everyday.md section 4.4 "Keyed posts" and section 5.5):
//  what ContentView does with `.projectDidOpen`, `.projectDidCreate` and `.projectDidClose`.
//
//  Until the lifecycle was wired through every entry point, these three posts RAN a project switch or close:
//  ContentView's handlers flushed the old project, backed it up and opened the next one. Since round C8b they run
//  nothing of the kind. A `perform` that ran inside `LifecycleEntry.run` posts the same notification KEYED
//  (`userInfo["lifecycleToken"]`, `LifecycleEntry.tokenUserInfoKey`) and the managed tail
//  (`ContentView+LifecycleTails.swift`) does the whole job, so a keyed post is ignored here. Two other cases remain:
//
//    - the Getting Started close carries `LifecycleEntry.gettingStartedCloseUserInfo` (it has nothing to save, so it
//      runs no lifecycle and has no token): `.projectDidClose` then runs `onClosed`, the token-less Getting Started
//      close (`ContentView.closeGettingStartedProject`);
//    - a post with neither is UNKEYED: a call site that was missed. The handler does nothing, `LifecycleEntry.
//      noteUnkeyedPost` logs it and counts it in DEBUG builds, so a test or the e2e can prove none is left. (The
//      pass-through posts of a command that found nothing to protect, with no ContentView mounted, are unkeyed too
//      but never reach here: FinalFinalApp swaps the root view and the NEW ContentView opens the project on mount.)
//
//  The three handlers live here so a unit test drives the real routing with real `Notification` values.
//

import Foundation

@MainActor
enum LegacyProjectNotifications {

    /// What a handler did with a post.
    enum Routing: Equatable {
        /// A managed lifecycle's post: its tail does the work, so this handler does nothing.
        case ignoredKeyed
        /// The Getting Started close: the token-less close ran.
        case gettingStartedClose
        /// Neither keyed nor the Getting Started close: a missed post site. Logged and counted, nothing done.
        case unkeyed
    }

    /// `.projectDidOpen`.
    @discardableResult
    static func opened(_ notification: Notification) -> Routing {
        route(notification, name: "projectDidOpen")
    }

    /// `.projectDidCreate`. The created project's content is not seeded from here: a managed create tail seeds it
    /// itself, and a project opened by a NEW ContentView (nothing was open, or Getting Started was) loads it from
    /// the new project's database on mount (`ProjectCommands.importMarkdown` saves it there before it posts).
    @discardableResult
    static func created(_ notification: Notification) -> Routing {
        route(notification, name: "projectDidCreate")
    }

    /// `.projectDidClose`. Runs `onClosed` only for the Getting Started close.
    @discardableResult
    static func closed(_ notification: Notification, onClosed: () -> Void) -> Routing {
        let routing = route(notification, name: "projectDidClose")
        if routing == .gettingStartedClose { onClosed() }
        return routing
    }

    private static func route(_ notification: Notification, name: String) -> Routing {
        if LifecycleEntry.isKeyed(notification) {
            DebugLog.log(.lifecycle, "[LegacyProjectNotifications] \(name) carries a lifecycle token: the managed tail handles it -- ignored")
            return .ignoredKeyed
        }
        if name == "projectDidClose", LifecycleEntry.isGettingStartedClose(notification) {
            DebugLog.log(.lifecycle, "[LegacyProjectNotifications] \(name): the Getting Started close")
            return .gettingStartedClose
        }
        LifecycleEntry.noteUnkeyedPost(name)
        return .unkeyed
    }
}
