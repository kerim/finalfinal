//
//  ContentView.swift
//  final final
//

import SwiftUI

/// Line-based cursor position for cross-editor coordination.
/// Uses line/column instead of raw offsets because ProseMirror (tree-based)
/// and markdown (flat text) positions don't map 1:1.
struct CursorPosition: Equatable {
    let line: Int
    let column: Int

    static let start = CursorPosition(line: 1, column: 0)
}

struct ContentView: View {
    @Environment(ThemeManager.self) private var themeManager
    @State private var editorState = EditorViewState()
    @State private var cursorPositionToRestore: CursorPosition? = nil

    private let demoContent = """
# Welcome to final final

This is a **WYSIWYG** editor powered by [Milkdown](https://milkdown.dev).

## Features

- Rich text editing
- Markdown support
- Focus mode (Cmd+Shift+F)
- Multiple themes

### Getting Started

Start typing to edit this document. Your changes are automatically saved.

> "The first draft is just you telling yourself the story." — Terry Pratchett

Try the following:

1. Toggle focus mode with **Cmd+Shift+F**
2. Switch themes with **Cmd+Opt+1** through **Cmd+Opt+5**
3. Toggle source view with **Cmd+/**
"""

    var body: some View {
        NavigationSplitView {
            sidebarView
        } detail: {
            detailView
        }
        .task {
            loadDemoContent()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleFocusMode).receive(on: DispatchQueue.main)) { _ in
            editorState.toggleFocusMode()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleEditorMode).receive(on: DispatchQueue.main)) { _ in
            editorState.toggleEditorMode()
        }
    }

    @ViewBuilder
    private var sidebarView: some View {
        VStack {
            Text("Outline Sidebar")
                .font(.headline)
                .foregroundColor(themeManager.currentTheme.sidebarText)
                .padding()
            Spacer()
            Text("Phase 1.6 will implement\nthe full outline view")
                .font(.caption)
                .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding()

            // Theme indicator for testing
            VStack(spacing: 4) {
                Text("Current Theme:")
                    .font(.caption2)
                Text(themeManager.currentTheme.name)
                    .font(.caption)
                    .bold()
            }
            .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.8))
            .padding()
        }
        .frame(minWidth: 200)
        .background(themeManager.currentTheme.sidebarBackground)
    }

    @ViewBuilder
    private var detailView: some View {
        VStack(spacing: 0) {
            editorView
            StatusBar(editorState: editorState)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(themeManager.currentTheme.editorBackground)
    }

    @ViewBuilder
    private var editorView: some View {
        switch editorState.editorMode {
        case .wysiwyg:
            MilkdownEditor(
                content: $editorState.content,
                focusModeEnabled: $editorState.focusModeEnabled,
                cursorPositionToRestore: $cursorPositionToRestore,
                onContentChange: { _ in
                    // Content change handling - could trigger outline parsing here
                },
                onStatsChange: { words, characters in
                    editorState.updateStats(words: words, characters: characters)
                },
                onCursorPositionSaved: { position in
                    cursorPositionToRestore = position
                }
            )
        case .source:
            CodeMirrorEditor(
                content: $editorState.content,
                cursorPositionToRestore: $cursorPositionToRestore,
                onContentChange: { _ in
                    // Content change handling - could trigger outline parsing here
                },
                onStatsChange: { words, characters in
                    editorState.updateStats(words: words, characters: characters)
                },
                onCursorPositionSaved: { position in
                    cursorPositionToRestore = position
                }
            )
        }
    }

    private func loadDemoContent() {
        if editorState.content.isEmpty {
            editorState.content = demoContent
        }
    }
}

#Preview {
    ContentView()
        .environment(ThemeManager.shared)
}
