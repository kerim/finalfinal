//
//  EditorViewState+Annotations.swift
//  final final
//

import SwiftUI

// MARK: - Annotation Filtering

extension EditorViewState {

    /// Document-level annotations (not anchored to markdown)
    var documentAnnotations: [AnnotationViewModel] {
        annotations.filter { $0.isDocumentLevel }
    }

    /// Document-level annotations filtered by type and completion status
    var displayDocumentAnnotations: [AnnotationViewModel] {
        documentAnnotations.filter { annotation in
            guard annotationTypeFilters.contains(annotation.type) else { return false }
            if hideCompletedTasks && annotation.type == .task && annotation.isCompleted {
                return false
            }
            return true
        }
    }

    /// Inline annotations to display in panel (filtered by type and completion status)
    var displayAnnotations: [AnnotationViewModel] {
        annotations.filter { annotation in
            // Exclude document-level (shown separately)
            guard !annotation.isDocumentLevel else { return false }

            // Must match type filter
            guard annotationTypeFilters.contains(annotation.type) else { return false }

            // Hide completed tasks if filter is on
            if hideCompletedTasks && annotation.type == .task && annotation.isCompleted {
                return false
            }

            return true
        }
    }

    /// Toggle visibility of an annotation type in the panel
    func toggleAnnotationTypeFilter(_ type: AnnotationType) {
        if annotationTypeFilters.contains(type) {
            annotationTypeFilters.remove(type)
        } else {
            annotationTypeFilters.insert(type)
        }
    }

    /// Set display mode for an annotation type -- a USER action, so it is saved to the open
    /// project (see AnnotationDisplaySettings.swift for the persist-on-user-intent rule).
    ///
    /// The save is deliberately synchronous, in the same MainActor turn as the assignment
    /// (no `Task`, no `await`): nothing can switch projects between the change and its write,
    /// so the value can never be written into the wrong project's database.
    ///
    /// Write rule (mirrored from EditorViewState+FocusMode.swift): Focus Mode's own assignments
    /// are always direct and are never written to disk — they are a temporary layer over the
    /// project's saved values. A change the USER makes while Focus Mode is on goes through the
    /// saving setter instead: it is written to the project AND folded into the pre-Focus
    /// snapshot, so their explicit choice survives leaving Focus Mode. Do not "tidy" Focus
    /// Mode's assignments into the setters. So Focus Mode's forced collapse and its restore on
    /// exit do NOT come through here.
    func setAnnotationDisplayMode(_ mode: AnnotationDisplayMode, for type: AnnotationType) {
        annotationDisplayModes[type] = mode

        // A change made inside Focus Mode also updates the pre-Focus snapshot, so the explicit
        // choice survives exiting Focus Mode (a no-op when there is no snapshot or it captured
        // no modes, so this never creates one).
        preFocusModeState?.annotationDisplayModes?[type] = mode

        persistAnnotationDisplaySetting("\(type.rawValue) display mode = \(mode.rawValue)") {
            try DocumentManager.shared.saveAnnotationDisplayMode(mode, for: type)
        }
    }

    /// Set the global "Panel Only" checkbox -- a USER action, saved synchronously to the
    /// open project (see `setAnnotationDisplayMode` for why).
    ///
    /// Write rule (mirrored from EditorViewState+FocusMode.swift): Focus Mode's own assignments
    /// are always direct and are never written to disk — they are a temporary layer over the
    /// project's saved values. A change the USER makes while Focus Mode is on goes through the
    /// saving setter instead: it is written to the project AND folded into the pre-Focus
    /// snapshot, so their explicit choice survives leaving Focus Mode. Do not "tidy" Focus
    /// Mode's assignments into the setters. (Inline Annotations = Hide forces Panel Only on as
    /// a Focus Mode assignment; a user who unticks it inside Focus Mode makes it their own
    /// choice: persisted, folded into the snapshot, kept after exit.)
    func setPanelOnlyMode(_ isPanelOnly: Bool) {
        isPanelOnlyMode = isPanelOnly

        // Fold a change made inside Focus Mode into the snapshot -- only when it already holds
        // a Panel Only value (Hide is armed), so this never creates one.
        if preFocusModeState?.annotationPanelOnly != nil {
            preFocusModeState?.annotationPanelOnly = isPanelOnly
        }

        persistAnnotationDisplaySetting("panel only = \(isPanelOnly)") {
            try DocumentManager.shared.saveAnnotationPanelOnly(isPanelOnly)
        }
    }

    /// Set the "Hide Completed" checkbox -- a USER action, saved synchronously to the open
    /// project (see `setAnnotationDisplayMode` for why).
    func setHideCompletedTasks(_ hideCompleted: Bool) {
        hideCompletedTasks = hideCompleted
        persistAnnotationDisplaySetting("hide completed = \(hideCompleted)") {
            try DocumentManager.shared.saveAnnotationHideCompleted(hideCompleted)
        }
    }

