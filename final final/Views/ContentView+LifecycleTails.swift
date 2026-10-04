//
//  ContentView+LifecycleTails.swift
//  final final
//
//  t-94369a83 Phase 3a-1b, round C5b (slice-3a-1b-everyday.md section 4.4): the TAILS -- what runs after
//  `perform` for a completed close, project switch or create. `LifecycleEntry` calls them through the
//  `LifecycleHost` closures `installLifecycleHost()` installs. Rounds C7a and C8 wired every entry point to
//  `LifecycleEntry.run` (`ProjectCommands`); since round C8b the old `.projectDidOpen` / `.projectDidClose` handlers
//  (`handleProjectOpened`, `performProjectClose`) are gone, the tails are the only way a project is switched, created
//  or closed, and the one close that has no lifecycle (Getting Started) uses `ContentView.closeGettingStartedProject`,
//  which reuses `runCloseTail`.
//
//  What a tail does NOT do is the save: by the time one runs, the save sequence (`runLifecycleFlush`) has already
//  force-sent the editor, written the fresh document through the ordered queue (FB), re-derived the
//  bibliography and footnotes and taken the writer barrier. The tail makes the automatic version of the old
//  project, stops and resets the services, retires the writer (P6) and then closes or opens.
//
//  Round C6 (N3): once a quit has joined, a tail's automatic version follows the quit's rule (`makeTailBackup`).
//
//  N7: after `perform` on a close, `DocumentManager.projectDatabase` is nil. Nothing here reads
//  `DocumentManager` for the CLOSING project: the database, the project and the fallback content all live in the
//  services and the `EditorViewState` this view captured (`autoBackupService` was configured with the database,
//  `editorState` holds the rest). N1: `wasGettingStarted` comes from the token, captured at arm, never from
//  `DocumentManager.isGettingStartedProject`, which already describes the NEW project by now.
//

import SwiftUI

extension ContentView {

    // MARK: - Close tail

    /// The close tail (plan section 4.4, #7, N30), in today's order, which is the order that works:
    ///
    /// 0. `stopObserving()` first, as the old close path (`performProjectClose`) did (it only feeds the outline sidebar);
    /// 1. the automatic version of the closing project (`projectWillClose()`) BEFORE any service reset, unless the
    ///    token says Getting Started was open when the lifecycle was armed (N1). `autoBackupService` keeps its
    ///    database and snapshot service until `reset()`, so a `reset()` run before this would turn the close backup
    ///    into a silent no-op (N30);
    /// 2. the remaining stops and resets, with `autoBackupService.reset()` LAST. `bibliographySyncService.reset()`
    ///    and `footnoteSyncService.reset()` also end the suspension the save sequence put them in at arm. (The
    ///    plan's section 4.4 lists these before the backup; today's close order, which the driver's brief for this
    ///    round restates, is backup first, and the services stay suspended through the backup either way);
    /// 3. a joined quit takes over from here: it owns the writer barrier until the process exits, so nothing below
    ///    runs (no retire, no reset, no `onProjectClosed`);
    /// 4. `retireForLifecycle(.close)`: the writer is retired and the barrier released, retire first (P6);
    /// 5. `resetForProjectSwitch()`, then `onProjectClosed` unless this is E9 (`callOnProjectClosed == false`: the
    ///    app's own view swap to Getting Started follows, and `onProjectClosed` would send it to the picker).
    ///
    /// Also records `lifecycleBackupDoneFor` so a quit that joins this lifecycle does not make a second version.
    @MainActor
    func runCloseTail(token: LifecycleToken, callOnProjectClosed: Bool) async {
        DebugLog.log(.lifecycle, "[LifecycleTail] close tail: token=\(token.id) wasGettingStarted=\(token.wasGettingStarted)")

        // 0. Observation feeds only the outline sidebar; stop it before anything awaits.
        editorState.stopObserving()

        // 1. The automatic version, before any reset (N30), unless Getting Started was open (N1). Once a quit has
        // joined, it follows the quit's rule (N3); when that rule skips it the backup service is left alone so the
        // quit can still make the version (N40).
        var leftForQuit = false
        if !token.wasGettingStarted {
            let backedUp = await makeTailBackup(token: token) { await autoBackupService.projectWillClose() }
            leftForQuit = !backedUp
        }

        // 2. The remaining stops and resets; the backup service's reset last (N30).
        stopContentServicesForLifecycle()
        if !leftForQuit { autoBackupService.reset() }

        // 3. A quit that joined owns everything from here (the barrier is held until exit).
        guard editorState.activeLifecycle?.kind != .quit else {
            DebugLog.log(.lifecycle, "[LifecycleTail] close tail: a quit joined -- standing down before retire (token=\(token.id))")
            return
        }

        // 4. Retire the writer and release the barrier, in that order (P6).
        editorState.retireForLifecycle(reason: .close)

        // 5. Reset the project-specific state; E9 posts nothing back to the picker.
        editorState.resetForProjectSwitch()
        if callOnProjectClosed {
            onProjectClosed?()
        }
    }

