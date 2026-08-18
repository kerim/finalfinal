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
    var isActive: Bool = false  // When true, show left accent bar (cursor is in this section)
    var onHoverChanged: ((Bool) -> Void)?  // Bubbles hover state to parent (bypasses PassthroughHostingView hit-test)
    /// Right-click/control-click context menu: duplicate/delete this section's full subtree
    /// (docs/plans/patient-rewinding-clockwork.md §7 Phase 4). Both nil-defaulted so every
    /// other call site (drag preview, etc.) is unaffected.
    var onDuplicate: (() -> Void)?
    var onDelete: (() -> Void)?
    /// True while the editor is zoomed into any section -- disables duplicate/delete (see
    /// ContentView+SectionOperations.swift's `isSectionOperationAvailable`).
    var isZoomed: Bool = false

    @Environment(ThemeManager.self) private var themeManager
    @Environment(GoalColorSettingsManager.self) private var goalManager
    @State private var isHovering = false
    @State private var showingGoalEditor = false

    var body: some View {

        VStack(alignment: .leading, spacing: 4) {
            // Header row: HashBar/BibIcon on left, StatusBadge on right
            HStack {
                if section.isBibliography {
                    // Bibliography section gets book icon instead of hash bar
                    BibliographyIcon()
                } else {
                    HashBar(level: section.headerLevel, isPseudoSection: section.isPseudoSection)
                }
                Spacer()
                if !section.isBibliography && !section.isNotes {
                    StatusBadge(status: $section.status)
                }
            }

            Text(section.title)
                .font(.sectionTitle(level: section.headerLevel))
                .foregroundColor(themeManager.currentTheme.sidebarText)
                .lineLimit(2)
                .italic(section.isPseudoSection)
                .accessibilityLabel(accessibleTitle)
                // Tooltip handled by OutlineSidebar overlay for instant display

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
            onHoverChanged?(hovering)
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
        .overlay(alignment: .leading) {
            if isActive && !isGhost {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(themeManager.currentTheme.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 4)
            }
        }
        .contextMenu {
            Button("Duplicate Section") { onDuplicate?() }
                .disabled(section.isBibliography || section.isNotes || isZoomed)
                .accessibilityIdentifier("section-duplicate-button")
            Button("Delete Section", role: .destructive) { onDelete?() }
                .disabled(section.isBibliography || section.isNotes || isZoomed)
                .accessibilityIdentifier("section-delete-button")
        }
    }

    /// Accessible name for the card's title text, used by VoiceOver and XCUITest to
    /// locate a section card by its section name.
    /// `section.title` is always populated by construction (headings fall back to
    /// "(Untitled)", section breaks to "§ Section Break" or "§ <excerpt>" — see
    /// `Block.outlineTitle` and `SectionSyncService+Parsing.extractPseudoSectionTitle`),
    /// but this guards defensively in case an empty title ever reaches the view.
    private var accessibleTitle: String {
        guard !section.title.isEmpty else {
            return section.isPseudoSection ? "Section break" : "Untitled section"
        }
        return section.title
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
                    aggregateGoal: $section.aggregateGoal,
                    aggregateGoalType: $section.aggregateGoalType,
                    currentWordCount: section.wordCount,
                    aggregateWordCount: section.aggregateWordCount,
                    isPresented: $showingGoalEditor,
                    onSave: { onSectionUpdated?(section) }
                )
            }
    }

    private var wordCountColor: Color {
        let status: GoalStatus
        if section.aggregateGoal != nil {
            status = GoalStatus.calculate(
                wordCount: section.aggregateWordCount,
                goal: section.aggregateGoal,
                goalType: section.aggregateGoalType,
                thresholds: goalManager.settings.thresholds
            )
        } else {
            status = GoalStatus.calculate(
                wordCount: section.wordCount,
                goal: section.wordGoal,
                goalType: section.goalType,
                thresholds: goalManager.settings.thresholds
            )
        }

        switch status {
        case .met:
            return goalManager.effectiveMetColor(theme: themeManager.currentTheme)
        case .warning:
            return goalManager.effectiveWarningColor(theme: themeManager.currentTheme)
        case .notMet:
            return goalManager.effectiveNotMetColor(theme: themeManager.currentTheme)
        case .noGoal:
            return themeManager.currentTheme.sidebarText.opacity(0.6)
        }
    }
}

