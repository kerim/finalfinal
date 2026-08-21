//
//  CodeMirrorCoordinator+Core.swift
//  final final
//
//  CodeMirrorEditor.Coordinator's primary declaration (stored properties,
//  init, deinit, and the poll-equality-guard cache reset). Split out of
//  CodeMirrorEditor.swift, whose struct body -- inclusive of the nested
//  Coordinator class it used to declare -- crossed SwiftLint's 300-line
//  type_body_length warning threshold. Swift extensions can't add stored
//  properties to an *existing* type, but they can declare a brand-new
//  nested type in full, so the whole Coordinator primary declaration
//  (unchanged) lives here instead. Behavior-preserving move only; no
//  logic changed. Coordinator's methods stay split across
//  CodeMirrorCoordinator+Handlers.swift and
//  CodeMirrorCoordinator+NotificationObservers.swift as before.
//

import SwiftUI
import WebKit

extension CodeMirrorEditor {
    @MainActor
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?

        var contentBinding: Binding<String>
        var cursorPositionToRestoreBinding: Binding<CursorPosition?>
        var scrollToOffsetBinding: Binding<Int?>
        var scrollToAnnotationIndexBinding: Binding<Int?>
        var isResettingContentBinding: Binding<Bool>
        /// P3 §4c/4d: second parameter is `wasUndo` -- see CodeMirrorEditor's matching
        /// property doc comment.
        let onContentChange: (String, Bool) -> Void
        let onStatsChange: (Int, Int) -> Void
        let onSectionChange: (String) -> Void
        let onCursorPositionSaved: (CursorPosition) -> Void

        /// Callback for block-ID-based section tracking (blockId, title)
        var onSectionIdChange: ((String?, String) -> Void)?

        /// Callback for selection changes (selected text; empty = deselected)
        var onSelectionChange: ((String) -> Void)?

        var pollingTimer: Timer?
        var lastReceivedFromEditor: Date = .distantPast
        var lastPushedContent: String = ""
        var lastPushTime: Date = .distantPast

        /// Timestamp of the most recent inbound `contentChanged` message -- set
        /// unconditionally at the top of that dispatch (CodeMirrorCoordinator+
        /// MessageDispatch.swift), ahead of `handleContentPush`'s own early-return guards,
        /// so it reflects every real local edit even in cases that guard skips (mid-
        /// contentState transition, the 150ms push grace window, mid-reset). Deliberately
        /// NOT `lastReceivedFromEditor`, which IS skipped in those cases and would
        /// therefore understate how recently the user actually typed. Reset to
        /// `.distantPast` on every `isEditorReady` false->true transition (a freshly
        /// mounted instance has no local edits of its own -- see `shouldPushContent`'s
        /// settle-window guard, undo-mode-switch-focus fix).
        var lastLocalEditAt: Date = .distantPast

        /// P3 (4c/4d, undo-mode-switch-focus second timing gap): the most recent
        /// `contentChanged` message's `wasUndo` flag (sticky-OR across the JS-side 50ms
        /// debounce window -- see main.ts). Captured on every `contentChanged` dispatch;
        /// NOT YET consumed by `SectionSyncService`'s re-correction suppression (§4d) --
        /// that wiring is deferred, see this round's coder report.
        var lastContentChangeWasUndo: Bool = false

        /// Debounced retry timer for a settle-window-suppressed push -- see
        /// `scheduleDeferredRecompute()`.
        var deferredPushTimer: Timer?

        /// Latest `forcedPushGeneration` value seen from the view (set every `updateNSView`
        /// cycle, mirroring `contentGeneration`'s own plumbing). Compared against
        /// `lastHonouredForcedPushGeneration` in `shouldPushContent`.
        var forcedPushGeneration: Int = 0

        /// The `forcedPushGeneration` value last actually honoured (forced a push through,
        /// bypassing the settle-window guard). Generation-scoped, not a sticky boolean --
        /// `updateNSView` runs many times per state change, so a plain flag would leak
        /// across cycles and disable the guard permanently after the first intentional
        /// replacement. Mirrors `lastPollCacheResetGeneration`'s pattern below.
        var lastHonouredForcedPushGeneration: Int = 0

