//
//  QuitFlushTestSupport.swift
//  final finalTests
//
//  t-94369a83 Phase 3a-1b, round C6: the entry the EXISTING quit-flush tests (`QuitFlushDuplicateInsertTests`,
//  `BlockSyncFetchContentTimeoutTests`) use now that quit's flush is the lifecycle save sequence under a QUIT
//  token (`EditorViewState.flushForQuit(token:host:...)`). It does what `AppDelegate.runQuitSequence(reply:)` does
//  up to the flush -- arm the quit token, run the sequence with production bounds -- with a host whose only live
//  closure hands out the editor's WebView, and no app delegate, backup or reply. Each of those tests keeps its
//  assertion and changes only its entry to this.
//

import Foundation
import WebKit
@testable import final_final

@MainActor
enum QuitFlushTestSupport {

    /// Arms the QUIT token on `editorState`, as `runQuitSequence` does before it starts its task. nil if it could not.
    static func armQuit(_ editorState: EditorViewState) -> LifecycleToken? {
        guard case .armed(let token) = editorState.armLifecycle(.quit, wasGettingStarted: false) else { return nil }
        return token
    }

    /// A host with no tails and no toasts; `activeWebView` is the WebView the editor "has mounted".
    static func host(webView: WKWebView?) -> LifecycleHost {
        LifecycleHost(
            activeWebView: { webView },
            runOpenTail: { _ in },
            runCreateTail: { _, _ in },
            runCloseTail: { _, _ in },
            repostDeferredRebuilds: {},
            scheduleSourceModeReparse: { _ in },
            toastCenter: { ToastCenter() }
        )
    }

    /// Quit's flush under the armed `token`, production bounds. Quit exits holding the writer barrier; a test
    /// process is not exiting, so the barrier is released and the token cleared afterwards.
    @discardableResult
    static func flush(_ editorState: EditorViewState, token: LifecycleToken, webView: WKWebView?) async -> LifecycleFlushResult {
        let result = await editorState.flushForQuit(
            token: token,
            host: host(webView: webView),
            structuralUndoController: nil,
            deadline: LifecycleDeadline(total: LifecycleBounds.production.quitTotal),
            bounds: .production
        )
        editorState.lifecycleBarrier?.release()
        editorState.lifecycleBarrier = nil
        editorState.clearLifecycle(token.id)
        return result
    }
}
