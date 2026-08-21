//
//  UndoRedoCommands.swift
//  final final
//
//  Replaces the system default Edit > Undo/Redo menu items
//  (docs/plans/patient-rewinding-clockwork.md §4.7). Phase 2: activation routes through the
//  same JS routing decision the keyboard interceptor uses -- never a direct
//  UnifiedUndoService.performUndo()/performRedo() call from here, which would bypass the
//  content-equality guard the JS side enforces (plan §4.2/§4.7). With zero structural
//  entries recorded yet, the JS routing decision always falls through to the editor's own
//  text undo, so this is a no-behavior-change wiring: pressing Cmd-Z / using the menu item
//  behaves exactly as it did before this phase.
//
//  Plain "Undo"/"Redo" titles are deliberate (not "Undo Delete Section..."): a structural
//  title could lie once real entries exist, since the timeline top isn't necessarily the
//  next chronological step (plan §4.7).
//
//  Review finding (round 1, must-fix): the system `.undoRedo` group this replaces dispatches
//  the classic `undo:`/`redo:` action with a NIL target, which walks the responder chain to
//  whatever is actually first responder -- that's the entire mechanism by which Cmd-Z inside
//  a native NSTextField/NSTextView (find bar, sidebar filter bar, section card title, tag
//  pills, Preferences fields) edits THAT field instead of the document. A plain SwiftUI
//  `Button` with a closure action does not participate in that responder-chain-first
//  dispatch on its own, so `performUndo()`/`performRedo()` below explicitly re-derive it:
//  route to the focused editor's JS only when a WKWebView is actually the first responder;
//  otherwise send `undo:`/`redo:` to a nil target exactly like the system item did, letting
//  a focused native field's own undo manager handle it. This also naturally scopes the
//  action to the KEY window (NSApp.keyWindow), so with two project windows open, one Cmd-Z
//  only ever affects the window it was pressed in -- never both.
//

import SwiftUI
import WebKit

struct UndoRedoCommands: Commands {
    @FocusedValue(\.editorState) var editorState
    @FocusedValue(\.unifiedUndoService) var unifiedUndoService

    /// Scene-wide "a project window is key" bit (plan §4.7): comes from `focusedSceneValue`,
    /// which is true whenever the KEY WINDOW contains an editor at all -- NOT whether any
    /// particular control inside that window currently has keyboard focus. It exists only to
    /// keep the menu items from looking permanently disabled, matching how the
    /// system-default (unwired) Undo/Redo items looked before this phase. It plays no part
    /// in deciding WHERE a press actually goes -- that per-press decision (the focused
    /// WKWebView vs. a native control's own undo manager) is made fresh on every invocation
    /// by `focusedWebView()`/`performUndo()`/`performRedo()` below, keyed off the real first
    /// responder, not this scene-wide bit.
    private var mayHaveTextUndo: Bool { editorState != nil }

    private var canUndo: Bool {
        mayHaveTextUndo || !(unifiedUndoService?.undoStack.isEmpty ?? true)
    }

    private var canRedo: Bool {
        mayHaveTextUndo || !(unifiedUndoService?.redoStack.isEmpty ?? true)
    }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                Self.performUndo()
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!canUndo)
            .accessibilityIdentifier("menu-undo")

            Button("Redo") {
                Self.performRedo()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!canRedo)
            .accessibilityIdentifier("menu-redo")
        }
    }

    /// Walks up from the KEY WINDOW's current first responder looking for a WKWebView
    /// ancestor. Returns nil when a native control -- a text field, a list, or nothing in
    /// particular -- is what's actually focused, not the document editor. Scoped to
    /// `NSApp.keyWindow` specifically (not "any open project window"), so with two project
    /// windows open this only ever finds the webview in the window that's actually key.
    private static func focusedWebView() -> WKWebView? {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSView else { return nil }
        var candidate: NSView? = responder
        while let current = candidate {
            if let webView = current as? WKWebView { return webView }
            candidate = current.superview
        }
        return nil
    }

    /// Routes to the focused editor's JS routing decision when a WKWebView is actually first
    /// responder; otherwise falls through to the standard nil-target responder-chain walk --
    /// exactly what the system-default Undo item did -- so a focused native text field's own
    /// undo manager handles it, never the document.
    private static func performUndo() {
        if let webView = focusedWebView() {
            webView.evaluateJavaScript("window.FinalFinal.requestUnifiedUndo()") { _, error in
                if let error {
                    DebugLog.log(.undo, "[UndoRedoCommands] requestUnifiedUndo failed: \(error.localizedDescription)")
                }
            }
        } else {
            DebugLog.log(.undo, "[UndoRedoCommands] performUndo: no focused WKWebView -- "
                + "falling through to nil-target undo: (this is the silent-no-op path)")
            NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        }
    }

    private static func performRedo() {
        if let webView = focusedWebView() {
            webView.evaluateJavaScript("window.FinalFinal.requestUnifiedRedo()") { _, error in
                if let error {
                    DebugLog.log(.undo, "[UndoRedoCommands] requestUnifiedRedo failed: \(error.localizedDescription)")
                }
            }
        } else {
            DebugLog.log(.undo, "[UndoRedoCommands] performRedo: no focused WKWebView -- "
                + "falling through to nil-target redo: (this is the silent-no-op path)")
            NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        }
    }
}
