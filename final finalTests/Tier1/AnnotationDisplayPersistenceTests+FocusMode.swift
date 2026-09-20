//
//  AnnotationDisplayPersistenceTests+FocusMode.swift
//  final finalTests
//
//  Tier 1: Focus Mode's transient inline-annotation override across project switches, and its
//  interaction with the persisted per-project settings. Focus Mode's own assignments are always
//  direct and never written; every test here ends by proving no settings row changed, in every
//  project it opened.
//
//  An extension of `AnnotationDisplayPersistenceTests` in its own file (so that suite's type
//  stays within SwiftLint's size limits). The same suite, so these tests stay serialized with
//  the others -- they share DocumentManager.shared and the Focus / default singletons.
//

import Testing
import Foundation
@testable import final_final

/// Every database a test opened. The app only drops its reference to a project's database when
/// the project closes (see TestDatabaseTeardown), so teardown must close each one explicitly. A
/// class so helpers can append to it and the test's `defer` sees the final list.
private final class OpenedDatabases {
    var databases: [ProjectDatabase] = []
}

/// Stands in for the web editors' own copy of the annotation display state, which production
/// only ever changes by receiving a post (the `.onChange` observers' or an explicit push). It
/// keeps whatever it received LAST, exactly like the editors' module-level map.
@MainActor
private final class EditorsStandIn {
    struct Received: Equatable {
        let modes: [AnnotationType: AnnotationDisplayMode]
        let isPanelOnly: Bool
        let hideCompleted: Bool
    }

    /// Everything received, in order. The tests assert on THESE values, never on a return value.
    private(set) var history: [Received] = []
    var last: Received? { history.last }

    func receive(_ modes: [AnnotationType: AnnotationDisplayMode], _ isPanelOnly: Bool, _ hideCompleted: Bool) {
        history.append(Received(modes: modes, isPanelOnly: isPanelOnly, hideCompleted: hideCompleted))
    }
}

extension AnnotationDisplayPersistenceTests {

    // MARK: - Focus preference helpers (also used by AnnotationDisplayPersistenceTests.swift)

    /// Sets Focus Mode's "Inline Annotations" preference to Collapse (the choice that makes
    /// Focus Mode force every annotation type collapsed) and returns the value it had, for the
    /// caller to restore in a `defer` -- `FocusModeSettingsManager.shared` is a process-wide
    /// singleton, so a test must never leave it changed for whichever test runs next.
    @MainActor
    func turnOnFocusCollapse() -> FocusInlineAnnotationMode {
        setFocusInline(.collapse)
    }

    /// Sets the "Inline Annotations" preference and returns the value it had (see
    /// `turnOnFocusCollapse()` for why the caller restores it).
    @MainActor
    func setFocusInline(_ mode: FocusInlineAnnotationMode) -> FocusInlineAnnotationMode {
        let original = FocusModeSettingsManager.shared.inlineAnnotations
        FocusModeSettingsManager.shared.inlineAnnotations = mode
        return original
    }

    // MARK: - Shared scenario

    private var allInline: [AnnotationType: AnnotationDisplayMode] {
        Dictionary(uniqueKeysWithValues: AnnotationType.allCases.map { ($0, AnnotationDisplayMode.inline) })
    }

    /// The annotation display settings rows of a project, for "nothing was written" checks.
    private func rows(of database: ProjectDatabase) throws -> [String: String] {
        try database.getSettings(keys: AnnotationDisplaySettingsKeys.all)
    }

