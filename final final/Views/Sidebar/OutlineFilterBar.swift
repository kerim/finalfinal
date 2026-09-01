//
//  OutlineFilterBar.swift
//  final final
//

import SwiftUI

/// Filter bar for the outline sidebar
/// Provides status filtering dropdown and word count display with document goal support
struct OutlineFilterBar: View {
    @Binding var selectedLevel: Int?
    @Binding var selectedFilter: SectionStatus?
    let visibleSections: [SectionViewModel]
    @Binding var documentGoal: Int?
    @Binding var documentGoalType: GoalType
    @Binding var excludeBibliography: Bool
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        HStack {
            // Header level filter
            Menu {
                Button {
                    selectedLevel = nil
                } label: {
                    HStack {
                        Text("All")
                        if selectedLevel == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Divider()

                ForEach(1...6, id: \.self) { level in
                    Button {
                        selectedLevel = level
                    } label: {
                        HStack {
                            Text(String(repeating: "#", count: level))
                            if selectedLevel == level {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(levelFilterLabel)
                        .lineLimit(1)
                }
                .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .tint(themeManager.currentTheme.accentColor)
            .fixedSize()

            // Status filter
            Menu {
                Button {
                    selectedFilter = nil
                } label: {
                    HStack {
                        Text("All")
                        if selectedFilter == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Divider()

                ForEach(SectionStatus.allCases, id: \.self) { status in
                    Button {
                        selectedFilter = status
                    } label: {
                        HStack {
                            Circle()
                                .fill(themeManager.currentTheme.statusColors.color(for: status))
                                .frame(width: 8, height: 8)
                            Text(status.displayName)
                            if selectedFilter == status {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text(filterLabel)
                        .lineLimit(1)
                }
                .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .tint(themeManager.currentTheme.accentColor)
            .fixedSize()

            Spacer()

            // Word count display with goal color (right-aligned). Extracted into its own leaf
            // view so that the word-count total -- which reads every visible section's
            // `wordCount` on every keystroke -- invalidates only this small leaf instead of the
            // whole filter bar (and, since this bar lives inside OutlineSidebar's body, the
            // whole sidebar). See FilteredWordCountLabel's doc comment.
            FilteredWordCountLabel(
                visibleSections: visibleSections,
                documentGoal: $documentGoal,
                documentGoalType: $documentGoalType,
                excludeBibliography: $excludeBibliography
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var levelFilterLabel: String {
        guard let level = selectedLevel else {
            return "#"
        }
        return String(repeating: "#", count: level)
    }

    private var filterLabel: String {
        guard let filter = selectedFilter else {
            return "All"
        }
        return filter.displayName
    }
}

/// Leaf view for the sidebar's word-count display. Extracted from `OutlineFilterBar` (bt
/// t-ef411da3, sidebar re-render investigation) so that summing `wordCount` across every visible
/// section -- necessarily an every-keystroke read of each section's `@Observable` `wordCount` --
/// invalidates only this small view, not `OutlineFilterBar` and (since `OutlineFilterBar` is
/// built inside `OutlineSidebar.body`) not the whole sidebar tree.
struct FilteredWordCountLabel: View {
    let visibleSections: [SectionViewModel]
    @Binding var documentGoal: Int?
    @Binding var documentGoalType: GoalType
    @Binding var excludeBibliography: Bool
    @Environment(ThemeManager.self) private var themeManager
    @Environment(GoalColorSettingsManager.self) private var goalManager
    @State private var showingGoalEditor = false

    /// Total word count of the given (already-filtered) sections, respecting
    /// `excludeBibliography`. `static` testable seam -- see `SidebarWordCountLeafTests`.
    static func total(of visible: [SectionViewModel], excludeBibliography: Bool) -> Int {
        visible.filter { !excludeBibliography || !$0.isBibliography }.reduce(0) { $0 + $1.wordCount }
    }

    var body: some View {
        let total = Self.total(of: visibleSections, excludeBibliography: excludeBibliography)
        #if DEBUG
        // swiftlint:disable:next redundant_discardable_let
        let _ = DebugLog.log(.viewUpdates, "[WordCountLabel] total=\(total)")
        #endif
        Text("\(total)")
            .font(.system(size: TypeScale.smallUI, weight: .medium, design: .monospaced))
            .foregroundColor(wordCountColor(total: total))
            .onTapGesture {
                showingGoalEditor = true
            }
            .popover(isPresented: $showingGoalEditor, arrowEdge: .bottom) {
                DocumentGoalPopover(
                    documentGoal: $documentGoal,
                    goalType: $documentGoalType,
                    excludeBibliography: $excludeBibliography,
                    currentWordCount: total,
                    isPresented: $showingGoalEditor
                )
            }
    }

    private func wordCountColor(total: Int) -> Color {
        let status = GoalStatus.calculate(
            wordCount: total,
            goal: documentGoal,
            goalType: documentGoalType,
            thresholds: goalManager.settings.thresholds
        )

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

/// Popover for setting document-level word count goals
struct DocumentGoalPopover: View {
    @Binding var documentGoal: Int?
    @Binding var goalType: GoalType
    @Binding var excludeBibliography: Bool
    let currentWordCount: Int
    @Binding var isPresented: Bool

    @State private var goalInput: String
    @Environment(ThemeManager.self) private var themeManager

    init(documentGoal: Binding<Int?>, goalType: Binding<GoalType>,
         excludeBibliography: Binding<Bool>, currentWordCount: Int,
         isPresented: Binding<Bool>) {
        self._documentGoal = documentGoal
        self._goalType = goalType
        self._excludeBibliography = excludeBibliography
        self.currentWordCount = currentWordCount
        self._isPresented = isPresented
        self._goalInput = State(initialValue: documentGoal.wrappedValue.map { String($0) } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Document Goal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(themeManager.currentTheme.sidebarTextSecondary)

            TextField("Goal (e.g., 5000)", text: $goalInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)

            Picker("Type", selection: $goalType) {
                ForEach(GoalType.allCases, id: \.self) { type in
                    Text("\(type.displaySymbol) \(type.displayName)")
                        .tag(type)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Exclude Bibliography", isOn: $excludeBibliography)
                .font(.system(size: 11))

            Text("Current: \(currentWordCount) words")
                .font(.system(size: 11))
                .foregroundColor(themeManager.currentTheme.sidebarTextSecondary)

            HStack {
                Button("Clear") {
                    documentGoal = nil
                    goalInput = ""
                }
                .disabled(documentGoal == nil)

                Spacer()

                Button("Done") {
                    if let value = Int(goalInput), value > 0 {
                        documentGoal = value
                    }
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

#Preview {
    @Previewable @State var levelFilter: Int?
    @Previewable @State var filter: SectionStatus?
    @Previewable @State var goal: Int? = 5000
    @Previewable @State var goalType: GoalType = .approx
    @Previewable @State var excludeBib: Bool = false

    VStack {
        OutlineFilterBar(
            selectedLevel: $levelFilter,
            selectedFilter: $filter,
            visibleSections: [],
            documentGoal: $goal,
            documentGoalType: $goalType,
            excludeBibliography: $excludeBib
        )
        Divider()
        Text("Selected: \(filter?.displayName ?? "All")")
    }
    .frame(width: 300)
    .environment(ThemeManager.shared)
    .environment(GoalColorSettingsManager.shared)
}
