//
//  OutlineFilterBar.swift
//  final final
//

import SwiftUI

/// Filter bar for the outline sidebar
/// Provides status filtering dropdown and word count display with document goal support
struct OutlineFilterBar: View {
    @Binding var selectedFilter: SectionStatus?
    let filteredWordCount: Int
    @Binding var documentGoal: Int?
    @Binding var documentGoalType: GoalType
    @Binding var excludeBibliography: Bool
    @Environment(ThemeManager.self) private var themeManager
    @State private var showingGoalEditor = false

    var body: some View {
        HStack {
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

            // Word count display with goal color (right-aligned)
            Text("\(filteredWordCount)")
                .font(.system(size: TypeScale.smallUI, weight: .medium, design: .monospaced))
                .foregroundColor(wordCountColor)
                .onTapGesture {
                    showingGoalEditor = true
                }
                .popover(isPresented: $showingGoalEditor, arrowEdge: .bottom) {
                    DocumentGoalPopover(
                        documentGoal: $documentGoal,
                        goalType: $documentGoalType,
                        excludeBibliography: $excludeBibliography,
                        currentWordCount: filteredWordCount,
                        isPresented: $showingGoalEditor
                    )
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var filterLabel: String {
        guard let filter = selectedFilter else {
            return "All"
        }
        return filter.displayName
    }

    private var wordCountColor: Color {
        let status = GoalStatus.calculate(
            wordCount: filteredWordCount,
            goal: documentGoal,
            goalType: documentGoalType
        )

        switch status {
        case .met:
            return themeManager.currentTheme.statusColors.final_  // Green
        case .notMet:
            return .red
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
    @Previewable @State var filter: SectionStatus?
    @Previewable @State var goal: Int? = 5000
    @Previewable @State var goalType: GoalType = .approx
    @Previewable @State var excludeBib: Bool = false

    VStack {
        OutlineFilterBar(
            selectedFilter: $filter,
            filteredWordCount: 1234,
            documentGoal: $goal,
            documentGoalType: $goalType,
            excludeBibliography: $excludeBib
        )
        Divider()
        Text("Selected: \(filter?.displayName ?? "All")")
    }
    .frame(width: 300)
    .environment(ThemeManager.shared)
}