    /// Project A is open and the user has chosen Comment = Collapsed and Panel Only on (both
    /// saved to A), then turned Focus Mode on. Returns the editor state, in Focus Mode.
    @MainActor
    private func projectAInFocusMode(dir: URL, opened: OpenedDatabases) throws -> EditorViewState {
        try openFixture(named: "FocusA", in: dir)
        opened.databases.append(try #require(DocumentManager.shared.projectDatabase))
        let state = EditorViewState()
        state.loadAndApplyAnnotationDisplaySettings()
        state.setAnnotationDisplayMode(.collapsed, for: .comment)
        state.setPanelOnlyMode(true)
        state.enterFocusMode()
        return state
    }

    /// Opens project B (every type saved Inline, Panel Only saved off) and runs the project-open
    /// sequence a switch runs in production (`EditorViewState.runProjectOpenSequence`, the very
    /// function ContentView.handleProjectOpened() calls), publishing to `editors`. Returns B's
    /// settings rows as they were saved, before the switch touched anything.
    @MainActor
    private func switchToProjectB(
        state: EditorViewState, dir: URL, opened: OpenedDatabases, editors: EditorsStandIn? = nil
    ) async throws -> [String: String] {
        let editors = editors ?? EditorsStandIn()
        try openFixture(named: "FocusB", in: dir)
        let database = try #require(DocumentManager.shared.projectDatabase)
        opened.databases.append(database)
        for type in AnnotationType.allCases {
            try DocumentManager.shared.saveAnnotationDisplayMode(.inline, for: type)
        }
        try DocumentManager.shared.saveAnnotationPanelOnly(false)
        let savedRows = try rows(of: database)
        #expect(EditorViewState.openProjectIsConfigurable, "The fixture must have a database, an id and a content id")

        await state.runProjectOpenSequence(kind: .projectSwitch, publish: editors.receive) { $0() }
        return savedRows
    }

    // MARK: - A project opened while Focus Mode is on

    @Test("A project opened during Focus Mode gets the Collapse override; exit restores ITS saved values, never the old project's")
    @MainActor
    func projectOpenedDuringFocusModeGetsTheCollapseOverride() async throws {
        let dir = try makeTempDir()
        let opened = OpenedDatabases()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir, extra: opened.databases) }
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        defer { FullScreenManager.resetForTesting() }
        let originalInline = setFocusInline(.collapse)
        defer { FocusModeSettingsManager.shared.inlineAnnotations = originalInline }
        let originalDefaults = setGlobalDefaults(displaySettings())
        defer { AnnotationDisplayDefaults.setSettings(originalDefaults) }

        let state = try projectAInFocusMode(dir: dir, opened: opened)
        let rowsA = try rows(of: opened.databases[0])
        let rowsB = try await switchToProjectB(state: state, dir: dir, opened: opened)

        // The override is on B: every type collapsed on screen, B's own values held for exit.
        for type in AnnotationType.allCases {
            #expect(state.annotationDisplayModes[type] == .collapsed)
        }
        #expect(state.preFocusModeState?.annotationDisplayModes == allInline, "The snapshot holds B's values, not A's")

        state.exitFocusMode()

