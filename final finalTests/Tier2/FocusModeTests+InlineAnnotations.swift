//
//  FocusModeTests+InlineAnnotations.swift
//  final finalTests
//
//  Tier 2: Focus Mode's "Inline Annotations" preference (Leave As Is / Collapse / Hide) is
//  separate from "Hide Annotations Panel"; it is decoded (with a migration from the old single
//  toggle) and re-armed when it changes mid-Focus. An extension of `FocusModeTests` in its own
//  file so the suite's type stays within SwiftLint's size limits; same suite, so these tests are
//  serialized with the rest (they change the process-wide FocusModeSettingsManager singleton).
//

import Testing
import Foundation
import Observation
@testable import final_final

/// Counts posts of a notification. A class because the observer closure is `@Sendable` and
/// cannot mutate a captured local; `@MainActor` so the count is only ever touched on the main
/// actor. Observers here are registered with `queue: nil` and the posts come from main-actor
/// tests, so delivery is synchronous on the main thread and `MainActor.assumeIsolated` is exact
/// (it would trap, not race, if that ever stopped being true).
@MainActor
private final class NotificationCounter {
    var count = 0
}

extension FocusModeTests {

    // MARK: - Helpers

    /// Sets the Focus preferences for one test and returns the originals, for the caller to
    /// restore in a `defer` (`FocusModeSettingsManager.shared` is a process-wide singleton).
    @MainActor
    private func armFocusPreferences(hidePanel: Bool = true, inline: FocusInlineAnnotationMode) -> FocusModeSettings {
        let original = FocusModeSettingsManager.shared.settings
        FocusModeSettingsManager.shared.update {
            $0.hideRightSidebar = hidePanel
            $0.inlineAnnotations = inline
        }
        return original
    }

    @MainActor
    private func restoreFocusPreferences(_ original: FocusModeSettings) {
        FocusModeSettingsManager.shared.update { $0 = original }
    }

    /// The project's own per-type display modes for these tests (Comment collapsed, so a forced
    /// collapse is distinguishable from the starting state).
    private var ownModes: [AnnotationType: AnnotationDisplayMode] {
        [.task: .inline, .comment: .collapsed, .reference: .inline]
    }

    private func decodeFocusSettings(_ json: String) throws -> FocusModeSettings {
        try JSONDecoder().decode(FocusModeSettings.self, from: Data(json.utf8))
    }

    /// A stored blob with every preference set to the NON-default value (false), except the panel
    /// toggle, which is as given, and with the given raw `inlineAnnotations` value.
    private func nonDefaultFocusBlob(panelToggle: Bool, inline: String) -> String {
        let fields = [
            #""hideLeftSidebar":false"#,
            #""hideRightSidebar":\#(panelToggle)"#,
            #""hideToolbar":false"#,
            #""hideStatusBar":false"#,
            #""enableParagraphHighlighting":false"#,
            #""inlineAnnotations":"\#(inline)""#
        ]
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// Opens a scratch project and returns its directory for `TestDatabaseTeardown`. The mid-Focus
    /// reconcile does nothing without an open project, so the tests of it need one.
    @MainActor
    private func openScratchProject(named name: String) throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp/claude/FocusInline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        TestFixtureCleanup.register(dir)
        let projectURL = dir.appendingPathComponent("\(name).ff")
        try TestFixtureFactory.createFixture(at: projectURL, title: name)
        _ = try DocumentManager.shared.openProject(at: projectURL)
        return dir
    }

    // MARK: - The three Inline Annotations choices

    @Test("Inline Annotations = Collapse forces every type collapsed and restores them on exit")
    @MainActor
    func inlineCollapseForcesEveryTypeAndRestoresOnExit() async {
        let sut = makeSUT()
        defer { FullScreenManager.resetForTesting() }
        let original = armFocusPreferences(inline: .collapse)
        defer { restoreFocusPreferences(original) }
        sut.annotationDisplayModes = ownModes

        sut.enterFocusMode()

        for type in AnnotationType.allCases {
            #expect(sut.annotationDisplayModes[type] == .collapsed)
        }
        #expect(sut.preFocusModeState?.annotationDisplayModes == ownModes, "The snapshot holds the project's own modes")
        #expect(sut.preFocusModeState?.annotationPanelOnly == nil)
        #expect(sut.isPanelOnlyMode == false, "Collapse never touches Panel Only")

        sut.exitFocusMode()

        #expect(sut.annotationDisplayModes == ownModes)
        #expect(sut.isPanelOnlyMode == false)
    }

