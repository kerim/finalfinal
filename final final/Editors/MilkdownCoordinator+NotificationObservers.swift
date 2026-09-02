//
//  MilkdownCoordinator+NotificationObservers.swift
//  final final
//
//  NotificationCenter subscription/teardown for MilkdownEditor.Coordinator.
//  Split out of MilkdownEditor.swift's init/deinit to keep the Coordinator's
//  type body length under SwiftLint's limit and to keep the initializer's
//  cyclomatic complexity low — each group below handles one concern.
//

import SwiftUI
import WebKit

extension MilkdownEditor.Coordinator {

    /// Subscribe to all notifications this coordinator cares about.
    /// Called once from `init`, split into per-concern groups below.
    func subscribeToEditorLifecycleNotifications() {
        // Subscribe to toggle notification - save cursor before editor switches
        toggleObserver = NotificationCenter.default.addObserver(
            forName: .willToggleEditorMode,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.saveAndNotify()
        }

        // Subscribe to insert section break notification
        insertBreakObserver = NotificationCenter.default.addObserver(
            forName: .insertSectionBreak,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.insertSectionBreak()
        }

        // Subscribe to editor appearance mode changes (Phase C dual-appearance)
        editorModeObserver = NotificationCenter.default.addObserver(
            forName: .editorAppearanceModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let mode = notification.userInfo?["mode"] as? String {
                self?.setEditorAppearanceMode(mode)
            }
        }
    }

    func subscribeToAnnotationNotifications() {
        // Subscribe to annotation display modes change notification
        annotationDisplayModesObserver = NotificationCenter.default.addObserver(
            forName: .annotationDisplayModesChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let modes = notification.userInfo?["modes"] as? [AnnotationType: AnnotationDisplayMode] {
                let isPanelOnly = notification.userInfo?["isPanelOnly"] as? Bool ?? false
                let hideCompletedTasks = notification.userInfo?["hideCompletedTasks"] as? Bool ?? false
                self?.setAnnotationDisplayModes(modes, isPanelOnly: isPanelOnly, hideCompletedTasks: hideCompletedTasks)
            }
        }

        // Subscribe to insert annotation notification (for keyboard shortcuts)
        insertAnnotationObserver = NotificationCenter.default.addObserver(
            forName: .insertAnnotation,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let type = notification.userInfo?["type"] as? AnnotationType {
                self?.insertAnnotation(type: type)
            }
        }
    }

    func subscribeToCitationNotifications() {
        // Subscribe to citation library updates from Zotero
        citationLibraryObserver = NotificationCenter.default.addObserver(
            forName: .citationLibraryChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let json = notification.userInfo?["json"] as? String {
                self?.setCitationLibrary(json)
            }
        }

        // Subscribe to refresh all citations notification (Cmd+Shift+R)
        refreshAllCitationsObserver = NotificationCenter.default.addObserver(
            forName: .refreshAllCitations,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAllCitations()
            }
        }

