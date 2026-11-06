//
//  MilkdownEditor.swift
//  final final
//
//  WKWebView wrapper for Milkdown WYSIWYG editor.
//  Uses 500ms polling pattern for content synchronization.
//

import SwiftUI
import WebKit

// Shared configuration for localStorage persistence across editor toggles
private let sharedDataStore = WKWebsiteDataStore.default()

/// Captures uncaught JS errors/unhandled rejections and forwards them to the
/// native `errorHandler` message handler. Only ever needed for `MilkdownEditor`'s
/// fresh-view path in `makeNSView` — the preloaded view already has it installed.
private let errorCaptureScript = WKUserScript(
    source: """
        window.onerror = function(msg, url, line, col, error) {
            window.webkit.messageHandlers.errorHandler.postMessage({
                type: 'error',
                message: msg,
                url: url,
                line: line,
                column: col,
                error: error ? error.toString() : null
            });
            return false;
        };
        window.addEventListener('unhandledrejection', function(e) {
            window.webkit.messageHandlers.errorHandler.postMessage({
                type: 'unhandledrejection',
                message: 'Unhandled Promise Rejection: ' + e.reason,
                url: '',
                line: 0,
                column: 0,
                error: e.reason ? e.reason.toString() : null
            });
        });
        console.log('[ErrorHandler] JS error capture installed');
    """,
    injectionTime: .atDocumentStart,
    forMainFrameOnly: true
)

/// The JS→native message handler names both the preloaded-view and fresh-view
/// paths in `MilkdownEditor.makeNSView` register identically — factored out to
/// avoid keeping two copies of this list in sync by hand.
private func registerMilkdownMessageHandlers(on controller: WKUserContentController, coordinator: MilkdownEditor.Coordinator) {
    controller.add(coordinator, name: "contentChanged")
    controller.add(coordinator, name: "sectionChanged")
    controller.add(coordinator, name: "errorHandler")
    controller.add(coordinator, name: "openCitationPicker")
    controller.add(coordinator, name: "resolveCitekeys")
    controller.add(coordinator, name: "paintComplete")
    controller.add(coordinator, name: "openURL")
    controller.add(coordinator, name: "zoomHeadingClicked")
    controller.add(coordinator, name: "spellcheck")
    controller.add(coordinator, name: "navigateToFootnote")
    controller.add(coordinator, name: "footnoteInserted")
    controller.add(coordinator, name: "pasteImage")
    controller.add(coordinator, name: "requestImagePicker")
    controller.add(coordinator, name: "updateImageMeta")
    controller.add(coordinator, name: "tableInsertTruncated")
    controller.add(coordinator, name: "openEquationDialog")
    controller.add(coordinator, name: "selectionChanged")
    // Unified-undo bridge (docs/architecture/unified-undo.md's registry/descriptor bridge
    // protocol section) -- Phase 3.
    controller.add(coordinator, name: "structuralUndoRequested")
    controller.add(coordinator, name: "structuralRedoRequested")
    controller.add(coordinator, name: "historyEdited")
    controller.add(coordinator, name: "structuralUndoRefused")
    // A Cmd-Z / Cmd-Shift-Z the editor held in its own queue ended without a request to Swift (fix round 5, close "allowance").
    controller.add(coordinator, name: "undoHeldPressSettled")
    // Esc-ladder bridge (UX contract §6) -- see EscapeLadder.swift.
    controller.add(coordinator, name: "escapeLadder")
    controller.add(coordinator, name: "escapeComposition")
    controller.add(coordinator, name: "escapeWebPopupOpen")
    // Typing-latency trace (slice 0 measurement, StructuralTrace.swift): posted only while the editor's trace flag is on.
    controller.add(coordinator, name: "typingEcho")
    controller.add(coordinator, name: "typingTrace")
    // Editor-first section delete (t-94369a83 Phase 4b slice 2a): the undo coordinator's 30 s safety net dropped queued presses
    // (addendum A4), and the first frame after the removal was painted (slice-0 trace, posted only while the trace flag is on).
    controller.add(coordinator, name: "undoQueueDropped")
    controller.add(coordinator, name: "efRemovalPainted")
}

struct MilkdownEditor: NSViewRepresentable {
    // Reasons a cloak (webView.alphaValue = 0, hiding the WebView) can be outstanding.
    // Declared here (one level of nesting inside MilkdownEditor) rather than inside
    // Coordinator, since SwiftLint caps nested types at one level deep; Coordinator's own
    // methods still resolve `CloakReason` unqualified since it's nested inside their
    // enclosing type.
    enum CloakReason {
        case zoom
        case mount
        case projectReset
    }

