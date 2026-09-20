//
//  AnnotationDisplayPersistenceTests.swift
//  final finalTests
//
//  Tier 1: the five annotation display settings persist per project, and NOTHING
//  but a user-action setter ever writes them (t-345ae20c).
//

import Testing
import Foundation
@testable import final_final

@Suite(.serialized)
struct AnnotationDisplayPersistenceTests {

    // The helpers below are internal (not private) because
    // AnnotationDisplayPersistenceTests+FocusMode.swift, an extension of this suite in another
    // file, shares them -- the same suite, so its tests stay serialized with these.

    func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp/claude/AnnotationDisplay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        TestFixtureCleanup.register(dir)
        return dir
    }

    @MainActor
    func openFixture(named name: String, in dir: URL) throws {
        let url = dir.appendingPathComponent("\(name).ff")
        try TestFixtureFactory.createFixture(at: url, title: name)
        _ = try DocumentManager.shared.openProject(at: url)
    }

    /// A full display-settings value: every type Inline unless `modes` names it, the two
    /// checkboxes as given. Keeps the tests' expectations readable.
    func displaySettings(
        _ modes: [AnnotationType: AnnotationDisplayMode] = [:], panelOnly: Bool = false, hideCompleted: Bool = false
    ) -> AnnotationDisplaySettings {
        AnnotationDisplaySettings(
            modes: Dictionary(uniqueKeysWithValues: AnnotationType.allCases.map { ($0, modes[$0] ?? .inline) }),
            isPanelOnlyMode: panelOnly,
            hideCompletedTasks: hideCompleted
        )
    }

    /// Stores the app-wide default (all five values) through its one write path and returns the
    /// value it had, for the caller to restore in a `defer` -- the default lives in a
    /// process-wide store that persists across tests, so a test that asserts a "default"
    /// outcome sets its own default first and never assumes it is unset.
    @MainActor
    func setGlobalDefaults(_ settings: AnnotationDisplaySettings) -> AnnotationDisplaySettings {
        let original = AnnotationDisplayDefaults.settings
        AnnotationDisplayDefaults.setSettings(settings)
        #expect(AnnotationDisplayDefaults.settings == settings)
        return original
    }

    @Test("A saved display mode round-trips through the project database")
    @MainActor
    func displayModeRoundTrips() throws {
        let dir = try makeTempDir()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir) }
        try openFixture(named: "RoundTrip", in: dir)

        try DocumentManager.shared.saveAnnotationDisplayMode(.collapsed, for: .comment)
        try DocumentManager.shared.saveAnnotationPanelOnly(true)
        try DocumentManager.shared.saveAnnotationHideCompleted(true)

        let loaded = try #require(try DocumentManager.shared.loadAnnotationDisplaySettings())
        #expect(loaded.modes[.comment] == .collapsed)
        #expect(loaded.isPanelOnlyMode == true)
        #expect(loaded.hideCompletedTasks == true)
    }

    @Test("Missing keys fall back to the stored default's five values")
    @MainActor
    func missingKeysFallBackToDefault() throws {
        let dir = try makeTempDir()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir) }
        try openFixture(named: "Fallback", in: dir)

        // A default that differs from the built-in in every option that can differ.
        let stored = displaySettings([.comment: .collapsed], panelOnly: true, hideCompleted: true)
        let originalDefaults = setGlobalDefaults(stored)
        defer { AnnotationDisplayDefaults.setSettings(originalDefaults) }

        let loaded = try #require(try DocumentManager.shared.loadAnnotationDisplaySettings())
        #expect(loaded == stored, "A project that saved nothing loads all five values from the default")
        #expect(loaded.modes[.comment] == .collapsed)
        #expect(loaded.modes[.task] == .inline)
        #expect(loaded.isPanelOnlyMode == true)
        #expect(loaded.hideCompletedTasks == true)
    }

    @Test("Opening, loading, resetting, closing and reopening a project writes no annotation settings rows")
    @MainActor
    func openAndCloseWriteNothing() throws {
        let dir = try makeTempDir()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir) }
        let url = dir.appendingPathComponent("NoWrites.ff")
        try TestFixtureFactory.createFixture(at: url, title: "NoWrites")
        _ = try DocumentManager.shared.openProject(at: url)

        // Everything project open does with these settings: load them, apply them, and reset
        // the state for the next project.
        let state = EditorViewState()
        state.applyAnnotationDisplaySettings(try DocumentManager.shared.loadAnnotationDisplaySettings())
        state.resetForProjectSwitch()

        // Close the project, then reopen it and read the rows back: a write at close time
        // would show up here. The app only drops its reference on close, so the first
        // connection is closed explicitly (see TestDatabaseTeardown) before the reopen.
        let firstDatabase = try #require(DocumentManager.shared.projectDatabase)
        DocumentManager.shared.closeProject()
        TestDatabaseTeardown.close(firstDatabase.dbWriter)
        _ = try DocumentManager.shared.openProject(at: url)

        let db = try #require(DocumentManager.shared.projectDatabase)
        for key in AnnotationDisplaySettingsKeys.all {
            #expect(try db.getSetting(key: key) == nil, "Open/load/reset/close must never write \(key)")
        }
    }

    // MUST-FIX 1: fails if enterFocusMode is ever routed through a saving setter.
    @Test("Focus Mode's forced collapse is never written to disk")
    @MainActor
    func focusModeForcedCollapseIsNeverPersisted() throws {
        let dir = try makeTempDir()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir) }
        try openFixture(named: "FocusMode", in: dir)
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        defer { FullScreenManager.resetForTesting() }
        let originalInlineAnnotations = turnOnFocusCollapse()
        defer { FocusModeSettingsManager.shared.inlineAnnotations = originalInlineAnnotations }

        let state = EditorViewState()
        for type in AnnotationType.allCases {
            state.setAnnotationDisplayMode(.inline, for: type)
        }
        let db = try #require(DocumentManager.shared.projectDatabase)

        state.enterFocusMode()
        // In memory Focus Mode forces collapsed...
        #expect(state.annotationDisplayModes[.comment] == .collapsed)
        // ...but nothing reached disk. This assertion is what fails if entry is
        // "tidied" into setAnnotationDisplayMode.
        for type in AnnotationType.allCases {
            #expect(try db.getSetting(key: AnnotationDisplaySettingsKeys.mode(type)) == "inline")
        }

        state.exitFocusMode()
        #expect(state.annotationDisplayModes[.comment] == .inline)
        for type in AnnotationType.allCases {
            #expect(try db.getSetting(key: AnnotationDisplaySettingsKeys.mode(type)) == "inline")
        }
    }

    // Acceptance bar: this test FAILS if the snapshot-update line in
    // `setAnnotationDisplayMode` (`preFocusModeState?.annotationDisplayModes?[type] = mode`)
    // is removed. Entry captures Comment as .inline; the user then chooses .collapsed inside
    // Focus Mode. Without the snapshot update, exiting Focus Mode restores the captured
    // .inline over the user's choice, so the in-memory value reads .inline here (and the
    // first #expect below fails) while the database, written by the setter itself, already
    // says "collapsed".
    @Test("A change made inside Focus Mode survives exiting it")
    @MainActor
    func changeInsideFocusModeSurvivesExit() throws {
        let dir = try makeTempDir()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir) }
        try openFixture(named: "FocusInside", in: dir)
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        defer { FullScreenManager.resetForTesting() }
        let originalInlineAnnotations = turnOnFocusCollapse()
        defer { FocusModeSettingsManager.shared.inlineAnnotations = originalInlineAnnotations }

        let state = EditorViewState()
        #expect(state.annotationDisplayModes[.comment] == .inline)   // what entry will capture
        state.enterFocusMode()
        #expect(state.annotationDisplayModes[.comment] == .collapsed)   // forced by Focus Mode
        state.setAnnotationDisplayMode(.collapsed, for: .comment)   // the user's own choice
        state.exitFocusMode()

        #expect(state.annotationDisplayModes[.comment] == .collapsed)
        let db = try #require(DocumentManager.shared.projectDatabase)
        #expect(try db.getSetting(key: AnnotationDisplaySettingsKeys.mode(.comment)) == "collapsed")
    }

    // Acceptance bar: this test FAILS if the persist call inside either setter is removed --
    // each checkbox's row is asserted on its own, both ways round.
    @Test("Panel Only and Hide Completed persist through the real setters")
    @MainActor
    func panelOnlyAndHideCompletedPersistThroughSetters() throws {
        let dir = try makeTempDir()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir) }
        try openFixture(named: "Checkboxes", in: dir)

        // A state loaded from the project, the way project open leaves it.
        let state = EditorViewState()
        state.applyAnnotationDisplaySettings(try DocumentManager.shared.loadAnnotationDisplaySettings())
        let db = try #require(DocumentManager.shared.projectDatabase)
        #expect(try db.getSetting(key: AnnotationDisplaySettingsKeys.panelOnly) == nil)
        #expect(try db.getSetting(key: AnnotationDisplaySettingsKeys.hideCompleted) == nil)

        state.setPanelOnlyMode(true)
        state.setHideCompletedTasks(true)
        #expect(state.isPanelOnlyMode == true)
        #expect(state.hideCompletedTasks == true)
        #expect(try db.getSetting(key: AnnotationDisplaySettingsKeys.panelOnly) == "true")
        #expect(try db.getSetting(key: AnnotationDisplaySettingsKeys.hideCompleted) == "true")

        state.setPanelOnlyMode(false)
        state.setHideCompletedTasks(false)
        #expect(state.isPanelOnlyMode == false)
        #expect(state.hideCompletedTasks == false)
        #expect(try db.getSetting(key: AnnotationDisplaySettingsKeys.panelOnly) == "false")
        #expect(try db.getSetting(key: AnnotationDisplaySettingsKeys.hideCompleted) == "false")
    }

    // MUST-FIX 2: the nil / throw path must still reset all five values.
    @Test("A nil load still resets every value to the defaults, writing nothing")
    @MainActor
    func nilLoadStillResetsEverything() throws {
        let dir = try makeTempDir()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir) }
        try openFixture(named: "NilLoad", in: dir)
        // nil means "the stored default" (AnnotationDisplaySettings.fallback), so the default
        // is set to values that differ from both the built-in ones and the seeded state below.
        let stored = displaySettings([.task: .collapsed, .reference: .collapsed], panelOnly: true, hideCompleted: true)
        let originalDefaults = setGlobalDefaults(stored)
        defer { AnnotationDisplayDefaults.setSettings(originalDefaults) }

        // Seed different IN-MEMORY state, as if a previous project had been open.
        let state = EditorViewState()
        state.annotationDisplayModes = [.task: .inline, .comment: .collapsed, .reference: .inline]
        state.isPanelOnlyMode = false
        state.hideCompletedTasks = false

        state.applyAnnotationDisplaySettings(nil)   // what the load path does on nil/throw

        #expect(state.annotationDisplayModes == stored.modes)
        #expect(state.isPanelOnlyMode == stored.isPanelOnlyMode)
        #expect(state.hideCompletedTasks == stored.hideCompletedTasks)

        let db = try #require(DocumentManager.shared.projectDatabase)
        for key in AnnotationDisplaySettingsKeys.all {
            #expect(try db.getSetting(key: key) == nil, "Applying settings must never write \(key)")
        }
    }

    // MARK: - Project switch reset

    @Test("A project switch resets the display properties to the neutral state, never the stored default; the next load lands on the default")
    @MainActor
    func projectSwitchResetsDisplaySettingsWithoutWriting() throws {
        let dir = try makeTempDir()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir) }
        try openFixture(named: "SwitchReset", in: dir)
        // The default differs from the neutral state AND from the previous project's values, so
        // neither assertion below can pass by accident.
        let stored = displaySettings([.task: .collapsed, .reference: .collapsed], panelOnly: true, hideCompleted: true)
        let originalDefaults = setGlobalDefaults(stored)
        defer { AnnotationDisplayDefaults.setSettings(originalDefaults) }

        // The previous project's values, still on screen.
        let state = EditorViewState()
        state.annotationDisplayModes = [.task: .collapsed, .comment: .collapsed, .reference: .collapsed]
        state.isPanelOnlyMode = true
        state.hideCompletedTasks = true

        state.resetForProjectSwitch()

        // The reset is neutral -- NOT the stored default (its Panel Only would broadcast "hide every
        // inline annotation" to the editors mid-switch, before the incoming project's own load).
        #expect(state.annotationDisplayModes == AnnotationDisplaySettings.neutral.modes)
        #expect(state.isPanelOnlyMode == false)
        #expect(state.hideCompletedTasks == false)

        // The LOAD of a project with no saved values is what lands on the stored default.
        state.loadAndApplyAnnotationDisplaySettings()
        #expect(state.annotationDisplayModes == stored.modes)
        #expect(state.isPanelOnlyMode == stored.isPanelOnlyMode)
        #expect(state.hideCompletedTasks == stored.hideCompletedTasks)

        let db = try #require(DocumentManager.shared.projectDatabase)
        for key in AnnotationDisplaySettingsKeys.all {
            #expect(try db.getSetting(key: key) == nil, "A project-switch reset and load must never write \(key)")
        }
    }

    @Test("A project switch during Focus Mode never restores the old project's modes on exit")
    @MainActor
    func projectSwitchDoesNotCarryFocusSnapshotModesIntoNextProject() {
        TestMode.clearTestState()
        FullScreenManager.resetForTesting()
        defer { FullScreenManager.resetForTesting() }
        let originalInlineAnnotations = turnOnFocusCollapse()
        defer { FocusModeSettingsManager.shared.inlineAnnotations = originalInlineAnnotations }
        // Comment is Inline in the default, so it cannot be mistaken for project A's Collapsed one,
        // and Task is Collapsed in it, so the neutral reset cannot be mistaken for the default.
        let stored = displaySettings([.task: .collapsed], panelOnly: false, hideCompleted: false)
        let originalDefaults = setGlobalDefaults(stored)
        defer { AnnotationDisplayDefaults.setSettings(originalDefaults) }

        // Project A has Comment collapsed when Focus Mode is entered, so the snapshot captures it.
        let state = EditorViewState()
        state.annotationDisplayModes[.comment] = .collapsed
        state.enterFocusMode()
        #expect(state.preFocusModeState?.annotationDisplayModes?[.comment] == .collapsed)

        // Switching projects drops ONLY the captured modes: the rest of the snapshot is kept,
        // or exiting Focus Mode would no longer leave full screen or re-show the sidebars.
        state.resetForProjectSwitch()
        #expect(state.preFocusModeState != nil)
        #expect(state.preFocusModeState?.annotationDisplayModes == nil)

        // Exit: nothing of project A's is restored; the reset left the neutral state (project B's
        // own load applies its values afterwards, in production).
        state.exitFocusMode()
        #expect(state.annotationDisplayModes == AnnotationDisplaySettings.neutral.modes)
        #expect(state.annotationDisplayModes[.comment] == .inline)
    }

    // MARK: - The stored default

    @Test("The default display settings are written to the isolated test store, all five values")
    @MainActor
    func defaultPreferenceIsTestIsolated() throws {
        let key = AnnotationDisplayDefaults.defaultsKey
        // The hosted test process IS the real app, so `.standard` here is the user's own domain:
        // whatever it holds for this key must be exactly the same after the write below.
        let standardBefore = UserDefaults.standard.object(forKey: key) as? Data

        let stored = displaySettings([.comment: .collapsed], panelOnly: true, hideCompleted: true)
        let originalDefaults = setGlobalDefaults(stored)
        defer { AnnotationDisplayDefaults.setSettings(originalDefaults) }

        #expect(TestMode.isTesting)
        let data = try #require(AppDefaults.store.data(forKey: key), "Written to the isolated store")
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let modes = try #require(object["modes"] as? [String: String])
        #expect(modes.count == AnnotationType.allCases.count)
        #expect(modes[AnnotationType.comment.rawValue] == "collapsed")
        #expect(modes[AnnotationType.task.rawValue] == "inline")
        #expect(object["panelOnly"] as? Bool == true)
        #expect(object["hideCompleted"] as? Bool == true)
        #expect(UserDefaults.standard.object(forKey: key) as? Data == standardBefore, "Nothing reached the real user's defaults")
    }
}

