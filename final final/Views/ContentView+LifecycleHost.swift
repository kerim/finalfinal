//
//  ContentView+LifecycleHost.swift
//  final final
//
//  t-94369a83 Phase 3a-1b, round C2 (slice-3a-1b-everyday.md section 5.2): installs the `LifecycleHost`
//  closures the close / project-switch / quit lifecycle calls back into. ContentView installs them in
//  `.task` (before `initializeProject()`) and removes them in `.onDisappear` (item 11).
//
//  The closures capture ContentView's own state, which in turn holds `editorState`, which holds the host:
//  a cycle that `.onDisappear` breaks. A lifecycle that is still running when the view goes away does not
//  depend on it, because it captured the host into `LifecycleEntry.current` at arm (N26).
//

import SwiftUI
import WebKit

extension ContentView {
    /// The services the content-change observer chain threads through, as one value. `body` and the
    /// lifecycle host both read it.
    var contentSyncServices: ContentSyncServices {
        ContentSyncServices(
            sectionSync: sectionSyncService,
            annotationSync: annotationSyncService,
            bibliographySync: bibliographySyncService,
            footnoteSync: footnoteSyncService,
            autoBackup: autoBackupService,
            documentManager: documentManager,
            scanMemo: editorState.scanMemo
        )
    }

    /// Installs this view's `LifecycleHost` on its editor state. The three tail closures are the real tails
    /// (`ContentView+LifecycleTails.swift`, round C5b); they take everything from this view's own services and
    /// editor state, which the closures capture (N7), never from `DocumentManager` for the project being closed.
    @MainActor
    func installLifecycleHost() {
        let editorState = editorState
        let findBarState = findBarState
        let services = contentSyncServices
        // The existing idle drain: re-posts ONE pending rebuild per call. The next idle transition (when
        // that rebuild finishes) picks up the next one, exactly as before.
        let repost: @MainActor () -> Void = { handleContentStateChange(from: .idle, to: .idle) }
        let reparse: @MainActor (String) -> Void = { content in
            ContentSyncObserverHost<EmptyView>.scheduleSourceModeReparse(
                newValue: content,
                editorState: editorState,
                services: services
            )
        }
        let openTail: @MainActor (LifecycleToken) async -> Void = { token in
            _ = await runOpenTail(token: token)
        }
        let createTail: @MainActor (LifecycleToken, String?) async -> Void = { token, content in
            await runCreateTail(token: token, content: content)
        }
        let closeTail: @MainActor (LifecycleToken, Bool) async -> Void = { token, callOnProjectClosed in
            await runCloseTail(token: token, callOnProjectClosed: callOnProjectClosed)
        }
        // N4: the quit's automatic version goes through THIS view's backup service, captured here and carried into
        // `LifecycleEntry.current` with the host, never read from the app delegate's weak (overwritable) reference.
        let backup = autoBackupService
        editorState.lifecycleHost = LifecycleHost(
            activeWebView: { findBarState.activeWebView },
            runOpenTail: openTail,
            runCreateTail: createTail,
            runCloseTail: closeTail,
            repostDeferredRebuilds: repost,
            scheduleSourceModeReparse: reparse,
            toastCenter: { editorState.toastCenter },
            backupForQuit: { await backup.appWillQuit() }
        )
    }
}