        // Subscribe to CSL citation style changes (Export preferences: custom-style toggle
        // or path edited). Always re-pushes the current effective style -- including a
        // revert to bundled -- see pushCitationStyle's doc comment.
        citationStyleObserver = NotificationCenter.default.addObserver(
            forName: .citationStyleChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pushCitationStyle()
        }
    }

    func subscribeToProofingNotifications() {
        // Subscribe to spellcheck toggle
        spellcheckStateObserver = NotificationCenter.default.addObserver(
            forName: .spellcheckStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let enabled = notification.userInfo?["enabled"] as? Bool {
                self?.setSpellcheck(enabled)
            }
        }

        // Subscribe to smart quotes toggle
        smartQuotesStateObserver = NotificationCenter.default.addObserver(
            forName: .smartQuotesStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let enabled = notification.userInfo?["enabled"] as? Bool {
                self?.setSmartQuotes(enabled)
            }
        }

        // Subscribe to proofing mode change (re-check with new mode)
        proofingModeObserver = NotificationCenter.default.addObserver(
            forName: .proofingModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.triggerSpellcheck()
        }

        // Subscribe to proofing settings change (re-check with new settings)
        proofingSettingsObserver = NotificationCenter.default.addObserver(
            forName: .proofingSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.triggerSpellcheck()
        }
    }

    func subscribeToFootnoteNotifications() {
        // Subscribe to footnote definitions updates (push to editor for tooltip display)
        footnoteDefsObserver = NotificationCenter.default.addObserver(
            forName: .footnoteDefinitionsReady,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let defs = notification.userInfo?["definitions"] as? [String: String] {
                self?.setFootnoteDefinitions(defs)
            }
        }

        // Subscribe to insert footnote notification (Cmd+Shift+N)
        insertFootnoteObserver = NotificationCenter.default.addObserver(
            forName: .insertFootnote,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.insertFootnoteAtCursor()
        }

        // Subscribe to renumber footnotes notification
        renumberFootnotesObserver = NotificationCenter.default.addObserver(
            forName: .renumberFootnotes,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let mapping = notification.userInfo?["mapping"] as? [String: String] {
                self?.renumberFootnotes(mapping: mapping)
            }
        }

        // Subscribe to scroll-to-footnote-definition notification.
        // E1/E4: `blockId`, when present, routes Milkdown through the new id-addressed
        // `focusFootnoteDefinition` JS API instead of the pre-existing label-only path -- see
        // `scrollToFootnoteDefinition(label:blockId:)`'s doc comment.
        scrollToFootnoteDefObserver = NotificationCenter.default.addObserver(
            forName: .scrollToFootnoteDefinition,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let label = notification.userInfo?["label"] as? String {
                let blockId = notification.userInfo?["blockId"] as? String
                self?.scrollToFootnoteDefinition(label: label, blockId: blockId)
            }
        }

        // Subscribe to zoom footnote state changes
        zoomFootnoteStateObserver = NotificationCenter.default.addObserver(
            forName: .setZoomFootnoteState,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let zoomed = notification.userInfo?["zoomed"] as? Bool,
               let maxLabel = notification.userInfo?["maxLabel"] as? Int {
                self?.setZoomFootnoteState(zoomed: zoomed, maxLabel: maxLabel)
            }
        }
    }

    func subscribeToBlockSyncNotifications() {
        // Subscribe to BlockSyncService content push — sync lastPushedContent to prevent
        // redundant updateNSView re-push that destroys block IDs.
        // queue: nil → handler fires synchronously on posting thread (MainActor).
        // This ensures lastPushedContent is updated BEFORE the Task body continues,
        // preventing updateNSView from seeing a stale value and re-pushing without block IDs.
        blockSyncPushObserver = NotificationCenter.default.addObserver(
            forName: .blockSyncDidPushContent,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let markdown = notification.userInfo?["markdown"] as? String else { return }
            self?.lastPushedContent = markdown
            self?.lastPushTime = Date()
        }
    }

    func subscribeToFormattingCommandNotifications() {
        // Subscribe to formatting command notifications
        toggleBoldObserver = NotificationCenter.default.addObserver(
            forName: .toggleBold, object: nil, queue: .main
        ) { [weak self] _ in self?.executeFormatting("toggleBold") }

        toggleItalicObserver = NotificationCenter.default.addObserver(
            forName: .toggleItalic, object: nil, queue: .main
        ) { [weak self] _ in self?.executeFormatting("toggleItalic") }

        toggleStrikethroughObserver = NotificationCenter.default.addObserver(
            forName: .toggleStrikethrough, object: nil, queue: .main
        ) { [weak self] _ in self?.executeFormatting("toggleStrikethrough") }

        setHeadingObserver = NotificationCenter.default.addObserver(
            forName: .setHeading, object: nil, queue: .main
        ) { [weak self] notification in
            if let level = notification.userInfo?["level"] as? Int {
                self?.executeFormatting("setHeading", argument: "\(level)")
            }
        }

        toggleBulletListObserver = NotificationCenter.default.addObserver(
            forName: .toggleBulletList, object: nil, queue: .main
        ) { [weak self] _ in self?.executeFormatting("toggleBulletList") }

        toggleNumberListObserver = NotificationCenter.default.addObserver(
            forName: .toggleNumberList, object: nil, queue: .main
        ) { [weak self] _ in self?.executeFormatting("toggleNumberList") }

        toggleBlockquoteObserver = NotificationCenter.default.addObserver(
            forName: .toggleBlockquote, object: nil, queue: .main
        ) { [weak self] _ in self?.executeFormatting("toggleBlockquote") }

        toggleCodeBlockObserver = NotificationCenter.default.addObserver(
            forName: .toggleCodeBlock, object: nil, queue: .main
        ) { [weak self] _ in self?.executeFormatting("toggleCodeBlock") }

        toggleInlineCodeObserver = NotificationCenter.default.addObserver(
            forName: .toggleInlineCode, object: nil, queue: .main
        ) { [weak self] _ in self?.executeFormatting("toggleInlineCode") }

        insertLinkObserver = NotificationCenter.default.addObserver(
            forName: .insertLink, object: nil, queue: .main
        ) { [weak self] _ in self?.executeFormatting("insertLink") }

        // Subscribe to insert citation notification (⌘⇧K / toolbar "Cite" button) —
        // opens the CAYW picker for a brand-new citation at the current cursor.
        insertCitationObserver = NotificationCenter.default.addObserver(
            forName: .insertCitation, object: nil, queue: .main
        ) { [weak self] _ in self?.executeFormatting("insertCitation") }

        // Subscribe to toggle highlight notification (Cmd+Shift+H)
        toggleHighlightObserver = NotificationCenter.default.addObserver(
            forName: .toggleHighlight,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.toggleHighlight()
        }
    }

    func subscribeToMediaNotifications() {
        // Subscribe to insert image notification (Insert > Image menu)
        insertImageObserver = NotificationCenter.default.addObserver(
            forName: .requestInsertImage,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleImagePicker()
        }

        // Subscribe to insert table notification (Insert > Table menu + toolbar button)
        insertTableObserver = NotificationCenter.default.addObserver(
            forName: .requestInsertTable,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isEditorReady, !self.isCleanedUp else { return }
            self.webView?.evaluateJavaScript("window.FinalFinal.insertTable(3, 2)") { _, _ in }
        }

        // Subscribe to insert equation notification (Insert > Equation menu + toolbar button)
        insertEquationObserver = NotificationCenter.default.addObserver(
            forName: .requestInsertEquation,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isEditorReady, !self.isCleanedUp else { return }
            self.webView?.evaluateJavaScript("window.FinalFinal.insertEquationDialog()") { _, _ in }
        }
    }

    /// Mount-flash fix (doc-open-blank-regression follow-up): observes
    /// `.willResetEditorForProjectSwitch`, posted by `ContentView+ProjectLifecycle.swift`'s
    /// `handleProjectOpened()` right before it would otherwise call
    /// `window.FinalFinal.resetForProjectSwitch()` directly.
    ///
    /// `queue: nil` (synchronous delivery, same reasoning as `subscribeToBlockSyncNotifications`'s
    /// `blockSyncPushObserver` above): `beginCloak()` must run, and mint its token, before
    /// `handleProjectOpened()` proceeds past the `post()` call -- a `.main`-queue observer
    /// would defer this to a later runloop tick, breaking that ordering guarantee.
    ///
    /// `object`-filtered against `self.webView`, NOT a bare `object: nil` match: this is a
    /// multi-window app (see `ProjectOpenErrorHost.swift`'s own `activeWebView` cross-window
    /// guard for a parallel concern), and `NotificationCenter.default.post` is global --
    /// without this filter, window A switching projects would also cloak (hide) window B's
    /// completely unrelated, unaffected Milkdown editor whenever both happen to be showing
    /// WYSIWYG mode at the same time.
    func subscribeToProjectResetNotifications() {
        projectResetObserver = NotificationCenter.default.addObserver(
            forName: .willResetEditorForProjectSwitch,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self, notification.object as? WKWebView === self.webView else { return }
            // Must-fix #3 (review round 2): confirm receipt via the handled-marker BEFORE
            // doing anything else, so the poster can detect a miss even if beginProjectResetCloak
            // itself bails early (e.g. its own `guard let webView` -- see that method's doc
            // comment) -- see NotificationHandledMarker's doc comment (EditorViewState+Types.swift).
            (notification.userInfo?["handledMarker"] as? NotificationHandledMarker)?.handled = true
            self.beginProjectResetCloak()
        }
    }

    /// `nonisolated` — safe to call from `deinit` (always nonisolated even on a
    /// `@MainActor` type) because it only touches its own parameter, never any
    /// actor-isolated stored property. The observer-token *properties* themselves
    /// must still be read directly inside `deinit` (see `MilkdownEditor.swift`) —
    /// Swift's isolated-stored-property access exemption applies only to `deinit`
    /// bodies themselves, not to a same-type method `deinit` merely calls.
    nonisolated func removeObserverIfPresent(_ observer: NSObjectProtocol?) {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