    // MARK: - Open tail

    /// The open tail (plan section 4.4) for a completed switch to another regular project: the old project's
    /// automatic version, the service stops, the undo-history invalidation, the writer's retire-then-release, then
    /// the same reconfigure-and-push the old open path (`handleProjectOpened`) ended with. `perform` already opened the new project, so
    /// reading `DocumentManager` for it from here on is right (it is the NEW project's database and id).
    ///
    /// 1. the service stops (the same stops the close tail runs);
    /// 2. `projectWillSwitch()` (the old project's automatic version), then `autoBackupService.reset()` (N30);
    /// 3. a joined quit takes over: stop here (the old project is saved and backed up; the new one is never set up);
    /// 4. `unifiedUndoService.invalidateAll(reason: "project switch")` (#12, N31): the timeline is per-project
    ///    in-memory state. It runs on every completed switch and NEVER on an abort (abort never reaches a tail);
    /// 5. `retireForLifecycle(.projectSwitch)` (P6);
    /// 6. the bibliography-rebuild suppression window opens (the token clears before the new content push settles);
    /// 7. `isResettingContent = true`, the JS-side reset, then `runProjectOpenSequence`;
    /// 8. `reconfigure` runs in BOTH modes (the old writer was retired); only the push and `startPolling` stay
    ///    Rich-Text-only.
    ///
    /// Returns whether the tail ran to the end (`false` when a quit joined), which the create tail reads.
    @MainActor
    @discardableResult
    func runOpenTail(token: LifecycleToken) async -> Bool {
        DebugLog.log(.lifecycle, "[LifecycleTail] open tail: token=\(token.id)")

        // 1-2. Stops, then the old project's automatic version, then its reset.
        editorState.stopObserving()
        stopContentServicesForLifecycle()
        let backedUp = await makeTailBackup(token: token) { await autoBackupService.projectWillSwitch() }
        if backedUp { autoBackupService.reset() }   // N3: skipped for a joined quit -> the quit makes the version

        // 3. A quit that joined owns everything from here.
        guard editorState.activeLifecycle?.kind != .quit else {
            DebugLog.log(.lifecycle, "[LifecycleTail] open tail: a quit joined -- standing down before retire (token=\(token.id))")
            return false
        }

        // 4. The undo timeline belongs to the project that is going away (#12, N31).
        unifiedUndoService.invalidateAll(reason: "project switch")

        // 5. Retire the writer and release the barrier, in that order (P6).
        editorState.retireForLifecycle(reason: .projectSwitch)

        // 6-7. The same window and reset the old open path ran; the flush it did first is now the save sequence.
        editorState.suppressBibliographyRebuildsDuringSwitch = true
        editorState.isResettingContent = true
        resetEditorJavaScriptStateForProjectSwitch()

        // 8. Reset project-specific state, load and publish the new project, reconfigure and push.
        await editorState.runProjectOpenSequence(kind: .projectSwitch, publish: annotationDisplayPublisher) { publishAfterContent in
            await configureAndPushContentAfterProjectSwitch(publishAfterContent: publishAfterContent)
        }
        return true
    }

    // MARK: - Create tail

    /// The create tail (New Project, Import, Save As): the open tail, then today's content seed
    /// (`seedCreatedProjectContent`). The seed needs the new project fully set up, so it is skipped when a quit
    /// joined and the open tail stood down.
    @MainActor
    func runCreateTail(token: LifecycleToken, content: String?) async {
        guard await runOpenTail(token: token) else { return }
        guard let content else { return }
        await Self.seedCreatedProjectContent(
            content,
            editorState: editorState,
            sectionSyncService: sectionSyncService,
            database: documentManager.projectDatabase,
            projectId: documentManager.projectId
        )
    }

    /// Today's `.projectDidCreate` seeding (previously inline in `withFileNotifications`), shared by the legacy
    /// handler and the create tail: put the created project's initial Markdown into the editor state, parse it
    /// into blocks in the NEW project's database, and sync the legacy sections. The callers pass
    /// `DocumentManager`'s database and project id on purpose: the created project is the open one by now.
    @MainActor
    static func seedCreatedProjectContent(
        _ content: String,
        editorState: EditorViewState,
        sectionSyncService: SectionSyncService,
        database: ProjectDatabase?,
        projectId: String?
    ) async {
        editorState.content = content
        // Parse initial content into blocks
        if let db = database,
           let pid = projectId {
            // C5: a brand-new project has no pre-existing Notes heading yet, so
            // this resolves to nil -> the "Notes" default either way -- wired
            // for consistency with every other production `BlockParser.parse`
            // site rather than as a behavior-affecting change here.
            let blocks = BlockParser.parse(
                markdown: content,
                projectId: pid,
                notesHeaderName: try? db.fetchNotesHeadingTitle(projectId: pid)
            )
            try? db.replaceBlocks(blocks, for: pid)
        }
        // Also sync to legacy sections (until fully retired)
        await sectionSyncService.syncNow(content)
    }

