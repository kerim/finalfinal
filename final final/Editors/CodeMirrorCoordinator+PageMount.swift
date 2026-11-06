//
//  CodeMirrorCoordinator+PageMount.swift
//  final final
//
//  The mount of a CodeMirror page whose load has finished (`webView(_:didFinish:)`, CodeMirrorCoordinator+Handlers.swift): the body that
//  used to sit inline there, moved out in Phase 5 job A5 (t-633df056) so the UI-test seam below could hold it without lengthening that
//  file. Behaviour-preserving in every normal launch: `mountLoadedPageAfterTestHold` runs `mountLoadedPage` right away, synchronously.
//

import SwiftUI
import WebKit

extension CodeMirrorEditor.Coordinator {

    /// Mounts the loaded page, or (UI-test seam `FF_UI_TESTING_MD_PAGE_READY_HOLD_MS`, `TestMode.holdMarkdownPageReady`) holds the first
    /// page of the launch for the asked milliseconds first, which widens the window between the status-bar badge saying Markdown and the
    /// page being ready (the window a Markdown section command is held in, StructuralUndoController+MarkdownPageWait.swift), so a real-app
    /// test can press one inside it on purpose. The hold is a plain suspension: the editor mode and the badge have already flipped, the
    /// page is not yet ready (`isEditorReady` stays false, so nothing is pushed to it), exactly as during a slow load. A page torn down
    /// during the hold (`isCleanedUp`: the user switched back) is not mounted.
    func mountLoadedPageAfterTestHold(_ webView: WKWebView) {
        // Phase 5 job A9: under the legacy switch (`FF_UI_TESTING_LEGACY_TRANSITION=switch`) the transition hold
        // (`FF_UI_TESTING_TRANS_HOLD_MS`) sits here, between the flip and the page's text, which is where today's switch loses typing.
        let legacySwitchHold = TestMode.isUITestingLegacyTransition(for: .modeSwitch) && TestMode.uiTestingTransHoldMs != nil
        guard TestMode.willHoldMarkdownPageReady || legacySwitchHold else {
            mountLoadedPage(webView)
            return
        }
        Task { @MainActor [weak self] in
            if legacySwitchHold { await TestMode.holdTransition("switch to markdown (legacy)") }
            await TestMode.holdMarkdownPageReady()
            guard let self, !self.isCleanedUp else { return }
            self.mountLoadedPage(webView)
        }
    }

    /// The mount: the ready flag, the mount reset, `onWebViewReady` (which moves the app's web-view pointers to this page), the content
    /// handover and the stats poll, in this order.
    func mountLoadedPage(_ webView: WKWebView) {
        isEditorReady = true
        // Mount reset (undo-mode-switch-focus fix): a freshly mounted instance has no local
        // edits of its own -- without this, a timestamp carried over from typing in the
        // OUTGOING editor (this Coordinator's own fields default-init fresh per instance,
        // but this reset is defense-in-depth against any future reuse) would suppress this
        // new editor's own legitimate mount push, landing the user in an empty/stale Source
        // editor. See `shouldPushContent`'s settle-window guard.
        lastLocalEditAt = .distantPast
        applyPersistedToggleStates()
        onWebViewReady?(webView)    // Push image meta first (FIFO guarantees execution order)
        batchInitialize()            // Then push content (decorations build with metadata present)
        startPolling()
    }

    /// Phase 5 job A9: the mount of a page a switch to Markdown filled before the flip (EditorPreloader+Prepare.swift). As
    /// `handlePreloadedView`, minus the content handover: the page already holds `content` (the rows' text Swift gave it while it was
    /// detached), so that is recorded as pushed and the caret the toggle saved is consumed (the prepare put it in). The switch itself
    /// carries the typing done meanwhile onto the page (EditorViewState+SwitchTransition.swift).
    func handlePreparedSwitchPage(content: String) {
        isEditorReady = true
        lastLocalEditAt = .distantPast
        applyPersistedToggleStates()
        lastPushedContent = content
        lastPushTime = Date()
        // The line `batchInitialize` writes at today's handover; the real-app tests wait for it as "the Markdown page has its text".
        DebugLog.log(.sync, "[CodeMirrorEditor] batchInitialize: setting lastPushedContent preemptively (len=\(content.count)) (prepared page)")
        if let webView { onWebViewReady?(webView) }
        // The saved caret stays set until the switch has ended (it clears it), and counts as consumed meanwhile: see
        // MilkdownCoordinator+PreparedPage.swift.
        consumedCursorRestore = cursorPositionToRestoreBinding.wrappedValue
        startPolling()
    }
}
