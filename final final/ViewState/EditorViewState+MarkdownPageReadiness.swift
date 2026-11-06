//
//  EditorViewState+MarkdownPageReadiness.swift
//  final final
//
//  t-633df056 (Phase 5 job A5): the Markdown page's readiness record, and the bounded wait a Markdown section command makes for it.
//
//  THE GAP. View > Switch to Markdown flips `editorMode` (and the status-bar badge) at once, but the new CodeMirror page exists only once
//  its load has finished: about 1 s on an idle Mac and 2.5 s on a busy one on the twelve-chapter book (VM figures, Phase 4c job 3). Until
//  that page's `onWebViewReady` runs, `findBarState.activeWebView`, `structuralUndoController.activeWebView` and `escapeLadder.activeWebView`
//  still name the outgoing Rich Text page. A Markdown section command pressed in the gap (Delete Section, Duplicate, the Outline drag, the
//  three Version History restores, the quick and the slow Cmd-Z / Cmd-Shift-Z) used to pass its guards (`activeWebView != nil`,
//  `editorMode == .source`), call `window.FinalFinal.markdownStructuralEditorFirst` on the Rich Text page, get no answer and quietly take
//  the old slow route: about 2.5 s on a busy Mac, no "Finishing the last change…" notice, the slow snapshot Cmd-Z. Nothing was lost.
//
//  THE RECORD. `markdownPageLoading` is true from `toggleEditorMode()` making the mode Markdown (`beginMarkdownPageLoad`) until the
//  CodeMirror `onWebViewReady` closure has moved the pointers and put the writer on the queue (`markMarkdownPageReady`), and false again
//  when the mode leaves Markdown (`endMarkdownPageLoadOnLeavingMarkdown`). It is NOT set by a plain `editorMode = .source`, which the
//  unit-test rigs do with no page behind them, so nothing waits in them.
//
//  THE WAIT. `awaitMarkdownPage(timeout:)` returns at once when no load is under way; otherwise it parks the caller on a continuation that
//  is resumed by the page becoming ready, by the mode leaving Markdown, or by the timeout. The commands call it through
//  `StructuralUndoController.awaitMarkdownPageForStructuralCommand` (StructuralUndoController+MarkdownPageWait.swift), at their entry,
//  inside the structural gate (so a second command pressed meanwhile is held behind it, in order) and BEFORE their click begins: no await
//  is added inside any click's synchronous stretch, so the sync model (`docs/architecture/tla/DocSyncCurrent.tla`), which treats the start
//  of a click as untimed, needs no change. The wait is bounded (`markdownPageWaitTimeout`); on a timeout, or when the editor left
//  Markdown meanwhile, the command takes the old route exactly as before.
//

import Foundation

extension EditorViewState {

    /// How a wait for the Markdown page ended.
    enum MarkdownPageWaitOutcome: Equatable {
        /// The page is mounted and the pointers name it (or no load was under way).
        case ready
        /// The editor is not in Markdown mode, or left it while the caller waited: there is no Markdown page to wait for.
        case modeChanged
        /// The bound passed with the page still not ready.
        case timedOut
    }

    /// One command waiting for the page: its continuation and the task that times it out.
    struct MarkdownPageWaiter {
        let continuation: CheckedContinuation<MarkdownPageWaitOutcome, Never>
        let timeout: Task<Void, Never>
    }

    /// The production bound on the wait. The twelve-chapter book's page takes about 1 s idle and 2.5 s busy (VM figures), so 15 s is far
    /// past anything a working page needs; a wait that reaches it hands the press to the old route, as before the wait existed.
    nonisolated static let markdownPageWaitTimeout: Duration = .seconds(15)

    /// Called by `toggleEditorMode()` when the mode becomes Markdown: the new page is not there yet.
    func beginMarkdownPageLoad() {
        markdownPageLoading = true
    }

    /// Called by the CodeMirror `onWebViewReady` closure (ContentView+EditorPresentation.swift) once the app's web-view pointers name the
    /// new page and the Markdown writer is on the queue: every waiting command goes on.
    func markMarkdownPageReady() {
        markdownPageLoading = false
        resumeMarkdownPageWaiters(with: .ready)
    }

    /// Called by `toggleEditorMode()` when the mode leaves Markdown: there is no Markdown page to wait for, so every waiting command is told
    /// so and takes the old route.
    func endMarkdownPageLoadOnLeavingMarkdown() {
        markdownPageLoading = false
        resumeMarkdownPageWaiters(with: .modeChanged)
    }

    /// Waits until the Markdown page is ready, the mode leaves Markdown, or `timeout` passes. Returns at once (no suspension) when the editor
    /// is not in Markdown mode (`.modeChanged`) or when no page load is under way (`.ready`).
    func awaitMarkdownPage(timeout: Duration) async -> MarkdownPageWaitOutcome {
        guard editorMode == .source else { return .modeChanged }
        guard markdownPageLoading else { return .ready }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.resumeMarkdownPageWaiter(id, with: .timedOut)
            }
            markdownPageWaiters[id] = MarkdownPageWaiter(continuation: continuation, timeout: timeoutTask)
        }
    }

    private func resumeMarkdownPageWaiter(_ id: UUID, with outcome: MarkdownPageWaitOutcome) {
        guard let waiter = markdownPageWaiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume(returning: outcome)
    }

    private func resumeMarkdownPageWaiters(with outcome: MarkdownPageWaitOutcome) {
        let waiters = markdownPageWaiters
        markdownPageWaiters.removeAll()
        for waiter in waiters.values {
            waiter.timeout.cancel()
            waiter.continuation.resume(returning: outcome)
        }
    }
}
