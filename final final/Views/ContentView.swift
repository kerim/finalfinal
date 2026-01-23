//
//  ContentView.swift
//  final final
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            VStack {
                Text("Outline Sidebar")
                    .font(.headline)
                    .padding()
                Spacer()
                Text("Phase 1.6 will implement\nthe full outline view")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
            .frame(minWidth: 200)
        } detail: {
            VStack {
                Spacer()
                Text("Editor Area")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("Phase 1.4-1.5 will add\nMilkdown and CodeMirror editors")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
                StatusBar()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview {
    ContentView()
}
