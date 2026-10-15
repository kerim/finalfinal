//
//  MilkdownCoordinator+Core.swift
//  final final
//
//  MilkdownEditor.Coordinator's primary declaration (stored properties, init, deinit, and the
//  poll-equality-guard cache reset). Split out of MilkdownEditor.swift, whose struct body --
//  inclusive of the nested Coordinator class it used to declare -- crossed SwiftLint's 300-line
//  type_body_length warning threshold. Swift extensions can't add stored properties to an
//  *existing* type, but they can declare a brand-new nested type in full, so the whole
//  Coordinator primary declaration (unchanged) lives here instead -- mirrors the same move
//  already made for CodeMirrorEditor.Coordinator (see CodeMirrorCoordinator+Core.swift).
//  Behavior-preserving move only; no logic changed. Coordinator's methods stay split across
//  MilkdownCoordinator+MessageHandlers.swift, MilkdownCoordinator+CloakOwnership.swift,
//  MilkdownCoordinator+Content.swift, MilkdownCoordinator+Images.swift,
//  MilkdownCoordinator+MessageDispatch.swift, and MilkdownCoordinator+NotificationObservers.swift
//  as before.
//

import SwiftUI
import WebKit

extension MilkdownEditor {
    @MainActor
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?

        /// The window this coordinator's editor belongs to (`EditorViewState.windowToken`); its
        /// annotation display observer receives only that window's posts.
        let windowToken: UUID

        var contentBinding: Binding<String>
        var cursorPositionToRestoreBinding: Binding<CursorPosition?>
        var scrollToOffsetBinding: Binding<Int?>
        var scrollToBlockIdBinding: Binding<String?>
        var isResettingContentBinding: Binding<Bool>
        /// P3 §4d: second parameter is `wasUndo` -- see MilkdownEditor's matching property.
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

        /// P3 (4c/4d, undo-mode-switch-focus second timing gap): the most recent
        /// `contentChanged` message's `wasUndo` flag (sticky-OR across the JS-side 50ms
        /// debounce window -- see main.ts). Captured on every `contentChanged` dispatch;
        /// NOT YET consumed by `SectionSyncService`'s re-correction suppression (§4d) --
        /// that wiring is deferred, see this round's coder report.
        var lastContentChangeWasUndo: Bool = false

        var lastFocusModeState: Bool = false
        /// The typewriter config `updateNSView` last asked for. Compared against
        /// `lastTypewriterSent` so an undelivered config is retried.
        var desiredTypewriterConfig = TypewriterConfig()
        /// The config actually DELIVERED to JS; nil until a send succeeds. Recording only on
        /// success is what stops a not-ready-guard rejection from dropping the config.
        var lastTypewriterSent: TypewriterConfig?
        var lastThemeCss: String = ""
        var isEditorReady = false
        var isCleanedUp = false

        /// Fire-once token for `notifyWebViewReadyWhenEditorReady` (MilkdownCoordinator+
        /// MessageHandlers.swift, t-18576cf7): both `didFinish` and `handlePreloadedView` can
        /// call into that gate, and this ensures `onWebViewReady` only ever fires once from
        /// whichever of (success, 3s timeout) reaches it first. `cleanup()` also sets this so
        /// an in-flight poll can never call back into a torn-down coordinator.
        var hasNotifiedWebViewReady = false

        /// The `notifyWebViewReadyWhenEditorReady` readiness probe, overridable so tests can
        /// simulate ready/not-ready without a real WKWebView JS engine round trip -- same seam
        /// CodeMirrorContentPushGuardTests uses elsewhere in this file's sibling coordinator.
        /// Default: the real `window.FinalFinal.isEditorReady()` evaluateJavaScript call.
        var editorReadyProbe: (WKWebView, @escaping (Bool) -> Void) -> Void = { webView, completion in
            webView.evaluateJavaScript("window.FinalFinal.isEditorReady()") { result, _ in
                completion(result as? Bool == true)
            }
        }

        /// Current content state - used to suppress polling during transitions
        var contentState: EditorContentState = .idle

        /// Direct zoom flag passed from view through updateNSView.
        /// Used to control alphaValue hiding and scrollToStart option in setContent().
        /// This bypasses the race condition where contentState may be stale.
        var isZoomingContent: Bool = false

        /// Generation counter for stale poll detection
        var contentGeneration: Int = 0

        /// Last values delivered via pollContent() — guards onStatsChange/
        /// onSectionChange/onSectionIdChange against re-firing (and re-triggering
        /// an @Observable invalidation) when a tick reports the same value as before.
        var lastPolledWordCount: Int?
        var lastPolledCharacterCount: Int?
        var lastPolledSectionTitle: String?
        var lastPolledSectionBlockId: String?

        /// Last `pollCacheResetGeneration` value applied via `resetPollCache()` --
        /// compared against the incoming value in `updateNSView` to detect a fresh
        /// project switch/close exactly once per generation bump.
        var lastPollCacheResetGeneration: Int = 0