        for type in AnnotationType.allCases {
            #expect(state.annotationDisplayModes[type] == .inline, "B's saved value -- A had Comment collapsed")
        }
        #expect(try rows(of: opened.databases[0]) == rowsA, "Nothing was written to A")
        #expect(try rows(of: opened.databases[1]) == rowsB, "Nothing was written to B")
    }

    @Test("A project opened during Focus Mode gets the Hide override; exit restores ITS saved Panel Only, never the old project's")
    @MainActor
    func projectOpenedDuringFocusModeGetsTheHideOverride() async throws {
        let dir = try makeTempDir()
        let opened = OpenedDatabases()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir, extra: opened.databases) }
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        defer { FullScreenManager.resetForTesting() }
        let originalInline = setFocusInline(.hide)
        defer { FocusModeSettingsManager.shared.inlineAnnotations = originalInline }
        let originalDefaults = setGlobalDefaults(displaySettings())
        defer { AnnotationDisplayDefaults.setSettings(originalDefaults) }

        let state = try projectAInFocusMode(dir: dir, opened: opened)   // A had Panel Only saved ON
        let rowsA = try rows(of: opened.databases[0])
        let rowsB = try await switchToProjectB(state: state, dir: dir, opened: opened)   // B has it saved OFF

        #expect(state.isPanelOnlyMode == true, "The Hide override is on B")
        #expect(state.preFocusModeState?.annotationPanelOnly == false, "The snapshot holds B's saved Panel Only")
        for type in AnnotationType.allCases {
            #expect(state.annotationDisplayModes[type] == .inline, "Hide does not touch the per-type modes")
        }

        state.exitFocusMode()

        #expect(state.isPanelOnlyMode == false, "B's saved value -- A had it on")
        #expect(try rows(of: opened.databases[0]) == rowsA, "Nothing was written to A")
        #expect(try rows(of: opened.databases[1]) == rowsB, "Nothing was written to B")
    }

    // The capture invariant: a snapshot field is only (re)captured while nil. Without it, a
    // second call would overwrite the real pre-Focus values with the already-overridden ones.
    @Test("Re-arming twice never overwrites the captured pre-Focus values", arguments: [FocusInlineAnnotationMode.collapse, .hide])
    @MainActor
    func reArmCalledTwiceNeverOverwritesTheCapturedValues(inline: FocusInlineAnnotationMode) async throws {
        let dir = try makeTempDir()
        let opened = OpenedDatabases()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir, extra: opened.databases) }
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        defer { FullScreenManager.resetForTesting() }
        let originalInline = setFocusInline(inline)
        defer { FocusModeSettingsManager.shared.inlineAnnotations = originalInline }
        let originalDefaults = setGlobalDefaults(displaySettings())
        defer { AnnotationDisplayDefaults.setSettings(originalDefaults) }

        let state = try projectAInFocusMode(dir: dir, opened: opened)
        let rowsA = try rows(of: opened.databases[0])
        let rowsB = try await switchToProjectB(state: state, dir: dir, opened: opened)

        state.applyFocusModeInlineOverrideForCurrentProject()
        state.applyFocusModeInlineOverrideForCurrentProject()

        switch inline {
        case .collapse:
            #expect(state.preFocusModeState?.annotationDisplayModes == allInline, "Still B's pre-override values")
            for type in AnnotationType.allCases {
                #expect(state.annotationDisplayModes[type] == .collapsed)
            }
        case .hide:
            #expect(state.preFocusModeState?.annotationPanelOnly == false, "Still B's pre-override Panel Only")
            #expect(state.isPanelOnlyMode == true)
        case .leaveAsIs:
            Issue.record("Not a case under test")
        }

        state.exitFocusMode()

        for type in AnnotationType.allCases {
            #expect(state.annotationDisplayModes[type] == .inline, "Exit restores B's values, not the forced ones")
        }
        #expect(state.isPanelOnlyMode == false)
        #expect(try rows(of: opened.databases[0]) == rowsA)
        #expect(try rows(of: opened.databases[1]) == rowsB)
    }

    // MARK: - A user's own change inside Focus Mode

    @Test("With Hide armed, the user's own Panel Only change inside Focus Mode is saved, folded into the snapshot, and survives exit")
    @MainActor
    func userChangeInsideFocusModeWithHideIsPersistedAndSurvivesExit() throws {
        let dir = try makeTempDir()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir) }
        try openFixture(named: "FocusHideUserChange", in: dir)
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        defer { FullScreenManager.resetForTesting() }
        let originalInline = setFocusInline(.hide)
        defer { FocusModeSettingsManager.shared.inlineAnnotations = originalInline }
        let database = try #require(DocumentManager.shared.projectDatabase)

        // The user's own Panel Only is on (saved) before Focus Mode. A user setter with no
        // Focus Mode snapshot must not create one.
        let state = EditorViewState()
        state.loadAndApplyAnnotationDisplaySettings()
        state.setPanelOnlyMode(true)
        #expect(state.preFocusModeState == nil)

        state.enterFocusMode()
        #expect(state.preFocusModeState?.annotationPanelOnly == true)

        state.setPanelOnlyMode(false)   // the user unticks it inside Focus Mode
        #expect(state.isPanelOnlyMode == false, "The annotations reappear in the text immediately")
        #expect(state.preFocusModeState?.annotationPanelOnly == false, "Folded into the snapshot")
        #expect(try database.getSetting(key: AnnotationDisplaySettingsKeys.panelOnly) == "false", "Saved as their own choice")

        state.exitFocusMode()

        #expect(state.isPanelOnlyMode == false, "Exit keeps the user's choice; without the fold it would restore the old on")
        #expect(try database.getSetting(key: AnnotationDisplaySettingsKeys.panelOnly) == "false")
    }

    // MARK: - Relaunch, no-ops, and a project closed during Focus Mode

    // The project-open sequence re-enters a restored Focus Mode right after the load and BEFORE the
    // first publish (so the editors' first post is already overridden), and ContentView's own later
    // call of the same re-entry then finds a snapshot and does nothing (no second capture).
    @Test("Relaunching into Focus Mode captures the restored project's own values and publishes the override first")
    @MainActor
    func relaunchIntoFocusModeCapturesTheRestoredProjectsValues() async throws {
        let dir = try makeTempDir()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir) }
        try openFixture(named: "Relaunch", in: dir)
        let database = try #require(DocumentManager.shared.projectDatabase)
        try DocumentManager.shared.saveAnnotationDisplayMode(.collapsed, for: .comment)   // the project's own choice
        let rowsBefore = try rows(of: database)

        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        defer { FullScreenManager.resetForTesting() }
        let originalInline = setFocusInline(.collapse)
        defer { FocusModeSettingsManager.shared.inlineAnnotations = originalInline }
        let originalDefaults = setGlobalDefaults(displaySettings())
        defer { AnnotationDisplayDefaults.setSettings(originalDefaults) }
        // A relaunch: Focus Mode is persisted as on, the snapshot (session-only) is nil.
        AppDefaults.store.set(true, forKey: "focusModeEnabled")
        defer { TestMode.clearTestState() }
        let state = EditorViewState()
        #expect(state.focusModeEnabled == true)
        #expect(state.preFocusModeState == nil)

        // initializeProject() runs the launch flavour of the project-open sequence.
        let editors = EditorsStandIn()
        var configured = false
        await state.runProjectOpenSequence(kind: .launch, publish: editors.receive) { publishAfterContent in
            configured = true
            publishAfterContent()
        }
        #expect(configured, "The view's configure step ran")

        let restored: [AnnotationType: AnnotationDisplayMode] = [.task: .inline, .comment: .collapsed, .reference: .inline]
        #expect(state.preFocusModeState?.annotationDisplayModes == restored, "The snapshot holds the restored project's own values")
        for type in AnnotationType.allCases {
            #expect(state.annotationDisplayModes[type] == .collapsed)
        }
        // What the editors received: the FIRST post is already the overridden state (no flash of
        // un-collapsed annotations while the rest of the launch runs), and so is the last.
        let allCollapsed = Dictionary(uniqueKeysWithValues: AnnotationType.allCases.map { ($0, AnnotationDisplayMode.collapsed) })
        #expect(editors.history.first?.modes == allCollapsed)
        #expect(editors.last?.modes == allCollapsed)

        // ContentView's own later call of the re-entry: a snapshot exists, so it captures nothing.
        state.reenterFocusModeIfRestored()
        #expect(state.preFocusModeState?.annotationDisplayModes == restored, "Not captured a second time, over the overridden values")

        state.exitFocusMode()

        #expect(state.annotationDisplayModes == restored)
        #expect(try rows(of: database) == rowsBefore, "Nothing was written")
    }

    @Test("The re-arm is a no-op without a snapshot, and without Focus Mode")
    @MainActor
    func focusOverrideReArmIsNoOpWithoutSnapshotOrFocusMode() {
        TestMode.clearTestState()
        defer { TestMode.clearTestState() }
        let originalInline = setFocusInline(.collapse)
        defer { FocusModeSettingsManager.shared.inlineAnnotations = originalInline }
        let own: [AnnotationType: AnnotationDisplayMode] = [.task: .inline, .comment: .collapsed, .reference: .inline]

        // Focus Mode off, no snapshot.
        let plain = EditorViewState()
        plain.annotationDisplayModes = own
        plain.applyFocusModeInlineOverrideForCurrentProject()
        #expect(plain.annotationDisplayModes == own)
        #expect(plain.preFocusModeState == nil)

        // Focus Mode off, but a snapshot present: still nothing to do.
        plain.preFocusModeState = FocusModeSnapshot(
            wasInFullScreen: false, outlineSidebarVisible: nil, annotationPanelVisible: nil,
            annotationDisplayModes: nil, annotationPanelOnly: nil
        )
        plain.applyFocusModeInlineOverrideForCurrentProject()
        #expect(plain.annotationDisplayModes == own)
        #expect(plain.preFocusModeState?.annotationDisplayModes == nil)

        // The cold-launch window: Focus Mode persisted as on, snapshot not built yet. The re-arm
        // must not capture -- enterFocusMode() is about to (the guard is on the snapshot).
        AppDefaults.store.set(true, forKey: "focusModeEnabled")
        let launching = EditorViewState()
        launching.annotationDisplayModes = own
        launching.applyFocusModeInlineOverrideForCurrentProject()
        #expect(launching.annotationDisplayModes == own)
        #expect(launching.preFocusModeState == nil)
    }

    @Test("A project closed during Focus Mode leaves nothing stale; the next project keeps its own values")
    @MainActor
    func projectClosedDuringFocusModeLeavesNothingStale() async throws {
        let dir = try makeTempDir()
        let opened = OpenedDatabases()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir, extra: opened.databases) }
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        defer { FullScreenManager.resetForTesting() }
        let originalInline = setFocusInline(.collapse)
        defer { FocusModeSettingsManager.shared.inlineAnnotations = originalInline }
        let originalDefaults = setGlobalDefaults(displaySettings())
        defer { AnnotationDisplayDefaults.setSettings(originalDefaults) }

        let state = try projectAInFocusMode(dir: dir, opened: opened)
        let rowsA = try rows(of: opened.databases[0])
        #expect(state.preFocusModeState?.annotationDisplayModes != nil)

        // The close sequence, exactly as production runs it: performProjectClose resets, then the
        // project goes away. There is no load on the close path, so nothing re-arms anything.
        state.resetForProjectSwitch()
        DocumentManager.shared.closeProject()

        #expect(state.preFocusModeState?.annotationDisplayModes == nil)
        #expect(state.preFocusModeState?.annotationPanelOnly == nil)
        for type in AnnotationType.allCases {
            #expect(state.annotationDisplayModes[type] == .inline, "The defaults, not A's collapsed Comment or the forced collapse")
        }
        #expect(state.isPanelOnlyMode == false)

        state.exitFocusMode()   // at the project picker

        for type in AnnotationType.allCases {
            #expect(state.annotationDisplayModes[type] == .inline, "Exit restores nothing")
        }
        #expect(state.isPanelOnlyMode == false)
        #expect(try rows(of: opened.databases[0]) == rowsA, "Nothing was written to A")

        // A project opened now, with Focus Mode off: the re-arm no-ops and its own values stand.
        #expect(state.focusModeEnabled == false)
        try openFixture(named: "AfterClose", in: dir)
        let database = try #require(DocumentManager.shared.projectDatabase)
        opened.databases.append(database)
        try DocumentManager.shared.saveAnnotationDisplayMode(.collapsed, for: .comment)
        let rowsAfterClose = try rows(of: database)
        await state.runProjectOpenSequence(kind: .projectSwitch, publish: EditorsStandIn().receive) { $0() }

        #expect(state.preFocusModeState == nil)
        #expect(state.annotationDisplayModes[.comment] == .collapsed, "Its own saved value stands")
        #expect(state.annotationDisplayModes[.task] == .inline)
        #expect(try rows(of: database) == rowsAfterClose)
    }

    // MARK: - The project-open sequence (what the editors are told)
    //
    // The V8 real-app run (Finder-open of B while in Focus Mode, Collapse) rendered B with A's saved
    // values, because a project opened in Collapse is a NET NO-OP for the in-memory values (every
    // type collapsed before and after), so the `.onChange` observers report nothing and the editors
    // keep whatever they were last sent. These tests drive `runProjectOpenSequence` -- the function
    // ContentView calls -- and assert on what a stand-in for the editors RECEIVED, in order.

    /// A: only Reference saved Collapsed (as the V8 e2e seeds it). B: only Comment saved Collapsed.
    /// Opens A and B in the temp dir; leaves B as the open project.
    @MainActor
    private func openV8Projects(dir: URL, opened: OpenedDatabases) throws {
        try openFixture(named: "V8A", in: dir)
        opened.databases.append(try #require(DocumentManager.shared.projectDatabase))
        try DocumentManager.shared.saveAnnotationDisplayMode(.collapsed, for: .reference)
        try openFixture(named: "V8B", in: dir)
        opened.databases.append(try #require(DocumentManager.shared.projectDatabase))
        try DocumentManager.shared.saveAnnotationDisplayMode(.collapsed, for: .comment)
        #expect(EditorViewState.openProjectIsConfigurable, "The fixture must have a database, an id and a content id")
    }

    // (a) Fails if the explicit publish is removed: nothing else in this test can deliver anything
    // to the stand-in, so with the publishes gone `history` is empty and both expectations below fail.
    @Test("Opening a project with Focus Mode on leaves the editors with the project's OVERRIDDEN modes")
    @MainActor
    func openingProjectWithFocusModeArmedLeavesEditorsWithTheOverriddenModes() async throws {
        let dir = try makeTempDir()
        let opened = OpenedDatabases()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir, extra: opened.databases) }
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        defer { FullScreenManager.resetForTesting() }
        let originalInline = setFocusInline(.collapse)
        defer { FocusModeSettingsManager.shared.inlineAnnotations = originalInline }
        let originalDefaults = setGlobalDefaults(displaySettings())
        defer { AnnotationDisplayDefaults.setSettings(originalDefaults) }

        // The window is in Focus Mode on A (A's snapshot exists), then B is opened.
        try openFixture(named: "V8A", in: dir)
        opened.databases.append(try #require(DocumentManager.shared.projectDatabase))
        try DocumentManager.shared.saveAnnotationDisplayMode(.collapsed, for: .reference)
        let state = EditorViewState()
        state.loadAndApplyAnnotationDisplaySettings()
        state.enterFocusMode()
        try openFixture(named: "V8B", in: dir)
        opened.databases.append(try #require(DocumentManager.shared.projectDatabase))
        try DocumentManager.shared.saveAnnotationDisplayMode(.collapsed, for: .comment)

        let editors = EditorsStandIn()
        var order: [String] = []
        await state.runProjectOpenSequence(
            kind: .projectSwitch,
            publish: { modes, panel, hide in
                order.append("publish")
                editors.receive(modes, panel, hide)
            },
            openProject: { publishAfterContent in
                order.append("openProject")
                publishAfterContent()
            }
        )

        let allCollapsed = Dictionary(uniqueKeysWithValues: AnnotationType.allCases.map { ($0, AnnotationDisplayMode.collapsed) })
        #expect(order == ["publish", "openProject", "publish"], "Publish before the view's step and again after it")
        #expect(editors.history.count == 2)
        #expect(editors.history.first?.modes == allCollapsed, "The FIRST thing the editors get is already B's overridden state")
        #expect(editors.last?.modes == allCollapsed)
        #expect(editors.last?.isPanelOnly == false)

        // Leaving Focus Mode: B's own saved values (Comment collapsed), never A's (Reference collapsed).
        state.exitFocusMode()
        state.publishAnnotationDisplayState(via: editors.receive)
        #expect(editors.last?.modes[.comment] == .collapsed)
        #expect(editors.last?.modes[.reference] == .inline)
        #expect(editors.last?.modes[.task] == .inline)
    }

    // (b) Fails if the load step is removed: without it the reset's defaults (all Inline) would be
    // published, and Focus Mode's re-arm (part of the load) would never run. Focus Mode off here, so
    // the received values must be exactly what B saved.
    @Test("The sequence loads the project's saved settings BEFORE it publishes anything")
    @MainActor
    func sequenceLoadsTheSavedSettingsBeforeAnyPublish() async throws {
        let dir = try makeTempDir()
        let opened = OpenedDatabases()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir, extra: opened.databases) }
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        defer { FullScreenManager.resetForTesting() }
        let originalDefaults = setGlobalDefaults(displaySettings())
        defer { AnnotationDisplayDefaults.setSettings(originalDefaults) }
        try openV8Projects(dir: dir, opened: opened)   // B is open: only Comment saved Collapsed

        let state = EditorViewState()
        state.annotationDisplayModes = [.task: .collapsed, .comment: .collapsed, .reference: .collapsed]   // the old project's
        let editors = EditorsStandIn()
        await state.runProjectOpenSequence(kind: .projectSwitch, publish: editors.receive) { $0() }

        let bsOwn: [AnnotationType: AnnotationDisplayMode] = [.task: .inline, .comment: .collapsed, .reference: .inline]
        #expect(editors.history.first?.modes == bsOwn, "The first publish already carries B's saved settings")
        #expect(editors.last?.modes == bsOwn)
        #expect(state.annotationDisplayModes == bsOwn)
    }

    // The launch flavour is the same function: initializeProject() no longer has a load line of its
    // own that a refactor could drop without any test noticing.
    @Test("The launch flavour of the sequence loads the project's saved settings and publishes them")
    @MainActor
    func launchSequenceLoadsAndPublishes() async throws {
        let dir = try makeTempDir()
        let opened = OpenedDatabases()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir, extra: opened.databases) }
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        defer { FullScreenManager.resetForTesting() }
        let originalDefaults = setGlobalDefaults(displaySettings())
        defer { AnnotationDisplayDefaults.setSettings(originalDefaults) }
        try openV8Projects(dir: dir, opened: opened)

        let state = EditorViewState()   // a fresh window: everything Inline
        let editors = EditorsStandIn()
        await state.runProjectOpenSequence(kind: .launch, publish: editors.receive) { $0() }

        #expect(editors.history.first?.modes[.comment] == .collapsed, "B's saved Comment reaches the editors at launch")
        #expect(editors.history.first?.modes[.reference] == .inline)
    }

    // "Not fully open" is decided by EditorViewState.openProjectIsConfigurable (database, id AND content
    // id -- what configureForCurrentProject() requires); the easiest such state to build is no project.
    @Test("With no project open, nothing is loaded or published, and the view's own step still runs")
    @MainActor
    func sequenceDoesNothingForAProjectItCannotConfigure() async throws {
        DocumentManager.shared.closeProject()   // no project open at all
        let state = EditorViewState()
        let editors = EditorsStandIn()
        var configureRan = false
        await state.runProjectOpenSequence(kind: .launch, publish: editors.receive) { publishAfterContent in
            configureRan = true
            publishAfterContent()
        }

        #expect(editors.history.isEmpty, "Nothing published for a project the view will not configure")
        #expect(configureRan, "The view's own step still runs (it refuses on its own)")
    }

    @Test("An open overtaken by a later one does not publish its state over the newer open's")
    @MainActor
    func overtakenOpenDoesNotPublishItsSecondPost() async throws {
        let dir = try makeTempDir()
        let opened = OpenedDatabases()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir, extra: opened.databases) }
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        defer { FullScreenManager.resetForTesting() }
        try openV8Projects(dir: dir, opened: opened)   // B is open

        let state = EditorViewState()
        let editors = EditorsStandIn()
        await state.runProjectOpenSequence(kind: .projectSwitch, publish: editors.receive) { publishAfterContent in
            // While B's open is still in flight, another project is opened over it.
            _ = try? self.openFixture(named: "V8C", in: dir)
            if let database = DocumentManager.shared.projectDatabase { opened.databases.append(database) }
            publishAfterContent()
        }

        #expect(editors.history.count == 1, "Only the first publish: the second is skipped, the open was overtaken")
    }

    // MARK: - The content push is not awaited by the sequence

    /// A content push the test controls: it starts un-awaited (like production's `Task {}`), stays
    /// suspended until `release()`, and then does what production's push does as its last step.
    @MainActor
    private final class SuspendedPush {
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var task: Task<Void, Never>?

        func start(then publishAfterContent: @escaping @MainActor () -> Void) {
            task = Task { [self] in
                if !released {
                    await withCheckedContinuation { continuation = $0 }
                }
                publishAfterContent()
            }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    @Test("The sequence returns while the content push is still suspended; publish 2 arrives only when it finishes")
    @MainActor
    func sequenceReturnsWhileThePushIsSuspendedAndPublishesAfterIt() async throws {
        let dir = try makeTempDir()
        let opened = OpenedDatabases()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir, extra: opened.databases) }
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        defer { FullScreenManager.resetForTesting() }
        try openV8Projects(dir: dir, opened: opened)

        let state = EditorViewState()
        let editors = EditorsStandIn()
        let push = SuspendedPush()
        await state.runProjectOpenSequence(kind: .projectSwitch, publish: editors.receive) { publishAfterContent in
            push.start(then: publishAfterContent)   // started, NOT awaited
        }

        // The sequence has returned (this line is reached) while the push is suspended: a caller that
        // does more work after it (ContentView's .projectDidCreate tail) is not held up by the push.
        #expect(editors.history.count == 1, "Only publish 1 so far: the push has not finished")

        push.release()
        await push.task?.value
        #expect(editors.history.count == 2, "Publish 2 arrives after the push completes")
        #expect(editors.last?.modes[.comment] == .collapsed, "and it carries B's own settings")
    }

    @Test("Publish 2 is not delivered when another project was opened while the push was suspended")
    @MainActor
    func supersededOpenPublishesNothingWhenItsPushFinishes() async throws {
        let dir = try makeTempDir()
        let opened = OpenedDatabases()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir, extra: opened.databases) }
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        defer { FullScreenManager.resetForTesting() }
        try openV8Projects(dir: dir, opened: opened)

        let state = EditorViewState()
        let editors = EditorsStandIn()
        let push = SuspendedPush()
        await state.runProjectOpenSequence(kind: .projectSwitch, publish: editors.receive) { publishAfterContent in
            push.start(then: publishAfterContent)
        }
        #expect(editors.history.count == 1)

        // A later project is opened before B's push finishes.
        try openFixture(named: "V8Later", in: dir)
        opened.databases.append(try #require(DocumentManager.shared.projectDatabase))

        push.release()
        await push.task?.value
        #expect(editors.history.count == 1, "The superseded open must not publish over the newer one")
    }

    // MARK: - Window scoping of the broadcast

    /// Stands in for one window's editors: receives display posts through the SAME API the real
    /// coordinators use (which applies the window-token guard itself).
    @MainActor
    private final class WindowEditorStandIn {
        private(set) var received: [[AnnotationType: AnnotationDisplayMode]] = []
        private var observer: NSObjectProtocol?

        init(token: UUID) {
            observer = AnnotationDisplayBroadcast.addObserver(for: token, queue: nil) { [weak self] display in
                MainActor.assumeIsolated { self?.received.append(display.modes) }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    @Test("A post from one window's state reaches only that window's editors")
    @MainActor
    func broadcastReachesOnlyTheOwningWindowsEditors() {
        let windowA = EditorViewState()
        let windowB = EditorViewState()
        #expect(windowA.windowToken != windowB.windowToken)
        let editorsOfA = WindowEditorStandIn(token: windowA.windowToken)
        let editorsOfB = WindowEditorStandIn(token: windowB.windowToken)
        let aModes: [AnnotationType: AnnotationDisplayMode] = [.task: .inline, .comment: .collapsed, .reference: .inline]

        AnnotationDisplayBroadcast.post(modes: aModes, isPanelOnly: false, hideCompletedTasks: false, windowToken: windowA.windowToken)

        #expect(editorsOfA.received == [aModes], "The owning window's editors receive it")
        #expect(editorsOfB.received.isEmpty, "Another window's editors do not")

        // A post carrying no token at all reaches nobody. Spelled out with the wire name on purpose:
        // production code cannot post without a token (the name is private to the broadcast type).
        NotificationCenter.default.post(
            name: Notification.Name("annotationDisplayModesChanged"), object: nil, userInfo: ["modes": aModes, "isPanelOnly": false]
        )
        #expect(editorsOfA.received.count == 1)
        #expect(editorsOfB.received.isEmpty)
    }
}
