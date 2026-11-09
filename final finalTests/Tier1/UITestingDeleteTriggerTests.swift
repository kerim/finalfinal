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

    // MARK: - The Duplicate trigger and the wait (2026-11-09)
    //
    // The two Duplicate-at-once real-app tests used to walk the mouse to the new copy's card (about 3.5 s in the VM) inside a 3.9 s
    // hold, and missed it on a slow night. They now post a second command straight after the first click: the app runs it the moment
    // the copy is in the sidebar's list.

    @Test("The Duplicate notification contract: its own name, the same userInfo keys, plus an optional wait in seconds")
    func testDuplicateContract() {
        #expect(UITestingDeleteTrigger.duplicateNotificationName.rawValue == "com.kerim.final-final.uitest.duplicateSection")
        #expect(UITestingDeleteTrigger.duplicateNotificationName != UITestingDeleteTrigger.notificationName)
        #expect(UITestingDeleteTrigger.waitSecondsKey == "waitSeconds")
    }

    @Test("A duplicate request runs only the duplicate action, and a delete request runs only the delete action")
    func testEachRequestRunsItsOwnAction() {
        let state = makeState(titles: ["Chapter 1", "Chapter 2"])
        let expectedId = state.sections[1].id
        var deleted: [String] = []
        var duplicated: [String] = []
        let trigger = UITestingDeleteTrigger()
        trigger.install(editorState: state, perform: { deleted.append($0) }, performDuplicate: { duplicated.append($0) })

        trigger.handleDuplicate(title: "Chapter 2")
        #expect(duplicated == [expectedId] && deleted.isEmpty, "duplicated \(duplicated), deleted \(deleted)")

        trigger.handle(title: "Chapter 2")
        #expect(duplicated == [expectedId] && deleted == [expectedId], "duplicated \(duplicated), deleted \(deleted)")
    }

    @Test("A duplicate request with no duplicate action installed, and an unknown title, do nothing")
    func testDuplicateWithoutAnActionOrTitleDoesNothing() {
        let state = makeState(titles: ["Chapter 1"])
        var deleted: [String] = []
        let trigger = UITestingDeleteTrigger()
        trigger.install(editorState: state) { deleted.append($0) }

        trigger.handleDuplicate(title: "Chapter 1")
        trigger.handleDuplicate(title: nil)

        #expect(deleted.isEmpty, "\(deleted)")
    }

    @Test("With a wait, a request for a title the list does not have yet runs the moment the title appears, once")
    func testWaitRunsWhenTheTitleAppears() async {
        let state = makeState(titles: ["Chapter 1"])
        var duplicated: [String] = []
        let trigger = UITestingDeleteTrigger()
        trigger.install(editorState: state, perform: { _ in }, performDuplicate: { duplicated.append($0) })

        trigger.handleDuplicate(title: "Chapter 1 copy", waitSeconds: 5)
        #expect(duplicated.isEmpty, "ran before the title existed")

        try? await Task.sleep(for: .milliseconds(60))
        #expect(duplicated.isEmpty, "ran with no section of that title")
        state.sections.append(section("Chapter 1 copy", sortOrder: 1))
        let copyId = state.sections[1].id

        for _ in 0..<100 where duplicated.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(duplicated == [copyId], "\(duplicated)")
        try? await Task.sleep(for: .milliseconds(60))
        #expect(duplicated == [copyId], "ran more than once: \(duplicated)")
    }

    @Test("With a wait that runs out, nothing is done and nothing runs later")
    func testWaitThatRunsOutDoesNothing() async {
        let state = makeState(titles: ["Chapter 1"])
        var deleted: [String] = []
        let trigger = UITestingDeleteTrigger()
        trigger.install(editorState: state) { deleted.append($0) }

        trigger.handle(title: "Chapter 1 copy", waitSeconds: 0.05)
        try? await Task.sleep(for: .milliseconds(150))
        state.sections.append(section("Chapter 1 copy", sortOrder: 1))
        try? await Task.sleep(for: .milliseconds(60))

        #expect(deleted.isEmpty, "\(deleted)")
    }

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
