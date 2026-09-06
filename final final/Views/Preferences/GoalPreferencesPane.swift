//
//  GoalPreferencesPane.swift
//  final final
//
//  Preferences pane for word count goal thresholds and colors.
//

import SwiftUI

/// Goal preferences pane with threshold and color settings
struct GoalPreferencesPane: View {
    @Environment(ThemeManager.self) private var themeManager
    @Environment(GoalColorSettingsManager.self) private var goalManager

    // Local state for editing thresholds (to avoid saving on every keystroke)
    @State private var minWarning: Double = GoalThresholds.defaults.minWarningPercent
    @State private var maxWarning: Double = GoalThresholds.defaults.maxWarningPercent
    @State private var approxGreen: Double = GoalThresholds.defaults.approxGreenPercent
    @State private var approxOrange: Double = GoalThresholds.defaults.approxOrangePercent

    // Local state for color overrides
    @State private var metColor: Color = .green
    @State private var warningColor: Color = .orange
    @State private var notMetColor: Color = .red

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                thresholdsSection
                colorsSection
                resetAllSection
            }
            .padding()
        }
        .onAppear {
            loadCurrentSettings()
        }
    }

    // MARK: - Thresholds Section

    @ViewBuilder
    private var thresholdsSection: some View {
        GroupBox("Thresholds") {
            VStack(alignment: .leading, spacing: 16) {
                // Minimum Goal
                VStack(alignment: .leading, spacing: 4) {
                    Text("Minimum Goal")
                        .font(.headline)
                    Text("Red below threshold, orange up to 100%, green at 100%+")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    settingRow(
                        label: "Warning from",
                        isOverridden: goalManager.settings.thresholds.minWarningPercent != GoalThresholds.defaults.minWarningPercent,
                        onReset: {
                            minWarning = GoalThresholds.defaults.minWarningPercent
                            saveThresholds()
                        },
                        content: {
                            HStack {
                                Text("\(Int(minWarning))%")
                                    .monospacedDigit()
                                    .frame(width: 50, alignment: .trailing)
                                Stepper("", value: $minWarning, in: 50...99, step: 1)
                                    .labelsHidden()
                                    .onChange(of: minWarning) { _, _ in
                                        saveThresholds()
                                    }
                            }
                        }
                    )
                }

                Divider()

                // Maximum Goal
                VStack(alignment: .leading, spacing: 4) {
                    Text("Maximum Goal")
                        .font(.headline)
                    Text("Green up to 100%, orange up to threshold, red above")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    settingRow(
                        label: "Warning up to",
                        isOverridden: goalManager.settings.thresholds.maxWarningPercent != GoalThresholds.defaults.maxWarningPercent,
                        onReset: {
                            maxWarning = GoalThresholds.defaults.maxWarningPercent
                            saveThresholds()
                        },
                        content: {
                            HStack {
                                Text("\(Int(maxWarning))%")
                                    .monospacedDigit()
                                    .frame(width: 50, alignment: .trailing)
                                Stepper("", value: $maxWarning, in: 101...150, step: 1)
                                    .labelsHidden()
                                    .onChange(of: maxWarning) { _, _ in
                                        saveThresholds()
                                    }
                            }
                        }
                    )
                }

                Divider()

                // Approximate Goal
                VStack(alignment: .leading, spacing: 4) {
                    Text("Approximate Goal")
                        .font(.headline)
                    Text("Green within green range, orange within orange range, red beyond")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    settingRow(
                        label: "Green range",
                        isOverridden: goalManager.settings.thresholds.approxGreenPercent != GoalThresholds.defaults.approxGreenPercent,
                        onReset: {
                            approxGreen = GoalThresholds.defaults.approxGreenPercent
                            saveThresholds()
                        },
                        content: {
                            HStack {
                                Text("\u{00B1}\(Int(approxGreen))%")
                                    .monospacedDigit()
                                    .frame(width: 50, alignment: .trailing)
                                Stepper("", value: $approxGreen, in: 1...20, step: 1)
                                    .labelsHidden()
                                    .onChange(of: approxGreen) { _, _ in
                                        // Ensure orange >= green
                                        if approxOrange < approxGreen {
                                            approxOrange = approxGreen
                                        }
                                        saveThresholds()
                                    }
                            }
                        }
                    )

                    settingRow(
                        label: "Orange range",
                        isOverridden: goalManager.settings.thresholds.approxOrangePercent != GoalThresholds.defaults.approxOrangePercent,
                        onReset: {
                            approxOrange = GoalThresholds.defaults.approxOrangePercent
                            saveThresholds()
                        },
                        content: {
                            HStack {
                                Text("\u{00B1}\(Int(approxOrange))%")
                                    .monospacedDigit()
                                    .frame(width: 50, alignment: .trailing)
                                Stepper("", value: $approxOrange, in: approxGreen...30, step: 1)
                                    .labelsHidden()
                                    .onChange(of: approxOrange) { _, _ in
                                        saveThresholds()
                                    }
                            }
                        }
                    )
                }
            }
            .padding(8)
        }
    }

    // MARK: - Colors Section

    @ViewBuilder
    private var colorsSection: some View {
        GroupBox("Goal Colors") {
            VStack(alignment: .leading, spacing: 12) {
                settingRow(
                    label: "Met (green)",
                    isOverridden: goalManager.isMetColorOverridden(),
                    onReset: {
                        goalManager.setMetColor(nil)
                        metColor = goalManager.effectiveMetColor(theme: themeManager.currentTheme)
                    },
                    content: {
                        ColorPicker("", selection: $metColor, supportsOpacity: false)
                            .labelsHidden()
                            .onChange(of: metColor) { _, newValue in
                                goalManager.setMetColor(newValue)
                            }
                    }
                )

                settingRow(
                    label: "Warning (orange)",
                    isOverridden: goalManager.isWarningColorOverridden(),
                    onReset: {
                        goalManager.setWarningColor(nil)
                        warningColor = goalManager.effectiveWarningColor(theme: themeManager.currentTheme)
                    },
                    content: {
                        ColorPicker("", selection: $warningColor, supportsOpacity: false)
                            .labelsHidden()
                            .onChange(of: warningColor) { _, newValue in
                                goalManager.setWarningColor(newValue)
                            }
                    }
                )

                settingRow(
                    label: "Not Met (red)",
                    isOverridden: goalManager.isNotMetColorOverridden(),
                    onReset: {
                        goalManager.setNotMetColor(nil)
                        notMetColor = goalManager.effectiveNotMetColor(theme: themeManager.currentTheme)
                    },
                    content: {
                        ColorPicker("", selection: $notMetColor, supportsOpacity: false)
                            .labelsHidden()
                            .onChange(of: notMetColor) { _, newValue in
                                goalManager.setNotMetColor(newValue)
                            }
                    }
                )
            }
            .padding(8)
        }
    }

    // MARK: - Reset All

    @ViewBuilder
    private var resetAllSection: some View {
        HStack {
            Spacer()
            Button("Reset All to Defaults") {
                goalManager.resetToDefaults()
                loadCurrentSettings()
            }
            Spacer()
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func settingRow<Content: View>(
        label: String,
        isOverridden: Bool,
        onReset: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(label)
                .frame(width: 120, alignment: .leading)
            Spacer()
            content()
            if isOverridden {
                Button {
                    onReset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Reset to default")
            } else {
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption)
                    .opacity(0)
            }
        }
    }

    private func loadCurrentSettings() {
        let thresholds = goalManager.settings.thresholds
        minWarning = thresholds.minWarningPercent
        maxWarning = thresholds.maxWarningPercent
        approxGreen = thresholds.approxGreenPercent
        approxOrange = thresholds.approxOrangePercent

        metColor = goalManager.effectiveMetColor(theme: themeManager.currentTheme)
        warningColor = goalManager.effectiveWarningColor(theme: themeManager.currentTheme)
        notMetColor = goalManager.effectiveNotMetColor(theme: themeManager.currentTheme)
    }

    private func saveThresholds() {
        let thresholds = GoalThresholds(
            minWarningPercent: minWarning,
            maxWarningPercent: maxWarning,
            approxGreenPercent: approxGreen,
            approxOrangePercent: approxOrange
        )
        goalManager.updateThresholds(thresholds)
    }
}

#Preview {
    GoalPreferencesPane()
        .frame(width: 500, height: 600)
        .environment(ThemeManager.shared)
        .environment(GoalColorSettingsManager.shared)
}
