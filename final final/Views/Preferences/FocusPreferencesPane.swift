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

                    Toggle("Typewriter Scrolling", isOn: Binding(
                        get: { settingsManager.typewriterScrollingEnabled },
                        set: { settingsManager.typewriterScrollingEnabled = $0 }
                    ))
                    .accessibilityIdentifier("focusTypewriterScrollingToggle")

                    typewriterOffsetRow

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

    /// "Line Offset": how far below centre the rest line sits, in whole lines. Built exactly
    /// like `inlineAnnotationsRow`, because the UX contract has no rule for a numeric
    /// preference control and this follows the pane's existing menu idiom rather than
    /// inventing a slider. Disabled while Typewriter Scrolling is off, since it has no effect
    /// then.
    @ViewBuilder
    private var typewriterOffsetRow: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.s8, verticalSpacing: Spacing.s8) {
            GridRow {
                Text("Line Offset:")
                    .gridColumnAlignment(.trailing)
                Picker("Line Offset:", selection: Binding(
                    get: { settingsManager.typewriterLineOffset },
                    set: { settingsManager.typewriterLineOffset = $0 }
                )) {
                    ForEach(
                        Array(FocusModeSettings.typewriterLineOffsetRange),
                        id: \.self
                    ) { lines in
                        Text(Self.typewriterOffsetLabel(lines)).tag(lines)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(!settingsManager.typewriterScrollingEnabled)
                .accessibilityIdentifier("focusTypewriterLineOffsetPicker")
            }
            GridRow {
                Color.clear
                    .gridCellUnsizedAxes([.horizontal, .vertical])
                Text(
                    "Keeps the line you are typing on at the same height while Focus Mode is on. "
                        + "Positive numbers move it below centre, negative above."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Self.captionMeasure, alignment: .leading)
            }
        }
    }

    /// "Centred" for 0, "+3 Lines" / "-3 Lines" otherwise.
    private static func typewriterOffsetLabel(_ lines: Int) -> String {
        if lines == 0 { return "Centred" }
        return lines > 0 ? "+\(lines) Lines" : "\(lines) Lines"
    }
}