    @Test("Inline Annotations = Hide sets Panel Only transiently and restores it on exit")
    @MainActor
    func inlineHideSetsPanelOnlyTransientlyAndRestoresOnExit() async {
        let sut = makeSUT()
        defer { FullScreenManager.resetForTesting() }
        let original = armFocusPreferences(inline: .hide)
        defer { restoreFocusPreferences(original) }
        sut.annotationDisplayModes = ownModes
        #expect(sut.isPanelOnlyMode == false)

        sut.enterFocusMode()

        #expect(sut.isPanelOnlyMode == true)
        #expect(sut.annotationDisplayModes == ownModes, "Hide leaves the per-type modes alone")
        #expect(sut.preFocusModeState?.annotationPanelOnly == false, "The snapshot holds the user's own Panel Only")
        #expect(sut.preFocusModeState?.annotationDisplayModes == nil)

        sut.exitFocusMode()

        #expect(sut.isPanelOnlyMode == false)
        #expect(sut.annotationDisplayModes == ownModes)
    }

    @Test("Inline Annotations = Leave As Is touches no inline state")
    @MainActor
    func inlineLeaveAsIsTouchesNoInlineState() async {
        let sut = makeSUT()
        defer { FullScreenManager.resetForTesting() }
        let original = armFocusPreferences(inline: .leaveAsIs)
        defer { restoreFocusPreferences(original) }
        sut.annotationDisplayModes = ownModes

        sut.enterFocusMode()

        #expect(sut.annotationDisplayModes == ownModes)
        #expect(sut.isPanelOnlyMode == false)
        #expect(sut.preFocusModeState?.annotationDisplayModes == nil)
        #expect(sut.preFocusModeState?.annotationPanelOnly == nil)

        sut.exitFocusMode()

        #expect(sut.annotationDisplayModes == ownModes)
        #expect(sut.isPanelOnlyMode == false)
    }

    // MARK: - Panel and inline are separate

    @Test("Hide Annotations Panel alone hides the panel and does not collapse inline annotations")
    @MainActor
    func hideAnnotationsPanelAloneDoesNotCollapseInline() async {
        let sut = makeSUT()
        defer { FullScreenManager.resetForTesting() }
        let original = armFocusPreferences(hidePanel: true, inline: .leaveAsIs)
        defer { restoreFocusPreferences(original) }
        sut.annotationDisplayModes = ownModes
        sut.isAnnotationPanelVisible = true

        sut.enterFocusMode()

        #expect(sut.isAnnotationPanelVisible == false, "The panel is hidden")
        #expect(sut.annotationDisplayModes == ownModes, "The annotations in the text are untouched")
        #expect(sut.isPanelOnlyMode == false)

        sut.exitFocusMode()

        #expect(sut.isAnnotationPanelVisible == true)
        #expect(sut.annotationDisplayModes == ownModes)
    }

    @Test("Collapse alone collapses inline annotations and does not hide the panel")
    @MainActor
    func collapseAloneDoesNotHideThePanel() async {
        let sut = makeSUT()
        defer { FullScreenManager.resetForTesting() }
        let original = armFocusPreferences(hidePanel: false, inline: .collapse)
        defer { restoreFocusPreferences(original) }
        sut.annotationDisplayModes = ownModes
        sut.isAnnotationPanelVisible = true

        sut.enterFocusMode()

        #expect(sut.isAnnotationPanelVisible == true, "The panel stays")
        for type in AnnotationType.allCases {
            #expect(sut.annotationDisplayModes[type] == .collapsed)
        }
        #expect(sut.preFocusModeState?.annotationPanelVisible == nil, "The panel was not touched, so it was not captured")

        sut.exitFocusMode()

        #expect(sut.annotationDisplayModes == ownModes)
    }

