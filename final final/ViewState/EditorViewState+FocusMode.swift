//
//  EditorViewState+FocusMode.swift
//  final final
//

import SwiftUI

// MARK: - Focus Mode

extension EditorViewState {

    /// Simple toggle for legacy callers
    func toggleFocusMode() {
        if focusModeEnabled {
            exitFocusMode()
        } else {
            enterFocusMode()
        }
    }

    /// Enter focus mode with configurable UI hiding based on preferences
    ///
    /// Write rule: Focus Mode's own assignments are always direct and are never written to disk
    /// — they are a temporary layer over the project's saved values. A change the USER makes
    /// while Focus Mode is on goes through the saving setter instead: it is written to the
    /// project AND folded into the pre-Focus snapshot, so their explicit choice survives leaving
    /// Focus Mode. Do not "tidy" Focus Mode's assignments into the setters.
    ///
    /// The Annotations PANEL follows `hideRightSidebar`; the annotations shown INSIDE the text
    /// follow `inlineAnnotations` (collapse them, hide them via Panel Only, or leave them).
    func enterFocusMode() {
        guard !focusModeEnabled else { return }

        let settings = FocusModeSettingsManager.shared

        // 1. Capture pre-focus state — only for elements that will be modified.
        // wasInFullScreen deliberately uses isSettledFullScreen(), NOT isEffectivelyFullScreen():
        // an .entering phase here might be a still-unresolved request from an earlier,
        // already-ended Focus Mode session (e.g. one interrupted mid-transition), not a real
        // pre-existing full-screen state the user set independently. Treating that as "already
        // full screen" is what stranded users in full screen after exiting Focus Mode, having
        // never asked for native full screen at all. See FullScreenTransitionModel.isSettledFullScreen().
        preFocusModeState = FocusModeSnapshot(
            wasInFullScreen: FullScreenManager.isSettledFullScreen(),
            outlineSidebarVisible: settings.hideLeftSidebar ? isOutlineSidebarVisible : nil,
            annotationPanelVisible: settings.hideRightSidebar ? isAnnotationPanelVisible : nil,
            annotationDisplayModes: settings.inlineAnnotations == .collapse ? annotationDisplayModes : nil,
            annotationPanelOnly: settings.inlineAnnotations == .hide ? isPanelOnlyMode : nil
        )

        // 2. Enter full screen. FullScreenManager coalesces this against any transition
        // already in flight, so it's always safe to call unconditionally — no need to check
        // current state first, and no need to wait for the animation here.
        FullScreenManager.request(.fullScreen)

        // 3. Conditionally hide sidebars with animation
        // t-784ff3aa: only set the instant-toggle flag when this will actually flip
        // isAnnotationPanelVisible (it may already be false, e.g. the user hid it before
        // entering Focus Mode) -- see the flag's doc comment in EditorViewState.swift for why
        // an unconsumed flag would otherwise corrupt a later, unrelated toggle.
        if settings.hideRightSidebar && isAnnotationPanelVisible {
            isAnnotationPanelToggleInstant = true
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            if settings.hideLeftSidebar { isOutlineSidebarVisible = false }
        }
        // t-784ff3aa: deliberately OUTSIDE the withAnimation block above (unlike
        // isOutlineSidebarVisible, which stays inside it) -- AnnotationPanel's `.frame` derives
        // minWidth/maxWidth directly from this property, so any ambient animation active while
        // it changes gets applied to those bounds by SwiftUI regardless of what `snapToggle`
        // does to `panelWidth`. Assigning it with no animation in scope is what actually makes
        // the panel's Focus Mode transition instant; see snapToggle's doc comment.
        if settings.hideRightSidebar { isAnnotationPanelVisible = false }

        // 4. Inline annotations per the "Inline Annotations" preference (direct assignment only,
        // never the saving setters -- see the write rule above)
        switch settings.inlineAnnotations {
        case .collapse:
            for type in AnnotationType.allCases {
                annotationDisplayModes[type] = .collapsed
            }
        case .hide:
            isPanelOnlyMode = true
        case .leaveAsIs:
            break
        }

        // 5. Set runtime state for toolbar/status bar (read by views)
        focusModeHidesToolbar = settings.hideToolbar
        focusModeHidesStatusBar = settings.hideStatusBar

        // 6. Enable focus mode (triggers paragraph highlighting in editors)
        focusModeEnabled = true

        // 7. Show toast notification
        withAnimation {
            ToastCenter.shared.show(ToastFactory.focusModeHint())
        }
    }

