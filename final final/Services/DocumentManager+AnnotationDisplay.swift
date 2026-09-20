//
//  DocumentManager+AnnotationDisplay.swift
//  final final
//
//  Per-project persistence of the five annotation display settings (three per-type display
//  modes, Panel Only, Hide Completed). See AnnotationDisplaySettings.swift for the storage
//  keys and the persist-on-user-intent rule: only EditorViewState's user-action setters call
//  the `save…` methods below; `loadAnnotationDisplaySettings()` is read-only.
//
//  Lives in its own file (like DocumentManager+RecentProjects.swift) so DocumentManager's
//  class body stays under SwiftLint's type_body_length limit.
//

import Foundation

extension DocumentManager {

    // MARK: - Annotation Display Settings

    /// Save one annotation type's display mode to the project's own `settings` table.
    /// Called only from EditorViewState's user-action setters -- never from load, reset, or
    /// Focus Mode (see AnnotationDisplaySettings.swift).
    func saveAnnotationDisplayMode(_ mode: AnnotationDisplayMode, for type: AnnotationType) throws {
        guard let db = projectDatabase else {
            throw DocumentError.noProjectOpen
        }
        try db.setSetting(key: AnnotationDisplaySettingsKeys.mode(type), value: mode.rawValue)
    }

    /// Save the "Panel Only" checkbox to the project's own `settings` table.
    func saveAnnotationPanelOnly(_ isPanelOnly: Bool) throws {
        guard let db = projectDatabase else {
            throw DocumentError.noProjectOpen
        }
        try db.setSetting(key: AnnotationDisplaySettingsKeys.panelOnly, value: isPanelOnly ? "true" : "false")
    }

    /// Save the "Hide Completed" checkbox to the project's own `settings` table.
    func saveAnnotationHideCompleted(_ hideCompleted: Bool) throws {
        guard let db = projectDatabase else {
            throw DocumentError.noProjectOpen
        }
        try db.setSetting(key: AnnotationDisplaySettingsKeys.hideCompleted, value: hideCompleted ? "true" : "false")
    }

    /// Load the current project's annotation display settings, or `nil` when no project is
    /// open. When a project is open, ALWAYS returns all five values, each falling back on its own
    /// to the app-wide default (`AnnotationDisplayDefaults.settings`) when the project has not
    /// saved it, so an old project with no rows simply picks up the default. Read-only -- it
    /// never writes, so opening a project can never create a row.
    func loadAnnotationDisplaySettings() throws -> AnnotationDisplaySettings? {
        guard let db = projectDatabase else { return nil }
        let stored = try db.getSettings(keys: AnnotationDisplaySettingsKeys.all)
        let defaults = AnnotationDisplayDefaults.settings

        var modes: [AnnotationType: AnnotationDisplayMode] = [:]
        for type in AnnotationType.allCases {
            modes[type] = stored[AnnotationDisplaySettingsKeys.mode(type)]
                .flatMap(AnnotationDisplayMode.init(rawValue:)) ?? defaults.modes[type] ?? .inline
        }

        // A row that is PRESENT and holds "true"/"false" wins. A row that is ABSENT, or present
        // holding anything else (a hand-edited or corrupted value), falls back to the app-wide
        // default -- never silently to false, which would look like the user had unticked it.
        func flag(_ key: String, default fallback: Bool) -> Bool {
            switch stored[key] {
            case "true": return true
            case "false": return false
            default: return fallback
            }
        }
        return AnnotationDisplaySettings(
            modes: modes,
            isPanelOnlyMode: flag(AnnotationDisplaySettingsKeys.panelOnly, default: defaults.isPanelOnlyMode),
            hideCompletedTasks: flag(AnnotationDisplaySettingsKeys.hideCompleted, default: defaults.hideCompletedTasks)
        )
    }
}
