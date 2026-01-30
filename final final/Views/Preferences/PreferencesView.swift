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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .export: return "Export"
        case .appearance: return "Appearance"
        }
    }

    var icon: String {
        switch self {
        case .export: return "square.and.arrow.up"
        case .appearance: return "paintbrush"
        }
    }
}

/// Main preferences window view
struct PreferencesView: View {
    @State private var selectedTab: PreferencesTab = .export

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
        }
        .frame(width: 500, height: 400)
        .padding()
    }
}

/// Placeholder for appearance preferences (future expansion)
struct AppearancePreferencesPane: View {
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Theme") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Theme", selection: Binding(
                        get: { themeManager.currentTheme.id },
                        set: { themeManager.setTheme(byId: $0) }
                    )) {
                        ForEach(AppColorScheme.all) { scheme in
                            Text(scheme.name).tag(scheme.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .padding(8)
            }

            GroupBox("Coming Soon") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Additional appearance settings will be added in future updates.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .padding(8)
            }

            Spacer()
        }
        .padding()
    }
}

#Preview {
    PreferencesView()
        .environment(ThemeManager.shared)
}
