//
//  ContentView+ProjectLifecycle.swift
//  final final
//
//  Project lifecycle: initialization, configuration, open/close, version history, integrity.
//

import SwiftUI

extension ContentView {
    /// Initialize the project - configure for currently open project
    func initializeProject() async {
        // Check if a project is already open (opened by FinalFinalApp)
        if documentManager.hasOpenProject {
            await configureForCurrentProject()
            return
        }

        // No project open - this shouldn't happen as FinalFinalApp handles launch state
        // but if it does, just wait for a project to be opened
        print("[ContentView] No project open at initialization")
    }

    /// Configure UI for the currently open project
    func configureForCurrentProject() async {
        guard let db = documentManager.projectDatabase,
              let pid = documentManager.projectId,
              let cid = documentManager.contentId else {
            return
        }

        // Configure sync services with database
        sectionSyncService.configure(database: db, projectId: pid)
        annotationSyncService.configure(database: db, contentId: cid)
        bibliographySyncService.configure(database: db, projectId: pid)
        footnoteSyncService.configure(database: db, projectId: pid)
        autoBackupService.configure(database: db, projectId: pid)

        // Inject sectionSyncService reference for zoom sourceContent updates
        editorState.sectionSyncService = sectionSyncService

        // Wire up hierarchy enforcement after sections are updated from database
        // This ensures slash commands that create new headings trigger rebalancing
        editorState.onSectionsUpdated = { [weak editorState, weak sectionSyncService, weak blockSyncService] in
            guard let editorState = editorState,
                  let sectionSyncService = sectionSyncService else { return }

            #if DEBUG
            print("[onSectionsUpdated] contentState=\(editorState.contentState), " +
                "syncSuppressed=\(sectionSyncService.isSyncSuppressed), " +
                "zoomed=\(editorState.zoomedSectionIds != nil), " +
                "hasViolations=\(Self.hasHierarchyViolations(in: editorState.sections))")
            #endif

            // Skip during drag operations (which handle hierarchy separately)
            guard !sectionSyncService.isSyncSuppressed else { return }
            guard editorState.contentState == .idle else { return }

            // Skip hierarchy enforcement while zoomed to prevent feedback loop:
            // User adds headings → DB observation fires → enforcement modifies levels →
            // rebuilds content → content change triggers block reparse → loop.
            // After zoom-out, zoomedSectionIds is nil so enforcement resumes naturally.
            guard editorState.zoomedSectionIds == nil else { return }

            // Check and enforce hierarchy constraints if violations exist
            if Self.hasHierarchyViolations(in: editorState.sections) {
                Task { @MainActor in
                    await Self.enforceHierarchyAsync(
                        editorState: editorState,
                        syncService: sectionSyncService
                    )
                }
            }
        }

        // Check and normalize duplicate sort orders BEFORE starting observation
        do {
            let existingBlocks = try db.fetchBlocks(projectId: pid)
            if !existingBlocks.isEmpty {
                let sortOrders = existingBlocks.map { $0.sortOrder }
                if Set(sortOrders).count < sortOrders.count {
                    #if DEBUG
                    print("[ContentView] Duplicate sortOrders detected (\(sortOrders.count) blocks, \(Set(sortOrders).count) unique). Normalizing...")
                    #endif
                    try db.normalizeSortOrders(projectId: pid)
                }
            }
        } catch {
            print("[ContentView] Error checking/normalizing sort orders: \(error)")
        }

        // Start reactive observation (now uses blocks internally)
        editorState.startObserving(database: db, projectId: pid)
        editorState.startObservingAnnotations(database: db, contentId: cid)

        // Load document goal settings
        if let goalSettings = try? documentManager.loadDocumentGoalSettings() {
            editorState.documentGoal = goalSettings.goal
            editorState.documentGoalType = goalSettings.goalType
            editorState.excludeBibliography = goalSettings.excludeBibliography
        }

        // Load content from blocks (or fall back to legacy content table)
        do {
            // Clean up orphaned footnote definitions from previous sessions before assembling
            try db.write { database in
                try FootnoteSyncService.deleteOrphanedFootnoteDefinitions(db: database, projectId: pid)
            }

            let existingBlocks = try db.fetchBlocks(projectId: pid)

            if !existingBlocks.isEmpty {
                // Blocks exist - assemble markdown from blocks
                editorState.content = BlockParser.assembleMarkdown(from: existingBlocks)
                updateSourceContentIfNeeded()
            } else {
                // No blocks yet - load from legacy content table and parse into blocks
                let savedContent = try documentManager.loadContent()

                if let savedContent = savedContent, !savedContent.isEmpty {
                    let cleanContent = SectionSyncService.stripBibliographyMarker(from: savedContent)
                    editorState.content = cleanContent
                    updateSourceContentIfNeeded()

                    // Parse content into blocks for the new system
                    // Preserve existing section metadata if available
                    let existingSections = try db.fetchSections(projectId: pid)
                    var metadata: [String: SectionMetadata] = [:]
                    for section in existingSections {
                        metadata[section.title] = SectionMetadata(from: section)
                    }

                    let blocks = BlockParser.parse(
                        markdown: cleanContent,
                        projectId: pid,
                        existingSectionMetadata: metadata.isEmpty ? nil : metadata
                    )
                    try db.replaceBlocks(blocks, for: pid)
                } else {
                    editorState.content = ""
                    updateSourceContentIfNeeded()
                }
            }

            // Record initial content hash for Getting Started edit detection
            if documentManager.isGettingStartedProject {
                var attempts = 0
                while attempts < 4 && editorState.content.isEmpty {
                    try? await Task.sleep(for: .milliseconds(150))
                    attempts += 1
                }
                documentManager.recordGettingStartedLoadedContent(editorState.content)
            }
        } catch {
            print("[ContentView] Failed to load content: \(error.localizedDescription)")
        }

        // Connect to Zotero (just verify it's available - search is on-demand)
        Task {
            await connectToZotero()
        }

    }

