//
//  GoalPopover.swift
//  final final
//

import SwiftUI

/// Popover for setting word count goal on a section
struct GoalPopover: View {
    @Binding var wordGoal: Int?
    @Binding var isPresented: Bool
    @State private var goalText: String = ""
    @FocusState private var isFocused: Bool
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Word Goal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(themeManager.currentTheme.sidebarText)

            HStack {
                TextField("e.g., 500", text: $goalText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .focused($isFocused)
                    .onSubmit {
                        applyGoal()
                    }

                Text("words")
                    .font(.system(size: 12))
                    .foregroundColor(themeManager.currentTheme.sidebarTextSecondary)
            }

            HStack {
                Button("Clear") {
                    wordGoal = nil
                    isPresented = false
                }
                .buttonStyle(.borderless)

                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.borderless)

                Button("Set") {
                    applyGoal()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 200)
        .onAppear {
            if let goal = wordGoal {
                goalText = String(goal)
            }
            isFocused = true
        }
    }

    private func applyGoal() {
        if let value = Int(goalText), value > 0 {
            wordGoal = value
        }
        isPresented = false
    }
}

#Preview {
    @Previewable @State var goal: Int? = 500
    @Previewable @State var isPresented = true

    GoalPopover(wordGoal: $goal, isPresented: $isPresented)
}
