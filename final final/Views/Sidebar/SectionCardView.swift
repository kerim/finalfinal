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
    let onDoubleClick: (ZoomMode) -> Void
    let onSectionUpdated: ((SectionViewModel) -> Void)?  // Called when word goal changes
    var isGhost: Bool = false  // When true, render at 30% opacity (drag source in subtree drag)

    @Environment(ThemeManager.self) private var themeManager
    @State private var isHovering = false
    @State private var showingGoalEditor = false

    var body: some View {

        VStack(alignment: .leading, spacing: 4) {
            // Header row: HashBar/BibIcon on left, StatusDot on right
            HStack {
                if section.isBibliography {
                    // Bibliography section gets book icon instead of hash bar
                    BibliographyIcon()
                } else {
                    HashBar(level: section.headerLevel, isPseudoSection: section.isPseudoSection)
                }
                Spacer()
                StatusDot(status: $section.status)
            }

            Text(section.title)
                .font(.sectionTitle(level: section.headerLevel))
                .foregroundColor(themeManager.currentTheme.sidebarText)
                .lineLimit(2)
                .italic(section.isPseudoSection)

            if section.isBibliography {
                bibliographyMetadataRow
            } else {
                metadataRow
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(backgroundColor)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // SwiftUI tap gesture doesn't provide modifier flags, so use .full as default
            // Option+double-click is handled by DraggableCardView's mouseUp handler
            onDoubleClick(.full)
        }
        .onTapGesture(count: 1) {
            onSingleClick()
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .onChange(of: section.status) { oldValue, newValue in
            guard oldValue != newValue else { return }
            onSectionUpdated?(section)
        }
        .opacity(isGhost ? 0.4 : 1.0)
        .overlay {
            if isGhost {
                // Ghost indicator: dashed border to show this card is part of the drag
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        themeManager.currentTheme.accentColor,
                        style: StrokeStyle(lineWidth: 2, dash: [4, 4])
                    )
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            }
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
        .font(.system(size: TypeScale.smallUI))
    }

    private var bibliographyMetadataRow: some View {
        HStack(spacing: 8) {
            // Citation count badge (extracted from word count as proxy)
            let citationCount = estimateCitationCount()
            if citationCount > 0 {
                Text("\(citationCount) refs")
                    .font(.system(size: TypeScale.smallUI, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.6))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(themeManager.currentTheme.sidebarText.opacity(0.08))
                    .clipShape(Capsule())
            }

            Spacer()
        }
        .font(.system(size: TypeScale.smallUI))
    }

    /// Estimate citation count from bibliography content
    /// Each entry typically ends with a DOI/URL or period-newline pattern
    private func estimateCitationCount() -> Int {
        let content = section.markdownContent
        // Count entries by looking for double newlines (bibliography entries are separated by blank lines)
        let entries = content.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // Subtract 1 for the header
        return max(0, entries.count - 1)
    }

    private var wordCountView: some View {
        Text(section.wordCountDisplay)
            .font(.system(size: TypeScale.smallUI, weight: .medium, design: .monospaced))
            .foregroundColor(wordCountColor)
            .onTapGesture {
                showingGoalEditor = true
            }
            .popover(isPresented: $showingGoalEditor, arrowEdge: .bottom) {
                WordCountGoalPopover(
                    wordGoal: $section.wordGoal,
                    goalType: $section.goalType,
                    currentWordCount: section.wordCount,
                    isPresented: $showingGoalEditor,
                    onSave: { onSectionUpdated?(section) }
                )
            }
    }

    private var wordCountColor: Color {
        switch section.goalStatus {
        case .met:
            return themeManager.currentTheme.statusColors.final_  // Green
        case .notMet:
            return .red
        case .noGoal:
            return themeManager.currentTheme.sidebarText.opacity(0.6)
        }
    }
}

/// Popover for setting word count goals
struct WordCountGoalPopover: View {
    @Binding var wordGoal: Int?
    @Binding var goalType: GoalType
    let currentWordCount: Int
    @Binding var isPresented: Bool
    var onSave: (() -> Void)?  // Called when goal is saved or cleared

    @State private var goalInput: String
    @Environment(ThemeManager.self) private var themeManager

    init(wordGoal: Binding<Int?>, goalType: Binding<GoalType>,
         currentWordCount: Int, isPresented: Binding<Bool>,
         onSave: (() -> Void)? = nil) {
        self._wordGoal = wordGoal
        self._goalType = goalType
        self.currentWordCount = currentWordCount
        self._isPresented = isPresented
        self.onSave = onSave
        self._goalInput = State(initialValue: wordGoal.wrappedValue.map { String($0) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Word Goal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(themeManager.currentTheme.sidebarTextSecondary)

            TextField("Goal (e.g., 500)", text: $goalInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)

            Picker("Type", selection: $goalType) {
                ForEach(GoalType.allCases, id: \.self) { type in
                    Text("\(type.displaySymbol) \(type.displayName)")
                        .tag(type)
                }
            }
            .pickerStyle(.segmented)

            Text("Current: \(currentWordCount) words")
                .font(.system(size: 11))
                .foregroundColor(themeManager.currentTheme.sidebarTextSecondary)

            HStack {
                Button("Clear") {
                    wordGoal = nil
                    goalInput = ""
                    onSave?()
                    isPresented = false
                }
                .disabled(wordGoal == nil)

                Spacer()

                Button("Done") {
                    if let value = Int(goalInput), value > 0 {
                        wordGoal = value
                    }
                    onSave?()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 280)
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
    var isPseudoSection: Bool  // Stored, not computed
    var isBibliography: Bool   // Auto-generated bibliography section
    var title: String
    var markdownContent: String
    var status: SectionStatus
    var tags: [String]
    var wordGoal: Int?
    var goalType: GoalType
    var wordCount: Int
    var startOffset: Int

    init(from section: Section) {
        self.id = section.id
        self.projectId = section.projectId
        self.parentId = section.parentId
        self.sortOrder = section.sortOrder
        self.headerLevel = section.headerLevel
        self.isPseudoSection = section.isPseudoSection
        self.isBibliography = section.isBibliography
        self.title = section.title
        // Strip legacy bibliography marker from content (migration for old format)
        // The marker is now injected only for CodeMirror source mode, not stored
        self.markdownContent = section.isBibliography
            ? section.markdownContent.replacingOccurrences(of: "<!-- ::auto-bibliography:: -->", with: "")
            : section.markdownContent
        self.status = section.status
        self.tags = section.tags
        self.wordGoal = section.wordGoal
        self.goalType = section.goalType
        self.wordCount = section.wordCount
        self.startOffset = section.startOffset
    }

    var goalProgress: Double? {
        guard let goal = wordGoal, goal > 0 else { return nil }
        return Double(wordCount) / Double(goal)
    }

    /// Goal status based on current word count, goal, and goal type
    var goalStatus: GoalStatus {
        GoalStatus.calculate(wordCount: wordCount, goal: wordGoal, goalType: goalType)
    }

    /// Display string for word count with goal type symbol when goal is set
    var wordCountDisplay: String {
        if wordGoal != nil {
            return "\(goalType.displaySymbol)\(wordCount)"
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
            isPseudoSection: isPseudoSection,
            isBibliography: isBibliography,
            title: title,
            markdownContent: markdownContent,
            status: status,
            tags: tags,
            wordGoal: wordGoal,
            goalType: goalType,
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
        isPseudoSection: Bool? = nil,
        isBibliography: Bool? = nil,
        markdownContent: String? = nil,
        startOffset: Int? = nil
    ) -> SectionViewModel {
        let section = Section(
            id: self.id,
            projectId: self.projectId,
            parentId: parentId ?? self.parentId,
            sortOrder: sortOrder ?? self.sortOrder,
            headerLevel: headerLevel ?? self.headerLevel,
            isPseudoSection: isPseudoSection ?? self.isPseudoSection,
            isBibliography: isBibliography ?? self.isBibliography,
            title: self.title,
            markdownContent: markdownContent ?? self.markdownContent,
            status: self.status,
            tags: self.tags,
            wordGoal: self.wordGoal,
            goalType: self.goalType,
            wordCount: self.wordCount,
            startOffset: startOffset ?? self.startOffset
        )
        return SectionViewModel(from: section)
    }
}

/// Bibliography section icon (book emoji)
struct BibliographyIcon: View {
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        Text("📚")
            .font(.system(size: 14))
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
        goalType: .approx,
        wordCount: 350
    ))

    VStack(spacing: 0) {
        SectionCardView(
            section: sampleSection,
            onSingleClick: { print("Single click") },
            onDoubleClick: { mode in print("Double click with mode: \(mode)") },
            onSectionUpdated: nil
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
                goalType: .min,
                wordCount: 1050
            )),
            onSingleClick: {},
            onDoubleClick: { _ in },
            onSectionUpdated: nil
        )
    }
    .frame(width: 300)
    .background(Color(nsColor: .windowBackgroundColor))
    .environment(ThemeManager.shared)
}
