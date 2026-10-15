//
//  EditorStateRegistry.swift
//  final final
//
//  t-94369a83 Phase 3a-1b, e2e fix round: which editor state the command layer (the close / project switch / quit
//  lifecycle, the quit hook, the menu commands) acts on.
//
//  The route (obligation 11). The command layer has no view hierarchy to ask, so it reads
//  `AppDelegate.shared?.editorState` (`LifecycleEnvironment.production`). That used to be a weak pointer that every
//  ContentView's `.task` overwrote with its own state, and that was wrong for any window that is not the app's real
//  one: opening a project from Finder (or `open(1)`) while one is open makes macOS create an EXTRA main-window scene
//  (`AppDelegate.closeSpuriousFinderOpenWindows` closes it a moment later). Its ContentView took the pointer and
//  installed its own host; the window closed, its `.onDisappear` dropped the host (or the state was freed), and the
//  lifecycle found no editor state or no host, passed through, and opened the new project in `DocumentManager`
//  without saving the old one and without reloading the editor on screen.
//
//  So a ContentView no longer writes a single pointer. It registers its state WITH THE WINDOW IT LIVES IN
//  (`AppDelegate.registerEditorState`, from the invisible `HostWindowReader` in its background), and
//  `AppDelegate.editorState` resolves, at the moment it is read, the state registered for `AppDelegate.mainWindow`.
//  What that gives:
//
//    - An extra window's state can never be the lifecycle's, whenever it mounted, in whatever order, and whether or
//      not its `.onDisappear` ever runs: it is not registered in the main window. Nothing about it needs clearing.
//    - Getting Started <-> regular project swaps the root view inside the SAME window: the NEW ContentView registers
//      in that window, and the most recent registration for a window wins, so the new state is the app's editor state
//      from then on whichever of "new view mounts" and "old view tears down" comes first. The OLD state is not read
//      from here again: a lifecycle armed on it holds it strongly in `LifecycleEntry.current` for its tail (item 11,
//      N26).
//    - Before `mainWindow` is captured (the first moments of a launch) there is nothing to match against, so the
//      earliest live registration is used: the real window is always created first. Once it is captured, matching
//      starts, with no re-registration needed.
//    - Entries are weak: a state that is freed drops out by itself, so nothing here keeps a ContentView alive.
//
//  Plain `AnyObject` for the window, so the rule is unit-testable without mounting a window.
//

import Foundation

@MainActor
final class EditorStateRegistry {
    private struct Entry {
        weak var state: EditorViewState?
        weak var window: AnyObject?
    }

    private var entries: [Entry] = []

    /// A ContentView's state, and the window its view is in (nil while the view is not in a window yet). Safe to call
    /// again for the same state: it keeps its place and records the window.
    func register(_ state: EditorViewState, in window: AnyObject?) {
        entries.removeAll { $0.state == nil }
        if let index = entries.firstIndex(where: { $0.state === state }) {
            if let window { entries[index].window = window }
        } else {
            entries.append(Entry(state: state, window: window))
        }
    }

    /// The state the command layer acts on: the most recently registered live state in `mainWindow`, or, while
    /// `mainWindow` is not known yet, the earliest live registration. nil when nothing matches (the lifecycle then
    /// passes through, as it does with no open project).
    func resolve(mainWindow: AnyObject?) -> EditorViewState? {
        let live = entries.filter { $0.state != nil }
        guard let mainWindow else { return live.first?.state }
        return live.last { $0.window === mainWindow }?.state
    }

    /// What a ContentView's `.onDisappear` does: drops that view's OWN lifecycle host (its closures reach the view's
    /// state, so they are released with the view; a lifecycle already running holds the host it captured at arm and
    /// never reads this property again, N26). It touches no other state and nothing registered, so an extra window
    /// going away cannot take the real window's host with it.
    static func contentViewDidDisappear(_ state: EditorViewState) {
        state.lifecycleHost = nil
        DebugLog.log(.lifecycle, "[EditorState] view disappeared, its host dropped: state=\(ObjectIdentifier(state))")
    }
}
