//
//  AnnotationFilterBar.swift
//  final final
//

import SwiftUI

/// Filter bar for annotation types and display modes
struct AnnotationFilterBar: View {
    @Binding var typeFilters: Set<AnnotationType>

    // The three display settings are read-only values plus explicit change callbacks, NOT
    // bindings: writing straight into a bound property would bypass the EditorViewState
    // setters that save the choice to the project (see AnnotationDisplaySettings.swift).
    let displayModes: [AnnotationType: AnnotationDisplayMode]
    let isPanelOnlyMode: Bool
    /// The user's OWN Panel Only choice (EditorViewState.userPanelOnlyChoice). Differs from
    /// `isPanelOnlyMode` only while Focus Mode's Inline Annotations = Hide is forcing Panel Only
    /// on: the Panel Only checkbox and the eye icon show the effective state, but the per-type
    /// pickers are disabled only by the user's own choice, so Focus Mode never greys them out.
    let userPanelOnlyChoice: Bool
    let hideCompletedTasks: Bool
    let onSetDisplayMode: (AnnotationType, AnnotationDisplayMode) -> Void
    let onSetPanelOnly: (Bool) -> Void
    let onSetHideCompleted: (Bool) -> Void
    /// "Set as Default": store this popover's five values as the app-wide defaults.
    let onSetAsDefault: () -> Void
    /// EditorViewState.focusModeAltersAnnotationDisplay: Focus Mode is currently CHANGING what this
    /// popover shows (a forced Collapsed / forced Panel Only that differs from the user's own
    /// values), so the values on screen are not the user's own and must not be offered as a default.
    let isFocusModeOverridingDisplay: Bool

