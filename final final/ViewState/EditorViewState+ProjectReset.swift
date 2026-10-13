//
//  EditorViewState+ProjectReset.swift
//  final final
//

import SwiftUI

// MARK: - Project Switch Reset

extension EditorViewState {

    /// Reset all project-specific state for a clean project switch.
    /// Call from handleProjectOpened() and performProjectClose().
    func resetForProjectSwitch() {
        // Cancel in-flight tasks first
        blockReparseTask?.cancel()
        blockReparseTask = nil
        currentPersistTask?.cancel()
        currentPersistTask = nil

        // Reset content
        content = ""
        sourceContent = ""
        sourceAnchors = []

        // The project switch this content belonged to is over -- content (about to be
        // freshly loaded for the new project by configureForCurrentProject()) is
        // trustworthy again. See switchInProgressContent's doc comment.
        switchInProgressContent = nil

        // Reset sections and annotations
        sections = []  // fires didSet -> clears the outline cache
        annotations = []

        // Reset zoom state
        zoomedSectionId = nil
        zoomedSectionIds = nil
        zoomedBlockRange = nil
        isZoomingContent = false
        // A project switch ends any in-flight zoom episode -- bumps `zoomEpoch` so a
        // `clearZoomRestoringEditor()` recovery spawned for the OLD project's lost zoom root
        // abandons instead of restoring the old project's blocks into the editor now showing
        // the new one (M3, judge fix round).
        zoomEpoch += 1

        // Reset content state machine
        contentState = .idle

        // Reset filters
        statusFilter = nil
        headerLevelFilter = nil

        // Reset project-specific settings
        isCitationLibraryPushed = false
        documentGoal = nil
        documentGoalType = .approx
        excludeBibliography = false

        // Reset the annotation display settings to the NEUTRAL state (every type Inline, both
        // checkboxes off), so the previous project's choices can never linger over the next
        // project (or over the picker after a close). Deliberately not the stored app-wide
        // default: the three display observers broadcast whatever this leaves behind to the
        // editors, and a default with Panel Only on would push "hide every inline annotation"
        // mid-switch, only for the incoming project's own load to push its values right after.
        // The LOAD path still fills every option the project has not saved from the stored
        // default (loadAndApplyAnnotationDisplaySettings()).
        // Direct assignment, never the saving setters: a reset must not write to the database
        // (the next project's own values are applied straight afterwards, by
        // runProjectOpenSequence()).
        applyAnnotationDisplaySettings(.neutral)

        // A Focus Mode session that outlives this switch must not restore the previous
        // project's annotation modes or Panel Only state into the next project on exit. Clear
        // ONLY those two fields -- not the whole snapshot: exitFocusMode() with no snapshot
        // skips leaving full screen and re-showing the sidebars it hid, which would strand
        // Focus Mode's other effects. Both being nil is also what lets the project load re-arm
        // the override (applyFocusModeInlineOverrideForCurrentProject() only captures a field
        // while it is nil), so the next project's snapshot holds ITS values.
        preFocusModeState?.annotationDisplayModes = nil
        preFocusModeState?.annotationPanelOnly = nil

        // Reset stats display
        wordCount = 0
        characterCount = 0
        currentSectionName = ""
        currentSectionId = nil
        scrollToOffset = nil
        scrollToBlockId = nil
        scrollToAnnotationIndex = nil
        pendingEditAnnotationId = nil

        // Tell the editor coordinators (which survive this reset -- the editor view
        // stays mounted across project switches) to drop their lastPolled* equality-guard
        // caches, which mirror the four stats properties just zeroed above. See this
        // property's doc comment for why: without it, a poll tick after reopening the
        // same project can match the stale cache and wrongly suppress the UI update.
        pollCacheResetGeneration += 1
    }

}
