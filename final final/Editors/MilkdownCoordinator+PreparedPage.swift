//
//  MilkdownCoordinator+PreparedPage.swift
//  final final
//
//  Phase 5 job A10 (design a7-a10-design.md, section 4; run record a9-notes.md): the mount of a Rich Text page a switch to Rich Text
//  filled before the flip (EditorPreloader+Prepare.swift, EditorViewState+SwitchTransition.swift). As `handlePreloadedView`, minus what the
//  switch already did on the detached page: the editor is mounted (no mount cloak, no editor-ready poll) and holds its text with its block
//  ids (no `batchInitialize` content, no citation style or library push, no `setContentWithBlockIds` from `onWebViewReady`:
//  `EditorViewState.transitionHolds` tells that closure the page is prepared).
//

import WebKit

extension MilkdownEditor.Coordinator {
    func handlePreparedSwitchPage(content: String) {
        isEditorReady = true
        applyPersistedToggleStates()
        lastPushedContent = content
        lastPushTime = Date()
        // The line today's handover writes (BlockSyncService.setContentWithBlockIds); the real-app tests wait for it as "the Rich Text page
        // has its text".
        DebugLog.log(.sync, "[BlockSyncService] Set content with block IDs atomically (prepared page, len=\(content.count))")
        startPolling()
        // The citation style and library were given to the page before its text, on the detached page (as today's mount gives them
        // before its content push); not again here, where a second library push would re-render every citation after the flip.
        // The caret was put in on the detached page. The saved caret stays set until the switch has ended (the switch clears it): while it
        // is set, the outgoing page's `dismantleNSView` does not save its own caret into it, which a later content reset (a zoom) would then
        // restore over the user's caret.
        // The saved caret counts as consumed (`restoreCursorPositionIfNeeded`'s idempotence guard): a later content reset (a zoom's) must
        // not restore it. The switch also clears the binding when it ends.
        consumedCursorRestore = cursorPositionToRestoreBinding.wrappedValue
        DebugLog.alwaysPersisted(
            "[TRANS] prepared Rich Text mount: saved caret marked consumed (\(consumedCursorRestore.map { "\($0.line):\($0.column)" } ?? "none"))")
        hasNotifiedWebViewReady = true
        if let webView { onWebViewReady?(webView) }
    }
}