    @Environment(ThemeManager.self) private var themeManager
    @State private var showDisplayModePopover = false
    /// True for a few seconds after "Set as Default" is pressed: the footer button relabels itself
    /// in place ("Saved as default", disabled) -- the outcome shown in the surface that owns the
    /// action, and the only success feedback. Reset when the popover closes.
    @State private var showsDefaultSavedConfirmation = false

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
                    .font(.system(size: TypeScale.annotationSmall))
                    .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Adjust display modes and set the app-wide default")
            .accessibilityIdentifier("annotationDisplayModeButton")
            .popover(isPresented: $showDisplayModePopover) {
                displayModePopover
            }
        }
        .padding(.horizontal, Spacing.s12)
        .padding(.vertical, Spacing.s8)
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
                    .font(.system(size: TypeScale.annotationSmall))
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
            Toggle(isOn: Binding(get: { isPanelOnlyMode }, set: onSetPanelOnly)) {
                HStack(spacing: Spacing.s8) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: TypeScale.annotationSmall))
                    Text("Panel Only")
                        .font(.system(size: TypeScale.annotationBody))
                }
            }
            .toggleStyle(.checkbox)
            .foregroundColor(themeManager.currentTheme.sidebarText)
            .help("Hide all annotations from the document text")
            .accessibilityIdentifier("annotationPanelOnlyToggle")

            // Hide completed tasks toggle
            Toggle(isOn: Binding(get: { hideCompletedTasks }, set: onSetHideCompleted)) {
                HStack(spacing: Spacing.s8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: TypeScale.annotationSmall))
                    Text("Hide Completed")
                        .font(.system(size: TypeScale.annotationBody))
                }
            }
            .toggleStyle(.checkbox)
            .foregroundColor(themeManager.currentTheme.sidebarText)
            .help("Hide completed tasks from panel")
            .accessibilityIdentifier("annotationHideCompletedToggle")

            Divider()
                .opacity(userPanelOnlyChoice ? 0.3 : 1)

            // Per-type display mode pickers (disabled when the USER's own Panel Only is on; a
            // Panel Only forced by Focus Mode's Hide does not disable them)
            ForEach(AnnotationType.allCases, id: \.self) { type in
                displayModeRow(for: type)
            }
            .opacity(userPanelOnlyChoice ? 0.4 : 1)
            .disabled(userPanelOnlyChoice)

            Divider()

            setAsDefaultFooter
        }
        .padding(Spacing.s16)
        .frame(width: Self.popoverWidth)
        // Bounded and cancelable: this task exists only while the confirmation shows, is cancelled
        // the moment it stops showing (id change), and with the popover (view removal).
        .task(id: showsDefaultSavedConfirmation) {
            guard showsDefaultSavedConfirmation else { return }
            try? await Task.sleep(for: Self.savedConfirmationDuration)
            guard !Task.isCancelled else { return }
            showsDefaultSavedConfirmation = false
        }
        .onDisappear { showsDefaultSavedConfirmation = false }
    }

    // MARK: - "Set as Default"

    private static let setAsDefaultHelp =
        "Save these settings as the default. Each project that hasn't chosen its own value for a setting " +
        "will use it. This project's own saved settings don't change."

    private static let setAsDefaultDisabledReason = "Unavailable while Focus Mode is changing how annotations are shown."

    /// How long the button stays relabelled "Saved as default" before it reverts.
    private static let savedConfirmationDuration: Duration = .seconds(3)

    /// The popover's secondary text colour, at full opacity: the disabled button and the caption
    /// that explains it share it, so the control is never fainter than its own explanation.
    private var secondaryTextColor: Color {
        themeManager.currentTheme.sidebarTextSecondary
    }

    /// The tooltip and the VoiceOver hint: what the button does, or why it is unavailable.
    private var setAsDefaultExplanation: String {
        isFocusModeOverridingDisplay ? Self.setAsDefaultDisabledReason : Self.setAsDefaultHelp
    }

    /// The popover's one action: store its five values as the app-wide defaults. The button, with
    /// the reason under it while it is unavailable.
    private var setAsDefaultFooter: some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            setAsDefaultButton
            if isFocusModeOverridingDisplay && !showsDefaultSavedConfirmation {
                // The reason is on screen, not only in a tooltip: a disabled control shows no
                // tooltip reliably, and a keyboard-only user never hovers.
                Text(Self.setAsDefaultDisabledReason)
                    .font(.system(size: TypeScale.annotationSmall))
                    .foregroundColor(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("annotationSetAsDefaultDisabledReason")
            }
        }
    }

    /// The button, one control in three states -- the affordance never leaves the row:
    /// - Ready: accent colour, "Set as Default", identifier `annotationSetAsDefaultButton`.
    /// - Unavailable (Focus Mode is changing what the popover shows, so the values on screen are
    ///   Focus Mode's, not the user's own): disabled, in the caption's colour (NOT dimmed further:
    ///   that convention belongs to the type rows, which have a picker pill behind the value),
    ///   identifier `annotationSetAsDefaultButton`.
    /// - Confirming, for a few seconds after a press: the SAME control relabelled in place with a
    ///   checkmark and "Saved as default", still disabled, identifier
    ///   `annotationSetAsDefaultConfirmation` (one element carries one identifier, so this is the
    ///   distinct handle for the confirming state). The icon and label swap; the row's height and
    ///   the popover's width do not change. This is the only success feedback -- no toast.
    /// Themed like the rest of this popover (§7a: opened from the Annotations panel), with the icon
    /// + text pattern of its two toggles plus the theme's accent colour, so a plain-style footer
    /// button does not read as a label.
    private var setAsDefaultButton: some View {
        Button(action: setAsDefault) {
            HStack(spacing: Spacing.s8) {
                Image(systemName: showsDefaultSavedConfirmation ? "checkmark" : "square.and.arrow.down")
                    .font(.system(size: TypeScale.annotationSmall))
                Text(showsDefaultSavedConfirmation ? "Saved as default" : "Set as Default")
                    .font(.system(size: TypeScale.annotationBody))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(
            isFocusModeOverridingDisplay && !showsDefaultSavedConfirmation
                ? secondaryTextColor
                : themeManager.currentTheme.accentColor
        )
        .disabled(isFocusModeOverridingDisplay || showsDefaultSavedConfirmation)
        .help(setAsDefaultExplanation)
        .accessibilityLabel(showsDefaultSavedConfirmation ? "Saved as default" : "Set as Default")
        .accessibilityHint(setAsDefaultExplanation)
        .accessibilityIdentifier(
            showsDefaultSavedConfirmation ? "annotationSetAsDefaultConfirmation" : "annotationSetAsDefaultButton"
        )
    }

    private func setAsDefault() {
        onSetAsDefault()
        showsDefaultSavedConfirmation = true
    }

    /// Popover width, sized from the widest row ("Reference" is the widest label): marker glyph + gap +
    /// label + gap + `displayModePickerWidth`. 240 was too small in the VM: the label column lost the
    /// width the control column gained and "Comment" / "Reference" wrapped mid-word. The labels need
    /// about what the old 280 layout gave them, so 260 = a 228pt content area (`popoverWidth - 2 * s16`).
    private static let popoverWidth: CGFloat = 260

    /// Fits "Collapsed" plus the menu chevron, which a `.menu` Picker draws at its intrinsic ~108pt
    /// (the previous 90pt clipped it to "Collaps..."). The Picker does not stretch, so the frame is
    /// leading-aligned: every row's popup then starts at the same x whatever value it shows.
    private static let displayModePickerWidth: CGFloat = 110

    private func displayModeRow(for type: AnnotationType) -> some View {
        HStack(spacing: Spacing.s8) {
            Text(type.collapsedMarker)
                .font(.system(size: TypeScale.annotationBody))
            Text(type.displayName)
                .font(.system(size: TypeScale.annotationBody))
                .foregroundColor(themeManager.currentTheme.sidebarText)
                .lineLimit(1) // a narrower popover must truncate visibly, never wrap mid-word

            Spacer(minLength: Spacing.s4)

            // A real label ("Task display mode", ...), visually hidden because the row's own
            // Text names the type: VoiceOver still reads which type this picker changes.
            // The selection is always the project's SAVED mode, also while Panel Only disables
            // the row: Panel Only never touches the per-type modes.
            Picker("\(type.displayName) display mode", selection: Binding(
                get: { displayModes[type] ?? .inline },
                set: { onSetDisplayMode(type, $0) }
            )) {
                ForEach(AnnotationDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: Self.displayModePickerWidth, alignment: .leading)
            .accessibilityIdentifier("annotationDisplayModePicker.\(type.rawValue)")
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
            displayModes: modes,
            isPanelOnlyMode: panelOnly,
            userPanelOnlyChoice: panelOnly,
            hideCompletedTasks: hideCompleted,
            onSetDisplayMode: { type, mode in modes[type] = mode },
            onSetPanelOnly: { panelOnly = $0 },
            onSetHideCompleted: { hideCompleted = $0 },
            onSetAsDefault: {},
            isFocusModeOverridingDisplay: false
        )
    }
    .frame(width: 280)
    .background(Color(nsColor: .windowBackgroundColor))
    .environment(ThemeManager.shared)
}