        var lastThemeCss: String = ""
        var lastFocusModeState: Bool = false

        /// Current content state - used to suppress polling during transitions
        var contentState: EditorContentState = .idle

        /// Direct zoom flag passed from view through updateNSView.
        /// Used to control alphaValue hiding and scrollToStart option in setContent().
        /// This bypasses the race condition where contentState may be stale.
        var isZoomingContent: Bool = false

        /// Generation counter for stale poll detection
        var contentGeneration: Int = 0

        // Poll-equality-guard cache -- see applyPollCacheReset() below (declared in an
        // extension so this doesn't count against this class's own body length).
        var lastPolledWordCount: Int?
        var lastPolledCharacterCount: Int?
        var lastPolledSectionTitle: String?
        var lastPolledSectionBlockId: String?
        var lastPollCacheResetGeneration: Int = 0

        var isEditorReady = false
        var isCleanedUp = false
        var toggleObserver: NSObjectProtocol?
        var insertBreakObserver: NSObjectProtocol?
        var annotationDisplayModesObserver: NSObjectProtocol?
        var insertAnnotationObserver: NSObjectProtocol?
        var toggleHighlightObserver: NSObjectProtocol?
        var spellcheckStateObserver: NSObjectProtocol?
        var smartQuotesStateObserver: NSObjectProtocol?
        var proofingModeObserver: NSObjectProtocol?
        var proofingSettingsObserver: NSObjectProtocol?
        var insertFootnoteObserver: NSObjectProtocol?
        var renumberFootnotesObserver: NSObjectProtocol?
        var scrollToFootnoteDefObserver: NSObjectProtocol?
        var zoomFootnoteStateObserver: NSObjectProtocol?
        var insertImageObserver: NSObjectProtocol?
        var insertTableObserver: NSObjectProtocol?
        var insertEquationObserver: NSObjectProtocol?

        // Formatting command observers
        var toggleBoldObserver: NSObjectProtocol?
        var toggleItalicObserver: NSObjectProtocol?
        var toggleStrikethroughObserver: NSObjectProtocol?
        var setHeadingObserver: NSObjectProtocol?
        var toggleBulletListObserver: NSObjectProtocol?
        var toggleNumberListObserver: NSObjectProtocol?
        var toggleBlockquoteObserver: NSObjectProtocol?
        var toggleCodeBlockObserver: NSObjectProtocol?
        var toggleInlineCodeObserver: NSObjectProtocol?
        var insertLinkObserver: NSObjectProtocol?
        var insertCitationObserver: NSObjectProtocol?

        /// Active spellcheck task (cancelled on new check or cleanup)
        var spellcheckTask: Task<Void, Never>?

        /// Last sent annotation display modes (to avoid redundant calls)
        var lastAnnotationDisplayModes: [AnnotationType: AnnotationDisplayMode] = [:]

        /// Pending cursor position that is being restored (set before JS call, cleared after)
        var pendingCursorRestore: CursorPosition?

        /// Callback invoked after content is confirmed set in WebView
        /// Used for acknowledgement-based synchronization during zoom transitions
        var onContentAcknowledged: (() -> Void)?

        /// Callback to provide WebView reference
        var onWebViewReady: ((WKWebView) -> Void)?

        /// Callback wired from ContentView, re-invoking the real `updateSourceContentIfNeeded()`
        /// against the NOW-current `editorState.content`. Called by
        /// `scheduleDeferredRecompute()` when a settle-window-suppressed push's retry timer
        /// fires -- undo-mode-switch-focus fix, must-fix F2 (judge review round): a
        /// settle-window-suppressed push must be RE-DERIVED at retry time, never replayed as
        /// the stale string that was suppressed. See that function's own doc comment.
        var onContentRecompute: (() -> Void)?

        /// P2 (undo-mode-switch-focus second timing gap): backing closure for
        /// CodeMirrorEditor's matching property -- see its doc comment.
        var isReconciliationPending: (() -> Bool)?

