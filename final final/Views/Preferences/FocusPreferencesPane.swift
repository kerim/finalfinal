//
//  FocusPreferencesPane.swift
//  final final
//
//  Focus mode preferences pane for configuring which UI elements
//  are affected when entering focus mode.
//
//  Layer model for the annotations shown in the text: Focus Mode's "Inline Annotations"
//  choice > the project's own saved display setting > the app-wide default (the annotation
//  display popover's "Set as Default"). Focus Mode's layer
//  is in memory only -- it is never saved to the project, and it never changes what the
//  annotation display popover shows as the user's own choice once Focus Mode is left.
//  Native styling only (UX contract §7a): no theme colours, no raw sizes.
//

import SwiftUI

struct FocusPreferencesPane: View {
    @State private var settingsManager = FocusModeSettingsManager.shared
    @State private var showingResetConfirmation = false

    /// Reading measure of the caption under the Inline Annotations menu: it wraps within this
    /// width instead of running as one line across the whole window.
    private static let captionMeasure: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s24) {
            GroupBox("Focus Mode") {
                VStack(alignment: .leading, spacing: Spacing.s12) {
                    Text("Choose what Focus Mode changes while you write.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Hide Outline Panel", isOn: Binding(
                        get: { settingsManager.hideLeftSidebar },
                        set: { settingsManager.hideLeftSidebar = $0 }
                    ))

                    // The panel only: what happens to the annotations IN the text is the
                    // Inline Annotations menu below.
                    Toggle("Hide Annotations Panel", isOn: Binding(
                        get: { settingsManager.hideRightSidebar },
                        set: { settingsManager.hideRightSidebar = $0 }
                    ))
                    .accessibilityIdentifier("focusHideAnnotationsPanelToggle")

                    inlineAnnotationsRow

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
                    .accessibilityIdentifier("focusParagraphHighlightingToggle")
                }
                // Fills the group box's width, so the box spans the window and the pane sits at the
                // same leading inset as the Export pane. Without it the box hugs its
                // content and the Settings tab container centres the whole pane.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.s8)
            }
            .accessibilityIdentifier("focusGroup")

            HStack {
                Spacer()
                Button("Reset Focus Settings") {
                    showingResetConfirmation = true
                }
            }
            .destructiveConfirmation(.resetPane(.focus), isPresented: $showingResetConfirmation) {
                settingsManager.resetToDefaults()
            }

            Spacer()
        }
        .padding()
    }

    /// "Inline Annotations": what Focus Mode does to the annotations shown in the text. A
    /// two-column row: a trailing-aligned label with a colon, the menu after it, and the caption
    /// under the menu.
    @ViewBuilder
    private var inlineAnnotationsRow: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.s8, verticalSpacing: Spacing.s8) {
            GridRow {
                Text("Inline Annotations:")
                    .gridColumnAlignment(.trailing)
                // The label is the row's own Text; the Picker keeps it as its accessibility label.
                // The identifier sits on the popup button itself (labelsHidden + fixedSize leave
                // the Picker as just that button), which is what the e2e helper drives.
                Picker("Inline Annotations:", selection: Binding(
                    get: { settingsManager.inlineAnnotations },
                    set: { settingsManager.inlineAnnotations = $0 }
                )) {
                    ForEach(FocusInlineAnnotationMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("focusInlineAnnotationsPicker")
            }
            GridRow {
                Color.clear
                    .gridCellUnsizedAxes([.horizontal, .vertical])
                Text(
                    "Changes only how annotations appear in your text; with Hide, they are still listed in the "
                        + "Annotations panel. Your own display settings come back when you leave Focus Mode, "
                        + "unless you change them while you are in it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Self.captionMeasure, alignment: .leading)
            }
        }
    }
}
