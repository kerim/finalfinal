//
//  SectionCardView.swift
//  final final
//

import SwiftUI

/// Individual section card for the outline sidebar
/// Layout: HashBar → Title → Metadata row
struct SectionCardView: View {
    @Bindable var section: SectionViewModel
    var isDropTarget: Bool = false
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void

    @Environment(ThemeManager.self) private var themeManager
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header row: HashBar on left, StatusDot on right
            HStack {
                HashBar(level: section.headerLevel)
                Spacer()
                StatusDot(status: $section.status)
            }

            Text(section.title)
                .font(.sectionTitle(level: section.headerLevel))
                .foregroundColor(themeManager.currentTheme.sidebarText)
                .lineLimit(2)
                .italic(section.isPseudoSection)

            metadataRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(backgroundColor)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onDoubleClick()
        }
        .onTapGesture(count: 1) {
            onSingleClick()
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var backgroundColor: Color {
        if isDropTarget {
            return themeManager.currentTheme.accentColor.opacity(0.3)
        }
        if isHovering {
            return themeManager.currentTheme.sidebarSelectedBackground.opacity(0.5)
        }
        return .clear
    }

    private var metadataRow: some View {
        HStack(spacing: 8) {
            if !section.tags.isEmpty {
                TagPillsView(tags: $section.tags)
                    .lineLimit(1)
            }

            Spacer()

            wordCountView
        }
        .font(.system(size: 11))
    }

    private var wordCountView: some View {
        Text(section.wordCountDisplay)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(wordCountColor)
    }

    private var wordCountColor: Color {
        guard let progress = section.goalProgress else {
            return themeManager.currentTheme.sidebarText.opacity(0.6)
        }

        if progress >= 1.0 {
            return themeManager.currentTheme.statusColors.final_
        } else if progress >= 0.75 {
            return themeManager.currentTheme.statusColors.review
        }
        return themeManager.currentTheme.sidebarText.opacity(0.6)
    }
}

/// ViewModel for binding Section data to UI
@Observable
class SectionViewModel: Identifiable {
    let id: String
    var projectId: String
    var parentId: String?
    var sortOrder: Int
    var headerLevel: Int
    var title: String
    var markdownContent: String
    var status: SectionStatus
    var tags: [String]
    var wordGoal: Int?
    var wordCount: Int

    init(from section: Section) {
        self.id = section.id
        self.projectId = section.projectId
        self.parentId = section.parentId
        self.sortOrder = section.sortOrder
        self.headerLevel = section.headerLevel
        self.title = section.title
        self.markdownContent = section.markdownContent
        self.status = section.status
        self.tags = section.tags
        self.wordGoal = section.wordGoal
        self.wordCount = section.wordCount
    }

    var isPseudoSection: Bool {
        headerLevel == 0
    }

    var goalProgress: Double? {
        guard let goal = wordGoal, goal > 0 else { return nil }
        return Double(wordCount) / Double(goal)
    }

    var wordCountDisplay: String {
        if let goal = wordGoal {
            return "\(wordCount)/\(goal)"
        }
        return "\(wordCount)"
    }

    func toSection(createdAt: Date, updatedAt: Date) -> Section {
        Section(
            id: id,
            projectId: projectId,
            parentId: parentId,
            sortOrder: sortOrder,
            headerLevel: headerLevel,
            title: title,
            markdownContent: markdownContent,
            status: status,
            tags: tags,
            wordGoal: wordGoal,
            wordCount: wordCount,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

#Preview {
    let sampleSection = SectionViewModel(from: Section(
        projectId: "test",
        sortOrder: 0,
        headerLevel: 2,
        title: "Introduction",
        markdownContent: "This is the introduction text with some words.",
        status: .writing,
        tags: ["research", "draft"],
        wordGoal: 500,
        wordCount: 350
    ))

    VStack(spacing: 0) {
        SectionCardView(
            section: sampleSection,
            onSingleClick: { print("Single click") },
            onDoubleClick: { print("Double click") }
        )

        Divider()

        SectionCardView(
            section: SectionViewModel(from: Section(
                projectId: "test",
                sortOrder: 1,
                headerLevel: 1,
                title: "Chapter One: The Beginning of Something New",
                status: .final_,
                wordGoal: 1000,
                wordCount: 1050
            )),
            onSingleClick: {},
            onDoubleClick: {}
        )
    }
    .frame(width: 300)
    .background(Color(nsColor: .windowBackgroundColor))
    .environment(ThemeManager.shared)
}