    // MARK: - Shared pieces

    /// The tail's automatic version, with N3 applied. Normally just `backup()` followed by recording
    /// `lifecycleBackupDoneFor` (so a quit that joins later does not make a second one) -- unbounded, as it always was.
    ///
    /// Once a quit has JOINED (`editorState.activeLifecycle?.kind == .quit`), the version follows quit's rule: it
    /// starts only if at least `joinedBackupMinimum` (0.5s) of the shared, tightened deadline remains, and is raced
    /// against `min(quitBackupReserve, remaining)`. The deadline is the one in `LifecycleEntry.current`, which the
    /// quit tightened to its own; it falls back to the quit total when this tail runs with no `current` (a test
    /// that calls a tail directly).
    ///
    /// Returns false only when N3 skipped the version: nothing is recorded as done and the caller must NOT reset
    /// the backup service, so the quit's own backup (`LifecycleHost.backupForQuit`, N40: always attempted, the
    /// 5-minute throttle still applies) still can.
    @MainActor
    private func makeTailBackup(token: LifecycleToken, _ backup: @escaping @MainActor () async -> Void) async -> Bool {
        guard editorState.activeLifecycle?.kind == .quit else {
            await backup()
            editorState.lifecycleBackupDoneFor = token.id
            return true
        }
        let bounds = LifecycleEntry.environment.bounds
        let remaining = LifecycleEntry.current?.deadline.remaining ?? bounds.quitTotal
        guard remaining >= bounds.joinedBackupMinimum else {
            DebugLog.alwaysPersisted(
                "[LifecycleTail] token=\(token.id): a quit joined and only \(remaining)s remain -- "
                    + "the tail's automatic version is left to the quit")
            return false
        }
        let bound = min(bounds.quitBackupReserve, remaining)
        _ = await raceAgainstTimeout(.seconds(bound)) { await backup() }
        editorState.lifecycleBackupDoneFor = token.id
        return true
    }

    /// The stops every tail runs after `stopObserving()`, in today's order (the same calls the old open and
    /// close paths, `handleProjectOpened` and `performProjectClose`, made): cancel the pending section and annotation syncs, and reset the
    /// bibliography and footnote services (which also ends the suspension the save sequence put them in).
    /// `autoBackupService.reset()` is NOT here: it must come after the automatic version (N30).
    @MainActor
    private func stopContentServicesForLifecycle() {
        sectionSyncService.cancelPendingSync()
        annotationSyncService.cancelPendingSync()
        bibliographySyncService.reset()
        footnoteSyncService.reset()
    }

    /// Resets the editor's JS-side transient state for a project switch (undo history, CAYW, search, block ids).
    /// Moved here unchanged from the old open path (`handleProjectOpened`); the open tail shares it.
    ///
    /// Milkdown's mount-flash cloak (beginCloak/endCloak, MilkdownCoordinator+CloakOwnership.swift) needs to mint
    /// its `.projectReset` token BEFORE the JS call reaches the WebView, so it can embed that token in the SAME
    /// call -- routing through a notification its Coordinator observes synchronously lets it own both steps
    /// atomically. See .willResetEditorForProjectSwitch's doc comment (EditorViewState+Types.swift). CodeMirror
    /// has no cloak (CodeMirrorCoordinator+MessageDispatch.swift's deliberate-divergence comment) and is
    /// unaffected either way, so Source mode keeps the direct, uncloaked call it always had.
    @MainActor
    func resetEditorJavaScriptStateForProjectSwitch() {
        if editorState.editorMode == .wysiwyg, let webView = findBarState.activeWebView {
            let handledMarker = NotificationHandledMarker()
            NotificationCenter.default.post(
                name: .willResetEditorForProjectSwitch, object: webView,
                userInfo: ["handledMarker": handledMarker]
            )
            // Must-fix #3 (review round 2): a plain post() has no return value -- if this
            // webView doesn't match ANY live Coordinator's own webView (e.g. a stale
            // findBarState.activeWebView left over from a torn-down editor), the notification
            // is silently a no-op AND resetForProjectSwitch() never runs at all: no cloak, and
            // the JS-side reset (undo history, search state, block IDs) never happens either,
            // leaking the previous project's state into the new one with nothing to show for
            // it. Detect the miss and fall back to the direct, uncloaked call so the reset
            // itself still happens even though the mount-flash cloak is skipped this once.
            if !handledMarker.handled {
                DebugLog.log(.lifecycle,
                    "[handleProjectOpened] WARNING: .willResetEditorForProjectSwitch had no matching Coordinator "
                    + "observer -- falling back to direct resetForProjectSwitch() call, mount-flash cloak will be skipped this time")
                webView.evaluateJavaScript("window.FinalFinal.resetForProjectSwitch()") { _, _ in }
            }
        } else {
            findBarState.activeWebView?.evaluateJavaScript(
                "window.FinalFinal.resetForProjectSwitch()"
            ) { _, _ in }
        }
    }
}
