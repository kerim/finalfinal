//
//  DocumentPreviewView.swift
//  final final
//
//  Read-only document preview for version history comparison.
//

import SwiftUI

/// View model for displaying snapshot sections in preview
struct SnapshotSectionViewModel: Identifiable, Equatable {
    let id: String
    let title: String
    let headerLevel: Int
    let markdownContent: String
    let status: SectionStatus?
    let wordCount: Int

    /// Initialize from SnapshotSection
    init(from section: SnapshotSection) {
        self.id = section.id
        self.title = section.title
        self.headerLevel = section.headerLevel
        self.markdownContent = section.markdownContent
        self.status = section.status
        self.wordCount = MarkdownUtils.wordCount(for: section.markdownContent)
    }

    /// Initialize from SectionViewModel (current sections)
    init(from viewModel: SectionViewModel) {
        self.id = viewModel.id
        self.title = viewModel.title
        self.headerLevel = viewModel.headerLevel
        self.markdownContent = viewModel.markdownContent
        self.status = viewModel.status
        self.wordCount = viewModel.wordCount
    }
}

/// Read-only document preview for middle and right columns
struct DocumentPreviewView: View {
    let title: String
    let sections: [SnapshotSectionViewModel]
    let highlightedSectionId: String?
    let onSectionTap: ((SnapshotSectionViewModel) -> Void)?

    /// Whether to show restore buttons on hover
    var showRestoreButtons: Bool = false
    var onRestoreSection: ((SnapshotSectionViewModel, SectionRestoreMode) -> Void)?

    @Environment(ThemeManager.self) private var themeManager
    @State private var hoveredSectionId: String?
    @State private var scrollPosition: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Column header
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(themeManager.currentTheme.sidebarBackground.opacity(0.5))

            Divider()

            // Document content
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            SectionPreviewRow(
                                section: section,
                                isHighlighted: section.id == highlightedSectionId,
                                isHovered: section.id == hoveredSectionId,
                                showRestoreButtons: showRestoreButtons,
                                onTap: {
                                    onSectionTap?(section)
                                },
                                onRestore: { mode in
                                    onRestoreSection?(section, mode)
                                }
                            )
                            .id(section.id)
                            .onHover { isHovered in
                                hoveredSectionId = isHovered ? section.id : nil
                            }
                        }
                    }
                    .padding()
                }
                .onChange(of: scrollPosition) { _, newValue in
                    if let id = newValue {
                        withAnimation {
                            proxy.scrollTo(id, anchor: .top)
                        }
                    }
                }
            }
        }
        .background(themeManager.currentTheme.editorBackground)
    }

    /// Scroll to a specific section
    func scrollTo(_ sectionId: String) {
        scrollPosition = sectionId
    }
}

/// Individual section row in the preview
struct SectionPreviewRow: View {
    let section: SnapshotSectionViewModel
    let isHighlighted: Bool
    let isHovered: Bool
    let showRestoreButtons: Bool
    let onTap: () -> Void
    let onRestore: (SectionRestoreMode) -> Void

    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                // Indent based on header level
                Text(String(repeating: "  ", count: max(0, section.headerLevel - 1)))
                    .font(.body)

                // Header indicator
                Text("H\(section.headerLevel)")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(themeManager.currentTheme.accentColor.opacity(0.2))
                    .cornerRadius(4)

                // Title
                Text(section.title)
                    .font(.headline)
                    .foregroundStyle(themeManager.currentTheme.editorText)

                Spacer()

                // Word count
                Text("\(section.wordCount) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Restore buttons (shown on hover)
                if showRestoreButtons && isHovered {
                    restoreButtons
                }
            }

            // Content preview (first few lines)
            if let preview = contentPreview {
                Text(preview)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.leading, CGFloat(section.headerLevel - 1) * 16)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(backgroundColor)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
    }

    private var backgroundColor: Color {
        if isHighlighted {
            return themeManager.currentTheme.accentColor.opacity(0.2)
        }
        if isHovered {
            return themeManager.currentTheme.sidebarBackground.opacity(0.5)
        }
        return .clear
    }

    private var contentPreview: String? {
        // Extract first paragraph after header
        let lines = section.markdownContent.split(separator: "\n", omittingEmptySubsequences: false)
        var paragraphLines: [String] = []

        for line in lines.dropFirst() { // Skip header line
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !paragraphLines.isEmpty { break }
                continue
            }
            if trimmed.hasPrefix("#") { break } // Next header
            paragraphLines.append(String(line))
        }

        let preview = paragraphLines.joined(separator: " ")
        return preview.isEmpty ? nil : preview
    }

    @ViewBuilder
    private var restoreButtons: some View {
        HStack(spacing: 4) {
            Button(action: { onRestore(.replace) }) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .help("Replace current section")

            Button(action: { onRestore(.duplicate) }) {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .help("Insert as new section")
        }
    }
}