        /// When `isReconciliationPending` was FIRST observed true (nil while it's false).
        /// `SectionSyncService.isSyncPending` is a plain Bool with no timestamp of its
        /// own, so `shouldPushContent` tracks this here to apply the 2s hard-cap backstop.
        var reconciliationPendingSince: Date?

        /// M3 (judge-review): whether the LAST call to `shouldPushContent` that returned
        /// `true` was the intentional-replacement (`isForced`) branch, vs. an ordinary
        /// derived push. `setContent` reads this to tell the JS side which classification
        /// this push is (`origin: 'intentional' | 'derived'`) -- JS's own P3 overlap logic
        /// no longer guesses "intentional vs. derived" from anything else. Confirmed failure
        /// case this replaces: zoom-in doesn't remount CodeMirror, so typing right before a
        /// zoom could get the ENTIRE zoom content replacement classified as "overlapping" by
        /// a JS-side-only heuristic, making it wrongly undoable (Cmd-Z would then restore the
        /// un-zoomed document inside the zoomed view).
        var lastPushWasForced: Bool = false

        init(
            content: Binding<String>,
            cursorPositionToRestore: Binding<CursorPosition?>,
            scrollToOffset: Binding<Int?>,
            scrollToAnnotationIndex: Binding<Int?>,
            isResettingContent: Binding<Bool>,
            onContentChange: @escaping (String, Bool) -> Void,
            onStatsChange: @escaping (Int, Int) -> Void,
            onSectionChange: @escaping (String) -> Void,
            onCursorPositionSaved: @escaping (CursorPosition) -> Void,
            onWebViewReady: ((WKWebView) -> Void)?
        ) {
            self.contentBinding = content
            self.cursorPositionToRestoreBinding = cursorPositionToRestore
            self.scrollToOffsetBinding = scrollToOffset
            self.scrollToAnnotationIndexBinding = scrollToAnnotationIndex
            self.isResettingContentBinding = isResettingContent
            self.onContentChange = onContentChange
            self.onStatsChange = onStatsChange
            self.onSectionChange = onSectionChange
            self.onCursorPositionSaved = onCursorPositionSaved
            self.onWebViewReady = onWebViewReady
            super.init()

            subscribeToEditorLifecycleNotifications()
            subscribeToAnnotationNotifications()
            subscribeToProofingNotifications()
            subscribeToFootnoteNotifications()
            subscribeToMediaNotifications()
            subscribeToFormattingCommandNotifications()
        }

        deinit {
            pollingTimer?.invalidate()
            deferredPushTimer?.invalidate()
            if let observer = toggleObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = insertBreakObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = annotationDisplayModesObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = insertAnnotationObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = toggleHighlightObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = spellcheckStateObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = smartQuotesStateObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = proofingModeObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = proofingSettingsObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = insertFootnoteObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = renumberFootnotesObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = scrollToFootnoteDefObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = zoomFootnoteStateObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = insertImageObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = insertTableObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = insertEquationObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            // Formatting command observers cleanup
            for observer in [toggleBoldObserver, toggleItalicObserver, toggleStrikethroughObserver,
                             setHeadingObserver, toggleBulletListObserver, toggleNumberListObserver,
                             toggleBlockquoteObserver, toggleCodeBlockObserver, toggleInlineCodeObserver,
                             insertLinkObserver, insertCitationObserver] {
                if let observer { NotificationCenter.default.removeObserver(observer) }
            }
        }
    }
}

extension CodeMirrorEditor.Coordinator {
    /// Drops the poll-equality-guard cache once `generation` moves past what was last
    /// applied (bumped by `EditorViewState.resetForProjectSwitch()` on project switch/close),
    /// so a poll tick can't compare a real value against one left from the previous project.
    func applyPollCacheReset(generation: Int) {
        guard lastPollCacheResetGeneration != generation else { return }
        lastPollCacheResetGeneration = generation
        lastPolledWordCount = nil
        lastPolledCharacterCount = nil
        lastPolledSectionTitle = nil
        lastPolledSectionBlockId = nil
    }
}