    /// Exit focus mode, restoring only the elements that were modified on entry
    func exitFocusMode() {
        guard focusModeEnabled else { return }

        guard let snapshot = preFocusModeState else {
            // No snapshot available - just disable focus mode
            focusModeEnabled = false
            focusModeHidesToolbar = false
            focusModeHidesStatusBar = false
            return
        }

        // 1. Exit full screen ONLY if focus mode entered it (respect user's original state)
        if !snapshot.wasInFullScreen {
            FullScreenManager.request(.windowed)
        }

        // 2. Restore only elements that were captured (non-nil)
        // t-784ff3aa: same "only if it will actually change" guard as enterFocusMode() above --
        // if the panel's visibility never changed during Focus Mode (snapshot value already
        // matches current), there is nothing for AnnotationPanel's onChange to consume, and an
        // unconsumed flag would wrongly de-animate a later, unrelated toggle.
        if let visible = snapshot.annotationPanelVisible, visible != isAnnotationPanelVisible {
            isAnnotationPanelToggleInstant = true
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            if let visible = snapshot.outlineSidebarVisible { isOutlineSidebarVisible = visible }
        }
        // t-784ff3aa: deliberately OUTSIDE the withAnimation block above -- same reasoning as
        // enterFocusMode() above: this property drives AnnotationPanel's `.frame` bounds
        // directly, so it must land with no ambient animation in scope to actually be instant.
        if let visible = snapshot.annotationPanelVisible { isAnnotationPanelVisible = visible }

        // 3. Restore annotation display modes / Panel Only if they were captured (direct
        // assignment: restoring writes nothing)
        if let modes = snapshot.annotationDisplayModes { annotationDisplayModes = modes }
        if let panelOnly = snapshot.annotationPanelOnly { isPanelOnlyMode = panelOnly }

        // 4. Clear runtime state
        focusModeHidesToolbar = false
        focusModeHidesStatusBar = false

        // 5. Disable focus mode (disables paragraph highlighting in editors)
        focusModeEnabled = false

        // 6. Clear snapshot
        preFocusModeState = nil
    }

    /// Cold relaunch into Focus Mode: the setting is persisted as on but the pre-Focus snapshot is
    /// session-only, so it is nil. Re-enter Focus Mode to capture a fresh snapshot (of the
    /// project's own, already-loaded values) and apply the override and full screen.
    ///
    /// Idempotent by construction: it does nothing unless Focus Mode is on AND no snapshot exists
    /// yet, so however many callers reach it (the project-open sequence before the first publish,
    /// then ContentView's own launch call) only the first one captures -- a snapshot is never
    /// captured twice, and never over already-overridden values.
    func reenterFocusModeIfRestored() {
        guard focusModeEnabled, preFocusModeState == nil else { return }
        focusModeEnabled = false  // Reset first
        enterFocusMode()
    }

    // MARK: - Inline override across project switches and preference changes

    /// Re-arm Focus Mode's transient inline-annotation override for the project whose own saved
    /// settings have just been applied. Called from loadAndApplyAnnotationDisplaySettings()
    /// (a project opened while Focus Mode is on) AFTER applyAnnotationDisplaySettings(loaded),
    /// and from reconcileFocusInlineOverride() (the preference changed mid-Focus), so the
    /// snapshot holds THIS project's values and exiting Focus Mode restores them, never the
    /// previous project's. Writes nothing.
    ///
    /// Write rule: Focus Mode's own assignments are always direct and are never written to disk
    /// — they are a temporary layer over the project's saved values. A change the USER makes
    /// while Focus Mode is on goes through the saving setter instead: it is written to the
    /// project AND folded into the pre-Focus snapshot, so their explicit choice survives leaving
    /// Focus Mode. Do not "tidy" Focus Mode's assignments into the setters.
    ///
    /// Capture invariant: a snapshot field may only be (re)captured while it is nil. That is
    /// exactly the state resetForProjectSwitch() leaves behind, and it is what makes a second
    /// call within one project's lifetime safe -- it re-applies the override without overwriting
    /// the real pre-Focus values with already-overridden ones.
    ///
    /// No-op when Focus Mode is off, and when there is no snapshot yet: on a cold relaunch into
    /// Focus Mode, ContentView re-enters Focus Mode after initializeProject(), and
    /// enterFocusMode() does its own capture.
    ///
    /// The `.focusInlineAnnotationsChanged` notification that leads to reconcile is posted only
    /// from preference changes (the Focus pane, "Reset Focus Settings"); a project switch never
    /// posts it and reaches this method only through the project load.
    func applyFocusModeInlineOverrideForCurrentProject() {
        guard focusModeEnabled, preFocusModeState != nil else { return }
        switch FocusModeSettingsManager.shared.inlineAnnotations {
        case .leaveAsIs:
            break
        case .collapse:
            if preFocusModeState?.annotationDisplayModes == nil {
                preFocusModeState?.annotationDisplayModes = annotationDisplayModes
            }
            for type in AnnotationType.allCases {
                annotationDisplayModes[type] = .collapsed
            }
        case .hide:
            if preFocusModeState?.annotationPanelOnly == nil {
                preFocusModeState?.annotationPanelOnly = isPanelOnlyMode
            }
            isPanelOnlyMode = true
        }
    }