    /// Apply a project's loaded annotation display settings to the in-memory state.
    ///
    /// `nil` (no project open, or the load threw) means "use the app-wide default display
    /// settings" (`.fallback`): every value is STILL assigned -- never skipped -- so nothing from
    /// a previous project can survive a failed or empty load (`resetForProjectSwitch()` also
    /// resets these three properties, and this is the second line of defence).
    ///
    /// Assigns the properties directly, never through the setters above, so loading can never
    /// write to the database. See `loadAndApplyAnnotationDisplaySettings()` for the caller
    /// that loads and reports a failed load.
    func applyAnnotationDisplaySettings(_ settings: AnnotationDisplaySettings?) {
        let resolved = settings ?? .fallback
        annotationDisplayModes = resolved.modes
        isPanelOnlyMode = resolved.isPanelOnlyMode
        hideCompletedTasks = resolved.hideCompletedTasks
    }

    /// "Set as Default" in the display popover: store the user's OWN current five values as the
    /// app-wide defaults, which seed every project that has not saved that option.
    ///
    /// Writes NOTHING to any project database -- it never calls a DocumentManager save… method,
    /// so the open project's own rows are unchanged. The popover disables this while Focus Mode
    /// is actually changing what it shows (focusModeAltersAnnotationDisplay); reading
    /// userAnnotationDisplaySettings rather than the live properties is the second line of
    /// defence, so a forced collapse or forced Panel Only can never become the user's default.
    ///
    /// Cannot fail: the writer encodes only strings and booleans and `UserDefaults` reports no
    /// failure, so there is no failed-write outcome to surface and no failure toast is needed.
    /// Shows no success toast either: the popover's footer button confirms it itself, relabelling
    /// in place (see AnnotationFilterBar), and that is the ONLY success channel -- a toast can be
    /// swallowed behind a standing warning toast (ToastCenter rule 3), which would leave the
    /// action reporting nothing.
    /// Synchronous on the main actor, like the Focus Mode functions it reads from: no interleaving.
    func saveCurrentAnnotationDisplayAsDefault() {
        AnnotationDisplayDefaults.setSettings(userAnnotationDisplaySettings)
    }

    /// Run a save. On failure, log it and tell the user with a warning toast -- never throw:
    /// the in-memory change has already taken effect, and a failed save must not undo or block
    /// what the user just chose, but it must not go unnoticed either (the screen and the
    /// project would silently disagree).
    private func persistAnnotationDisplaySetting(_ label: String, save: () throws -> Void) {
        do {
            try save()
        } catch {
            DebugLog.log(.lifecycle, "[AnnotationDisplay] Failed to save \(label): \(error)")
            withAnimation {
                ToastCenter.shared.show(ToastFactory.annotationDisplaySettingsNotSaved())
            }
        }
    }

    /// Get display mode for an annotation type
    func displayMode(for type: AnnotationType) -> AnnotationDisplayMode {
        annotationDisplayModes[type] ?? .inline
    }

    /// Toggle annotation panel visibility
    func toggleAnnotationPanel() {
        isAnnotationPanelVisible.toggle()
    }

    /// Toggle outline sidebar visibility
    func toggleOutlineSidebar() {
        isOutlineSidebarVisible.toggle()
    }

    /// Get annotation counts by type (single-pass)
    var annotationCounts: [AnnotationType: Int] {
        annotations.reduce(into: [:]) { counts, annotation in
            counts[annotation.type, default: 0] += 1
        }
    }

    /// Get incomplete task count
    var incompleteTaskCount: Int {
        annotations.filter { $0.type == .task && !$0.isCompleted }.count
    }

    /// `annotation`'s position within the INLINE-only ordering -- the numbering the JS bridge
    /// functions (`getAnnotations()`/`scrollToAnnotation()`/`deleteInlineAnnotation()`) use on
    /// both web editors. Document Notes are DB-only rows (`charOffset < 0`, sorted first in
    /// `annotations`) that are never written into the document's markdown/nodes, so those JS
    /// functions never see or count them; any index computed against the FULL `annotations`
    /// array is therefore off by however many Document Notes exist, landing on the wrong
    /// annotation. This filters them out before indexing so callers land on the annotation the
    /// user actually clicked.
    ///
    /// Panel-display filters (`annotationTypeFilters`, `hideCompletedTasks`) deliberately do
    /// NOT enter this index: they only hide cards from the panel's own list, they never remove
    /// the corresponding node from the document, so the bridge's inline ordering is unaffected
    /// by them. Only Document Notes -- which really are absent from the document -- are
    /// excluded here.
    ///
    /// Returns `nil` if `annotation` is itself document-level (it has no inline index) or is
    /// not present in `annotations` at all.
    func inlineAnnotationIndex(of annotation: AnnotationViewModel) -> Int? {
        guard !annotation.isDocumentLevel else { return nil }
        return annotations
            .filter { !$0.isDocumentLevel }
            .firstIndex(where: { $0.id == annotation.id })
    }

}