    @Binding var content: String
    @Binding var focusModeEnabled: Bool
    /// `focusMode && typewriterScrollingEnabled`, computed once in
    /// `ContentView+EditorPresentation.editorView`'s body so that body subscribes to the
    /// observed settings store. Plain stored values, compared against the coordinator's
    /// `lastTypewriter*` fields so the idempotent JS call is sent only on a real change.
    var typewriterEnabled: Bool = false
    var typewriterLineOffset: Int = 0
    @Binding var cursorPositionToRestore: CursorPosition?
    @Binding var scrollToOffset: Int?
    @Binding var scrollToBlockId: String?
    @Binding var scrollToAnnotationIndex: Int?
    @Binding var isResettingContent: Bool

    /// Content state for suppressing polling during transitions (zoom, hierarchy enforcement)
    var contentState: EditorContentState = .idle

    /// Direct zoom flag passed through SwiftUI view hierarchy to bypass coordinator state race condition.
    /// When true, setContent() will hide the WebView and use scrollToStart option.
    var isZoomingContent: Bool = false

    /// Generation counter for stale poll detection
    var contentGeneration: Int = 0

    /// Bumped by `EditorViewState.resetForProjectSwitch()` on every project switch/close.
    /// `updateNSView` compares this against the Coordinator's last-seen value and, on
    /// change, clears the Coordinator's `lastPolled*` equality-guard caches -- see
    /// `EditorViewState.pollCacheResetGeneration`'s doc comment for why.
    var pollCacheResetGeneration: Int = 0

    /// `EditorViewState.windowToken` of the window this editor belongs to. REQUIRED (no default):
    /// handed to the Coordinator so it receives only its own window's annotation display posts
    /// (see `AnnotationDisplayBroadcast`); a creation site that omits it does not compile.
    var windowToken: UUID

    /// CSS variables for theming - when this changes, updateNSView is called
    var themeCSS: String = ThemeManager.shared.cssVariables

    /// P3 §4d (undo-mode-switch-focus second timing gap): second parameter is `wasUndo` --
    /// true if the content push that produced this string was (or included, sticky-OR) an
    /// undo replay. Mirrors CodeMirrorEditor's matching property.
    let onContentChange: (String, Bool) -> Void
    let onStatsChange: (Int, Int) -> Void
    let onSectionChange: (String) -> Void
    let onCursorPositionSaved: (CursorPosition) -> Void

    /// Callback for block-ID-based section tracking (blockId, title)
    var onSectionIdChange: ((String?, String) -> Void)?

    /// Callback for selection changes (selected text; empty = deselected).
    /// Drives the status-bar selection word count.
    var onSelectionChange: ((String) -> Void)?

    /// Callback invoked when editor confirms content was set
    /// Used for acknowledgement-based sync during zoom transitions
    var onContentAcknowledged: (() -> Void)?

