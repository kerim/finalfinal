//
//  DocumentPreviewView.swift
//  final final
//
//  Read-only document preview for version history comparison.
//

import SwiftUI

// MARK: - Comparison Types

/// Mode for comparing snapshot sections
enum ComparisonMode: String, CaseIterable {
    case vsCurrent = "vs Current"
    case vsPrevious = "vs Previous"
}

/// Type of change detected for a section
enum SectionChangeType {
    case modified
    case new
}

/// Compute section changes between displayed and comparison section sets
func computeSectionChanges(
    displayed: [SnapshotSectionViewModel],
    comparison: [SnapshotSectionViewModel]
) -> [String: SectionChangeType] {
    // Primary: match by originalSectionId
    let compMapById = Dictionary(
        comparison.compactMap { vm in
            vm.originalSectionId.map { ($0, vm.markdownContent) }
        },
        uniquingKeysWith: { first, _ in first }
    )
    // Fallback: match by (title, headerLevel) for old snapshots without originalSectionId
    let compMapByTitle = Dictionary(
        comparison.map { ("\($0.title)|\($0.headerLevel)", $0.markdownContent) },
        uniquingKeysWith: { first, _ in first }
    )

    var changes: [String: SectionChangeType] = [:]
    for section in displayed {
        if let origId = section.originalSectionId, let compContent = compMapById[origId] {
            // Matched by ID
            if compContent != section.markdownContent {
                changes[section.id] = .modified
            }
        } else if let compContent = compMapByTitle["\(section.title)|\(section.headerLevel)"] {
            // Fallback: matched by title+level (for old snapshots or decode failures)
            if compContent != section.markdownContent {
                changes[section.id] = .modified
            }
        } else {
            changes[section.id] = .new
        }
    }
    return changes
}

/// View model for displaying snapshot sections in preview
struct SnapshotSectionViewModel: Identifiable, Equatable {
    let id: String
    let title: String
    let headerLevel: Int
    let markdownContent: String
    let status: SectionStatus?
    let wordCount: Int
    let originalSectionId: String?

    /// Initialize from SnapshotSection
    init(from section: SnapshotSection) {
        self.id = section.id
        self.title = section.title
        self.headerLevel = section.headerLevel
        self.markdownContent = section.markdownContent
        self.status = section.status
        self.wordCount = MarkdownUtils.wordCount(for: section.markdownContent)
        self.originalSectionId = section.originalSectionId
    }

    /// Initialize from SectionViewModel (current sections — their own ID is the original)
    init(from viewModel: SectionViewModel) {
        self.id = viewModel.id
        self.title = viewModel.title
        self.headerLevel = viewModel.headerLevel
        self.markdownContent = viewModel.markdownContent
        self.status = viewModel.status
        self.wordCount = viewModel.wordCount
        self.originalSectionId = viewModel.id
    }
}

/// Read-only document preview for middle and right columns
struct DocumentPreviewView<TrailingHeader: View>: View {
    let title: String
    let sections: [SnapshotSectionViewModel]
    let highlightedSectionId: String?
    let onSectionTap: ((SnapshotSectionViewModel) -> Void)?

    /// Whether to show restore buttons on hover
    var showRestoreButtons: Bool = false
    /// Whether to show full content (vs truncated preview)
    var showFullContent: Bool = false
    var onRestoreSection: ((SnapshotSectionViewModel, SectionRestoreMode) -> Void)?
    /// Section change types for highlighting
    var changeTypes: [String: SectionChangeType] = [:]
    /// Trailing content for the header area
    let trailingHeader: TrailingHeader

    @Environment(ThemeManager.self) private var themeManager
    @State private var hoveredSectionId: String?
    @State private var scrollPosition: String?

    init(
        title: String,
        sections: [SnapshotSectionViewModel],
        highlightedSectionId: String?,
        onSectionTap: ((SnapshotSectionViewModel) -> Void)?,
        showRestoreButtons: Bool = false,
        showFullContent: Bool = false,
        onRestoreSection: ((SnapshotSectionViewModel, SectionRestoreMode) -> Void)? = nil,
        changeTypes: [String: SectionChangeType] = [:],
        @ViewBuilder trailingHeader: () -> TrailingHeader
    ) {
        self.title = title
        self.sections = sections
        self.highlightedSectionId = highlightedSectionId
        self.onSectionTap = onSectionTap
        self.showRestoreButtons = showRestoreButtons
        self.showFullContent = showFullContent
        self.onRestoreSection = onRestoreSection
        self.changeTypes = changeTypes
        self.trailingHeader = trailingHeader()
    }

    var body: some View {
        let _ = { // swiftlint:disable:this redundant_discardable_let
            DebugLog.log(.lifecycle, "[DocumentPreviewView] '\(title)' rendering with \(sections.count) sections")
        }()
        VStack(alignment: .leading, spacing: 0) {
            // Column header
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(themeManager.currentTheme.sidebarText)
                Spacer()
                trailingHeader
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
            .background(themeManager.currentTheme.sidebarBackground)

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
                                changeType: changeTypes[section.id],
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

extension DocumentPreviewView where TrailingHeader == EmptyView {
    init(
        title: String,
        sections: [SnapshotSectionViewModel],
        highlightedSectionId: String?,
        onSectionTap: ((SnapshotSectionViewModel) -> Void)?,
        showRestoreButtons: Bool = false,
        showFullContent: Bool = false,
        onRestoreSection: ((SnapshotSectionViewModel, SectionRestoreMode) -> Void)? = nil,
        changeTypes: [String: SectionChangeType] = [:]
    ) {
        self.title = title
        self.sections = sections
        self.highlightedSectionId = highlightedSectionId
        self.onSectionTap = onSectionTap
        self.showRestoreButtons = showRestoreButtons
        self.showFullContent = showFullContent
        self.onRestoreSection = onRestoreSection
        self.changeTypes = changeTypes
        self.trailingHeader = EmptyView()
    }
}

/// Individual section row in the preview
struct SectionPreviewRow: View {
    let section: SnapshotSectionViewModel
    let isHighlighted: Bool
    let isHovered: Bool
    let showRestoreButtons: Bool
    let showFullContent: Bool
    let changeType: SectionChangeType?
    let onTap: () -> Void
    let onRestore: (SectionRestoreMode) -> Void

    init(
        section: SnapshotSectionViewModel,
        isHighlighted: Bool,
        isHovered: Bool,
        showRestoreButtons: Bool,
        showFullContent: Bool = false,
        changeType: SectionChangeType? = nil,
        onTap: @escaping () -> Void,
        onRestore: @escaping (SectionRestoreMode) -> Void
    ) {
        self.section = section
        self.isHighlighted = isHighlighted
        self.isHovered = isHovered
        self.showRestoreButtons = showRestoreButtons
        self.showFullContent = showFullContent
        self.changeType = changeType
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

                // Change badge
                if let change = changeType {
                    Text(change == .new ? "New" : "Modified")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(change == .new ? Color.green.opacity(0.2) : themeManager.currentTheme.accentColor.opacity(0.2))
                        )
                        .foregroundStyle(change == .new ? Color.green : themeManager.currentTheme.accentColor)
                }

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
        .padding(.leading, changeType != nil ? 4 : 0)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(backgroundColor)
        )
        .overlay(alignment: .leading) {
            if let change = changeType {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(change == .new ? Color.green : themeManager.currentTheme.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 2)
            }
        }
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
            return themeManager.currentTheme.editorText.opacity(0.08)
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
