//
//  AnnotationDisplaySettings.swift
//  final final
//
//  The five annotation display settings the Annotations panel's display popover
//  controls -- three per-type display modes (Task / Comment / Reference, inline or
//  collapsed) and the two checkboxes (Panel Only, Hide Completed) -- plus the app-wide
//  DEFAULT for all five, which seeds every option a project has not saved.
//
//  Storage: one string row per setting in the PROJECT's own `settings` table (see
//  ProjectDatabase+Settings.swift), so the choice travels with the project. The app-wide
//  default is the full five-value settings value, stored as one JSON blob in `AppDefaults.store`
//  (UserDefaults), like `FocusModeSettings`. It is set from the popover's "Set as Default" button
//  (EditorViewState.saveCurrentAnnotationDisplayAsDefault()), never from Settings.
//
//  Persist on user intent, never on state change: the only code that writes the per-project rows
//  is the three user-action setters on EditorViewState (`setAnnotationDisplayMode`,
//  `setPanelOnlyMode`, `setHideCompletedTasks`); "Set as Default" writes only the app-wide
//  default and no project row. Loading, project reset, and Focus Mode's forced collapse all
//  assign the in-memory properties directly and can never write.
//

import Foundation

// MARK: - Storage Keys

/// Keys of the per-project `settings` rows that hold the five annotation display settings.
enum AnnotationDisplaySettingsKeys {
    /// Display mode of one annotation type, e.g. `annotationDisplayMode.comment`.
    static func mode(_ type: AnnotationType) -> String {
        "annotationDisplayMode.\(type.rawValue)"
    }

    /// Global "Panel Only" checkbox (`"true"` / `"false"`).
    static let panelOnly = "annotationPanelOnly"

    /// "Hide Completed" checkbox (`"true"` / `"false"`).
    static let hideCompleted = "annotationHideCompleted"

    /// Every key, so callers can enumerate them (loading, and asserting nothing was written).
    static let all: [String] = AnnotationType.allCases.map { mode($0) } + [panelOnly, hideCompleted]
}

// MARK: - Settings Value

/// The complete set of annotation display settings for one project.
struct AnnotationDisplaySettings: Equatable, Sendable {
    var modes: [AnnotationType: AnnotationDisplayMode]
    var isPanelOnlyMode: Bool
    var hideCompletedTasks: Bool

    /// What a project shows when it has nothing of its own saved (or when nothing could be
    /// loaded): the app-wide default for all five options -- the same state a fresh project
    /// opens in.
    static var fallback: AnnotationDisplaySettings {
        AnnotationDisplayDefaults.settings
    }

    /// Every type Inline, both checkboxes off: what the app showed before defaults existed, and
    /// the built-in value of every option. A project-switch reset applies THIS, never the stored
    /// default, so no transient default-derived state (e.g. Panel Only on) is ever broadcast to
    /// the editors between one project and the next.
    static let neutral = AnnotationDisplaySettings(
        modes: Dictionary(uniqueKeysWithValues: AnnotationType.allCases.map { ($0, AnnotationDisplayMode.inline) }),
        isPanelOnlyMode: false,
        hideCompletedTasks: false
    )
}

// MARK: - App-Wide Default

/// The app-wide default for all five annotation display options, used for every option of every
/// project that has no saved value of its own for it. The ONE writer is `setSettings`, called only
/// from `EditorViewState.saveCurrentAnnotationDisplayAsDefault()`.
enum AnnotationDisplayDefaults {
    /// One JSON blob under one key, like FocusModeSettings' own. Routed through `AppDefaults.store`
    /// (`.standard` in production, an isolated suite under any test run) rather than
    /// `UserDefaults.standard` directly, for the same reason as `FocusModeSettings.load()`: a
    /// hosted unit-test run must never read or overwrite the real user's preference.
    static let defaultsKey = "com.kerim.final-final.annotationDisplayDefaults"

    /// The stored shape. Every field decodes leniently and on its own, so one unreadable or
    /// missing field costs only that option, never the others.
    private struct Payload: Codable {
        var modes: [String: String]   // AnnotationType.rawValue -> AnnotationDisplayMode.rawValue
        var panelOnly: Bool
        var hideCompleted: Bool

        init(modes: [String: String], panelOnly: Bool, hideCompleted: Bool) {
            self.modes = modes
            self.panelOnly = panelOnly
            self.hideCompleted = hideCompleted
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // A checkbox that is absent or not a boolean reads as unticked -- indistinguishable, on
            // screen, from a default the user deliberately left unticked, so it is logged.
            func flag(_ key: CodingKeys) -> Bool {
                if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
                    return value
                }
                DebugLog.log(
                    .lifecycle,
                    "[AnnotationDisplay] Stored default display settings have no readable \(key.stringValue) value; treating it as unticked"
                )
                return false
            }
            modes = (try? container.decodeIfPresent([String: String].self, forKey: .modes)) ?? [:]
            panelOnly = flag(.panelOnly)
            hideCompleted = flag(.hideCompleted)
        }
    }

    /// What every option is before any default has been set: what the app did before defaults
    /// existed -- `.inline` for a mode, `false` for a checkbox.
    private static var builtIn: AnnotationDisplaySettings { .neutral }

    /// The app-wide default each of the five options falls back to. Nothing stored => every option
    /// is its built-in value. A stored blob that is a JSON object degrades PER OPTION: a mode that
    /// is missing or unrecognised reverts to Inline, a checkbox that is missing or not a boolean
    /// reverts to unticked, and the other options keep their stored values. A blob that is not a
    /// JSON object at all cannot be read, so ALL five options revert to their built-in values.
    static var settings: AnnotationDisplaySettings {
        guard let data = AppDefaults.store.data(forKey: defaultsKey) else { return builtIn }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            DebugLog.log(.lifecycle, "[AnnotationDisplay] Stored default display settings unreadable, using the built-in defaults: \(error)")
            return builtIn
        }
        var modes: [AnnotationType: AnnotationDisplayMode] = [:]
        for type in AnnotationType.allCases {
            modes[type] = payload.modes[type.rawValue].flatMap(AnnotationDisplayMode.init(rawValue:)) ?? .inline
        }
        return AnnotationDisplaySettings(modes: modes, isPanelOnlyMode: payload.panelOnly, hideCompletedTasks: payload.hideCompleted)
    }

    /// Store `settings` as the app-wide default for all five options. Writes no project row.
    static func setSettings(_ settings: AnnotationDisplaySettings) {
        var rawModes: [String: String] = [:]
        for (type, mode) in settings.modes {
            rawModes[type.rawValue] = mode.rawValue
        }
        let payload = Payload(modes: rawModes, panelOnly: settings.isPanelOnlyMode, hideCompleted: settings.hideCompletedTasks)
        do {
            AppDefaults.store.set(try JSONEncoder().encode(payload), forKey: defaultsKey)
        } catch {
            DebugLog.log(.lifecycle, "[AnnotationDisplay] Could not store the default display settings: \(error)")
        }
    }
}
