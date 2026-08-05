//
//  SceneID.swift
//  final final
//

enum SceneID {
    /// Also referenced by AppDelegate.swift's Finder duplicate-window guard
    /// (window.identifier?.rawValue.contains(SceneID.mainWindow)) and by the
    /// AppKit-derived frame-autosave key this identifier produces. Do not
    /// change this string without checking both call sites.
    static let mainWindow = "AppWindow"
}
