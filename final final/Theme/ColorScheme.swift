//
//  ColorScheme.swift
//  final final
//
//  Stub - full theming in Phase 1.3.
//

import SwiftUI

struct AppColorScheme: Identifiable, Equatable {
    let id: String
    let name: String
    let sidebarBackground: Color
    let sidebarText: Color
    let sidebarSelectedBackground: Color
    let editorBackground: Color
    let editorText: Color
    let editorSelection: Color
    let accentColor: Color
    let dividerColor: Color
}

extension AppColorScheme {
    static let light = AppColorScheme(
        id: "light",
        name: "Light",
        sidebarBackground: Color(nsColor: .windowBackgroundColor),
        sidebarText: Color(nsColor: .labelColor),
        sidebarSelectedBackground: Color.accentColor.opacity(0.2),
        editorBackground: Color.white,
        editorText: Color.black,
        editorSelection: Color.accentColor.opacity(0.3),
        accentColor: Color.accentColor,
        dividerColor: Color(nsColor: .separatorColor)
    )

    static let dark = AppColorScheme(
        id: "dark",
        name: "Dark",
        sidebarBackground: Color(nsColor: .windowBackgroundColor),
        sidebarText: Color(nsColor: .labelColor),
        sidebarSelectedBackground: Color.accentColor.opacity(0.3),
        editorBackground: Color(white: 0.15),
        editorText: Color.white,
        editorSelection: Color.accentColor.opacity(0.4),
        accentColor: Color.accentColor,
        dividerColor: Color(nsColor: .separatorColor)
    )

    static let all: [AppColorScheme] = [.light, .dark]
}
