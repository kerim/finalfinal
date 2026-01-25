//
//  SectionCardView.swift
//  final final
//

import SwiftUI

/// Individual section card for the outline sidebar
/// Layout: HashBar → Title → Metadata row
struct SectionCardView: View {
    @Bindable var section: SectionViewModel
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void

    @Environment(ThemeManager.self) private var themeManager
    @State private var isHovering = false
    @State private var showAggregateWordCount = false
    @State private var showGoalPopover = false

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
        Text(wordCountDisplayText)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(wordCountColor)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                showGoalPopover = true
            }
            .onTapGesture(count: 1) {
                showAggregateWordCount.toggle()
            }
            .popover(isPresented: $showGoalPopover) {
                GoalEditorPopover(
                    wordCount: section.wordCount,
                    goal: Binding(
                        get: { section.wordGoal },
                        set: { section.wordGoal = $0 }
                    )
                )
            }
    }

    private var wordCountDisplayText: String {
        if showAggregateWordCount {
            // Aggregate display: Σ + aggregate count
            if let goal = section.wordGoal {
                return "Σ \(section.aggregateWordCount)/\(goal)"
            }
            return "Σ \(section.aggregateWordCount)"
        } else {
            // Individual display
            return section.wordCountDisplay
        }
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
    var startOffset: Int
    /// Aggregate word count (this section + all descendants). Set by OutlineSidebar.
    var aggregateWordCount: Int = 0

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
        self.startOffset = section.startOffset
        self.aggregateWordCount = section.wordCount  // Default to own count
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
            startOffset: startOffset,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// Create a modified copy for reorder operations.
    /// Returns a NEW object instance to trigger SwiftUI re-render.
    /// Uses double-optional for parentId to distinguish "set to nil" from "don't change".
    func withUpdates(
        parentId: String?? = nil,
        sortOrder: Int? = nil,
        headerLevel: Int? = nil,
        markdownContent: String? = nil,
        startOffset: Int? = nil
    ) -> SectionViewModel {
        let section = Section(
            id: self.id,
            projectId: self.projectId,
            parentId: parentId ?? self.parentId,
            sortOrder: sortOrder ?? self.sortOrder,
            headerLevel: headerLevel ?? self.headerLevel,
            title: self.title,
            markdownContent: markdownContent ?? self.markdownContent,
            status: self.status,
            tags: self.tags,
            wordGoal: self.wordGoal,
            wordCount: self.wordCount,
            startOffset: startOffset ?? self.startOffset
        )
        let copy = SectionViewModel(from: section)
        copy.aggregateWordCount = self.aggregateWordCount
        return copy
    }
}

/// Popover for editing word count goal
struct GoalEditorPopover: View {
    let wordCount: Int
    @Binding var goal: Int?

    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeManager.self) private var themeManager
    @State private var goalText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Word Count Goal")
                .font(.headline)
                .foregroundColor(themeManager.currentTheme.sidebarText)

            HStack {
                Text("Current:")
                    .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.7))
                Text("\(wordCount)")
                    .fontWeight(.medium)
                    .foregroundColor(themeManager.currentTheme.sidebarText)
            }
            .font(.system(size: 12))

            TextField("Goal (e.g., 500)", text: $goalText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .onSubmit {
                    saveGoal()
                }

            HStack(spacing: 8) {
                Button("Clear") {
                    goal = nil
                    dismiss()
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)

                Spacer()

                Button("Save") {
                    saveGoal()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 200)
        .onAppear {
            if let existingGoal = goal {
                goalText = "\(existingGoal)"
            }
        }
    }

    private func saveGoal() {
        if let value = Int(goalText), value > 0 {
            goal = value
        }
        dismiss()
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