    /// The "Inline Annotations" Focus preference changed while Focus Mode is on: undo the
    /// override that is currently armed (so the project's own display comes back), forget what
    /// was captured, and re-arm for the NEW preference (which captures fresh, correct values).
    /// Switching Collapse to Leave As Is therefore restores the project's own display at once
    /// and leaves nothing to restore on exit; Collapse to Hide swaps one override for the other.
    ///
    /// No-op unless Focus Mode is on, has a snapshot, AND a project is open. The project gate is
    /// the same one loadAndApplyAnnotationDisplaySettings() puts on its re-arm: with no project
    /// open (Focus Mode still on at the project picker) there is nothing for Focus Mode to
    /// override, and arming would leave the picker with a forced state and a snapshot of
    /// defaults. Direct assignment only -- writes nothing (see the write rule on
    /// applyFocusModeInlineOverrideForCurrentProject()).
    func reconcileFocusInlineOverride() {
        guard focusModeEnabled, preFocusModeState != nil, DocumentManager.shared.hasOpenProject else { return }
        if let modes = preFocusModeState?.annotationDisplayModes { annotationDisplayModes = modes }
        if let panelOnly = preFocusModeState?.annotationPanelOnly { isPanelOnlyMode = panelOnly }
        preFocusModeState?.annotationDisplayModes = nil
        preFocusModeState?.annotationPanelOnly = nil
        applyFocusModeInlineOverrideForCurrentProject()
    }

    /// The user's OWN Panel Only choice, as opposed to the effective `isPanelOnlyMode`, which
    /// Inline Annotations = Hide forces on while Focus Mode is on. While Focus Mode holds that
    /// forced value, the user's own value lives in the pre-Focus snapshot; otherwise it is
    /// `isPanelOnlyMode` itself. The annotation display popover keys the enabled state of the
    /// per-type pickers off this, so Focus Mode's Hide never greys out a setting the user did
    /// not change (the Panel Only checkbox itself still shows the effective state).
    var userPanelOnlyChoice: Bool {
        preFocusModeState?.annotationPanelOnly ?? isPanelOnlyMode
    }

    /// True while Focus Mode is currently HOLDING an inline-annotation override, i.e. the display
    /// popover is showing transient values that are not the user's own: Inline Annotations =
    /// Collapse (the modes field is captured) or = Hide (the Panel Only field is captured). False
    /// for Leave As Is and whenever Focus Mode is off -- in both of those the popover already shows
    /// the user's own values. This is exactly the capture condition in enterFocusMode() and
    /// applyFocusModeInlineOverrideForCurrentProject(), so it can never disagree with what is
    /// armed. It says an override is ARMED, not that it changes anything on screen (Hide with
    /// Panel Only already on is armed but invisible): the "Set as Default" button keys off
    /// `focusModeAltersAnnotationDisplay` instead.
    var focusModeHoldsAnnotationDisplayOverride: Bool {
        preFocusModeState?.annotationDisplayModes != nil || preFocusModeState?.annotationPanelOnly != nil
    }

    /// True only while Focus Mode is actually CHANGING what the annotation display popover shows:
    /// the effective values (what is on screen) differ from the user's own five
    /// (`userAnnotationDisplaySettings`). It compares state to intent, not "was something captured":
    /// Hide with the user's own Panel Only already on, or Collapse with all three types already
    /// Collapsed, arms an override that changes nothing, so the popover then shows exactly the
    /// user's own values and "Set as Default" stays available. The button is disabled while this
    /// is true.
    var focusModeAltersAnnotationDisplay: Bool {
        let user = userAnnotationDisplaySettings
        return annotationDisplayModes != user.modes
            || isPanelOnlyMode != user.isPanelOnlyMode
            || hideCompletedTasks != user.hideCompletedTasks
    }

    /// The user's OWN five display settings, as opposed to the effective ones Focus Mode may be
    /// overriding. Collapse: the modes live in the snapshot, Panel Only is live. Hide: Panel Only
    /// lives in the snapshot, the modes are live (Hide never touches them). Leave As Is / Focus off:
    /// both live. Hide Completed is never touched by Focus Mode at all, so it is always the live
    /// value. Kept as defence in depth even though the popover's button is disabled while an
    /// override is armed: nothing here may ever store a transient value as the user's default.
    ///
    /// No interleaving to guard against: this, saveCurrentAnnotationDisplayAsDefault(),
    /// reconcileFocusInlineOverride(), enterFocusMode() and exitFocusMode() are all synchronous
    /// @MainActor code with no await inside, so the snapshot cannot be re-armed or cleared between
    /// reading a field here and writing the value out.
    var userAnnotationDisplaySettings: AnnotationDisplaySettings {
        AnnotationDisplaySettings(
            modes: preFocusModeState?.annotationDisplayModes ?? annotationDisplayModes,
            isPanelOnlyMode: userPanelOnlyChoice,
            hideCompletedTasks: hideCompletedTasks
        )
    }

}
