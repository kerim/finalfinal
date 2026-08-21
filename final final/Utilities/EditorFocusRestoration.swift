//
//  EditorFocusRestoration.swift
//  final final
//
//  Shared "return focus to the editor" helper — the single implementation for the two-halves
//  fix every confirmed focus-restoration bug in this feature turned out to need.
//

import WebKit

/// Restores keyboard focus to an editor `WKWebView` after some other control that had it
/// (a find bar field, a dialog, a sheet, a secondary window) is dismissed.
///
/// Three confirmed live bugs (find bar, mode switch × 2 directions) shared the exact same
/// root cause: a dismissal path implemented only HALF of the fix. There are two
/// independently necessary halves:
///
/// 1. **AppKit half** — `window.makeFirstResponder(webView)`. Without this,
///    `UndoRedoCommands.focusedWebView()` (which walks `NSApp.keyWindow?.firstResponder`)
///    never finds the WebView at all, so native Cmd-Z/Cmd-Shift-Z routing silently falls
///    through to a no-op `undo:`/`redo:` responder-chain send.
/// 2. **DOM half** — `window.FinalFinal.focus()`. Without this, AppKit delivers key events to
///    the WebView process, but inside the page they target `document.body` — both editors'
///    keymaps listen on the editor's own content element (`view.dom` / `contentDOM`), which
///    a `body`-targeted event never reaches. `makeFirstResponder` alone looks like it worked
///    (the WebView IS first responder) while typing/undo still silently does nothing.
///
/// Neither half substitutes for the other when BOTH are actually needed -- confirmed live
/// for the find-bar and mode-switch cases this helper was extracted from (see
/// `FindBarState.hide()`'s own doc comment for the find-bar case's root-cause writeup). Most
/// OTHER call sites are NOT confirmed to need this fix, though: three separate real
/// negative-control vmtest runs -- one per Version History dismissal path (button-click
/// "Close", the post-restore auto-close, and the titlebar close button) -- each found AppKit's
/// own window-key-status handback already restores both halves on its own for that shape (a
/// separate window closing, handing key status back to an already-focused main window).
/// Calling this helper there is harmless but was not, in the end, load-bearing for any of the
/// three. Every other call site in this codebase (Tier 2's editor-window alert sheets, Tier
/// 3's untouched panels/other alerts) has never been negative-controlled at all -- their
/// status is "fixed but unconfirmed" or "not fixed, unverified," not "confirmed necessary."
/// See `docs/architecture/unified-undo.md`'s "Focus restoration after dismissal" section for
/// the full, honestly-categorized account before citing any of this file's call sites as
/// live-confirmed. `FindBarState.hide()` remains the one call site this generalizes that
/// genuinely IS confirmed necessary.
@MainActor
enum EditorFocusRestoration {
    #if DEBUG
    /// Test-only ordering spy: called once for each half this function attempts, in the
    /// order it attempts them, so a unit test can assert both the JS call and the
    /// `makeFirstResponder` call actually happened -- and in the right order -- without a
    /// real WebView/NSWindow round trip. Mirrors `StructuralUndoController.testOrderingSpy`.
    /// No cost in release builds (property doesn't exist). `step` is `"js"` or
    /// `"makeFirstResponder"`.
    static var testSpy: ((_ context: String, _ step: String) -> Void)?
    #endif

    private static func spy(_ context: String, _ step: String) {
        #if DEBUG
        testSpy?(context, step)
        #endif
    }

    /// Restores both halves of editor focus to `webView`.
    ///
    /// Safe to call from any dismissal path that hands control back to the editor window: a
    /// nil `webView`, a `webView` not yet attached to any `NSWindow`, or a page whose
    /// `window.FinalFinal` bridge isn't ready yet are all handled as logged no-ops rather than
    /// crashing.
    ///
    /// - Parameters:
    ///   - webView: the editor WebView that should reclaim focus. Pass `nil` freely (e.g. no
    ///     active editor at all) — the call becomes a logged no-op.
    ///   - context: short label identifying the call site, folded into every `.undo`
    ///     DebugLog line this call emits (e.g. `"find-bar hide"`, `"version-history close"`).
    static func restoreFocus(to webView: WKWebView?, context: String) {
        guard let webView else {
            DebugLog.log(.undo, "[EditorFocusRestoration] context=\(context) skipped: no webView")
            return
        }

        // DOM half first (order doesn't matter for correctness — both are independently
        // applied — but matches FindBarState.hide()'s existing call order).
        spy(context, "js")
        webView.evaluateJavaScript("window.FinalFinal.focus()") { result, error in
            // `focus()` (Milkdown) / `focusEditor()` (CodeMirror) now return whether the
            // content DOM actually holds focus afterward, NOT just whether the call ran
            // without throwing (review round fix) -- both editors' `focus()` silently
            // swallow their own failure and always resolve, so `error == nil` alone can't
            // distinguish a real success from a no-op on a still-loading/detached page.
            let domFocused = (result as? Bool) ?? false
            if let error {
                DebugLog.log(.undo, "[EditorFocusRestoration] context=\(context) JS focus() error: \(error)")
            } else {
                DebugLog.log(.undo, "[EditorFocusRestoration] context=\(context) JS focus() domFocused=\(domFocused)")
            }
        }

        // AppKit half.
        guard let window = webView.window else {
            DebugLog.log(.undo, "[EditorFocusRestoration] context=\(context) skipped makeFirstResponder: no window")
            return
        }
        spy(context, "makeFirstResponder")
        let becameFirstResponder = window.makeFirstResponder(webView)
        DebugLog.log(.undo, "[EditorFocusRestoration] context=\(context) makeFirstResponder=\(becameFirstResponder)")
    }
}