        /// Clears the poll-equality-guard cache above. Called from `updateNSView` when
        /// `pollCacheResetGeneration` changes (project switch/close) so a poll tick can't
        /// compare the next real value against a count/section left over from the
        /// previous project.
        func resetPollCache() {
            lastPolledWordCount = nil
            lastPolledCharacterCount = nil
            lastPolledSectionTitle = nil
            lastPolledSectionBlockId = nil
        }

        /// Callback invoked after content is confirmed set in WebView
        /// Used for acknowledgement-based synchronization during zoom transitions
        var onContentAcknowledged: (() -> Void)?

        /// Callback to provide WebView reference
        var onWebViewReady: ((WKWebView) -> Void)?

        var toggleObserver: NSObjectProtocol?
        var insertBreakObserver: NSObjectProtocol?
        var annotationDisplayModesObserver: NSObjectProtocol?
        var insertAnnotationObserver: NSObjectProtocol?
        var toggleHighlightObserver: NSObjectProtocol?
        var citationLibraryObserver: NSObjectProtocol?
        var citationStyleObserver: NSObjectProtocol?
        var refreshAllCitationsObserver: NSObjectProtocol?
        var insertCitationObserver: NSObjectProtocol?
        var editorModeObserver: NSObjectProtocol?
        var spellcheckStateObserver: NSObjectProtocol?
        var smartQuotesStateObserver: NSObjectProtocol?
        var proofingModeObserver: NSObjectProtocol?
        var proofingSettingsObserver: NSObjectProtocol?
        var footnoteDefsObserver: NSObjectProtocol?
        var insertFootnoteObserver: NSObjectProtocol?
        var renumberFootnotesObserver: NSObjectProtocol?
        var scrollToFootnoteDefObserver: NSObjectProtocol?
        var blockSyncPushObserver: NSObjectProtocol?
        var zoomFootnoteStateObserver: NSObjectProtocol?
        var insertImageObserver: NSObjectProtocol?
        var insertTableObserver: NSObjectProtocol?
        var insertEquationObserver: NSObjectProtocol?
        /// Slice 0 measurement (StructuralTrace.swift): follows the Diagnostics toggle, to switch the editor's typing trace.
        var diagnosticsLoggingObserver: NSObjectProtocol?

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

        /// Active spellcheck task (cancelled on new check or cleanup)
        var spellcheckTask: Task<Void, Never>?

        /// Pending cursor position that is being restored (set before JS call, cleared after)
        var pendingCursorRestore: CursorPosition?

        /// The last position `restoreCursorPositionIfNeeded()` actually consumed and applied.
        /// Idempotence guard: the async clear of `cursorPositionToRestoreBinding` (below) opens
        /// a small window where a subsequent content-reset cycle could see the same
        /// not-yet-nilled value and replay it a second time. Compared against on entry; reset in
        /// `saveAndNotify()` so a genuinely-saved-twice identical position still restores.
        var consumedCursorRestore: CursorPosition?

        /// Cancellable handle for the delayed `setCursorPosition` call in
        /// `restoreCursorPositionIfNeeded()`, so a later event (e.g. the footnote's own cursor
        /// placement) can cancel a still-pending stale restore before it fires.
        var cursorRestoreWorkItem: DispatchWorkItem?

        /// Tracks previous isResettingContent state to detect reset→idle transition
        var wasResettingContent = false

        // MARK: - Cloak ownership (mount-flash fix, doc-open-blank-regression follow-up)
        //
        // See beginCloak/endCloak's doc comments (MilkdownCoordinator+MessageHandlers.swift)
        // for the full token-ownership design this closes: reset-release clearing a live zoom
        // cloak, and zoom-release/fallback clearing a live reset cloak. `CloakReason` itself is
        // declared at the MilkdownEditor level (not nested here), to stay within SwiftLint's
        // one-level nesting limit -- still resolves unqualified from Coordinator's own scope.

        /// Monotonic token source for beginCloak()/endCloak(). Never reused within this
        /// Coordinator's lifetime -- each beginCloak() call mints a fresh value.
        var nextCloakToken = 0

        /// Tokens minted by beginCloak() that have not yet been released by endCloak() (via
        /// an explicit release or its own fallback firing). alphaValue is restored to 1 only
        /// once this is EMPTY -- a Set, not a single flag, because multiple reasons (e.g. a
        /// project reset landing mid-zoom) can hold the WebView hidden concurrently.
        var outstandingCloaks: Set<Int> = []

        /// Per-token fallback work items (DispatchQueue.main.asyncAfter -- see beginCloak's
        /// doc comment for why a plain Timer would be unsafe here). Cancelled and removed by
        /// endCloak() on a normal release, or run out and self-remove on timeout.
        var cloakFallbackWorkItems: [Int: DispatchWorkItem] = [:]

        /// Latest token minted for a given reason -- used to resolve a `paintComplete`
        /// message that carries a recognized `reason` but no explicit `token` field. In
        /// practice this is only `.mount`, which can have at most one outstanding cloak per
        /// Coordinator instance; `.zoom` and `.projectReset` each echo back their own real
        /// token instead (see resolveCloakToken's doc comment, MilkdownCoordinator+
        /// MessageHandlers.swift).
        var latestCloakTokenForReason: [CloakReason: Int] = [:]

