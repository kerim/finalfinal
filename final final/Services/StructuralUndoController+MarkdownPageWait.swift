//
//  StructuralUndoController+MarkdownPageWait.swift
//  final final
//
//  t-633df056 (Phase 5 job A5): the one precondition every Markdown section command checks at its entry. Right after View > Switch to
//  Markdown the badge says Markdown but the new CodeMirror page is not mounted yet, and `activeWebView` still names the outgoing Rich
//  Text page (about 1 s idle, 2.5 s busy on the twelve-chapter book, VM figures). A command pressed in that gap used to ask the Rich
//  Text page, get no answer and quietly take the old slow route. Now it waits for the page here, inside the structural gate (so a second
//  command pressed meanwhile is held behind it, in order) and BEFORE its click begins (no await is added inside any click's synchronous
//  stretch; the sync model treats the start of a click as untimed, so it needs no change). Held, never refused (UX contract 4.2): the
//  caller's "Finishing the last change…" notice is made before this wait, so a wait past one second shows it. The wait is bounded; on a
//  timeout, or when the editor left Markdown meanwhile, the caller takes the old route exactly as before.
//
//  Callers (each at its entry, after its guards and its notice, before its timeline begins): the Markdown editor-first Delete, Duplicate,
//  reorder and the three Version History restores, the Markdown quick undo and redo, and the Markdown slow undo and redo.
//

import Foundation

extension StructuralUndoController {

    /// True when the press may go on: no page load was under way, or the page became ready within `timeout`. False when the press must take
    /// the old route (the wait timed out, or the editor left Markdown while it waited). The log lines are read by the real-app test
    /// (`WriteQueuePhase5BeforeNumbersE2ETests`): "held until it is ready", "ready after <n> ms", and the two old-route lines.
    func awaitMarkdownPageForStructuralCommand(
        label: String, timeout: Duration = EditorViewState.markdownPageWaitTimeout
    ) async -> Bool {
        guard let editorState, editorState.editorMode == .source, editorState.markdownPageLoading else { return true }
        DebugLog.log(.undo, "[StructuralUndoController] markdown \(label): the Markdown page is still loading -- held until it is ready")
        let began = Date()
        let outcome = await editorState.awaitMarkdownPage(timeout: timeout)
        let waitedMs = Int((Date().timeIntervalSince(began) * 1_000).rounded())
        switch outcome {
        case .ready:
            DebugLog.log(.undo, "[StructuralUndoController] markdown \(label): the Markdown page is ready after \(waitedMs) ms -- the press goes on")
            return true
        case .timedOut:
            DebugLog.log(
                .undo, "[StructuralUndoController] markdown \(label): the Markdown page was still not ready after \(waitedMs) ms "
                + "-- old path for this press")
            return false
        case .modeChanged:
            DebugLog.log(
                .undo, "[StructuralUndoController] markdown \(label): the editor left Markdown while the press waited (\(waitedMs) ms) "
                + "-- old path for this press")
            return false
        }
    }
}
