//
//  EditorViewState+AnnotationDisplayLoading.swift
//  final final
//
//  How the open project's annotation display settings reach the screen WITHOUT a user action:
//  loading them when a project opens (with the app-wide default filling in every option the
//  project has not saved), and telling the editors the result. Loading assigns the in-memory
//  properties directly and NEVER writes to the database -- only the three user-action setters
//  in EditorViewState+Annotations.swift save (see AnnotationDisplaySettings.swift).
//

import SwiftUI

extension EditorViewState {

    /// Hand this window's CURRENT annotation display state (per-type modes, Panel Only, Hide
    /// Completed) to `post`, which delivers it to this window's editors (ContentView passes a
    /// closure over `AnnotationDisplayBroadcast.post` with this window's token).
    ///
    /// Used when a project is opened (`runProjectOpenSequence`) because the editors' own copy
    /// of this state (a module-level map in each web editor) is only otherwise changed by the
    /// `.onChange` observers, which report a CHANGE of the in-memory values. A project opened
    /// while Focus Mode is on ends with the same values it began with (every type collapsed),
    /// so nothing would be reported and the editors would keep whatever they were last sent.
    /// Reads state only; writes nothing.
    func publishAnnotationDisplayState(
        via post: @MainActor (_ modes: [AnnotationType: AnnotationDisplayMode], _ isPanelOnly: Bool, _ hideCompletedTasks: Bool) -> Void
    ) {
        post(annotationDisplayModes, isPanelOnlyMode, hideCompletedTasks)
    }

    /// Load the open project's annotation display settings and apply them -- the one
    /// load-and-assign path, used when a project opens.
    ///
    /// A load that returns `nil` (no project open) applies the defaults. A load that THROWS
    /// also applies the defaults, but says so with a warning toast rather than silently
    /// showing defaults over whatever the project actually saved.
    ///
    /// Focus Mode: a project opened while Focus Mode is on gets Focus Mode's inline override
    /// re-armed on top of its own values (last statement, AFTER they are applied, so the
    /// pre-Focus snapshot captures THIS project's values and exit restores them). Transient:
    /// nothing here is written.
    func loadAndApplyAnnotationDisplaySettings() {
        let loaded: AnnotationDisplaySettings?
        do {
            loaded = try DocumentManager.shared.loadAnnotationDisplaySettings()
        } catch {
            DebugLog.log(.lifecycle, "[AnnotationDisplay] Could not load settings, using defaults: \(error)")
            withAnimation {
                ToastCenter.shared.show(ToastFactory.annotationDisplaySettingsNotLoaded())
            }
            loaded = nil
        }
        applyAnnotationDisplaySettings(loaded)
        // Never before the load above: the snapshot would capture the defaults (H7). Only for
        // a real project: with none open (a close, or configure's no-project early return)
        // there is nothing for Focus Mode to override, and arming would leave the picker with
        // a forced state and a snapshot of defaults.
        if DocumentManager.shared.hasOpenProject {
            applyFocusModeInlineOverrideForCurrentProject()
        }
    }
}
