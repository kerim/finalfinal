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

        // Reset sections and annotations
        sections = []
        annotations = []
        invalidateOutlineCache()

        // Reset zoom state
        zoomedSectionId = nil
        zoomedSectionIds = nil
        zoomedBlockRange = nil
        isZoomingContent = false

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
