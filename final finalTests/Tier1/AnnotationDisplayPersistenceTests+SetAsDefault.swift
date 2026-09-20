//
//  AnnotationDisplayPersistenceTests+SetAsDefault.swift
//  final finalTests
//
//  Tier 1: "Set as Default" (EditorViewState.saveCurrentAnnotationDisplayAsDefault()) while Focus
//  Mode is on. Focus Mode's Inline Annotations override shows the popover TRANSIENT values -- a
//  forced Collapse in the per-type modes, or a forced Panel Only -- and the action must always
//  store the user's OWN five values, never those. The popover disables its button while Focus Mode
//  is actually CHANGING what it shows (`focusModeAltersAnnotationDisplay`); the first five tests
//  cover the function underneath, which stays correct on its own, and the rest cover the
//  disabled condition.
//
//  An extension of `AnnotationDisplayPersistenceTests` in its own file (so neither the suite's type
//  nor the Focus Mode file goes over SwiftLint's size limits). The same suite, so these tests stay
//  serialized with the others -- they share DocumentManager.shared and the Focus / default singletons.
//

import Testing
import Foundation
@testable import final_final

extension AnnotationDisplayPersistenceTests {

    // Acceptance bar: fails if the action reads the live properties instead of the user's own
    // values -- under Collapse it would store all three types Collapsed.
    @Test("Set as Default under Collapse stores the user's own modes, not the forced collapse")
    @MainActor
    func setAsDefaultUnderCollapseStoresTheUsersOwnModes() throws {
        let dir = try makeTempDir()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir) }
        try openFixture(named: "SetDefaultCollapse", in: dir)
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        defer { FullScreenManager.resetForTesting() }
        let originalInline = setFocusInline(.collapse)
        defer { FocusModeSettingsManager.shared.inlineAnnotations = originalInline }
        let originalDefaults = setGlobalDefaults(displaySettings())
        defer { AnnotationDisplayDefaults.setSettings(originalDefaults) }
        let db = try #require(DocumentManager.shared.projectDatabase)

        // The user's own values: Task and Reference Inline, Comment Collapsed, Hide Completed on.
        let state = EditorViewState()
        state.loadAndApplyAnnotationDisplaySettings()
        state.setAnnotationDisplayMode(.collapsed, for: .comment)
        state.setHideCompletedTasks(true)
        let rowsBefore = try db.getSettings(keys: AnnotationDisplaySettingsKeys.all)

        state.enterFocusMode()
        for type in AnnotationType.allCases {
            #expect(state.annotationDisplayModes[type] == .collapsed, "Focus Mode forces every type collapsed on screen")
        }

        state.saveCurrentAnnotationDisplayAsDefault()

        #expect(AnnotationDisplayDefaults.settings == displaySettings([.comment: .collapsed], panelOnly: false, hideCompleted: true))
        #expect(AnnotationDisplayDefaults.settings.modes[.task] == .inline, "Task's own Inline, not the forced Collapsed")
        #expect(state.annotationDisplayModes[.task] == .collapsed, "The action leaves Focus Mode's override in place")
        #expect(try db.getSettings(keys: AnnotationDisplaySettingsKeys.all) == rowsBefore, "The action wrote no project row")

        state.exitFocusMode()
        #expect(state.annotationDisplayModes[.task] == .inline, "Exit restores the user's own values")
    }

    // Acceptance bar: fails if the action reads `isPanelOnlyMode` instead of the user's own Panel
    // Only choice -- under Hide it would store Panel Only ON, which the user never chose.
    @Test("Set as Default under Hide stores the user's own Panel Only, not the forced one")
    @MainActor
    func setAsDefaultUnderHideStoresTheUsersOwnPanelOnly() throws {
        let dir = try makeTempDir()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir) }
        try openFixture(named: "SetDefaultHide", in: dir)
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        defer { FullScreenManager.resetForTesting() }
        let originalInline = setFocusInline(.hide)
        defer { FocusModeSettingsManager.shared.inlineAnnotations = originalInline }
        let originalDefaults = setGlobalDefaults(displaySettings())
        defer { AnnotationDisplayDefaults.setSettings(originalDefaults) }
        let db = try #require(DocumentManager.shared.projectDatabase)

        // The user's own values: Reference Collapsed, Panel Only off, Hide Completed on.
        let state = EditorViewState()
        state.loadAndApplyAnnotationDisplaySettings()
        state.setAnnotationDisplayMode(.collapsed, for: .reference)
        state.setHideCompletedTasks(true)
        let rowsBefore = try db.getSettings(keys: AnnotationDisplaySettingsKeys.all)

        state.enterFocusMode()
        #expect(state.isPanelOnlyMode == true, "Hide forces Panel Only on")

        state.saveCurrentAnnotationDisplayAsDefault()

        #expect(AnnotationDisplayDefaults.settings == displaySettings([.reference: .collapsed], panelOnly: false, hideCompleted: true))
        #expect(state.isPanelOnlyMode == true, "The action leaves Focus Mode's override in place")
        #expect(try db.getSettings(keys: AnnotationDisplaySettingsKeys.all) == rowsBefore, "The action wrote no project row")

        state.exitFocusMode()
        #expect(state.isPanelOnlyMode == false, "Exit restores the user's own Panel Only")
    }

    @Test("Set as Default under Leave As Is stores the live values")
    @MainActor
    func setAsDefaultUnderLeaveAsIsStoresTheLiveValues() throws {
        let dir = try makeTempDir()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir) }
        try openFixture(named: "SetDefaultLeave", in: dir)
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        defer { FullScreenManager.resetForTesting() }
        let originalInline = setFocusInline(.leaveAsIs)
        defer { FocusModeSettingsManager.shared.inlineAnnotations = originalInline }
        let originalDefaults = setGlobalDefaults(displaySettings())
        defer { AnnotationDisplayDefaults.setSettings(originalDefaults) }

        let state = EditorViewState()
        state.loadAndApplyAnnotationDisplaySettings()
        state.setAnnotationDisplayMode(.collapsed, for: .comment)
        state.setPanelOnlyMode(true)
        state.setHideCompletedTasks(true)

        state.enterFocusMode()
        #expect(state.preFocusModeState?.annotationDisplayModes == nil, "Leave As Is captures nothing")
        #expect(state.preFocusModeState?.annotationPanelOnly == nil, "Leave As Is captures nothing")

        state.saveCurrentAnnotationDisplayAsDefault()

        let live = AnnotationDisplaySettings(
            modes: state.annotationDisplayModes, isPanelOnlyMode: state.isPanelOnlyMode, hideCompletedTasks: state.hideCompletedTasks
        )
        #expect(AnnotationDisplayDefaults.settings == live)
        #expect(live == displaySettings([.comment: .collapsed], panelOnly: true, hideCompleted: true), "and those are the user's choices")

        state.exitFocusMode()
    }

    // The user's unticking Panel Only inside Focus Mode is folded into the snapshot by
    // setPanelOnlyMode, so the snapshot always holds the user's CURRENT own value.
    @Test("A user change made inside Focus Mode is what Set as Default stores")
    @MainActor
    func setAsDefaultStoresTheChangeTheUserMadeInsideFocusMode() throws {
        let dir = try makeTempDir()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir) }
        try openFixture(named: "SetDefaultInside", in: dir)
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        defer { FullScreenManager.resetForTesting() }
        let originalInline = setFocusInline(.hide)
        defer { FocusModeSettingsManager.shared.inlineAnnotations = originalInline }
        let originalDefaults = setGlobalDefaults(displaySettings())
        defer { AnnotationDisplayDefaults.setSettings(originalDefaults) }

        // Panel Only is on (saved) before Focus Mode, so Hide captures ON.
        let state = EditorViewState()
        state.loadAndApplyAnnotationDisplaySettings()
        state.setPanelOnlyMode(true)
        state.enterFocusMode()
        #expect(state.preFocusModeState?.annotationPanelOnly == true)

        state.setPanelOnlyMode(false)   // the user unticks it inside Focus Mode
        state.saveCurrentAnnotationDisplayAsDefault()
        #expect(AnnotationDisplayDefaults.settings.isPanelOnlyMode == false, "The user's untick, not the value captured on entry")

        state.setPanelOnlyMode(true)   // and ticks it again
        state.saveCurrentAnnotationDisplayAsDefault()
        #expect(AnnotationDisplayDefaults.settings.isPanelOnlyMode == true, "Their latest own choice each time")

        state.exitFocusMode()
    }

    // `focusModeHoldsAnnotationDisplayOverride` is true exactly while a snapshot field is captured
    // (Collapse: the modes; Hide: Panel Only). On a fresh state -- neutral values -- an armed override
    // also changes what is on screen, so `focusModeAltersAnnotationDisplay` (the button's condition)
    // agrees with it here; the tests after this one cover where the two differ.
    @Test(
        "The override flags are true exactly when an override is armed, and back to false on reset and exit",
        arguments: [
            (FocusInlineAnnotationMode.collapse, true),
            (FocusInlineAnnotationMode.hide, true),
            (FocusInlineAnnotationMode.leaveAsIs, false)
        ]
    )
    @MainActor
    func overrideConditionIsTrueExactlyWhileAnOverrideIsArmed(inline: FocusInlineAnnotationMode, armed: Bool) {
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        defer { FullScreenManager.resetForTesting() }
        let originalInline = setFocusInline(inline)
        defer { FocusModeSettingsManager.shared.inlineAnnotations = originalInline }

        let state = EditorViewState()
        #expect(state.focusModeHoldsAnnotationDisplayOverride == false, "Focus Mode off")

        #expect(state.focusModeAltersAnnotationDisplay == false, "Focus Mode off")

        state.enterFocusMode()
        #expect(state.focusModeHoldsAnnotationDisplayOverride == armed, "Focus Mode on, Inline Annotations = \(inline)")
        #expect(state.focusModeAltersAnnotationDisplay == armed, "Neutral values: an armed override changes the screen")

        // A project switch clears both captured fields while Focus Mode stays on: nothing is
        // armed until the next project's load re-arms it.
        state.resetForProjectSwitch()
        #expect(state.focusModeHoldsAnnotationDisplayOverride == false, "After the reset, before any re-arm")
        #expect(state.focusModeAltersAnnotationDisplay == false, "After the reset, before any re-arm")
        state.applyFocusModeInlineOverrideForCurrentProject()
        #expect(state.focusModeHoldsAnnotationDisplayOverride == armed, "Re-armed for the next project")
        #expect(state.focusModeAltersAnnotationDisplay == armed, "Re-armed for the next project")

        state.exitFocusMode()
        #expect(state.focusModeHoldsAnnotationDisplayOverride == false, "Focus Mode off again")
        #expect(state.focusModeAltersAnnotationDisplay == false, "Focus Mode off again")
    }

    // MARK: - The button's disabled condition compares state to intent

    // Acceptance bar (a): fails if the condition is "a snapshot field was captured". Hide captures
    // Panel Only unconditionally, but with the user's own Panel Only already on nothing changes on
    // screen, so the popover shows exactly the user's own values and the button stays ENABLED.
    @Test("Hide with the user's own Panel Only already on leaves Set as Default enabled")
    @MainActor
    func hideWithPanelOnlyAlreadyOnLeavesTheButtonEnabled() {
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        defer { FullScreenManager.resetForTesting() }
        let originalInline = setFocusInline(.hide)
        defer { FocusModeSettingsManager.shared.inlineAnnotations = originalInline }

        let state = EditorViewState()
        state.isPanelOnlyMode = true   // the user's own choice, made before Focus Mode
        state.enterFocusMode()

        #expect(state.focusModeHoldsAnnotationDisplayOverride == true, "Hide captured the user's Panel Only")
        #expect(state.isPanelOnlyMode == true, "...but nothing changed on screen")
        #expect(state.focusModeAltersAnnotationDisplay == false, "so the popover shows the user's own values")

        state.exitFocusMode()
    }

    // Acceptance bar (b): the same for Collapse when every type was already Collapsed.
    @Test("Collapse with all three types already Collapsed leaves Set as Default enabled")
    @MainActor
    func collapseWithEveryTypeAlreadyCollapsedLeavesTheButtonEnabled() {
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        defer { FullScreenManager.resetForTesting() }
        let originalInline = setFocusInline(.collapse)
        defer { FocusModeSettingsManager.shared.inlineAnnotations = originalInline }

        let state = EditorViewState()
        state.annotationDisplayModes = displaySettings(
            [.task: .collapsed, .comment: .collapsed, .reference: .collapsed]
        ).modes
        state.enterFocusMode()

        #expect(state.focusModeHoldsAnnotationDisplayOverride == true, "Collapse captured the user's modes")
        #expect(state.focusModeAltersAnnotationDisplay == false, "but every type was already Collapsed")

        state.exitFocusMode()
    }

    // Acceptance bar (c): Hide with the user's Panel Only off really does change the screen.
    @Test("Hide with the user's own Panel Only off disables Set as Default")
    @MainActor
    func hideWithPanelOnlyOffDisablesTheButton() {
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        defer { FullScreenManager.resetForTesting() }
        let originalInline = setFocusInline(.hide)
        defer { FocusModeSettingsManager.shared.inlineAnnotations = originalInline }

        let state = EditorViewState()
        state.isPanelOnlyMode = false
        state.enterFocusMode()

        #expect(state.isPanelOnlyMode == true, "Hide forces Panel Only on")
        #expect(state.focusModeAltersAnnotationDisplay == true, "the popover is showing a forced value")

        state.exitFocusMode()
    }

    // Acceptance bar (d): Collapse changes the screen as soon as ANY type was Inline, whichever it is.
    @Test("Collapse with any one type still Inline disables Set as Default", arguments: AnnotationType.allCases)
    @MainActor
    func collapseWithAnyOneTypeInlineDisablesTheButton(inlineType: AnnotationType) {
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        defer { FullScreenManager.resetForTesting() }
        let originalInline = setFocusInline(.collapse)
        defer { FocusModeSettingsManager.shared.inlineAnnotations = originalInline }

        let state = EditorViewState()
        var own = displaySettings(
            [.task: .collapsed, .comment: .collapsed, .reference: .collapsed]
        ).modes
        own[inlineType] = .inline
        state.annotationDisplayModes = own
        state.enterFocusMode()

        #expect(state.annotationDisplayModes[inlineType] == .collapsed, "Focus Mode forces it Collapsed")
        #expect(state.focusModeAltersAnnotationDisplay == true, "\(inlineType) was Inline, so the screen changed")

        state.exitFocusMode()
    }
}
