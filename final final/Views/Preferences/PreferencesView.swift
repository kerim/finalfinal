//
//  PreferencesView.swift
//  final final
//
//  Main preferences window container with tab navigation.
//

import SwiftUI

/// Tab identifiers for preferences
enum PreferencesTab: String, CaseIterable, Identifiable {
    case export
    case appearance
    case focus
    case goals
    case proofing
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .export: return "Export"
        case .appearance: return "Appearance"
        case .focus: return "Focus"
        case .goals: return "Goals"
        case .proofing: return "Proofing"
        case .diagnostics: return "Diagnostics"
        }
    }

    var icon: String {
        switch self {
        case .export: return "square.and.arrow.up"
        case .appearance: return "paintbrush"
        case .focus: return "eye.slash"
        case .goals: return "target"
        case .proofing: return "textformat.abc"
        case .diagnostics: return "stethoscope"
        }
    }
}

/// Main preferences window view
struct PreferencesView: View {
    /// Where a caller's request for a specific tab ("Export Preferences...", the toast's
    /// "Open Diagnostics") is held -- see PreferencesTabRouter for why it is stored, not
    /// just broadcast.
    @State private var router = PreferencesTabRouter.shared

    /// Starts on the requested tab if one is already waiting (cold launch: the request that
    /// opened this window was made before this view existed), else Export. Reading the
    /// request here does not clear it; `applyPendingTab()` does, on appear.
    @State private var selectedTab: PreferencesTab = PreferencesTabRouter.shared.initialTab

    var body: some View {
        TabView(selection: $selectedTab) {
            ExportPreferencesPane()
                .tabItem {
                    Label(PreferencesTab.export.title, systemImage: PreferencesTab.export.icon)
                }
                .tag(PreferencesTab.export)

            AppearancePreferencesPane()
                .tabItem {
                    Label(PreferencesTab.appearance.title, systemImage: PreferencesTab.appearance.icon)
                }
                .tag(PreferencesTab.appearance)

            FocusPreferencesPane()
                .tabItem {
                    Label(PreferencesTab.focus.title, systemImage: PreferencesTab.focus.icon)
                }
                .tag(PreferencesTab.focus)

            GoalPreferencesPane()
                .tabItem {
                    Label(PreferencesTab.goals.title, systemImage: PreferencesTab.goals.icon)
                }
                .tag(PreferencesTab.goals)

            ProofingPreferencesPane()
                .tabItem {
                    Label(PreferencesTab.proofing.title, systemImage: PreferencesTab.proofing.icon)
                }
                .tag(PreferencesTab.proofing)

            DiagnosticsPreferencesPane()
                .tabItem {
                    Label(PreferencesTab.diagnostics.title, systemImage: PreferencesTab.diagnostics.icon)
                }
                .tag(PreferencesTab.diagnostics)
        }
        .frame(width: 700, height: 550)
        .padding()
        // Both entry routes read the same stored request: on appear (a window created by the
        // request itself), and on change (a window that was already open).
        .onAppear { applyPendingTab() }
        .onChange(of: router.pendingTab) { _, _ in applyPendingTab() }
    }

    /// Switch to the requested tab, if any, and clear the request so it applies exactly once.
    private func applyPendingTab() {
        if let requested = router.consumePendingTab() {
            selectedTab = requested
        }
    }
}

#Preview {
    PreferencesView()
        .environment(ThemeManager.shared)
}
