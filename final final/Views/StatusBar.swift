//
//  StatusBar.swift
//  final final
//

import SwiftUI

struct StatusBar: View {
    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        HStack {
            Text("0 words")
                .font(.caption)
            Spacer()
            Text("No section")
                .font(.caption)
            Spacer()
            Text("WYSIWYG")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(themeManager.currentTheme.accentColor.opacity(0.2))
                .cornerRadius(4)
        }
        .foregroundColor(themeManager.currentTheme.sidebarText.opacity(0.7))
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(themeManager.currentTheme.sidebarBackground)
    }
}

#Preview {
    StatusBar()
        .environment(ThemeManager.shared)
}