    /// Connect to Zotero (via Better BibTeX) - just verifies availability
    /// Search happens on-demand via JSON-RPC when user types /cite
    func connectToZotero() async {
        let zotero = ZoteroService.shared

        do {
            try await zotero.connect()
            print("[ContentView] Zotero/BBT is available for citation search")
        } catch {
            print("[ContentView] Zotero connection failed: \(error.localizedDescription)")
            // Silent failure - Zotero is optional dependency
        }
    }

    /// Handle project opened notification
    func handleProjectOpened() async {
        // Stop block polling FIRST — prevents poll timer from firing during
        // the await suspension points in flushAllPendingContent() and writing
        // conflicting data to the database.
        blockSyncService.stopPolling()

        // Flush all pending content to OLD project's database before switching.
        await flushAllPendingContent()

        // Stop remaining services
        editorState.stopObserving()
        blockSyncService.cancelPendingSync()
        sectionSyncService.cancelPendingSync()
        annotationSyncService.cancelPendingSync()
        bibliographySyncService.reset()
        footnoteSyncService.reset()
        autoBackupService.reset()

        // Set flag to prevent polling from overwriting empty content during reset
        editorState.isResettingContent = true

        // REMOVED: isEditorPreloadReady = false — WebView stays alive to avoid blank screen

        // Reset JS-side transient state (undo history, CAYW, search, block IDs)
        findBarState.activeWebView?.evaluateJavaScript(
            "window.FinalFinal.resetForProjectSwitch()"
        ) { _, _ in }

        // Reset all project-specific state (content, sourceContent, zoom, tasks, etc.)
        editorState.resetForProjectSwitch()

        // Configure for new project
        await configureForCurrentProject()

        suppressNextBibliographyRebuild = true

        // Reconfigure BlockSyncService with new DB (weak WebView ref still valid)
        if editorState.editorMode == .wysiwyg,
           let db = documentManager.projectDatabase,
           let pid = documentManager.projectId {
            blockSyncService.reconfigure(database: db, projectId: pid)
            Task {
                if let result = fetchBlocksWithIds() {
                    // Sync editorState.content to prevent polling from overwriting the atomic push
                    editorState.content = result.markdown
                    updateSourceContentIfNeeded()
                    await blockSyncService.setContentWithBlockIds(
                        markdown: result.markdown, blockIds: result.blockIds)
                }
                editorState.isResettingContent = false
                blockSyncService.startPolling()
                // Scroll to top after content push settles
                try? await Task.sleep(for: .milliseconds(100))
                findBarState.activeWebView?.evaluateJavaScript(
                    "window.scrollTo({top: 0, behavior: 'instant'})"
                ) { _, _ in }
            }
            // Watchdog: ensure isResettingContent is cleared even if JS call hangs
            Task {
                try? await Task.sleep(for: .seconds(3))
                if editorState.isResettingContent {
                    print("[handleProjectOpened] WATCHDOG: isResettingContent stuck, forcing clear")
                    editorState.isResettingContent = false
                }
            }
        } else {
            editorState.isResettingContent = false
        }
    }