    /// Callback to provide the WebView reference (for find operations)
    var onWebViewReady: ((WKWebView) -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        // Phase 5 job A10: the page a switch to Rich Text filled before the flip (EditorPreloader+Prepare.swift). Its editor is mounted and
        // holds its text, so there is no mount cloak and no content handover (`handlePreparedSwitchPage`).
        if let staged = EditorPreloader.shared.claimStagedMilkdownPage() {
            registerMilkdownMessageHandlers(on: staged.webView.configuration.userContentController, coordinator: context.coordinator)
            staged.webView.navigationDelegate = context.coordinator
            context.coordinator.webView = staged.webView
            context.coordinator.handlePreparedSwitchPage(content: staged.content)
            #if DEBUG
            staged.webView.isInspectable = true
            #endif
            DebugLog.log(.sync, "[MilkdownEditor] Using the page the switch prepared")
            return staged.webView
        }

        // Try to use preloaded WebView for faster startup
        if let preloaded = EditorPreloader.shared.claimMilkdownView() {
            // Re-register message handlers with this coordinator
            registerMilkdownMessageHandlers(on: preloaded.configuration.userContentController, coordinator: context.coordinator)

            preloaded.navigationDelegate = context.coordinator
            context.coordinator.webView = preloaded

            // Mount-flash fix (redesign after review round): a claimed preloaded view's
            // page load finished during preload, but that says nothing about whether
            // main.ts's async initEditor() -> Editor.make().create() -- and the internal
            // container-swap teardown/rebuild dance inside it -- has ALSO finished (see
            // notifyWebViewReadyWhenEditorReady's doc comment two files over for why those
            // are two different moments). That dance may already be done (harmless, it ran
            // off-screen) or may still be in flight, in which case it would otherwise finish
            // visibly right here, the instant this view attaches. Cloak unconditionally and
            // let pollMountCloakReleaseForClaimedView's isEditorReady() poll release it the
            // moment mount is actually confirmed -- see that method's doc comment
            // (MilkdownCoordinator+MessageHandlers.swift) for why paintComplete's own
            // auto-fire (fresh-WebView branch, below) cannot be relied on for this branch.
            let mountCloakToken = context.coordinator.beginCloak(.mount)
            context.coordinator.pollMountCloakReleaseForClaimedView(token: mountCloakToken)

            // Handle the preloaded view (navigation already finished)
            context.coordinator.handlePreloadedView()

            #if DEBUG
            preloaded.isInspectable = true
            #endif
            DebugLog.log(.sync, "[MilkdownEditor] Using preloaded WebView")

            return preloaded
        }

        // Fallback: create new WebView (preload wasn't ready)
        DebugLog.log(.sync, "[MilkdownEditor] Creating new WebView (preload not ready)")

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = sharedDataStore  // Persist localStorage across editor toggles
        configuration.setURLSchemeHandler(EditorSchemeHandler(), forURLScheme: "editor")
        configuration.setURLSchemeHandler(MediaSchemeHandler.shared, forURLScheme: "projectmedia")

        // === PHASE 4: Add error handler script to capture JS errors ===
        configuration.userContentController.addUserScript(errorCaptureScript)
        registerMilkdownMessageHandlers(on: configuration.userContentController, coordinator: context.coordinator)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator

        #if DEBUG
        webView.isInspectable = true
        #endif

        context.coordinator.webView = webView

        // Mount-flash fix (doc-open-blank-regression follow-up): hide the WebView until
        // main.ts's initEditor() signals paint-complete after Milkdown's own internal
        // container-swap teardown/rebuild dance has settled -- see beginCloak/endCloak's
        // doc comments (MilkdownCoordinator+MessageHandlers.swift). This branch's release
        // signal is initEditor()'s own one-shot paintComplete post: registerMilkdownMessageHandlers
        // above (which wires up "paintComplete") always runs before webView.load() below, so
        // that handler is guaranteed to exist by the time initEditor() ever gets a chance to
        // post to it -- unlike the claimed-preloaded branch above, which needs the separate
        // isEditorReady()-poll release mechanism (see that branch's own comment) because its
        // mount work runs during preload, before ANY handler -- or coordinator -- exists yet.
        context.coordinator.beginCloak(.mount)

        if let url = URL(string: "editor://milkdown/milkdown.html") {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Update content state, zoom flag, generation, and callbacks for coordinator
        // IMPORTANT: isZoomingContent must be set BEFORE content check to avoid race condition
        context.coordinator.isZoomingContent = isZoomingContent
        context.coordinator.contentState = contentState
        context.coordinator.contentGeneration = contentGeneration
        context.coordinator.onContentAcknowledged = onContentAcknowledged
        context.coordinator.onSectionIdChange = onSectionIdChange
        context.coordinator.onSelectionChange = onSelectionChange

        // Project switch/close just ran -- drop the poll-equality-guard cache so the
        // next poll tick can't be suppressed by a value cached from the old project.
        if context.coordinator.lastPollCacheResetGeneration != pollCacheResetGeneration {
            context.coordinator.lastPollCacheResetGeneration = pollCacheResetGeneration
            context.coordinator.resetPollCache()
        }

        let effectiveFocusMode = focusModeEnabled && FocusModeSettingsManager.shared.enableParagraphHighlighting
        if context.coordinator.lastFocusModeState != effectiveFocusMode {
            context.coordinator.lastFocusModeState = effectiveFocusMode
            context.coordinator.setFocusMode(effectiveFocusMode)
        }

        // Typewriter scrolling: record the DESIRED config here; the send happens below the
        // project-reset guard (and again from the ready-flip hook), so a send attempted
        // mid-reset, or one the not-ready guard rejects, is never recorded as delivered.
        context.coordinator.desiredTypewriterConfig = TypewriterConfig(
            enabled: typewriterEnabled,
            lineOffset: typewriterLineOffset
        )

        // Track reset state for transition detection
        let wasResetting = context.coordinator.wasResettingContent
        context.coordinator.wasResettingContent = isResettingContent

        // Skip content/theme pushes during project reset to prevent empty flash
        guard !isResettingContent else {
            return
        }

        // The config is sent AFTER the reset guard, so a send attempted mid-reset is not
        // recorded as delivered and is retried on the next cycle or on the ready flip.
        context.coordinator.pushTypewriterConfigIfNeeded()

        // If we just finished a content reset (e.g. after setContentWithBlockIds),
        // restore cursor position that was preserved during batchInitialize
        if wasResetting {
            context.coordinator.restoreCursorPositionIfNeeded()
        }

        // Theme FIRST — CSS variables must be set before content renders
        // (matches batchInitialize() order: setTheme → setContent)
        if context.coordinator.lastThemeCss != themeCSS {
            context.coordinator.lastThemeCss = themeCSS
            context.coordinator.setTheme(themeCSS)
        }

        if context.coordinator.shouldPushContent(content) {
            DebugLog.log(.sync, "[SYNC-DIAG:UpdateNSView] PUSHING content len=\(content.count) hasFigures=\(content.contains("!["))")
            context.coordinator.setContent(content)
        }

        // Handle scroll-to-offset requests from sidebar
        if let offset = scrollToOffset {
            context.coordinator.scrollToOffset(offset)
            DebugLog.log(.reentrancy, "[MilkdownEditor] updateNSView scheduling deferred nil-write: scrollToOffset (was \(offset))")
            DispatchQueue.main.async {
                DebugLog.log(.reentrancy, "[MilkdownEditor] deferred write firing: scrollToOffset = nil")
                self.scrollToOffset = nil
            }
        }

        // Handle block-ID-based scroll requests (used for sections when images are present)
        if let blockId = scrollToBlockId {
            context.coordinator.scrollToBlock(blockId)
            DebugLog.log(.reentrancy, "[MilkdownEditor] updateNSView scheduling deferred nil-write: scrollToBlockId (was \(blockId))")
            DispatchQueue.main.async {
                DebugLog.log(.reentrancy, "[MilkdownEditor] deferred write firing: scrollToBlockId = nil")
                self.scrollToBlockId = nil
            }
        }

        // Handle annotation-specific scroll requests (uses ordinal index, not charOffset)
        if let index = scrollToAnnotationIndex {
            context.coordinator.scrollToAnnotation(index: index)
            DebugLog.log(.reentrancy, "[MilkdownEditor] updateNSView scheduling deferred nil-write: scrollToAnnotationIndex (was \(index))")
            DispatchQueue.main.async {
                DebugLog.log(.reentrancy, "[MilkdownEditor] deferred write firing: scrollToAnnotationIndex = nil")
                self.scrollToAnnotationIndex = nil
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            content: $content,
            cursorPositionToRestore: $cursorPositionToRestore,
            scrollToOffset: $scrollToOffset,
            scrollToBlockId: $scrollToBlockId,
            isResettingContent: $isResettingContent,
            contentState: contentState,
            onContentChange: onContentChange,
            onStatsChange: onStatsChange,
            onSectionChange: onSectionChange,
            onCursorPositionSaved: onCursorPositionSaved,
            onContentAcknowledged: onContentAcknowledged, onWebViewReady: onWebViewReady, windowToken: windowToken
        )
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        // Only save cursor if not already saved by Phase 1 toggle flow. Phase 5 jobs A9/A10: never for the page a carried switch replaced
        // (the incoming page already has its caret; a caret saved here would be restored over the user's at the next content reset).
        let carriedSwitch = EditorPreloader.shared.consumeOutgoingCursorSaveSuppression()
        if !carriedSwitch, coordinator.cursorPositionToRestoreBinding.wrappedValue == nil {
            coordinator.saveCursorPositionBeforeCleanup()
        }
        coordinator.cleanup()
    }

    // Coordinator's primary declaration (stored properties, init, deinit) lives in
    // MilkdownCoordinator+Core.swift, moved there to keep this struct's body under
    // SwiftLint's type_body_length limit -- mirrors the same move already made for
    // CodeMirrorEditor.Coordinator (see CodeMirrorCoordinator+Core.swift). Coordinator's
    // methods stay split across MilkdownCoordinator+MessageHandlers.swift,
    // MilkdownCoordinator+CloakOwnership.swift, MilkdownCoordinator+Content.swift,
    // MilkdownCoordinator+Images.swift, MilkdownCoordinator+MessageDispatch.swift, and
    // MilkdownCoordinator+NotificationObservers.swift as before.
}
