//
//  TagPillView.swift
//  final final
//

import SwiftUI

/// Small rounded pill displaying a tag
struct TagPill: View {
    let tag: String
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        Text(tag)
            .font(.system(size: TypeScale.smallUI, weight: .medium))
            .foregroundColor(themeManager.currentTheme.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(themeManager.currentTheme.accentColor.opacity(0.15))
            )
    }
}

/// Row of tag pills with click-to-edit
struct TagPillsView: View {
    @Binding var tags: [String]
    @Environment(ThemeManager.self) private var themeManager
    @State private var showingEditor = false
    @State private var editingText = ""

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                TagPill(tag: tag)
            }

            if tags.isEmpty {
                Button {
                    editingText = tags.joined(separator: ", ")
                    showingEditor = true
                } label: {
                    Image(systemName: "tag")
                        .font(.system(size: TypeScale.smallUI))
                        .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .onTapGesture {
            editingText = tags.joined(separator: ", ")
            showingEditor = true
        }
        .popover(isPresented: $showingEditor, arrowEdge: .bottom) {
            tagEditor
        }
    }

    private var tagEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags (comma-separated)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(themeManager.currentTheme.sidebarTextSecondary)

            TextField("research, draft, urgent", text: $editingText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 200)

            HStack {
                Spacer()
                Button("Done") {
                    tags = editingText
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    showingEditor = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
    }
}

#Preview {
    @Previewable @State var tags = ["research", "draft"]
    @Previewable @State var emptyTags: [String] = []

    VStack(alignment: .leading, spacing: 16) {
        TagPillsView(tags: $tags)
        TagPillsView(tags: $emptyTags)
    }
    .padding()
    .environment(ThemeManager.shared)
}