    /// Handle project closed notification
    func handleProjectClosed() {
        // Check if this is the Getting Started project with modifications
        if documentManager.isGettingStartedProject && documentManager.isGettingStartedModified() {
            showGettingStartedCloseAlert = true
            return
        }

        performProjectClose()
    }

    /// Actually close the project and reset state
    func performProjectClose() {
        // Flush pending content synchronously before closing.
        // editorState.content is current (JS 50ms debounce has fired by button click time).
        editorState.flushContentToDatabase()

        // Create auto-backup before closing if there are unsaved changes (not for Getting Started)
        if !documentManager.isGettingStartedProject {
            Task {
                await autoBackupService.projectWillClose()
            }
        }

        // Stop observation and services FIRST to prevent any further syncs
        editorState.stopObserving()
        blockSyncService.stopPolling()
        blockSyncService.cancelPendingSync()
        sectionSyncService.cancelPendingSync()
        annotationSyncService.cancelPendingSync()
        bibliographySyncService.reset()
        footnoteSyncService.reset()
        autoBackupService.reset()

        // Reset all project-specific state (content, sourceContent, zoom, tasks, etc.)
        editorState.resetForProjectSwitch()

        // Notify parent to show picker
        onProjectClosed?()
    }

    /// Handle "Create New Project" from Getting Started close alert
    func handleCreateFromGettingStarted() {
        // Get current content before closing
        let currentContent = (try? documentManager.getCurrentContent()) ?? ""

        let savePanel = NSSavePanel()
        savePanel.title = "Save Your Work"
        savePanel.nameFieldLabel = "Project Name:"
        savePanel.nameFieldStringValue = "Untitled"
        savePanel.allowedContentTypes = [.init(exportedAs: "com.kerim.final-final.document")]
        savePanel.canCreateDirectories = true

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            Task { @MainActor in
                do {
                    let title = url.deletingPathExtension().lastPathComponent
                    try self.documentManager.newProject(at: url, title: title, initialContent: currentContent)
                    // No need to call onProjectOpened - we're replacing the current project
                    await self.handleProjectOpened()
                } catch {
                    print("[ContentView] Failed to create project from Getting Started: \(error)")
                }
            }
        }
    }

    // MARK: - Version History Handlers

    /// Handle save version command (Cmd+Shift+S)
    func handleSaveVersion() async {
        guard let db = documentManager.projectDatabase,
              let pid = documentManager.projectId else {
            print("[ContentView] Cannot save version: no project open")
            return
        }

        let name = saveVersionName.isEmpty ? nil : saveVersionName
        let service = SnapshotService(database: db, projectId: pid)

        do {
            if let versionName = name {
                let snapshot = try service.createManualSnapshot(name: versionName)
                print("[ContentView] Created manual snapshot: \(snapshot.displayName)")
            } else {
                let snapshot = try service.createAutoSnapshot()
                print("[ContentView] Created auto snapshot: \(snapshot.id)")
            }
        } catch {
            print("[ContentView] Failed to create snapshot: \(error)")
        }

        saveVersionName = ""
    }

    // MARK: - Integrity Alert Handlers

    /// Handle repair action from integrity alert
    /// Loops until all repairable issues are fixed or an unrepairable issue is encountered
    func handleRepair(report: IntegrityReport) async {
        guard let url = pendingProjectURL else { return }

        var currentReport = report
        var repairAttempts = 0
        let maxRepairAttempts = 5  // Prevent infinite loops

        do {
            // Loop to repair all issues (some repairs reveal new issues)
            while currentReport.canAutoRepair && repairAttempts < maxRepairAttempts {
                repairAttempts += 1
                print("[ContentView] Repair attempt \(repairAttempts) for \(currentReport.issues.count) issue(s)")

                let result = try documentManager.repairProject(report: currentReport)
                print("[ContentView] Repair result: \(result.message)")

                guard result.success else {
                    // Repair failed - keep showing the alert with failure info
                    print("[ContentView] Repair failed for issues: \(result.failedIssues.map { $0.description })")
                    return
                }

                // Re-validate after repair to check for remaining/new issues
                currentReport = try documentManager.checkIntegrity(at: url)

                if currentReport.isHealthy {
                    break
                }
                // Loop continues if there are more repairable issues
            }

            if currentReport.isHealthy {
                try documentManager.openProject(at: url)
                await configureForCurrentProject()
                pendingProjectURL = nil
                integrityReport = nil
            } else if !currentReport.hasCriticalIssues {
                // Non-critical, non-repairable issues remain - force open with warning
                print("[ContentView] Opening with non-critical issues: \(currentReport.issues.map { $0.description })")
                try documentManager.forceOpenProject(at: url)
                await configureForCurrentProject()
                pendingProjectURL = nil
                integrityReport = nil
            } else {
                // Critical unrepairable issues remain - show updated alert
                integrityReport = currentReport
            }
        } catch {
            print("[ContentView] Repair failed: \(error.localizedDescription)")
            // Keep alert showing so user can cancel
        }
    }

    /// Handle "open anyway" action from integrity alert (unsafe)
    func handleOpenAnyway(report: IntegrityReport) async {
        guard let url = pendingProjectURL else { return }

        print("[ContentView] Opening project despite integrity issues (user chose unsafe)")
        for issue in report.issues {
            print("[ContentView] Warning: \(issue.description)")
        }

        do {
            try documentManager.forceOpenProject(at: url)
            await configureForCurrentProject()
        } catch {
            print("[ContentView] Failed to force-open project: \(error.localizedDescription)")
        }

        pendingProjectURL = nil
        integrityReport = nil
    }

    /// Handle cancel action from integrity alert
    func handleIntegrityCancel() {
        pendingProjectURL = nil
        // Could optionally open demo project or show welcome state
    }

    // MARK: - Content Flush Helpers

    /// Fetch latest content directly from WebView, bypassing JS 50ms debounce.
    /// Returns nil if WebView is unavailable, JS call fails, or 2s timeout elapses.
    private func fetchContentFromWebView() async -> String? {
        guard let webView = findBarState.activeWebView else { return nil }
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    webView.evaluateJavaScript("window.FinalFinal.getContent()") { result, error in
                        #if DEBUG
                        if let error { print("[ContentView] fetchContentFromWebView JS error: \(error)") }
                        #endif
                        continuation.resume(returning: result as? String)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Flush all pending content to DB before project switch/close.
    /// Must be called BEFORE resetForProjectSwitch() which clears editorState.content.
    private func flushAllPendingContent() async {
        // 1. Fetch fresh content from WebView (catches edits within JS 50ms debounce)
        if let freshContent = await fetchContentFromWebView(), !freshContent.isEmpty {
            editorState.content = freshContent
        }
        guard !editorState.content.isEmpty else { return }

        // 2. Flush blocks to DB (synchronous — re-parses content into blocks and writes)
        editorState.flushContentToDatabase()

        // 3. Flush section metadata (immediate write, bypasses 500ms debounce)
        await sectionSyncService.syncNow(editorState.content)

        // 4. Flush annotation positions
        await annotationSyncService.syncNow(editorState.content)

        #if DEBUG
        print("[ContentView] flushAllPendingContent completed")
        #endif
    }
}
