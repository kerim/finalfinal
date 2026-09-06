//
//  DestructiveConfirmation.swift
//  final final
//
//  Shared copy and presentation for Tier 2 destructive-action confirmations
//  (local and permanent, but not touching document content) --
//  see .claude/rules/ux-contract.md §3.
//

import SwiftUI

/// Copy for a Tier 2 destructive confirmation: delete a preset, clear recent
/// projects, or reset a preferences pane to defaults. Every site that presents
/// one of these confirmations -- whether via `.confirmationDialog` (SwiftUI)
/// or `NSAlert` (a Commands-menu action, which SwiftUI cannot present a
/// confirmation dialog from) -- reads its wording from here, so the two
/// presentation mechanisms never drift.
enum DestructiveConfirmationCopy {
    case deletePreset(named: String)
    case clearRecentProjects
    case resetPane(PreferencesTab)

    /// The confirmation dialog's title. A verb phrase naming the object,
    /// never a bare "OK", "Yes", "Confirm", or unqualified verb.
    var title: String {
        switch self {
        case .deletePreset:
            return "Delete Preset"
        case .clearRecentProjects:
            return "Clear Recent Projects"
        case .resetPane(let tab):
            return "Reset \(tab.title) Settings"
        }
    }

    /// The confirmation dialog's body: one sentence on what happens, one on
    /// whether it can be undone.
    var message: String {
        switch self {
        case .deletePreset(let name):
            return "This deletes the preset \"\(name)\". This cannot be undone."
        case .clearRecentProjects:
            return "This removes every project from the Recent Projects list. This cannot be undone."
        case .resetPane(.appearance):
            // Appearance's "defaults" are the CURRENT THEME's built-in values (every
            // override becomes nil, falling back to the theme), not fixed factory
            // values -- AppearanceSettings.resetToDefaults() sets `.defaults`, whose
            // doc comment says exactly this. "to their defaults" alone would misstate
            // that as a fixed, theme-independent reset (review round finding).
            return "This restores the current theme's default settings. If you saved a preset, you can still reapply " +
                "those changes, otherwise all your style changes will be lost."
        case .resetPane(let tab):
            return "This resets all \(tab.title) settings to their defaults. This cannot be undone."
        }
    }

    /// The destructive button's label. Same verb-phrase-naming-the-object
    /// rule as `title`; the two are identical for every case today.
    var confirmTitle: String { title }

    /// A short, stable slug for accessibility identifiers -- derived from the
    /// case, not the (possibly interpolated) title, so it never contains
    /// spaces or the user-supplied preset name.
    var identifierSlug: String {
        switch self {
        case .deletePreset:
            return "delete-preset"
        case .clearRecentProjects:
            return "clear-recent-projects"
        case .resetPane(let tab):
            return "reset-\(tab.rawValue)"
        }
    }
}

extension View {
    /// Presents a Tier 2 destructive confirmation dialog: a Cancel button
    /// that is both the Return default and (via `role: .cancel`) the Escape
    /// action, and a destructive confirm button that is neither -- see
    /// .claude/rules/ux-contract.md §3, "Cancel is always present and is the
    /// default".
    ///
    /// Cancel is declared FIRST and carries both signals SwiftUI exposes for
    /// "this is the Return default" (`role: .cancel` alone only documents
    /// Escape on macOS): declaration order (`.confirmationDialog` renders as
    /// a real macOS alert panel, and AppKit's own `NSAlert.addButton`
    /// defaults the first-added button to Return) and the explicit
    /// `.keyboardShortcut(.defaultAction)` modifier. Applying both is
    /// deliberate belt-and-suspenders. Verified live via e2e
    /// (`E2EScratchTests`): Return does not trigger the destructive action;
    /// Cancel/dismissal is confirmed correct. The accessibility identifiers
    /// below exist specifically so an XCUITest can press Return on a live
    /// dialog and assert the destructive action did NOT fire.
    ///
    /// For a Commands-menu action, where SwiftUI cannot present a
    /// confirmation dialog at all, use an `NSAlert` built from the same
    /// `DestructiveConfirmationCopy` case instead (see
    /// `FileOperations.makeClearRecentProjectsAlert()`), which faces the same
    /// one-button/two-key-equivalents constraint and solves it with an
    /// AppKit-native relay button rather than a SwiftUI modifier.
    func destructiveConfirmation(
        _ copy: DestructiveConfirmationCopy,
        isPresented: Binding<Bool>,
        perform action: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            copy.title,
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("\(copy.identifierSlug)-cancel")
            Button(copy.confirmTitle, role: .destructive, action: action)
                .accessibilityIdentifier("\(copy.identifierSlug)-confirm")
        } message: {
            Text(copy.message)
        }
    }
}
