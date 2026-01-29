//
//  AnnotationFilterBar.swift
//  final final
//

import SwiftUI

/// Filter bar for annotation types and display modes
struct AnnotationFilterBar: View {
    @Binding var typeFilters: Set<AnnotationType>
    @Binding var displayModes: [AnnotationType: AnnotationDisplayMode]
    @Binding var isPanelOnlyMode: Bool
    @Binding var hideCompletedTasks: Bool

    @Environment(ThemeManager.self) private var themeManager
    @State private var showDisplayModePopover = false

    var body: some View {
        HStack(spacing: 4) {
            // Type filter toggles
            ForEach(AnnotationType.allCases, id: \.self) { type in
                typeFilterButton(for: type)
            }

            Spacer()

            // Display mode button
            Button {
                showDisplayModePopover = true
            } label: {
                Image(systemName: isPanelOnlyMode ? "eye.slash" : "eye")
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Adjust display modes")
            .popover(isPresented: $showDisplayModePopover) {
                displayModePopover
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(themeManager.currentTheme.sidebarBackground.opacity(0.3))
    }

    private func typeFilterButton(for type: AnnotationType) -> some View {
        let isSelected = typeFilters.contains(type)

        return Button {
            if isSelected {
                typeFilters.remove(type)
            } else {
                typeFilters.insert(type)
            }
        } label: {
            HStack(spacing: 2) {
                Text(type.collapsedMarker)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                isSelected
                    ? themeManager.currentTheme.accentColor.opacity(0.2)
                    : Color.clear
            )
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .help("\(isSelected ? "Hide" : "Show") \(type.displayName.lowercased())s")
    }

    private var displayModePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Display Modes")
                .font(.headline)
                .foregroundColor(themeManager.currentTheme.sidebarText)

            // Global "Panel Only" toggle
            Toggle(isOn: $isPanelOnlyMode) {
                HStack(spacing: 6) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 11))
                    Text("Panel Only")
                        .font(.system(size: 12))
                }
            }
            .toggleStyle(.checkbox)
            .foregroundColor(themeManager.currentTheme.sidebarText)
            .help("Hide all annotations from editor")

            // Hide completed tasks toggle
            Toggle(isOn: $hideCompletedTasks) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                    Text("Hide Completed")
                        .font(.system(size: 12))
                }
            }
            .toggleStyle(.checkbox)
            .foregroundColor(themeManager.currentTheme.sidebarText)
            .help("Hide completed tasks from panel")

            Divider()
                .opacity(isPanelOnlyMode ? 0.3 : 1)

            // Per-type display mode pickers (disabled when panel-only mode is on)
            ForEach(AnnotationType.allCases, id: \.self) { type in
                displayModeRow(for: type)
            }
            .opacity(isPanelOnlyMode ? 0.4 : 1)
            .disabled(isPanelOnlyMode)
        }
        .padding()
        .frame(width: 220)
    }

    private func displayModeRow(for type: AnnotationType) -> some View {
        HStack {
            Text(type.collapsedMarker)
                .font(.system(size: 12))
            Text(type.displayName)
                .font(.system(size: 12))
                .foregroundColor(themeManager.currentTheme.sidebarText)

            Spacer()

            Picker("", selection: Binding(
                get: { displayModes[type] ?? .inline },
                set: { displayModes[type] = $0 }
            )) {
                ForEach(AnnotationDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 90)
        }
    }
}

#Preview {
    @Previewable @State var filters: Set<AnnotationType> = Set(AnnotationType.allCases)
    @Previewable @State var modes: [AnnotationType: AnnotationDisplayMode] = [
        .task: .inline,
        .comment: .collapsed,
        .reference: .collapsed
    ]
    @Previewable @State var panelOnly = false
    @Previewable @State var hideCompleted = false

    VStack {
        AnnotationFilterBar(
            typeFilters: $filters,
            displayModes: $modes,
            isPanelOnlyMode: $panelOnly,
            hideCompletedTasks: $hideCompleted
        )
    }
    .frame(width: 280)
    .background(Color(nsColor: .windowBackgroundColor))
    .environment(ThemeManager.shared)
}