// A separate extension, not more struct body: keeps the suite struct under SwiftLint's type-body
// limit. It is still part of the same serialized suite and reuses its private helpers.
extension AnnotationDisplayPersistenceTests {
    // Panel Only disables the per-type pickers but must never touch the per-type modes: not the
    // in-memory values the greyed-out pickers keep showing, and not the stored rows.
    @Test("Toggling Panel Only on and off leaves the saved per-type modes unchanged")
    @MainActor
    func panelOnlyToggleNeverChangesPerTypeModes() throws {
        let dir = try makeTempDir()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir) }
        try openFixture(named: "PanelOnlyModes", in: dir)

        let state = EditorViewState()
        state.applyAnnotationDisplaySettings(try DocumentManager.shared.loadAnnotationDisplaySettings())
        state.setAnnotationDisplayMode(.collapsed, for: .comment)
        state.setAnnotationDisplayMode(.inline, for: .task)
        state.setAnnotationDisplayMode(.inline, for: .reference)
        let db = try #require(DocumentManager.shared.projectDatabase)
        let expectedStored: [AnnotationType: String] = [.comment: "collapsed", .task: "inline", .reference: "inline"]

        func expectModesUnchanged() throws {
            for (type, stored) in expectedStored {
                #expect(state.annotationDisplayModes[type]?.rawValue == stored, "\(type) in memory")
                #expect(try db.getSetting(key: AnnotationDisplaySettingsKeys.mode(type)) == stored, "\(type) stored")
            }
        }

        try expectModesUnchanged()
        state.setPanelOnlyMode(true)
        #expect(try db.getSetting(key: AnnotationDisplaySettingsKeys.panelOnly) == "true")
        try expectModesUnchanged()
        state.setPanelOnlyMode(false)
        #expect(try db.getSetting(key: AnnotationDisplaySettingsKeys.panelOnly) == "false")
        try expectModesUnchanged()
    }

    // MARK: - Set as Default (the popover's action)

    // Acceptance bar: fails if the action stores anything less than the whole value -- e.g. only
    // the three modes, or only the checkboxes.
    @Test("Set as Default stores all five of the user's current values")
    @MainActor
    func setAsDefaultStoresAllFiveValues() throws {
        let dir = try makeTempDir()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir) }
        try openFixture(named: "SetDefaultAll", in: dir)
        let originalDefaults = setGlobalDefaults(displaySettings())
        defer { AnnotationDisplayDefaults.setSettings(originalDefaults) }

        let state = EditorViewState()
        state.loadAndApplyAnnotationDisplaySettings()
        state.setAnnotationDisplayMode(.inline, for: .task)
        state.setAnnotationDisplayMode(.collapsed, for: .comment)
        state.setAnnotationDisplayMode(.collapsed, for: .reference)
        state.setPanelOnlyMode(true)
        state.setHideCompletedTasks(true)
        let toastBefore = ToastCenter.shared.current?.id
        let queuedBefore = ToastCenter.shared.pending?.toast.id

        state.saveCurrentAnnotationDisplayAsDefault()

        let expected = displaySettings([.comment: .collapsed, .reference: .collapsed], panelOnly: true, hideCompleted: true)
        #expect(AnnotationDisplayDefaults.settings == expected)
        // The popover's footer button is the ONLY success channel: the action shows no toast (a toast
        // can be swallowed behind a standing warning toast, so it would not be a reliable report).
        #expect(ToastCenter.shared.current?.id == toastBefore, "Set as Default shows no toast of its own")
        #expect(ToastCenter.shared.pending?.toast.id == queuedBefore, "and queues none behind a warning")
    }

    // Acceptance bar: fails if the action is ever routed through a saving setter -- it would then
    // create rows in the open project, which must keep exactly the rows the user's own clicks wrote.
    @Test("Set as Default writes no rows to the open project")
    @MainActor
    func setAsDefaultWritesNoProjectRows() throws {
        let dir = try makeTempDir()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir) }
        try openFixture(named: "SetDefaultNoRows", in: dir)
        let originalDefaults = setGlobalDefaults(displaySettings())
        defer { AnnotationDisplayDefaults.setSettings(originalDefaults) }
        let db = try #require(DocumentManager.shared.projectDatabase)

        // A project that saved nothing: the values on screen are direct assignments, not saves.
        let state = EditorViewState()
        state.loadAndApplyAnnotationDisplaySettings()
        state.annotationDisplayModes[.comment] = .collapsed
        state.isPanelOnlyMode = true
        state.hideCompletedTasks = true
        #expect(try db.getSettings(keys: AnnotationDisplaySettingsKeys.all).isEmpty)

        state.saveCurrentAnnotationDisplayAsDefault()

        // The action really stored something (so the empty table below is not "nothing happened")...
        #expect(AnnotationDisplayDefaults.settings == displaySettings([.comment: .collapsed], panelOnly: true, hideCompleted: true))
        // ...and no key was written, whatever the value on screen.
        for key in AnnotationDisplaySettingsKeys.all {
            #expect(try db.getSetting(key: key) == nil, "Set as Default must never write \(key)")
        }

        // A project WITH saved rows keeps exactly those rows: it is neither added to nor rewritten.
        state.setAnnotationDisplayMode(.collapsed, for: .task)
        let rowsBefore = try db.getSettings(keys: AnnotationDisplaySettingsKeys.all)
        #expect(rowsBefore == [AnnotationDisplaySettingsKeys.mode(.task): "collapsed"])
        state.saveCurrentAnnotationDisplayAsDefault()
        #expect(try db.getSettings(keys: AnnotationDisplaySettingsKeys.all) == rowsBefore)
    }

    @Test("A project with no saved rows opens with the stored default's five values")
    @MainActor
    func projectWithNoRowsOpensWithTheStoredDefault() throws {
        let dir = try makeTempDir()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir) }
        let stored = displaySettings([.comment: .collapsed, .reference: .collapsed], panelOnly: true, hideCompleted: true)
        let originalDefaults = setGlobalDefaults(stored)
        defer { AnnotationDisplayDefaults.setSettings(originalDefaults) }
        try openFixture(named: "OpensWithDefault", in: dir)

        // The state a fresh window is in, then exactly what project open does.
        let state = EditorViewState()
        state.loadAndApplyAnnotationDisplaySettings()

        #expect(state.annotationDisplayModes == stored.modes)
        #expect(state.annotationDisplayModes[.task] == .inline)
        #expect(state.annotationDisplayModes[.comment] == .collapsed)
        #expect(state.annotationDisplayModes[.reference] == .collapsed)
        #expect(state.isPanelOnlyMode == true, "Panel Only comes from the default")
        #expect(state.hideCompletedTasks == true, "Hide Completed comes from the default")
        let db = try #require(DocumentManager.shared.projectDatabase)
        #expect(try db.getSettings(keys: AnnotationDisplaySettingsKeys.all).isEmpty, "Inheriting a default writes nothing")
    }

    @Test("A project's own saved row beats the default, per option")
    @MainActor
    func projectsOwnRowBeatsTheDefaultPerOption() throws {
        let dir = try makeTempDir()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir) }
        let stored = displaySettings([.comment: .collapsed, .reference: .collapsed], panelOnly: true, hideCompleted: true)
        let originalDefaults = setGlobalDefaults(stored)
        defer { AnnotationDisplayDefaults.setSettings(originalDefaults) }
        try openFixture(named: "OwnRowWins", in: dir)

        // The project saved ONLY Panel Only, and saved it off; everything else follows the default.
        try DocumentManager.shared.saveAnnotationPanelOnly(false)
        var loaded = try #require(try DocumentManager.shared.loadAnnotationDisplaySettings())
        #expect(loaded.isPanelOnlyMode == false, "The project's own row wins over the default's Panel Only")
        #expect(loaded.modes == stored.modes, "The other four options come from the default")
        #expect(loaded.hideCompletedTasks == true)

        // The same holds for a mode: Reference saved Inline beats the default's Collapsed, Comment still follows it.
        try DocumentManager.shared.saveAnnotationDisplayMode(.inline, for: .reference)
        loaded = try #require(try DocumentManager.shared.loadAnnotationDisplaySettings())
        #expect(loaded.modes[.reference] == .inline)
        #expect(loaded.modes[.comment] == .collapsed)
        #expect(loaded.modes[.task] == .inline)
    }

    // Acceptance bar: fails if an unreadable boolean row is read as "false" -- that would look like
    // the user had unticked a box they never touched.
    @Test("A malformed row falls back to the default, not to false")
    @MainActor
    func malformedRowFallsBackToTheDefault() throws {
        let dir = try makeTempDir()
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir) }
        let stored = displaySettings([.comment: .collapsed], panelOnly: true, hideCompleted: true)
        let originalDefaults = setGlobalDefaults(stored)
        defer { AnnotationDisplayDefaults.setSettings(originalDefaults) }
        try openFixture(named: "MalformedRow", in: dir)
        let db = try #require(DocumentManager.shared.projectDatabase)

        try db.setSetting(key: AnnotationDisplaySettingsKeys.hideCompleted, value: "maybe")
        try db.setSetting(key: AnnotationDisplaySettingsKeys.panelOnly, value: "yes")
        try db.setSetting(key: AnnotationDisplaySettingsKeys.mode(.comment), value: "sideways")

        let loaded = try #require(try DocumentManager.shared.loadAnnotationDisplaySettings())
        #expect(loaded.hideCompletedTasks == true, "An unreadable Hide Completed row means the default (on), not off")
        #expect(loaded.isPanelOnlyMode == true, "A non-boolean Panel Only row means the default (on), not off")
        #expect(loaded.modes[.comment] == .collapsed, "An unrecognised mode row means the default")
    }
}
