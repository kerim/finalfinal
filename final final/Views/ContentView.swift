//
//  ContentView.swift
//  final final
//

import SwiftUI

struct ContentView: View {
    @Environment(ThemeManager.self) private var themeManager
    @State private var editorState = EditorViewState()

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
        .onReceive(NotificationCenter.default.publisher(for: .toggleFocusMode)) { _ in
            editorState.toggleFocusMode()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleEditorMode)) { _ in
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
                onContentChange: { _ in
                    // Content change handling - could trigger outline parsing here
                },
                onStatsChange: { words, characters in
                    editorState.updateStats(words: words, characters: characters)
                }
            )
        case .source:
            // Placeholder for CodeMirror (Phase 1.5)
            VStack {
                Spacer()
                Text("Source Mode")
                    .font(.largeTitle)
                    .foregroundColor(themeManager.currentTheme.editorText.opacity(0.5))
                Text("Phase 1.5 will add CodeMirror editor")
                    .font(.body)
                    .foregroundColor(themeManager.currentTheme.editorText.opacity(0.5))
                Spacer()
            }
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