/// Popover for setting word count goals (section + aggregate)
struct WordCountGoalPopover: View {
    @Binding var wordGoal: Int?
    @Binding var goalType: GoalType
    @Binding var aggregateGoal: Int?
    @Binding var aggregateGoalType: GoalType
    let currentWordCount: Int
    let aggregateWordCount: Int
    @Binding var isPresented: Bool
    var onSave: (() -> Void)?

    // Local state to prevent flickering from @Observable re-renders
    @State private var sectionGoalInput: String
    @State private var localGoalType: GoalType
    @State private var aggGoalInput: String
    @State private var localAggGoalType: GoalType
    @Environment(ThemeManager.self) private var themeManager

    init(wordGoal: Binding<Int?>, goalType: Binding<GoalType>,
         aggregateGoal: Binding<Int?>, aggregateGoalType: Binding<GoalType>,
         currentWordCount: Int, aggregateWordCount: Int,
         isPresented: Binding<Bool>, onSave: (() -> Void)? = nil) {
        self._wordGoal = wordGoal
        self._goalType = goalType
        self._aggregateGoal = aggregateGoal
        self._aggregateGoalType = aggregateGoalType
        self.currentWordCount = currentWordCount
        self.aggregateWordCount = aggregateWordCount
        self._isPresented = isPresented
        self.onSave = onSave
        self._sectionGoalInput = State(initialValue: wordGoal.wrappedValue.map { String($0) } ?? "")
        self._localGoalType = State(initialValue: goalType.wrappedValue)
        self._aggGoalInput = State(initialValue: aggregateGoal.wrappedValue.map { String($0) } ?? "")
        self._localAggGoalType = State(initialValue: aggregateGoalType.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Word Goals")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(themeManager.currentTheme.sidebarTextSecondary)

            // Section Goal
            VStack(alignment: .leading, spacing: 6) {
                Text("Section Goal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.sidebarTextSecondary)

                HStack(spacing: 6) {
                    TextField("Goal", text: $sectionGoalInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)

                    goalTypePicker(selection: $localGoalType)
                }

                Text("Current: \(currentWordCount) words")
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.currentTheme.sidebarTextSecondary)
            }

            Divider()

            // Aggregate Goal
            VStack(alignment: .leading, spacing: 6) {
                Text("Aggregate Goal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(themeManager.currentTheme.sidebarTextSecondary)

                HStack(spacing: 6) {
                    TextField("Goal", text: $aggGoalInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)

                    goalTypePicker(selection: $localAggGoalType)
                }

                Text("Subtree: \(aggregateWordCount) words")
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.currentTheme.sidebarTextSecondary)
            }

            HStack {
                Button("Clear All") {
                    wordGoal = nil
                    goalType = .approx
                    aggregateGoal = nil
                    aggregateGoalType = .approx
                    sectionGoalInput = ""
                    aggGoalInput = ""
                    localGoalType = .approx
                    localAggGoalType = .approx
                    onSave?()
                    isPresented = false
                }
                .disabled(wordGoal == nil && aggregateGoal == nil)

                Spacer()

                Button("Done") {
                    // Commit section goal
                    if let value = Int(sectionGoalInput), value > 0 {
                        wordGoal = value
                    } else {
                        wordGoal = nil
                    }
                    goalType = localGoalType

                    // Commit aggregate goal
                    if let value = Int(aggGoalInput), value > 0 {
                        aggregateGoal = value
                    } else {
                        aggregateGoal = nil
                    }
                    aggregateGoalType = localAggGoalType

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

    private func goalTypePicker(selection: Binding<GoalType>) -> some View {
        Picker("", selection: selection) {
            ForEach(GoalType.allCases, id: \.self) { type in
                Text(type.displaySymbol).tag(type)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 100)
    }
}

/// ViewModel for binding Section data to UI
@Observable
class SectionViewModel: Identifiable {
    let id: String
    var projectId: String
    var parentId: String?
    var sortOrder: Double
    var headerLevel: Int
    var isPseudoSection: Bool  // Stored, not computed
    var isBibliography: Bool   // Auto-generated bibliography section
    var isNotes: Bool          // Auto-generated footnote notes section
    var title: String
    var markdownContent: String
    var status: SectionStatus
    var tags: [String]
    var wordGoal: Int?
    var goalType: GoalType
    var aggregateGoal: Int?
    var aggregateGoalType: GoalType
    var aggregateWordCount: Int = 0
    var wordCount: Int
    var startOffset: Int

    init(from section: Section) {
        self.id = section.id
        self.projectId = section.projectId
        self.parentId = section.parentId
        self.sortOrder = Double(section.sortOrder)
        self.headerLevel = section.headerLevel
        self.isPseudoSection = section.isPseudoSection
        self.isBibliography = section.isBibliography
        self.isNotes = section.isNotes
        self.title = section.title
        // Strip legacy bibliography marker from content (migration for old format)
        // The marker is now injected only for CodeMirror source mode, not stored.
        // Also strip the bibliography-end terminator (BlockParser.bibliographyEndMarker) —
        // this is display-only sidebar text, so unlike editorState.content the terminator
        // must NOT survive here (see SectionSyncService.stripBibliographyEndMarker's doc
        // comment).
        //
        // Unconditional, NOT gated on section.isBibliography: DocumentPreviewView.swift's
        // SnapshotSectionViewModel documents that Section.isBibliography is never actually
        // set true by any production writer, so a gated strip here would silently never
        // fire, letting the raw terminator text leak into this sidebar card's preview.
        // Both strips are pure substring removals — safe no-ops on any section that
        // doesn't contain the marker text at all.
        self.markdownContent = SectionSyncService.stripBibliographyEndMarker(
            from: section.markdownContent.replacingOccurrences(of: "<!-- ::auto-bibliography:: -->", with: "")
        )
        self.status = section.status
        self.tags = section.tags
        self.wordGoal = section.wordGoal
        self.goalType = section.goalType
        self.aggregateGoal = section.aggregateGoal
        self.aggregateGoalType = section.aggregateGoalType
        self.wordCount = section.wordCount
        self.startOffset = section.startOffset
    }

    init(from block: Block) {
        self.id = block.id
        self.projectId = block.projectId
        self.parentId = block.parentId
        self.sortOrder = block.sortOrder
        self.headerLevel = block.headingLevel ?? 1
        self.isPseudoSection = block.isPseudoSection
        self.isBibliography = block.isBibliography
        self.isNotes = block.isNotes
        self.title = block.outlineTitle
        self.markdownContent = block.markdownFragment
        self.status = block.status ?? .writing
        self.tags = block.tags ?? []
        self.wordGoal = block.wordGoal
        self.goalType = block.goalType
        self.aggregateGoal = block.aggregateGoal
        self.aggregateGoalType = block.aggregateGoalType
        self.wordCount = 0  // Populated externally via sectionOnlyWordCount
        self.startOffset = 0  // Not used for blocks (scroll by block ID)
    }

    /// Update this view model in place from a re-fetched `Block`, preserving object identity
    /// so SwiftUI's per-card `@Observable` dependency tracking doesn't tear down and reinstall
    /// on every database tick (see `EditorViewState.mergeSections`).
    ///
    /// Deliberately excludes `wordCount`, `aggregateWordCount`, and `startOffset`: those are
    /// placeholders in `init(from block: Block)` that the caller patches in afterward from a
    /// separate batch word-count fetch. Copying them here would write `wordCount = 0` on every
    /// merge before the counts loop overwrites it (an extra `@Observable` write per section per
    /// keystroke, undermining the fix this method exists for) and would zero out counts whenever
    /// that batch fetch fails, instead of retaining the last-known value.
    ///
    /// Also deliberately excludes `parentId`: `block.parentId` is always `nil` for the
    /// heading/pseudo-section rows this observation path fetches, and
    /// `EditorViewState.recalculateParentRelationships()` runs immediately after the merge on
    /// the same tick and sets the level-derived `parentId` on every object regardless. Writing
    /// it here would just be a second guarded-but-still-firing `@Observable` write on every
    /// section below H1, every tick, for no effect.
    ///
    /// Every assignment is equality-guarded: `@Observable` fires on any write, including one
    /// that writes the same value back, so an unguarded assignment would defeat the fix just as
    /// surely as replacing the object outright.
    ///
    /// Split into per-group helpers purely to keep cyclomatic complexity down; the field
    /// grouping and assignment order below is unchanged from the original single-function form.
    func apply(_ block: Block) {
        applyIdentity(from: block)
        applyContent(from: block)
        applyGoals(from: block)
    }

    /// Applies identity/structural fields: project, ordering, header level, and section-kind flags.
    private func applyIdentity(from block: Block) {
        if projectId != block.projectId { projectId = block.projectId }
        if sortOrder != block.sortOrder { sortOrder = block.sortOrder }
        let newHeaderLevel = block.headingLevel ?? 1
        if headerLevel != newHeaderLevel { headerLevel = newHeaderLevel }
        if isPseudoSection != block.isPseudoSection { isPseudoSection = block.isPseudoSection }
        if isBibliography != block.isBibliography { isBibliography = block.isBibliography }
        if isNotes != block.isNotes { isNotes = block.isNotes }
    }

    /// Applies content fields: title, markdown body, status, and tags.
    private func applyContent(from block: Block) {
        let newTitle = block.outlineTitle
        if title != newTitle { title = newTitle }
        let newMarkdownContent = block.markdownFragment
        if markdownContent != newMarkdownContent { markdownContent = newMarkdownContent }
        let newStatus = block.status ?? .writing
        if status != newStatus { status = newStatus }
        let newTags = block.tags ?? []
        if tags != newTags { tags = newTags }
    }

    /// Applies word-goal fields: section goal/type and aggregate goal/type.
    private func applyGoals(from block: Block) {
        if wordGoal != block.wordGoal { wordGoal = block.wordGoal }
        if goalType != block.goalType { goalType = block.goalType }
        if aggregateGoal != block.aggregateGoal { aggregateGoal = block.aggregateGoal }
        if aggregateGoalType != block.aggregateGoalType { aggregateGoalType = block.aggregateGoalType }
    }

    var goalProgress: Double? {
        guard let goal = wordGoal, goal > 0 else { return nil }
        return Double(wordCount) / Double(goal)
    }

    /// Goal status based on current word count, goal, and goal type
    /// Prefers aggregate goal when set
    var goalStatus: GoalStatus {
        if aggregateGoal != nil {
            return GoalStatus.calculate(wordCount: aggregateWordCount, goal: aggregateGoal, goalType: aggregateGoalType)
        }
        return GoalStatus.calculate(wordCount: wordCount, goal: wordGoal, goalType: goalType)
    }

    /// Display string for word count with goal type symbol when goal is set
    /// Shows aggregate (with sigma prefix) when aggregate goal is set
    var wordCountDisplay: String {
        if let aggGoal = aggregateGoal, aggGoal > 0 {
            return "\u{03A3} \(aggregateGoalType.displaySymbol)\(aggregateWordCount)/\(aggGoal)"
        }
        if let goal = wordGoal, goal > 0 {
            return "\(goalType.displaySymbol)\(wordCount)/\(goal)"
        }
        return "\(wordCount)"
    }

    func toSection(createdAt: Date, updatedAt: Date) -> Section {
        Section(
            id: id,
            projectId: projectId,
            parentId: parentId,
            sortOrder: Int(sortOrder),
            headerLevel: headerLevel,
            isPseudoSection: isPseudoSection,
            isBibliography: isBibliography,
            isNotes: isNotes,
            title: title,
            markdownContent: markdownContent,
            status: status,
            tags: tags,
            wordGoal: wordGoal,
            goalType: goalType,
            aggregateGoal: aggregateGoal,
            aggregateGoalType: aggregateGoalType,
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
        sortOrder: Double? = nil,
        headerLevel: Int? = nil,
        isPseudoSection: Bool? = nil,
        isBibliography: Bool? = nil,
        isNotes: Bool? = nil,
        markdownContent: String? = nil,
        startOffset: Int? = nil
    ) -> SectionViewModel {
        let section = Section(
            id: self.id,
            projectId: self.projectId,
            parentId: parentId ?? self.parentId,
            sortOrder: Int(sortOrder ?? self.sortOrder),
            headerLevel: headerLevel ?? self.headerLevel,
            isPseudoSection: isPseudoSection ?? self.isPseudoSection,
            isBibliography: isBibliography ?? self.isBibliography,
            isNotes: isNotes ?? self.isNotes,
            title: self.title,
            markdownContent: markdownContent ?? self.markdownContent,
            status: self.status,
            tags: self.tags,
            wordGoal: self.wordGoal,
            goalType: self.goalType,
            aggregateGoal: self.aggregateGoal,
            aggregateGoalType: self.aggregateGoalType,
            wordCount: self.wordCount,
            startOffset: startOffset ?? self.startOffset
        )
        let vm = SectionViewModel(from: section)
        // Preserve the original Double sortOrder if not explicitly changed
        vm.sortOrder = sortOrder ?? self.sortOrder
        // Preserve word count (not stored in Section)
        vm.wordCount = self.wordCount
        // Preserve aggregate word count (computed externally, not in Section)
        vm.aggregateWordCount = self.aggregateWordCount
        return vm
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
    .environment(GoalColorSettingsManager.shared)
}
