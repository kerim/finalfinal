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
    /// Whether to show full content (vs truncated preview)
    var showFullContent: Bool = false
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
                    .foregroundStyle(themeManager.currentTheme.editorTextSecondary)
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
                                showFullContent: showFullContent,
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
    let showFullContent: Bool
    let onTap: () -> Void
    let onRestore: (SectionRestoreMode) -> Void

    init(
        section: SnapshotSectionViewModel,
        isHighlighted: Bool,
        isHovered: Bool,
        showRestoreButtons: Bool,
        showFullContent: Bool = false,
        onTap: @escaping () -> Void,
        onRestore: @escaping (SectionRestoreMode) -> Void
    ) {
        self.section = section
        self.isHighlighted = isHighlighted
        self.isHovered = isHovered
        self.showRestoreButtons = showRestoreButtons
        self.showFullContent = showFullContent
        self.onTap = onTap
        self.onRestore = onRestore
    }

    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                // Header level indicator (flat display, no indent)
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
                    .foregroundStyle(themeManager.currentTheme.editorTextSecondary)

                // Restore buttons (shown on hover)
                if showRestoreButtons && isHovered {
                    restoreButtons
                }
            }

            // Content preview (full or truncated, flat display)
            if showFullContent {
                // Show full markdown content (excluding header line)
                if let fullContent = fullContentText {
                    Text(fullContent)
                        .font(.body)
                        .foregroundStyle(themeManager.currentTheme.editorTextSecondary)
                        .textSelection(.enabled)
                }
            } else if let preview = contentPreview {
                Text(preview)
                    .font(.body)
                    .foregroundStyle(themeManager.currentTheme.editorTextSecondary)
                    .lineLimit(3)
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
        .contextMenu {
            if showRestoreButtons {
                Button {
                    onRestore(.replace)
                } label: {
                    Label("Replace Current Section", systemImage: "arrow.uturn.backward")
                }

                Button {
                    onRestore(.duplicate)
                } label: {
                    Label("Insert as New Section", systemImage: "doc.on.doc")
                }
            }
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

    private var fullContentText: String? {
        // Extract all content after header line
        let lines = section.markdownContent.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return nil }

        let contentLines = lines.dropFirst()
        let content = contentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    @ViewBuilder
    private var restoreButtons: some View {
        HStack(spacing: 4) {
            Button {
                onRestore(.replace)
            } label: {
                Label("Replace", systemImage: "arrow.uturn.backward")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .help("Replace current section with this backup")

            Button {
                onRestore(.duplicate)
            } label: {
                Label("Insert", systemImage: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .help("Insert as new section at end of document")
        }
    }
}
