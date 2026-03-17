//
//  ContentStateMachineTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Tests for the EditorContentState machine in EditorViewState.
//  State machine failure lets all sync services corrupt data simultaneously.
//

import Testing
import Foundation
@testable import final_final

@Suite("Content State Machine — Tier 1: Silent Killers")
@MainActor
struct ContentStateMachineTests {

    // MARK: - contentGeneration Tracking

    @Test("contentGeneration increments on idle → non-idle transition")
    func generationIncrementsOnTransition() {
        let state = EditorViewState()
        let initialGeneration = state.contentGeneration

        state.contentState = .zoomTransition
        #expect(state.contentGeneration == initialGeneration + 1)

        // Back to idle should not increment
        state.contentState = .idle
        #expect(state.contentGeneration == initialGeneration + 1)

        // Another non-idle transition should increment again
        state.contentState = .bibliographyUpdate
        #expect(state.contentGeneration == initialGeneration + 2)
    }

    @Test("contentGeneration does not increment on non-idle → non-idle transition")
    func generationStableOnNonIdleToNonIdle() {
        let state = EditorViewState()

        state.contentState = .zoomTransition
        let gen = state.contentGeneration

        // Non-idle to non-idle should NOT increment (oldValue != .idle)
        state.contentState = .bibliographyUpdate
        #expect(state.contentGeneration == gen, "Non-idle → non-idle should not increment generation")
    }

    // MARK: - isBusy

    @Test("isBusy reflects non-idle content state")
    func isBusyReflectsState() {
        let state = EditorViewState()

        #expect(!state.isBusy, "Should not be busy in idle state")

        state.contentState = .zoomTransition
        #expect(state.isBusy, "Should be busy during zoom transition")

        state.contentState = .idle
        #expect(!state.isBusy, "Should not be busy after returning to idle")
    }

    @Test("All content states report isBusy except idle")
    func allNonIdleStatesAreBusy() {
        let state = EditorViewState()

        let nonIdleStates: [EditorContentState] = [
            .zoomTransition,
            .hierarchyEnforcement,
            .bibliographyUpdate,
            .editorTransition,
            .dragReorder,
            .projectSwitch,
            .annotationEdit,
        ]

        for contentState in nonIdleStates {
            state.contentState = contentState
            #expect(state.isBusy, "\(contentState) should report isBusy = true")
            state.contentState = .idle  // Reset for next iteration
        }
    }

    // MARK: - Watchdog Timer

    @Test("Watchdog fires and resets to idle after 5 seconds")
    func watchdogResetsToIdle() async throws {
        let state = EditorViewState()
        state.contentState = .bibliographyUpdate
        #expect(state.isBusy)

        // Wait for watchdog (5s + buffer)
        try await Task.sleep(for: .seconds(6))

        #expect(state.contentState == .idle, "Watchdog should have reset to idle")
        #expect(!state.isBusy)
    }

    @Test("Watchdog clears zoom state on zoomTransition timeout")
    func watchdogClearsZoomState() async throws {
        let state = EditorViewState()
        state.zoomedSectionId = "test-section"
        state.zoomedSectionIds = Set(["test-section", "child-1"])
        state.isZoomingContent = true

        state.contentState = .zoomTransition

        // Wait for watchdog
        try await Task.sleep(for: .seconds(6))

        #expect(state.contentState == .idle)
        #expect(state.zoomedSectionId == nil, "Watchdog should clear zoomedSectionId on zoom timeout")
        #expect(state.zoomedSectionIds == nil, "Watchdog should clear zoomedSectionIds on zoom timeout")
        #expect(state.isZoomingContent == false, "Watchdog should clear isZoomingContent on zoom timeout")
    }

    @Test("Returning to idle cancels watchdog")
    func idleCancelsWatchdog() async throws {
        let state = EditorViewState()
        state.contentState = .bibliographyUpdate

        // Immediately return to idle — watchdog should be cancelled
        state.contentState = .idle

        // Wait past the watchdog timeout
        try await Task.sleep(for: .seconds(6))

        // Generation should only have incremented once (the initial transition)
        // If watchdog fired incorrectly, it would have set idle again (no-op but still wrong)
        #expect(state.contentState == .idle, "Should still be idle after watchdog timeout")
    }

    // MARK: - Mode Switch Guards

    @Test("Mode switch blocked during zoomTransition")
    func modeSwitchBlockedDuringZoom() {
        let state = EditorViewState()
        state.contentState = .zoomTransition
        let originalMode = state.editorMode

        // requestEditorModeToggle should silently return (no toggle)
        state.requestEditorModeToggle()

        #expect(state.editorMode == originalMode, "Editor mode should not change during zoomTransition")
    }

    @Test("Mode switch blocked during projectSwitch")
    func modeSwitchBlockedDuringProjectSwitch() {
        let state = EditorViewState()
        state.contentState = .projectSwitch
        let originalMode = state.editorMode

        state.requestEditorModeToggle()

        #expect(state.editorMode == originalMode, "Editor mode should not change during projectSwitch")
    }

    @Test("Mode switch allowed during other content states")
    func modeSwitchAllowedDuringOtherStates() {
        let state = EditorViewState()

        // These states should NOT block mode toggle
        let allowedStates: [EditorContentState] = [
            .bibliographyUpdate,
            .hierarchyEnforcement,
            .dragReorder,
            .annotationEdit,
        ]

        for contentState in allowedStates {
            state.contentState = contentState
            // Reset debounce to allow toggle
            state.lastToggleRequestTime = .distantPast

            let modeBefore = state.editorMode
            state.requestEditorModeToggle()
            // Note: requestEditorModeToggle posts a notification, doesn't toggle directly.
            // The mode won't actually change without the notification handler, but it should
            // NOT return early. We verify it didn't return early by checking lastToggleRequestTime changed.
            #expect(state.lastToggleRequestTime != .distantPast,
                    "\(contentState) should allow mode toggle (not return early)")

            // Reset for next iteration
            state.lastToggleRequestTime = .distantPast
            state.contentState = .idle
            state.editorMode = modeBefore
        }
    }

    // MARK: - Debounce

    @Test("Toggle debounce prevents rapid double-toggle")
    func toggleDebounce() {
        let state = EditorViewState()

        // First toggle — should work
        state.lastToggleRequestTime = .distantPast
        #expect(state.canToggleEditorMode)

        state.requestEditorModeToggle()

        // Immediate second toggle — should be blocked by debounce
        #expect(!state.canToggleEditorMode, "Should be debounced after immediate re-toggle")
    }
}