    @Test("Hide with the user's own Panel Only already on: captured true, no visible change, exit leaves it on, nothing written")
    @MainActor
    func hideOverrideWithUsersPanelOnlyAlreadyOn() async throws {
        let sut = makeSUT()
        defer { FullScreenManager.resetForTesting() }
        let original = armFocusPreferences(inline: .hide)
        defer { restoreFocusPreferences(original) }

        let dir = try openScratchProject(named: "PanelOnlyOn")
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir) }
        let database = try #require(DocumentManager.shared.projectDatabase)
        // The load below fills unsaved options from the process-wide app-wide default, which the
        // Tier 1 persistence suite also changes: pin it, restoring it after.
        let originalDefaults = AnnotationDisplayDefaults.settings
        AnnotationDisplayDefaults.setSettings(.neutral)
        defer { AnnotationDisplayDefaults.setSettings(originalDefaults) }

        // The user's own choice, saved before entering Focus Mode.
        sut.loadAndApplyAnnotationDisplaySettings()
        sut.setPanelOnlyMode(true)
        let rowsBefore = try database.getSettings(keys: AnnotationDisplaySettingsKeys.all)

        sut.enterFocusMode()

        #expect(sut.preFocusModeState?.annotationPanelOnly == true)
        #expect(sut.isPanelOnlyMode == true, "No visible change: it was already on")

        sut.exitFocusMode()

        #expect(sut.isPanelOnlyMode == true, "Exit leaves the user's own Panel Only on")
        #expect(try database.getSettings(keys: AnnotationDisplaySettingsKeys.all) == rowsBefore, "Focus Mode wrote nothing")
    }

    // MARK: - Decoding and the migration from the old toggle

    @Test("A legacy blob without inlineAnnotations takes it from the old Hide Annotations toggle")
    func legacyBlobMigratesFromTheOldToggle() throws {
        let toggleOn = try decodeFocusSettings(
            #"{"hideLeftSidebar":true,"hideRightSidebar":true,"hideToolbar":true,"hideStatusBar":true,"enableParagraphHighlighting":true}"#
        )
        #expect(toggleOn.inlineAnnotations == .collapse, "Toggle on kept collapsing inline annotations")

        let toggleOff = try decodeFocusSettings(
            #"{"hideLeftSidebar":true,"hideRightSidebar":false,"hideToolbar":false,"hideStatusBar":true,"enableParagraphHighlighting":true}"#
        )
        #expect(toggleOff.inlineAnnotations == .leaveAsIs, "Toggle off kept leaving them alone")
        #expect(toggleOff.hideRightSidebar == false)
        #expect(toggleOff.hideToolbar == false, "The other stored fields still decode")

        #expect(try decodeFocusSettings("{}").inlineAnnotations == .collapse, "No stored fields: the defaults apply")
    }

    @Test("A blob that already has inlineAnnotations keeps it, whatever the panel toggle says")
    func blobWithTheKeyKeepsIt() throws {
        #expect(try decodeFocusSettings(#"{"hideRightSidebar":false,"inlineAnnotations":"hide"}"#).inlineAnnotations == .hide)
        #expect(try decodeFocusSettings(#"{"hideRightSidebar":true,"inlineAnnotations":"leaveAsIs"}"#).inlineAnnotations == .leaveAsIs)

        // The current settings round-trip through the encoder and the migrating decoder unchanged.
        var settings = FocusModeSettings.default
        settings.inlineAnnotations = .hide
        settings.hideRightSidebar = false
        let encodedData = try JSONEncoder().encode(settings)
        let encoded = try #require(String(data: encodedData, encoding: .utf8))
        #expect(try decodeFocusSettings(encoded) == settings)
    }

    @Test("An unrecognised inlineAnnotations value falls back to the migration rule and keeps every other preference")
    @MainActor
    func unrecognisedInlineValueKeepsTheRestOfTheBlob() throws {
        // Panel toggle off: the fallback is the migration rule's Leave As Is. All five other
        // preferences are non-default (off) and must survive.
        let panelOff = try decodeFocusSettings(nonDefaultFocusBlob(panelToggle: false, inline: "hidden"))
        #expect(panelOff.inlineAnnotations == .leaveAsIs)
        #expect(panelOff.hideLeftSidebar == false)
        #expect(panelOff.hideRightSidebar == false)
        #expect(panelOff.hideToolbar == false)
        #expect(panelOff.hideStatusBar == false)
        #expect(panelOff.enableParagraphHighlighting == false)

        // Panel toggle on: the fallback is Collapse; the other four preferences still survive.
        let panelOn = try decodeFocusSettings(nonDefaultFocusBlob(panelToggle: true, inline: "hidden"))
        #expect(panelOn.inlineAnnotations == .collapse)
        #expect(panelOn.hideLeftSidebar == false)
        #expect(panelOn.hideToolbar == false)
        #expect(panelOn.hideStatusBar == false)
        #expect(panelOn.enableParagraphHighlighting == false)

        // Through load(): the blob is not discarded (a throw there would return .default).
        TestMode.clearTestState()
        defer { TestMode.clearTestState() }
        AppDefaults.store.set(
            Data(nonDefaultFocusBlob(panelToggle: false, inline: "hidden").utf8),
            forKey: "com.kerim.final-final.focusModeSettings"
        )
        let loaded = FocusModeSettings.load()
        #expect(loaded != FocusModeSettings.default)
        #expect(loaded.hideToolbar == false)
        #expect(loaded.inlineAnnotations == .leaveAsIs)
    }

    @Test("Loading a legacy stored blob migrates it in memory and writes nothing back")
    @MainActor
    func legacyStoredBlobMigratesWithoutWriting() {
        TestMode.clearTestState()
        defer { TestMode.clearTestState() }
        let key = "com.kerim.final-final.focusModeSettings"
        let legacy = Data(#"{"hideRightSidebar":false}"#.utf8)
        AppDefaults.store.set(legacy, forKey: key)

        #expect(FocusModeSettings.load().inlineAnnotations == .leaveAsIs)
        #expect(AppDefaults.store.data(forKey: key) == legacy, "The migration is decode-time only; the blob is untouched")
    }

    @Test("With no stored blob at all, the defaults carry Collapse and Hide Annotations Panel on")
    @MainActor
    func defaultSettingsCarryCollapse() {
        TestMode.clearTestState()
        defer { TestMode.clearTestState() }
        let loaded = FocusModeSettings.load()

        #expect(loaded == FocusModeSettings.default)
        #expect(loaded.hideRightSidebar == true)
        #expect(loaded.inlineAnnotations == .collapse)
    }

    // MARK: - Reset and change notifications

    @Test("Reset Focus Settings restores Inline Annotations to Collapse")
    @MainActor
    func resetToDefaultsRestoresInlineAnnotations() {
        let original = FocusModeSettingsManager.shared.settings
        defer { restoreFocusPreferences(original) }
        FocusModeSettingsManager.shared.update {
            $0.inlineAnnotations = .hide
            $0.hideRightSidebar = false
        }

        FocusModeSettingsManager.shared.resetToDefaults()

        #expect(FocusModeSettingsManager.shared.inlineAnnotations == .collapse)
        #expect(FocusModeSettingsManager.shared.hideRightSidebar == true)
        #expect(FocusModeSettingsManager.shared.settings == FocusModeSettings.default)
    }

    @Test("The change notification is posted only when Inline Annotations really changes")
    @MainActor
    func inlineAnnotationsChangePostsOnlyOnRealChange() {
        let original = FocusModeSettingsManager.shared.settings
        defer { restoreFocusPreferences(original) }
        let manager = FocusModeSettingsManager.shared
        manager.inlineAnnotations = .collapse   // a known starting point

        let counter = NotificationCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .focusInlineAnnotationsChanged, object: nil, queue: nil
        ) { _ in MainActor.assumeIsolated { counter.count += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }

        manager.inlineAnnotations = .collapse
        #expect(counter.count == 0, "Setting the same value posts nothing")
        manager.hideToolbar = !manager.hideToolbar
        #expect(counter.count == 0, "Another preference changing posts nothing")
        manager.inlineAnnotations = .leaveAsIs
        #expect(counter.count == 1)
    }

    @Test("Reset Focus Settings posts the change notification when it flips Inline Annotations")
    @MainActor
    func resetToDefaultsPostsWhenInlineAnnotationsChanges() {
        let original = FocusModeSettingsManager.shared.settings
        defer { restoreFocusPreferences(original) }
        let manager = FocusModeSettingsManager.shared
        manager.inlineAnnotations = .leaveAsIs   // the default is Collapse, so a reset flips it

        let counter = NotificationCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .focusInlineAnnotationsChanged, object: nil, queue: nil
        ) { _ in MainActor.assumeIsolated { counter.count += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }

        manager.resetToDefaults()
        #expect(manager.inlineAnnotations == .collapse)
        #expect(counter.count == 1, "A reset that changes Inline Annotations must reach an open project in Focus Mode")

        manager.resetToDefaults()
        #expect(counter.count == 1, "A reset that changes nothing posts nothing")
    }

    // MARK: - A preference change mid-Focus (reconcile)

    @Test("Switching Collapse to Leave As Is mid-Focus clears the stale override at once")
    @MainActor
    func reconcileClearsAStaleOverrideWhenThePreferenceChangesMidFocus() async throws {
        let dir = try openScratchProject(named: "ReconcileLeave")
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir) }
        let sut = makeSUT()
        defer { FullScreenManager.resetForTesting() }
        let original = armFocusPreferences(inline: .collapse)
        defer { restoreFocusPreferences(original) }
        sut.annotationDisplayModes = ownModes
        sut.enterFocusMode()
        for type in AnnotationType.allCases {
            #expect(sut.annotationDisplayModes[type] == .collapsed)
        }

        FocusModeSettingsManager.shared.inlineAnnotations = .leaveAsIs
        sut.reconcileFocusInlineOverride()   // what the change notification's observer calls

        #expect(sut.annotationDisplayModes == ownModes, "The project's own display is back immediately")
        #expect(sut.preFocusModeState?.annotationDisplayModes == nil)
        #expect(sut.preFocusModeState?.annotationPanelOnly == nil)

        sut.exitFocusMode()

        #expect(sut.annotationDisplayModes == ownModes, "Exit changes nothing further")
        #expect(sut.isPanelOnlyMode == false)
    }

    @Test("Switching Collapse to Hide mid-Focus swaps the collapse for the hide, and exit restores the user's Panel Only")
    @MainActor
    func reconcileSwapsCollapseForHideWhenThePreferenceChangesMidFocus() async throws {
        let dir = try openScratchProject(named: "ReconcileHide")
        defer { TestDatabaseTeardown.closeProjectThenCleanUp(dir) }
        let sut = makeSUT()
        defer { FullScreenManager.resetForTesting() }
        let original = armFocusPreferences(inline: .collapse)
        defer { restoreFocusPreferences(original) }
        sut.annotationDisplayModes = ownModes
        sut.enterFocusMode()

        FocusModeSettingsManager.shared.inlineAnnotations = .hide
        sut.reconcileFocusInlineOverride()

        #expect(sut.annotationDisplayModes == ownModes, "The collapse is undone")
        #expect(sut.isPanelOnlyMode == true, "Panel Only is now forced")
        #expect(sut.preFocusModeState?.annotationDisplayModes == nil)
        #expect(sut.preFocusModeState?.annotationPanelOnly == false, "Captured fresh: the user's own value")

        sut.exitFocusMode()

        #expect(sut.isPanelOnlyMode == false, "Exit restores the user's Panel Only")
        #expect(sut.annotationDisplayModes == ownModes)
    }

    // MARK: - No project open

    @Test("A preference change in Focus Mode with no project open arms nothing")
    @MainActor
    func reconcileWithNoProjectOpenArmsNothing() async {
        DocumentManager.shared.closeProject()   // make sure none is open (Focus Mode at the picker)
        let sut = makeSUT()
        defer { FullScreenManager.resetForTesting() }
        let original = armFocusPreferences(inline: .leaveAsIs)
        defer { restoreFocusPreferences(original) }
        sut.annotationDisplayModes = ownModes
        sut.enterFocusMode()   // Focus Mode on, nothing armed
        defer { sut.exitFocusMode() }
        #expect(DocumentManager.shared.hasOpenProject == false)

        // The app's own wiring, in miniature: the posted change reconciles. Plus two witnesses
        // that nothing reached this window's editors: a display observer for this window's token
        // (it would see a post if reconcile published the display state itself, or if the view
        // layer re-posted after a change of the modes or Panel Only), and a change of those values.
        let reconciler = NotificationCenter.default.addObserver(
            forName: .focusInlineAnnotationsChanged, object: nil, queue: nil
        ) { _ in MainActor.assumeIsolated { sut.reconcileFocusInlineOverride() } }
        defer { NotificationCenter.default.removeObserver(reconciler) }
        let displayPosts = NotificationCounter()
        let displayObserver = AnnotationDisplayBroadcast.addObserver(for: sut.windowToken, queue: nil) { _ in
            MainActor.assumeIsolated { displayPosts.count += 1 }
        }
        defer { NotificationCenter.default.removeObserver(displayObserver) }
        let observedChanges = NotificationCounter()
        withObservationTracking {
            _ = sut.annotationDisplayModes
            _ = sut.isPanelOnlyMode
        } onChange: {
            MainActor.assumeIsolated { observedChanges.count += 1 }
        }

        FocusModeSettingsManager.shared.inlineAnnotations = .collapse   // posts the change
        FocusModeSettingsManager.shared.inlineAnnotations = .hide

        #expect(sut.annotationDisplayModes == ownModes, "No collapse was armed")
        #expect(sut.isPanelOnlyMode == false, "No Panel Only was forced")
        #expect(sut.preFocusModeState?.annotationDisplayModes == nil)
        #expect(sut.preFocusModeState?.annotationPanelOnly == nil)
        #expect(displayPosts.count == 0, "Nothing was published for this window")
        #expect(observedChanges.count == 0)

        // The witness itself can fail: a post for THIS window is seen, one for another window is not.
        AnnotationDisplayBroadcast.post(modes: ownModes, isPanelOnly: false, hideCompletedTasks: false, windowToken: UUID())
        #expect(displayPosts.count == 0, "A post carrying another window's token is not received")
        AnnotationDisplayBroadcast.post(modes: ownModes, isPanelOnly: false, hideCompletedTasks: false, windowToken: sut.windowToken)
        #expect(displayPosts.count == 1, "A post carrying this window's token is")
    }

    // MARK: - The user's own Panel Only choice (drives the popover's per-type pickers)

    @Test("With Hide armed, the user's own Panel Only choice is the one that counts, not the forced one", arguments: [false, true])
    @MainActor
    func userPanelOnlyChoiceIsTheUsersOwnUnderHide(own: Bool) async {
        let sut = makeSUT()
        defer { FullScreenManager.resetForTesting() }
        let original = armFocusPreferences(inline: .hide)
        defer { restoreFocusPreferences(original) }
        sut.isPanelOnlyMode = own

        sut.enterFocusMode()

        #expect(sut.isPanelOnlyMode == true, "Hide forces the effective Panel Only on")
        #expect(sut.userPanelOnlyChoice == own, "Own off: the per-type pickers stay enabled; own on: disabled")

        sut.exitFocusMode()

        #expect(sut.userPanelOnlyChoice == own)
    }

    @Test("Without Hide forcing anything, the user's own Panel Only choice follows isPanelOnlyMode")
    @MainActor
    func userPanelOnlyChoiceFollowsIsPanelOnlyModeWithoutHide() async {
        let sut = makeSUT()
        defer { FullScreenManager.resetForTesting() }
        let original = armFocusPreferences(inline: .collapse)
        defer { restoreFocusPreferences(original) }

        // No Focus Mode.
        sut.isPanelOnlyMode = true
        #expect(sut.userPanelOnlyChoice == true)
        sut.isPanelOnlyMode = false
        #expect(sut.userPanelOnlyChoice == false)

        // Focus Mode with Collapse: Panel Only is not forced, so the user's own value stands.
        sut.isPanelOnlyMode = true
        sut.enterFocusMode()
        #expect(sut.userPanelOnlyChoice == true)
        sut.exitFocusMode()
        #expect(sut.userPanelOnlyChoice == true)
    }
}
