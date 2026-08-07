//
//  CodeMirrorCoordinator+NotificationObservers.swift
//  final final
//
//  NotificationCenter subscription/teardown for CodeMirrorEditor.Coordinator.
//  Split out of CodeMirrorEditor.swift's init/deinit to keep the Coordinator's
//  type body length under SwiftLint's limit and to keep the initializer's
//  cyclomatic complexity low — each group below handles one concern.
//

import SwiftUI
import WebKit

extension CodeMirrorEditor.Coordinator {

    /// Register this coordinator as the `WKScriptMessageHandler` for every JS → Swift
    /// message channel the editor uses. `includeTableInsertTruncated` is `false` on the
    /// preloaded-WebView path and `true` on the fresh-WebView path in `makeNSView` —
    /// that asymmetry is preserved verbatim from the pre-move code, not a new decision
    /// made here.
    func registerMessageHandlers(on controller: WKUserContentController, includeTableInsertTruncated: Bool) {
        controller.add(self, name: "contentChanged")
        controller.add(self, name: "sectionChanged")
        controller.add(self, name: "errorHandler")
        controller.add(self, name: "openCitationPicker")
        controller.add(self, name: "paintComplete")
        controller.add(self, name: "openURL")
        controller.add(self, name: "spellcheck")
        controller.add(self, name: "navigateToFootnote")
        controller.add(self, name: "footnoteInserted")
        controller.add(self, name: "pasteImage")
        controller.add(self, name: "requestImagePicker")
        controller.add(self, name: "updateImageMeta")
        if includeTableInsertTruncated {
            controller.add(self, name: "tableInsertTruncated")
        }
        controller.add(self, name: "openEquationDialog")
        controller.add(self, name: "selectionChanged")
    }

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
    }

    func subscribeToAnnotationNotifications() {
        // Subscribe to annotation display modes changes
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

        // Subscribe to insert annotation notifications (keyboard shortcuts)
        insertAnnotationObserver = NotificationCenter.default.addObserver(
            forName: .insertAnnotation,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let type = notification.userInfo?["type"] as? AnnotationType {
                self?.insertAnnotation(type: type)
            }
        }

        // Subscribe to toggle highlight notification (Cmd+Shift+H)
        toggleHighlightObserver = NotificationCenter.default.addObserver(
            forName: .toggleHighlight,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.toggleHighlight()
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

        // Subscribe to scroll-to-footnote-definition notification
        scrollToFootnoteDefObserver = NotificationCenter.default.addObserver(
            forName: .scrollToFootnoteDefinition,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let label = notification.userInfo?["label"] as? String {
                self?.scrollToFootnoteDefinition(label: label)
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

    func subscribeToMediaNotifications() {
        // Subscribe to insert image notification (Insert > Image menu)
        insertImageObserver = NotificationCenter.default.addObserver(
            forName: .requestInsertImage,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isEditorReady, !self.isCleanedUp else { return }
            self.handleImagePicker()
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

        // Subscribe to insert citation notification (toolbar "Cite" button, or the
        // native Insert > Citation... menu item's ⌘⇧K) — opens the CAYW picker for a
        // brand-new citation at the current cursor. The native menu shortcut now
        // works in Source Mode too (EditorCommands.swift posts .insertCitation, which
        // both editors observe identically).
        insertCitationObserver = NotificationCenter.default.addObserver(
            forName: .insertCitation, object: nil, queue: .main
        ) { [weak self] _ in self?.executeFormatting("insertCitation") }
    }
}