        /// Observes `.willResetEditorForProjectSwitch` (posted by ContentView+LifecycleTails.swift's
        /// resetEditorJavaScriptStateForProjectSwitch(), called from the open tail, filtered to THIS Coordinator's own
        /// webView -- see subscribeToProjectResetNotifications' doc comment for why a global
        /// notification needs that filter in a multi-window app).
        var projectResetObserver: NSObjectProtocol?

        init(
            content: Binding<String>,
            cursorPositionToRestore: Binding<CursorPosition?>,
            scrollToOffset: Binding<Int?>,
            scrollToBlockId: Binding<String?>,
            isResettingContent: Binding<Bool>,
            contentState: EditorContentState,
            onContentChange: @escaping (String, Bool) -> Void,
            onStatsChange: @escaping (Int, Int) -> Void,
            onSectionChange: @escaping (String) -> Void,
            onCursorPositionSaved: @escaping (CursorPosition) -> Void,
            onContentAcknowledged: (() -> Void)?,
            onWebViewReady: ((WKWebView) -> Void)?, windowToken: UUID
        ) {
            self.windowToken = windowToken
            self.contentBinding = content
            self.cursorPositionToRestoreBinding = cursorPositionToRestore
            self.scrollToOffsetBinding = scrollToOffset
            self.scrollToBlockIdBinding = scrollToBlockId
            self.isResettingContentBinding = isResettingContent
            self.contentState = contentState
            self.onContentChange = onContentChange
            self.onStatsChange = onStatsChange
            self.onSectionChange = onSectionChange
            self.onCursorPositionSaved = onCursorPositionSaved
            self.onContentAcknowledged = onContentAcknowledged
            self.onWebViewReady = onWebViewReady
            super.init()

            // Notification subscriptions are grouped by concern in
            // MilkdownCoordinator+NotificationObservers.swift to keep this
            // initializer's cyclomatic complexity low.
            subscribeToEditorLifecycleNotifications()
            subscribeToAnnotationNotifications()
            subscribeToCitationNotifications()
            subscribeToProofingNotifications()
            subscribeToFootnoteNotifications()
            subscribeToBlockSyncNotifications()
            subscribeToFormattingCommandNotifications()
            subscribeToMediaNotifications()
            subscribeToProjectResetNotifications()
            subscribeToTraceNotifications()
        }

        deinit {
            pollingTimer?.invalidate()

            // Cancel every outstanding cloak fallback (mount-flash fix) -- a torn-down
            // Coordinator must not have a stale DispatchWorkItem fire later and touch
            // properties on an instance nothing else references anymore.
            for (_, workItem) in cloakFallbackWorkItems {
                workItem.cancel()
            }

            // Observer removal must happen directly inside deinit, not via a called-out
            // method: deinit is always nonisolated even on this @MainActor type, and
            // Swift's isolated-stored-property access exemption for deinit applies only
            // to deinit's own body, not to a same-type method deinit merely calls.
            // removeObserverIfPresent (MilkdownCoordinator+NotificationObservers.swift)
            // is safe to call here because it only touches its own parameter.
            removeObserverIfPresent(projectResetObserver)
            removeObserverIfPresent(toggleObserver)
            removeObserverIfPresent(insertBreakObserver)
            removeObserverIfPresent(annotationDisplayModesObserver)
            removeObserverIfPresent(insertAnnotationObserver)
            removeObserverIfPresent(toggleHighlightObserver)
            removeObserverIfPresent(citationLibraryObserver)
            removeObserverIfPresent(citationStyleObserver)
            removeObserverIfPresent(refreshAllCitationsObserver)
            removeObserverIfPresent(editorModeObserver)
            removeObserverIfPresent(spellcheckStateObserver)
            removeObserverIfPresent(smartQuotesStateObserver)
            removeObserverIfPresent(proofingModeObserver)
            removeObserverIfPresent(proofingSettingsObserver)
            removeObserverIfPresent(footnoteDefsObserver)
            removeObserverIfPresent(insertFootnoteObserver)
            removeObserverIfPresent(renumberFootnotesObserver)
            removeObserverIfPresent(scrollToFootnoteDefObserver)
            removeObserverIfPresent(blockSyncPushObserver)
            removeObserverIfPresent(zoomFootnoteStateObserver)
            removeObserverIfPresent(insertImageObserver)
            removeObserverIfPresent(insertTableObserver)
            removeObserverIfPresent(insertEquationObserver)
            removeObserverIfPresent(diagnosticsLoggingObserver)

            // Formatting command observers cleanup
            for observer in [toggleBoldObserver, toggleItalicObserver, toggleStrikethroughObserver,
                             setHeadingObserver, toggleBulletListObserver, toggleNumberListObserver,
                             toggleBlockquoteObserver, toggleCodeBlockObserver, toggleInlineCodeObserver,
                             insertLinkObserver, insertCitationObserver] {
                removeObserverIfPresent(observer)
            }
        }
    }
}
