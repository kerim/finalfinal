//
//  AppDelegate+EditorState.swift
//  final final
//
//  t-94369a83 Phase 3a-1b, e2e fix round: the app's editor state, resolved per window. See `EditorStateRegistry` for
//  the route and why it is no longer one pointer every ContentView overwrites. Lives in its own file so
//  `AppDelegate`'s body stays under SwiftLint's type_body_length limit; the registry itself is a stored property
//  (`editorStateRegistry`) in the class body, since extensions cannot hold one.
//

import AppKit

extension AppDelegate {
    /// The editor state of the MAIN window: the one the close / project switch / quit lifecycle, the quit hook and
    /// the menu commands act on. nil when no ContentView is registered for it (a launch not yet mounted, the picker
    /// before a first project). A lifecycle resolves it ONCE at entry and then holds that state strongly for its length
    /// (`LifecycleEntry.current`), so a later change here, such as a Getting Started swap, does not move it.
    var editorState: EditorViewState? {
        editorStateRegistry.resolve(mainWindow: mainWindow)
    }

    /// A ContentView registers its state with the window its view is in (from `HostWindowReader`, each time the view
    /// lands in a window). Only the main window's registration is ever returned from `editorState`; the log line
    /// says which kind this was, so a failed project switch shows which windows existed.
    func registerEditorState(_ state: EditorViewState, in window: NSWindow?) {
        editorStateRegistry.register(state, in: window)
        DebugLog.log(
            .lifecycle,
            "[EditorState] registered state=\(ObjectIdentifier(state)) windowNumber=\(window?.windowNumber ?? -1) "
                + "isMainWindow=\(window != nil && window === mainWindow) "
                + "resolvesToIt=\(editorState === state)"
        )
    }
}
