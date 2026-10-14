//
//  UITestingDeleteTriggerTests.swift
//  final finalTests
//
//  Tier 1 (t-94369a83 Phase 4b slice 2a, fix round 12, speed): the UI-test-only delete trigger (UITestingDeleteTrigger.swift, DEBUG).
//  A distributed notification `com.kerim.final-final.uitest.deleteSection` with userInfo `["title": ...]` runs the sidebar's delete
//  action for the section with that exact title. These tests drive `handle(title:)` directly; outside UI testing nothing is
//  registered with the distributed notification center, so a unit-test run never reacts to a notification.
//
//  NOT RUN by the coder: the driver builds and runs every Swift test.
//

#if DEBUG

import AppKit
import Foundation
import Testing
@testable import final_final

@Suite("UI-test delete trigger — Phase 4b slice 2a fix round 12 (Tier 1)")
@MainActor
struct UITestingDeleteTriggerTests {

    private func section(_ title: String, sortOrder: Int) -> SectionViewModel {
        SectionViewModel(from: Section(
            projectId: "test", sortOrder: sortOrder, headerLevel: 1, title: title, markdownContent: "# \(title)"))
    }

    private func makeState(titles: [String]) -> EditorViewState {
        let state = EditorViewState()
        state.sections = titles.enumerated().map { section($0.element, sortOrder: $0.offset) }
        return state
    }

    @Test("The notification contract: name and userInfo key are exactly what the UI test posts")
    func testContract() {
        #expect(UITestingDeleteTrigger.notificationName.rawValue == "com.kerim.final-final.uitest.deleteSection")
        #expect(UITestingDeleteTrigger.titleKey == "title")
    }

    @Test("A title that matches a section runs the delete action with that section's id, once")
    func testKnownTitleRunsTheDeleteAction() {
        let wanted = "Chapter 6: The Quiet Archive and Its Ledgers"
        let state = makeState(titles: ["Chapter 5: Another", wanted, "Chapter 7: After"])
        let expectedId = state.sections[1].id
        var deleted: [String] = []
        let trigger = UITestingDeleteTrigger()
        trigger.install(editorState: state) { deleted.append($0) }

        trigger.handle(title: wanted)

        #expect(deleted == [expectedId], "\(deleted)")
    }

    @Test("A title no section has, a title that only partly matches, and a missing title do nothing")
    func testUnknownTitleDoesNothing() {
        let state = makeState(titles: ["Chapter 6: The Quiet Archive and Its Ledgers"])
        var deleted: [String] = []
        let trigger = UITestingDeleteTrigger()
        trigger.install(editorState: state) { deleted.append($0) }

        trigger.handle(title: "No Such Section")
        trigger.handle(title: "Chapter 6")
        trigger.handle(title: nil)

        #expect(deleted.isEmpty, "\(deleted)")
    }

    // MARK: - No click behind the trigger (fix round 13a)
    //
    // The trigger calls the sidebar's own delete entry point, which writes the `click-start` trace line from `NSApp.currentEvent`.
    // With no click that is the last event the run loop handled, in a UI-test run a key-up many seconds old, and the line took
    // that event's time as its `t=`, so the UI test's analyser (it pairs a `click-start` with the `start` line only if they are at
    // most 10 s apart) never paired them. The recorder's own `click: nil` -> `click-start type=none` line is covered in
    // StructuralTraceTests (`clickWithoutAnEvent`); these tests cover the flag that makes the trigger's call take that path.

    @Test("The trigger marks the next click as having no event only while its action runs, and clears it when the action returns")
    func testFlagIsSetOnlyWhileTheActionRuns() {
        let state = makeState(titles: ["Chapter 6"])
        var flagDuring: Bool?
        let trigger = UITestingDeleteTrigger()
        // An action that returns without writing a click note, as the zoom-locked early return does.
        trigger.install(editorState: state) { _ in flagDuring = StructuralTrace.nextClickHasNoEvent.withLock { $0 } }
        let flagBefore = StructuralTrace.nextClickHasNoEvent.withLock { $0 }

        trigger.handle(title: "Chapter 6")

        #expect(flagBefore == false)
        #expect(flagDuring == true)
        #expect(StructuralTrace.nextClickHasNoEvent.withLock { $0 } == false, "the flag was left set for a later real menu click")
    }

    @Test("A click note written while the flag is set takes the flag and does not read the current event")
    func testNoteCommandClickConsumesTheFlagInsteadOfReadingTheEvent() {
        // The stale event `NSApp.currentEvent` would have returned in a UI-test run: a key-up, long ago.
        let staleKeyUp = NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: [], timestamp: 1.0, windowNumber: 0, context: nil,
            characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)
        let state = makeState(titles: ["Chapter 6"])
        var flagBeforeNote: Bool?
        var flagAfterNote: Bool?
        var eventReads = 0
        let trigger = UITestingDeleteTrigger()
        trigger.install(editorState: state) { _ in
            flagBeforeNote = StructuralTrace.nextClickHasNoEvent.withLock { $0 }
            StructuralTrace.noteCommandClick(label: "sectionDelete", event: { eventReads += 1; return staleKeyUp }())
            flagAfterNote = StructuralTrace.nextClickHasNoEvent.withLock { $0 }
        }

        trigger.handle(title: "Chapter 6")
        #expect(flagBeforeNote == true)
        #expect(flagAfterNote == false, "noteCommandClick did not take the flag, so the next click would also be treated as eventless")
        #expect(eventReads == 0, "the stale event was read")
    }
}

#endif
