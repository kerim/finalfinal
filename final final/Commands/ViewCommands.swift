//
//  ViewCommands.swift
//  final final
//

import SwiftUI

struct ViewCommands: Commands {
    @FocusedValue(\.editorState) var editorState

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()

            Button(outlineToggleLabel) {
                NotificationCenter.default.post(name: .toggleOutlineSidebar, object: nil)
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(editorState == nil)

            Button(annotationsToggleLabel) {
                NotificationCenter.default.post(name: .toggleAnnotationSidebar, object: nil)
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(editorState == nil)

            Divider()

            Button("Toggle Focus Mode") {
                NotificationCenter.default.post(name: .toggleFocusMode, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Button(editorModeToggleLabel) {
                editorState?.requestEditorModeToggle()
            }
            .keyboardShortcut("/", modifiers: .command)
            .disabled(editorState == nil)

            Divider()

            Button("Refresh Citations") {
                NotificationCenter.default.post(name: .refreshAllCitations, object: nil)
            }

            Divider()

            Menu("Theme") {
                ForEach(AppColorScheme.all) { theme in
                    Button(theme.name) {
                        ThemeManager.shared.setThemeAndClearOverrides(byId: theme.id)
                    }
                }
            }
        }
    }

    /// "Hide Outline" when the sidebar is currently visible, "Show Outline" otherwise --
    /// the HIG-correct reading of the UX contract's "Show/Hide Outline" shorthand (§5), not a
    /// literal static string with a slash in it. Tracks every way visibility can change --
    /// the menu action itself, dragging the sidebar closed via its divider (`withSidebarSync`
    /// in ViewNotificationModifiers.swift), and Focus Mode hiding it
    /// (`EditorViewState+FocusMode.swift`) -- because all three write through the same
    /// `editorState.isOutlineSidebarVisible`, which this reads live via `@FocusedValue`; no
    /// separate plumbing is needed since that property already existed and was already kept
    /// in sync with all three.
    ///
    /// `editorState == nil` (no document open, e.g. at the project picker): reads "Show
    /// Outline" -- there is no sidebar to hide -- and the button above is disabled, so it
    /// can't be actioned either way.
    private var outlineToggleLabel: String {
        (editorState?.isOutlineSidebarVisible ?? false) ? "Hide Outline" : "Show Outline"
    }

    /// See `outlineToggleLabel` -- identical rationale, for the Annotations panel's
    /// `isAnnotationPanelVisible`.
    private var annotationsToggleLabel: String {
        (editorState?.isAnnotationPanelVisible ?? false) ? "Hide Annotations" : "Show Annotations"
    }

    /// Names the destination (§5). `editorState == nil` (no doc open) falls back to
    /// `.wysiwyg`'s reading, "Switch to Markdown" — the button is `.disabled` there anyway,
    /// so this only prevents a blank render.
    private var editorModeToggleLabel: String {
        (editorState?.editorMode ?? .wysiwyg).switchToLabel
    }
}

extension Notification.Name {
    static let toggleOutlineSidebar = Notification.Name("toggleOutlineSidebar")
    static let toggleAnnotationSidebar = Notification.Name("toggleAnnotationSidebar")
    static let refreshAllCitations = Notification.Name("refreshAllCitations")
}
