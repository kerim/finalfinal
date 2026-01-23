//
//  ContentView.swift
//  final final
//

import SwiftUI

struct ContentView: View {
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        NavigationSplitView {
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
        } detail: {
            VStack {
                Spacer()
                Text("Editor Area")
                    .font(.largeTitle)
                    .foregroundColor(themeManager.currentTheme.editorText.opacity(0.5))
                Text("Phase 1.4-1.5 will add\nMilkdown and CodeMirror editors")
                    .font(.body)
                    .foregroundColor(themeManager.currentTheme.editorText.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
                StatusBar()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(themeManager.currentTheme.editorBackground)
        }
    }
}

#Preview {
    ContentView()
        .environment(ThemeManager.shared)
}
