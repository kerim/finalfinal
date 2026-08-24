//
//  ExportSettingsResetNotificationTests.swift
//  final finalTests
//
//  Tier 1: Silent Killers
//  Regression coverage for ExportSettingsManager.resetToDefaults() silently leaving an open
//  document's citation formatting stale. Every individual CSL-style setter
//  (`useCustomCSLStyle`, `customCSLStylePath` -- see ExportSettings.swift, just below
//  `resetToDefaults()`) posts `.citationStyleChanged` so every open editor's
//  `MilkdownCoordinator` re-pushes the effective CSL style (see
//  MilkdownCoordinator+NotificationObservers.swift's `citationStyleObserver` /
//  `pushCitationStyle`). `resetToDefaults()` reset those same two fields back to their
//  defaults WITHOUT posting that notification -- so resetting back to the bundled style left
//  any already-open document showing the stale custom style until an unrelated trigger (e.g.
//  reopening the document) happened to re-push it. This suite proves resetToDefaults() now
//  posts the notification too, matching the setters.
//
//  Why a plain unit test, not an e2e/UI test: nothing in the app calls
//  ExportSettingsManager.resetToDefaults() today -- no Preferences pane wires a "Reset to
//  Defaults" button to it for export settings, unlike Appearance/Focus/Goal settings (see
//  PreferencesView+Presets.swift). With no user-visible flow to drive, there's nothing for an
//  XCUITest to click through -- and XCUITest itself drives the app out-of-process, over the
//  accessibility tree, so even a disposable UI test could not call this internal method
//  directly either way. This exercises the method itself instead.
//
//  Isolation: `ExportSettingsManager.shared` is a process-wide singleton whose `settings` is
//  cached in memory and mutated in place by `update()`/`resetToDefaults()` -- both this
//  test's own arrange-phase writes AND the `resetToDefaults()` call under test would
//  otherwise leave changed state for every later test/suite that touches the same singleton.
//  This captures `manager.settings` up front and restores it via `defer`
//  (`DiagnosticsSettingsTests.swift` uses the same shape for its own `.shared` singleton), and
//  additionally points `ExportSettings.userDefaults` at a throwaway per-test suite for the
//  duration -- `resetToDefaults()` calls `settings.save()` unconditionally, same as every
//  other settings mutation. `.serialized` orders this suite's own tests only (Swift Testing
//  runs suites concurrently by default).
//

import Testing
import Foundation
@testable import final_final

@MainActor
@Suite(.serialized)
struct ExportSettingsResetNotificationTests {

    @Test("resetToDefaults() posts .citationStyleChanged, matching the individual CSL-style setters")
    func resetToDefaultsPostsCitationStyleChanged() {
        let manager = ExportSettingsManager.shared
        let previousSettings = manager.settings

        let suiteName = "com.kerim.final-final.tests.exportSettingsManagerReset.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        let previousStore = ExportSettings.userDefaults
        ExportSettings.userDefaults = testDefaults
        defer {
            ExportSettings.userDefaults = previousStore
            testDefaults.removePersistentDomain(forName: suiteName)
            manager.update { $0 = previousSettings }
        }

        // Arrange: move away from the default CSL settings via the individual setters, so
        // resetToDefaults() actually has something to revert instead of a no-op. (Those
        // setters post their own .citationStyleChanged too -- the counting observer below is
        // installed only after this, so those posts are never counted.)
        manager.useCustomCSLStyle = true
        manager.customCSLStylePath = "/tmp/my-style.csl"

        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .citationStyleChanged, object: nil, queue: .main
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        manager.resetToDefaults()

        // Drain the main run loop to process the posted notification -- addObserver(queue:)
        // schedules its block asynchronously even when posted from the main thread (same
        // pattern as DocumentManagerOpenTests.swift's notification test).
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        #expect(
            notificationCount == 1,
            ".citationStyleChanged must be posted by resetToDefaults(), matching useCustomCSLStyle/customCSLStylePath's own setters"
        )
        #expect(manager.settings.useCustomCSLStyle == false)
        #expect(manager.settings.customCSLStylePath == nil)
    }
}
