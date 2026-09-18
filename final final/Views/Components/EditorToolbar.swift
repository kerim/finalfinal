//
//  EditorToolbar.swift
//  final final
//
//  Native toolbar with insert/annotation buttons (Pages-style icon+label).
//

import SwiftUI

/// Toolbar content for the editor window title bar.
/// Provides annotation inserts, citation, footnote, and future items.
struct EditorToolbar: ToolbarContent {
    let editorState: EditorViewState

    var body: some ToolbarContent {
        // Outline sidebar toggle, in the LEADING section of the title bar (left of the window
        // title) -- the position the native sidebar chevron held before the Outline's container
        // became an `HSplitView`. `.navigation` is the placement for that leading section on
        // macOS; a `.primaryAction` item (where this started) belongs to the trailing cluster,
        // which is right of the title and therefore the wrong end of the bar. Semantics: this is a
        // navigation control over the window's leading pane, so `.navigation` is also the
        // honest description of it, not just the leading slot. Deliberately a bare `ToolbarItem`
        // rather than a group: it is a single standalone control, matching how the chevron it
        // replaces appeared. `NativeToolbarButton` supplies the label, tooltip and accessibility
        // identifier exactly as before (UX contract §5/§8: one icon-button style, matching
        // "Show/Hide Outline" wording and a tooltip carrying the shortcut).
        ToolbarItem(placement: .navigation) {
            NativeToolbarButton(
                systemSymbolName: "sidebar.left",
                accessibilityLabel: editorState.isOutlineSidebarVisible
                    ? "Hide Outline"
                    : "Show Outline",
                helpText: editorState.isOutlineSidebarVisible
                    ? "Hide Outline (⌘[)"
                    : "Show Outline (⌘[)",
                accessibilityHint: "(⌘[ to toggle)",
                accessibilityIdentifier: "toolbar-outline-toggle"
            ) {
                editorState.toggleOutlineSidebar()
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            // Annotations group
            Button {
                NotificationCenter.default.post(
                    name: .insertAnnotation,
                    object: nil,
                    userInfo: ["type": AnnotationType.task]
                )
            } label: {
                Label("Task", systemImage: "checkmark.circle")
            }
            .help("Insert task annotation (⇧⌘T)")

            Button {
                NotificationCenter.default.post(
                    name: .insertAnnotation,
                    object: nil,
                    userInfo: ["type": AnnotationType.comment]
                )
            } label: {
                Label("Comment", systemImage: "text.bubble")
            }
            .help("Insert comment annotation (⇧⌘C)")

            Button {
                NotificationCenter.default.post(
                    name: .insertAnnotation,
                    object: nil,
                    userInfo: ["type": AnnotationType.reference]
                )
            } label: {
                Label("Reference", systemImage: "bookmark")
            }
            .help("Insert reference annotation (⇧⌘R)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            // Inserts group — ControlGroup merges into one visual capsule
            ControlGroup {
                Button {
                    NotificationCenter.default.post(name: .insertCitation, object: nil)
                } label: {
                    Label("Citation", systemImage: "text.book.closed")
                }
                .help("Insert citation (⇧⌘K)")

                Button {
                    NotificationCenter.default.post(name: .insertFootnote, object: nil)
                } label: {
                    Label("Footnote", systemImage: "text.append")
                }
                .help("Insert footnote (⇧⌘N)")
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                NotificationCenter.default.post(name: .requestInsertImage, object: nil)
            } label: {
                Label("Image", systemImage: "photo")
            }
            .help("Insert image (⇧⌘I)")

            Button {
                NotificationCenter.default.post(name: .requestInsertTable, object: nil)
            } label: {
                Label("Table", systemImage: "tablecells")
            }
            .help("Insert table (⇧⌘D)")

            Button {
                NotificationCenter.default.post(name: .requestInsertEquation, object: nil)
            } label: {
                Label("Math", systemImage: "function")
            }
            .help("Insert equation (⇧⌘E)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            // Sidebar toggle
            NativeToolbarButton(
                systemSymbolName: "sidebar.right",
                accessibilityLabel: editorState.isAnnotationPanelVisible
                    ? "Hide Annotations"
                    : "Show Annotations",
                helpText: editorState.isAnnotationPanelVisible
                    ? "Hide Annotations (⌘])"
                    : "Show Annotations (⌘])",
                accessibilityHint: "(⌘] to toggle)",
                accessibilityIdentifier: "toolbar-annotations-toggle"
            ) {
                editorState.toggleAnnotationPanel()
            }
        }
    }
}
