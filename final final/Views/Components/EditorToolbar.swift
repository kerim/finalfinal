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
            .help("Insert task annotation (⌘⇧T)")

            Button {
                NotificationCenter.default.post(
                    name: .insertAnnotation,
                    object: nil,
                    userInfo: ["type": AnnotationType.comment]
                )
            } label: {
                Label("Comment", systemImage: "text.bubble")
            }
            .help("Insert comment annotation (⌘⇧C)")

            Button {
                NotificationCenter.default.post(
                    name: .insertAnnotation,
                    object: nil,
                    userInfo: ["type": AnnotationType.reference]
                )
            } label: {
                Label("Reference", systemImage: "bookmark")
            }
            .help("Insert reference annotation (⌘⇧R)")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            // Inserts group — ControlGroup merges into one visual capsule
            ControlGroup {
                Button {
                    NotificationCenter.default.post(name: .refreshAllCitations, object: nil)
                } label: {
                    Label {
                        Text("Cite")
                    } icon: {
                        Text("\u{275D}").font(.system(size: 16, weight: .medium))
                    }
                }
                .help("Insert citation (⌘⇧K)")

                Button {
                    NotificationCenter.default.post(name: .insertFootnote, object: nil)
                } label: {
                    Label {
                        Text("Footnote")
                    } icon: {
                        Text("‡").font(.system(size: 16, weight: .medium))
                    }
                }
                .help("Insert footnote (⌘⇧N)")
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            // Deferred items (disabled)
            Button {} label: {
                Label("Image", systemImage: "photo")
            }
            .disabled(true)
            .help("Coming soon")

            Button {} label: {
                Label("Table", systemImage: "tablecells")
            }
            .disabled(true)
            .help("Coming soon")

            Button {} label: {
                Label("Math", systemImage: "function")
            }
            .disabled(true)
            .help("Coming soon")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            // Sidebar toggle
            NativeToolbarButton(
                systemSymbolName: "sidebar.right",
                accessibilityLabel: editorState.isAnnotationPanelVisible
                    ? "Hide annotations panel"
                    : "Show annotations panel"
            ) {
                editorState.toggleAnnotationPanel()
            }
            .help(editorState.isAnnotationPanelVisible
                  ? "Hide annotations panel (⌘])"
                  : "Show annotations panel (⌘])")
        }
    }
}
