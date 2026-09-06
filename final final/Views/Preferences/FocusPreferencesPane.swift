//
//  FocusPreferencesPane.swift
//  final final
//
//  Focus mode preferences pane for configuring which UI elements
//  are affected when entering focus mode.
//

import SwiftUI

struct FocusPreferencesPane: View {
    @State private var settingsManager = FocusModeSettingsManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Focus Mode") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose which UI elements are hidden when entering focus mode.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Hide Outline Sidebar", isOn: Binding(
                        get: { settingsManager.hideLeftSidebar },
                        set: { settingsManager.hideLeftSidebar = $0 }
                    ))

                    Toggle("Hide Annotation Panel", isOn: Binding(
                        get: { settingsManager.hideRightSidebar },
                        set: { settingsManager.hideRightSidebar = $0 }
                    ))

                    Toggle("Hide Toolbar", isOn: Binding(
                        get: { settingsManager.hideToolbar },
                        set: { settingsManager.hideToolbar = $0 }
                    ))

                    Toggle("Hide Status Bar", isOn: Binding(
                        get: { settingsManager.hideStatusBar },
                        set: { settingsManager.hideStatusBar = $0 }
                    ))

                    Toggle("Paragraph Highlighting", isOn: Binding(
                        get: { settingsManager.enableParagraphHighlighting },
                        set: { settingsManager.enableParagraphHighlighting = $0 }
                    ))
                }
                .padding(8)
            }

            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    settingsManager.resetToDefaults()
                }
            }

            Spacer()
        }
        .padding()
    }
}
